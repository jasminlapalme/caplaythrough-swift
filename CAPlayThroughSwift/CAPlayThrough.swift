//
//  CAPlayThrough.swift
//  CAPlayThroughSwift
//
//  Created by Jasmin Lapalme on 15-12-30.
//  Copyright © 2016 jPense. All rights reserved.
//

import Foundation
import AudioUnit;
import CoreAudio;
import AudioToolbox;

func mergeAudioBufferList(abl: UnsafeMutableAudioBufferListPointer, inNumberFrames: UInt32) -> [Float] {
	let umpab = abl.map({ return UnsafeMutablePointer<Float32>($0.mData) })
	var b = Array<Float>(count: Int(inNumberFrames), repeatedValue: 0);
	for (i, _) in b.enumerate() {
		b[i] = umpab.reduce(Float(0), combine: { (f: Float, ab: UnsafeMutablePointer<Float32>) -> Float in
			return f + ab[i];
		})
	}
	return b;
}

func inputProc(inRefCon: UnsafeMutablePointer<Void>, ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, inTimeStamp: UnsafePointer<AudioTimeStamp>, inBusNumber: UInt32, inNumberFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
	let This = Unmanaged<CAPlayThrough>.fromOpaque(COpaquePointer(inRefCon)).takeUnretainedValue()
	if (This.firstInputTime < 0) {
		This.firstInputTime = inTimeStamp.memory.mSampleTime;
	}
	
	// Get the new audio data
	if let err = checkErr(AudioUnitRender(This.inputUnit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, This.inputBuffer.unsafeMutablePointer)) {
		return err;
	}
	
	var samples = mergeAudioBufferList(This.inputBuffer, inNumberFrames: inNumberFrames);
	
	if (This.bufferManager.needsNewFFTData > 0) {
		This.dcRejectionFilter.processInplace(&samples);
		This.bufferManager.copyAudioDataToFFTInputBuffer(samples);
	}
	
	let ringBufferErr = This.buffer.store(This.inputBuffer, framesToWrite: inNumberFrames, startWrite: CARingBuffer.SampleTime(inTimeStamp.memory.mSampleTime))
	
	return ringBufferErr.toOSStatus();
}

func makeBufferSilent(ioData: UnsafeMutableAudioBufferListPointer) {
	for buf in ioData {
		memset(buf.mData, 0, Int(buf.mDataByteSize));
	}
}

func outputProc(inRefCon: UnsafeMutablePointer<Void>, ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, inTimeStamp: UnsafePointer<AudioTimeStamp>, inBusNumber: UInt32, inNumberFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
	let This = Unmanaged<CAPlayThrough>.fromOpaque(COpaquePointer(inRefCon)).takeUnretainedValue()
	var rate : Float64 = 0.0;
	var inTS = AudioTimeStamp();
	var outTS = AudioTimeStamp();
	let abl = UnsafeMutableAudioBufferListPointer(ioData)
	
	if (This.firstInputTime < 0) {
		// input hasn't run yet -> silence
		makeBufferSilent (abl);
		return noErr;
	}
	
	// use the varispeed playback rate to offset small discrepancies in sample rate
	// first find the rate scalars of the input and output devices
	// this callback may still be called a few times after the device has been stopped
	if (AudioDeviceGetCurrentTime(This.inputDevice.id, &inTS) != noErr) {
		makeBufferSilent (abl);
		return noErr;
	}
	
	if let err = checkErr(AudioDeviceGetCurrentTime(This.outputDevice.id, &outTS)) {
		return err;
	}
	
	rate = inTS.mRateScalar / outTS.mRateScalar;
	if let err = checkErr(AudioUnitSetParameter(This.varispeedUnit, kVarispeedParam_PlaybackRate, kAudioUnitScope_Global, 0, AudioUnitParameterValue(rate), 0)) {
		return err;
	}
	
	// get Delta between the devices and add it to the offset
	if (This.firstOutputTime < 0) {
		This.firstOutputTime = inTimeStamp.memory.mSampleTime;
		let delta = (This.firstInputTime - This.firstOutputTime);
		This.computeThruOffset();
		// changed: 3865519 11/10/04
		if (delta < 0.0) {
			This.inToOutSampleOffset -= delta;
		} else {
			This.inToOutSampleOffset = -delta + This.inToOutSampleOffset;
		}
		
		makeBufferSilent (abl);
		return noErr;
	}
	
	// copy the data from the buffers
	let err = This.buffer.fetch(abl, nFrames: inNumberFrames, startRead: Int64(inTimeStamp.memory.mSampleTime - This.inToOutSampleOffset));
	if (err != CARingBufferError.OK) {
		makeBufferSilent (abl);
		var bufferStartTime : Int64 = 0;
		var bufferEndTime : Int64 = 0;
		This.buffer.getTimeBounds(startTime: &bufferStartTime, endTime: &bufferEndTime);
		This.inToOutSampleOffset = inTimeStamp.memory.mSampleTime - Float64(bufferStartTime);
	}
	
	return noErr;
}

class CAPlayThrough {
	var inputUnit: AudioUnit = nil;
	var inputBuffer = UnsafeMutableAudioBufferListPointer(nil);
	var inputDevice: AudioDevice!;
	var outputDevice: AudioDevice!;
	
	var buffer = CARingBuffer();
	var bufferManager: BufferManager!;
	var dcRejectionFilter: DCRejectionFilter!;
	
	// AudioUnits and Graph
	var graph: AUGraph = nil;
	var varispeedNode: AUNode = 0;
	var varispeedUnit: AudioUnit = nil;
	var outputNode: AUNode = 0;
	var outputUnit: AudioUnit = nil;
	
	// Buffer sample info
	var firstInputTime: Float64 = -1;
	var firstOutputTime: Float64 = -1;
	var inToOutSampleOffset: Float64 = 0;
	
	init(input: AudioDeviceID, output: AudioDeviceID) {
		// Note: You can interface to input and output devices with "output" audio units.
		// Please keep in mind that you are only allowed to have one output audio unit per graph (AUGraph).
		// As you will see, this sample code splits up the two output units.  The "output" unit that will
		// be used for device input will not be contained in a AUGraph, while the "output" unit that will
		// interface the default output device will be in a graph.
		
		// Setup AUHAL for an input device
		if let _ = checkErr(setupAUHAL(input)) {
			exit(1);
		}
		
		// Setup Graph containing Varispeed Unit & Default Output Unit
		if let _ = checkErr(setupGraph(output)) {
			exit(1);
		}
		
		if let _ = checkErr(setupBuffers()) {
			exit(1);
		}
		
		// the varispeed unit should only be conected after the input and output formats have been set
		if let _ = checkErr(AUGraphConnectNodeInput(graph, varispeedNode, 0, outputNode, 0)) {
			exit(1);
		}
		
		if let _ = checkErr(AUGraphInitialize(graph)) {
			exit(1);
		}
		
		// Add latency between the two devices
		computeThruOffset();
	}
	
	deinit {
		cleanup()
	}
	
	func getInputDeviceID()	-> AudioDeviceID { return inputDevice.id;	}
	func getOutputDeviceID() -> AudioDeviceID { return outputDevice.id; }
	
	func cleanup() {
		stop();
		
		if inputBuffer.unsafePointer != nil {
			free(inputBuffer.unsafeMutablePointer)
		}
	}
	
	func start() -> OSStatus {
		if isRunning() {
			return noErr;
		}
		// Start pulling for audio data
		if let err = checkErr(AudioOutputUnitStart(inputUnit)) {
			return err;
		}
		
		if let err = checkErr(AUGraphStart(graph)) {
			return err;
		}
		
		// reset sample times
		firstInputTime = -1;
		firstOutputTime = -1;
		
		return noErr;
	}
	
	func stop() -> OSStatus {
		if !isRunning() {
			return noErr;
		}
		if let err = checkErr(AudioOutputUnitStop(inputUnit)) {
			return err;
		}
		if let err = checkErr(AUGraphStop(graph)) {
			return err;
		}
		firstInputTime = -1;
		firstOutputTime = -1;
		return noErr;
	}
	
	func isRunning() -> Bool {
		var auhalRunning : UInt32 = 0;
		
		var graphRunning : DarwinBoolean = false;
		var size : UInt32 = UInt32(sizeof(UInt32));
		if (inputUnit != nil) {
			if let _ = checkErr(AudioUnitGetProperty(inputUnit, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0, &auhalRunning, &size)) {
				return false;
			}
		}
		
		if (graph != nil) {
			if let _ = checkErr(AUGraphIsRunning(graph, &graphRunning)) {
				return false;
			}
		}
		return (auhalRunning > 0 || graphRunning);
	}
	
	func setOutputDeviceAsCurrent(var out: AudioDeviceID) -> OSStatus {
		var size = UInt32(sizeof(AudioDeviceID));
		
		var theAddress = AudioObjectPropertyAddress(
			mSelector: kAudioHardwarePropertyDefaultOutputDevice,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMaster
		);
		
		if (out == kAudioDeviceUnknown) {
			if let err = checkErr(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &theAddress, 0, nil,
				&size, &out)) {
					return err;
			}
		}
		outputDevice = AudioDevice(devid: out, isInput: false);
		
		// Set the Current Device to the Default Output Unit.
		return AudioUnitSetProperty(outputUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
			&outputDevice.id, UInt32(sizeof(AudioDeviceID)));
	}
	
	func setInputDeviceAsCurrent(var input: AudioDeviceID) -> OSStatus {
		var size = UInt32(sizeof(AudioDeviceID));
		
		var theAddress = AudioObjectPropertyAddress(
			mSelector: kAudioHardwarePropertyDefaultInputDevice,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMaster
		);
		
		if (input == kAudioDeviceUnknown) {
			if let err = checkErr(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &theAddress, 0, nil,
				&size, &input)) {
					return err;
			}
		}
		inputDevice = AudioDevice(devid: input, isInput: true);
		
		// Set the Current Device to the AUHAL.
		// this should be done only after IO has been enabled on the AUHAL.
		if let err = checkErr(AudioUnitSetProperty(inputUnit, kAudioOutputUnitProperty_CurrentDevice,
			kAudioUnitScope_Global, 0, &inputDevice.id,
			UInt32(sizeof(AudioDeviceID)))) {
				return err;
		}
		return noErr;
	}
	
	func setupGraph(out: AudioDeviceID) -> OSStatus {
		// Make a New Graph
		if let err = checkErr(NewAUGraph(&graph)) {
			return err;
		}
		
		// Open the Graph, AudioUnits are opened but not initialized
		if let err = checkErr(AUGraphOpen(graph)) {
			return err;
		}
		
		if let err = checkErr(makeGraph()) {
			return err;
		}
		
		if let err = checkErr(setOutputDeviceAsCurrent(out)) {
			return err;
		}
		
		// Tell the output unit not to reset timestamps
		// Otherwise sample rate changes will cause sync los
		var startAtZero : UInt32 = 0;
		if let err = checkErr(AudioUnitSetProperty(outputUnit, kAudioOutputUnitProperty_StartTimestampsAtZero,
			kAudioUnitScope_Global, 0, &startAtZero, UInt32(sizeof(UInt32)))) {
				return err;
		}
		
		var output = AURenderCallbackStruct(
			inputProc: outputProc,
			inputProcRefCon: UnsafeMutablePointer<Void>(Unmanaged<CAPlayThrough>.passUnretained(self).toOpaque())
		);
		
		if let err = checkErr(AudioUnitSetProperty(varispeedUnit, kAudioUnitProperty_SetRenderCallback,
			kAudioUnitScope_Input, 0, &output, UInt32(sizeof(AURenderCallbackStruct)))) {
				return err;
		}
		return noErr;
	}
	
	func makeGraph() -> OSStatus {
		var varispeedDesc = AudioComponentDescription();
		var outDesc = AudioComponentDescription();
		
		// Q:Why do we need a varispeed unit?
		// A:If the input device and the output device are running at different sample rates
		// we will need to move the data coming to the graph slower/faster to avoid a pitch change.
		varispeedDesc.componentType = kAudioUnitType_FormatConverter;
		varispeedDesc.componentSubType = kAudioUnitSubType_Varispeed;
		varispeedDesc.componentManufacturer = kAudioUnitManufacturer_Apple;
		varispeedDesc.componentFlags = 0;
		varispeedDesc.componentFlagsMask = 0;
		
		outDesc.componentType = kAudioUnitType_Output;
		outDesc.componentSubType = kAudioUnitSubType_DefaultOutput;
		outDesc.componentManufacturer = kAudioUnitManufacturer_Apple;
		outDesc.componentFlags = 0;
		outDesc.componentFlagsMask = 0;
		
		//////////////////////////
		/// MAKE NODES
		// This creates a node in the graph that is an AudioUnit, using
		// the supplied ComponentDescription to find and open that unit
		if let err = checkErr(AUGraphAddNode(graph, &varispeedDesc, &varispeedNode)) {
			return err;
		}
		if let err = checkErr(AUGraphAddNode(graph, &outDesc, &outputNode)) {
			return err;
		}
		
		// Get Audio Units from AUGraph node
		if let err = checkErr(AUGraphNodeInfo(graph, varispeedNode, nil, &varispeedUnit)) {
			return err;
		}
		
		if let err = checkErr(AUGraphNodeInfo(graph, outputNode, nil, &outputUnit)) {
			return err;
		}
		
		// don't connect nodes until the varispeed unit has input and output formats set
		
		return noErr;
	}
	
	func setupAUHAL(input: AudioDeviceID) -> OSStatus {
		var comp : AudioComponent;
		var desc = AudioComponentDescription();
		
		// There are several different types of Audio Units.
		// Some audio units serve as Outputs, Mixers, or DSP
		// units. See AUComponent.h for listing
		desc.componentType = kAudioUnitType_Output;
		
		// Every Component has a subType, which will give a clearer picture
		// of what this components function will be.
		desc.componentSubType = kAudioUnitSubType_HALOutput;
		
		// all Audio Units in AUComponent.h must use
		// "kAudioUnitManufacturer_Apple" as the Manufacturer
		desc.componentManufacturer = kAudioUnitManufacturer_Apple;
		desc.componentFlags = 0;
		desc.componentFlagsMask = 0;
		
		// Finds a component that meets the desc spec's
		comp = AudioComponentFindNext(nil, &desc);
		if (comp == nil) {
			exit(-1);
		}
		
		// gains access to the services provided by the component
		if let err = checkErr(AudioComponentInstanceNew(comp, &inputUnit)) {
			return err;
		}
		
		// AUHAL needs to be initialized before anything is done to it
		if let err = checkErr(AudioUnitInitialize(inputUnit)) {
			return err;
		}
		
		if let err = checkErr(enableIO()) {
			return err;
		}
		
		if let err = checkErr(setInputDeviceAsCurrent(input)) {
			return err;
		}
		
		if let err = checkErr(callbackSetup()) {
			return err;
		}
		
		// Don't setup buffers until you know what the
		// input and output device audio streams look like.
		
		if let err = checkErr(AudioUnitInitialize(inputUnit)) {
			return err;
		}
		return noErr;
	}
	
	func enableIO() -> OSStatus {
		var enableIO : UInt32 = 1;
		
		///////////////
		// ENABLE IO (INPUT)
		// You must enable the Audio Unit (AUHAL) for input and disable output
		// BEFORE setting the AUHAL's current device.
		
		// Enable input on the AUHAL
		if let err = checkErr(AudioUnitSetProperty(inputUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, // input element
			&enableIO, UInt32(sizeof(UInt32)))) {
				return err;
		}
		
		// disable Output on the AUHAL
		enableIO = 0;
		if let err = checkErr(AudioUnitSetProperty(inputUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, // output element
			&enableIO, UInt32(sizeof(UInt32)))) {
				return err;
		}
		return noErr;
	}
	
	func callbackSetup() -> OSStatus {
		var maxFramesPerSlice: UInt32 = 4096;
		
		if let err = checkErr(AudioUnitSetProperty(inputUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFramesPerSlice, UInt32(sizeof(UInt32)))) {
			return err;
		}
		
		var propSize = UInt32(sizeof(UInt32));
		if let err = checkErr(AudioUnitGetProperty(inputUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFramesPerSlice, &propSize)) {
			return err;
		}
		
		bufferManager = BufferManager(inMaxFramesPerSlice: Int(maxFramesPerSlice));
		dcRejectionFilter = DCRejectionFilter();
		
		var input = AURenderCallbackStruct(
			inputProc: inputProc,
			inputProcRefCon: UnsafeMutablePointer<Void>(Unmanaged<CAPlayThrough>.passUnretained(self).toOpaque())
		);
		
		// Setup the input callback.
		if let err = checkErr(AudioUnitSetProperty(inputUnit, kAudioOutputUnitProperty_SetInputCallback,
			kAudioUnitScope_Global, 0, &input,
			UInt32(sizeof(AURenderCallbackStruct)))) {
				return err;
		}
		return noErr;
	}
	
	func setupBuffers() -> OSStatus {
		var bufferSizeFrames : UInt32 = 0;
		var bufferSizeBytes : UInt32 = 0;
		
		var asbd = AudioStreamBasicDescription();
		var asbd_dev1_in = AudioStreamBasicDescription();
		var asbd_dev2_out = AudioStreamBasicDescription();
		var rate : Float64 = 0;
		
		// Get the size of the IO buffer(s)
		var propertySize = UInt32(sizeof(UInt32));
		if let err = checkErr(AudioUnitGetProperty(inputUnit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &bufferSizeFrames, &propertySize)) {
			return err;
		}
		bufferSizeBytes = bufferSizeFrames * UInt32(sizeof(Float32));
		
		// Get the Stream Format (Output client side)
		propertySize = UInt32(sizeof(AudioStreamBasicDescription));
		if let err = checkErr(AudioUnitGetProperty(inputUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &asbd_dev1_in, &propertySize)) {
			return err;
		}
		// printf("=====Input DEVICE stream format\n" );
		// asbd_dev1_in.Print();
		
		// Get the Stream Format (client side)
		propertySize = UInt32(sizeof(AudioStreamBasicDescription));
		if let err = checkErr(AudioUnitGetProperty(inputUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &asbd, &propertySize)) {
			return err;
		}
		// printf("=====current Input (Client) stream format\n");
		// asbd.Print();
		
		// Get the Stream Format (Output client side)
		propertySize = UInt32(sizeof(AudioStreamBasicDescription));
		if let err = checkErr(AudioUnitGetProperty(outputUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &asbd_dev2_out, &propertySize)) {
			return err;
		}
		// printf("=====Output (Device) stream format\n");
		// asbd_dev2_out.Print();
		
		//////////////////////////////////////
		// Set the format of all the AUs to the input/output devices channel count
		// For a simple case, you want to set this to the lower of count of the channels
		// in the input device vs output device
		//////////////////////////////////////
		asbd.mChannelsPerFrame = ((asbd_dev1_in.mChannelsPerFrame < asbd_dev2_out.mChannelsPerFrame) ? asbd_dev1_in.mChannelsPerFrame : asbd_dev2_out.mChannelsPerFrame);
		// printf("Info: Input Device channel count=%ld\t Input Device channel count=%ld\n",asbd_dev1_in.mChannelsPerFrame,asbd_dev2_out.mChannelsPerFrame);
		// printf("Info: CAPlayThrough will use %ld channels\n",asbd.mChannelsPerFrame);
		
		
		// We must get the sample rate of the input device and set it to the stream format of AUHAL
		propertySize = UInt32(sizeof(Float64));
		var theAddress = AudioObjectPropertyAddress(
			mSelector: kAudioDevicePropertyNominalSampleRate,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMaster
		);
		
		if let err = checkErr(AudioObjectGetPropertyData(inputDevice.id, &theAddress, 0, nil, &propertySize, &rate)) {
			return err;
		}
		
		asbd.mSampleRate = rate;
		propertySize = UInt32(sizeof(AudioStreamBasicDescription));
		
		// Set the new formats to the AUs...
		if let err = checkErr(AudioUnitSetProperty(inputUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &asbd, propertySize)) {
			return err;
		}
		
		if let err = checkErr(AudioUnitSetProperty(varispeedUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, propertySize)) {
			return err;
		}
		
		// Set the correct sample rate for the output device, but keep the channel count the same
		propertySize = UInt32(sizeof(Float64));
		
		if let err = checkErr(AudioObjectGetPropertyData(outputDevice.id, &theAddress, 0, nil, &propertySize, &rate)) {
			return err;
		}
		
		asbd.mSampleRate = rate;
		propertySize = UInt32(sizeof(AudioStreamBasicDescription));
		
		// Set the new audio stream formats for the rest of the AUs...
		if let err = checkErr(AudioUnitSetProperty(varispeedUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &asbd, propertySize)) {
			return err;
		}
		
		if let err = checkErr(AudioUnitSetProperty(outputUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, propertySize)) {
			return err;
		}
		
		inputBuffer = AudioBufferList.allocate(maximumBuffers: Int(asbd.mChannelsPerFrame));
		
		for var buf in inputBuffer {
			buf.mNumberChannels = 1;
			buf.mDataByteSize = bufferSizeBytes;
		}
		
		// Alloc ring buffer that will hold data between the two audio devices
		buffer = CARingBuffer();
		buffer.allocate(Int(asbd.mChannelsPerFrame), bytesPerFrame: asbd.mBytesPerFrame, capacityFrames: bufferSizeFrames * 20);
		
		return noErr;
	}
	
	func computeThruOffset() {
		// The initial latency will at least be the safety offset's of the devices + the buffer sizes
		inToOutSampleOffset = Float64(inputDevice.safetyOffset + inputDevice.bufferSizeFrames + outputDevice.safetyOffset + outputDevice.bufferSizeFrames);
	}
}

class CAPlayThroughHost {
	var streamListenerQueue: dispatch_queue_t!;
	var streamListenerBlock: AudioObjectPropertyListenerBlock!;
	var playThrough : CAPlayThrough!;
	
	init(input: AudioDeviceID, output: AudioDeviceID) {
		createPlayThrough(input, output);
	}
	
	func createPlayThrough(input: AudioDeviceID, _ output: AudioDeviceID) {
		playThrough = CAPlayThrough(input: input, output: output);
		streamListenerQueue = dispatch_queue_create("com.CAPlayThough.StreamListenerQueue", DISPATCH_QUEUE_SERIAL);
		addDeviceListeners(input);
	}
	
	func deletePlayThrough() {
		if playThrough == nil {
			return;
		}
		playThrough.stop();
		removeDeviceListeners(playThrough.getInputDeviceID());
		streamListenerQueue = nil;
		playThrough = nil;
	}
	
	func resetPlayThrough() {
		let input = playThrough.getInputDeviceID();
		let output = playThrough.getOutputDeviceID();
		
		deletePlayThrough();
		createPlayThrough(input, output);
		playThrough.start();
	}
	
	func playThroughExists() -> Bool {
		return (playThrough != nil) ? true : false;
	}
	
	func start() -> OSStatus {
		if playThrough != nil {
			return playThrough.start();
		}
		return noErr;
	}
	
	func stop() -> OSStatus {
		if playThrough != nil {
			return playThrough.stop();
		}
		return noErr;
	}
	
	func isRunning() -> Bool {
		if playThrough != nil {
			return playThrough.isRunning();
		}
		return false;
	}
	
	func addDeviceListeners(input: AudioDeviceID) {
		streamListenerBlock = { (inNumberAddresses: UInt32, inAddresses: UnsafePointer<AudioObjectPropertyAddress>) in
			self.resetPlayThrough();
		};
		
		var theAddress = AudioObjectPropertyAddress(
			mSelector: kAudioDevicePropertyStreams,
			mScope: kAudioDevicePropertyScopeInput,
			mElement: kAudioObjectPropertyElementMaster
		);
		
		// StreamListenerBlock is called whenever the sample rate changes (as well as other format characteristics of the device)
		var propSize : UInt32 = 0;
		if let _ = checkErr(AudioObjectGetPropertyDataSize(input, &theAddress, 0, nil, &propSize)) {
			return;
		}
		
		let streams = UnsafeMutablePointer<AudioStreamID>.alloc(Int(propSize));
		let streamsBuf = UnsafeMutableBufferPointer<AudioStreamID>(start: streams, count: Int(propSize) / sizeof(AudioStreamID));
		
		if let _ = checkErr(AudioObjectGetPropertyData(input, &theAddress, 0, nil, &propSize, streams)) {
			return;
		}
		
		for stream in streamsBuf {
			propSize = UInt32(sizeof(UInt32));
			theAddress.mSelector = kAudioStreamPropertyDirection;
			theAddress.mScope = kAudioObjectPropertyScopeGlobal;
			
			var isInput : UInt32 = 0;
			if let _ = checkErr(AudioObjectGetPropertyData(stream, &theAddress, 0, nil, &propSize, &isInput)) {
				continue;
			}
			if isInput == 0 {
				continue;
			}
			theAddress.mSelector = kAudioStreamPropertyPhysicalFormat;
			
			checkErr(AudioObjectAddPropertyListenerBlock(stream, &theAddress, streamListenerQueue, streamListenerBlock))
		}
		free(streams)
	}
	
	func removeDeviceListeners(input: AudioDeviceID) {
		var theAddress = AudioObjectPropertyAddress(
			mSelector: kAudioDevicePropertyStreams,
			mScope: kAudioDevicePropertyScopeInput,
			mElement: kAudioObjectPropertyElementMaster
		);
		
		var propSize : UInt32 = 0;
		if let _ = checkErr(AudioObjectGetPropertyDataSize(input, &theAddress, 0, nil, &propSize)) {
			return;
		}
		
		let streams = UnsafeMutablePointer<AudioStreamID>.alloc(Int(propSize));
		let streamsBuf = UnsafeMutableBufferPointer<AudioStreamID>(start: streams, count: Int(propSize) / sizeof(AudioStreamID));
		
		if let _ = checkErr(AudioObjectGetPropertyData(input, &theAddress, 0, nil, &propSize, streams)) {
			return;
		}
		
		for stream in streamsBuf {
			propSize = UInt32(sizeof(UInt32));
			theAddress.mSelector = kAudioStreamPropertyDirection;
			theAddress.mScope = kAudioObjectPropertyScopeGlobal;
			
			var isInput: UInt32 = 0;
			if let _ = checkErr(AudioObjectGetPropertyData(stream, &theAddress, 0, nil, &propSize, &isInput)) {
				continue;
			}
			if isInput == 0 {
				continue;
			}
			theAddress.mSelector = kAudioStreamPropertyPhysicalFormat;
			
			checkErr(AudioObjectRemovePropertyListenerBlock(stream, &theAddress, streamListenerQueue, streamListenerBlock));
			streamListenerBlock = nil;
		}
		free(streams)
	}
}
