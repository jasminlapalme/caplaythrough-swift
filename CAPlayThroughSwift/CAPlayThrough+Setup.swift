//
//  CAPlayThrough+Setup.swift
//  CAPlayThroughSwift
//
//  Created by Jasmin Lapalme on 2019-03-12.
//  Copyright © 2019 jPense. All rights reserved.
//

import Foundation
import AudioUnit

extension CAPlayThrough {
  func setupGraph(_ out: AudioDeviceID) -> OSStatus {
    // Make a New Graph
    if let err = checkErr(NewAUGraph(&graph)) {
      return err
    }
    // Open the Graph, AudioUnits are opened but not initialized
    if let err = checkErr(AUGraphOpen(graph!)) {
      return err
    }
    if let err = checkErr(makeGraph()) {
      return err
    }
    if let err = checkErr(setOutputDeviceAsCurrent(out)) {
      return err
    }

    // Tell the output unit not to reset timestamps
    // Otherwise sample rate changes will cause sync los
    var startAtZero: UInt32 = 0
    if let err = checkErr(AudioUnitSetProperty(outputUnit!, kAudioOutputUnitProperty_StartTimestampsAtZero,
                                               kAudioUnitScope_Global, 0, &startAtZero,
                                               UInt32(MemoryLayout<UInt32>.size))) {
      return err
    }

    var output = AURenderCallbackStruct(
      inputProc: outputProc,
      inputProcRefCon: UnsafeMutableRawPointer(Unmanaged<CAPlayThrough>.passUnretained(self).toOpaque())
    )

    if let err = checkErr(AudioUnitSetProperty(varispeedUnit!, kAudioUnitProperty_SetRenderCallback,
                                               kAudioUnitScope_Input, 0, &output,
                                               UInt32(MemoryLayout<AURenderCallbackStruct>.size))) {
      return err
    }
    return noErr
  }

  func makeGraph() -> OSStatus {
    var varispeedDesc = AudioComponentDescription()
    var outDesc = AudioComponentDescription()

    // Q:Why do we need a varispeed unit?
    // A:If the input device and the output device are running at different sample rates
    // we will need to move the data coming to the graph slower/faster to avoid a pitch change.
    varispeedDesc.componentType = kAudioUnitType_FormatConverter
    varispeedDesc.componentSubType = kAudioUnitSubType_Varispeed
    varispeedDesc.componentManufacturer = kAudioUnitManufacturer_Apple
    varispeedDesc.componentFlags = 0
    varispeedDesc.componentFlagsMask = 0

    outDesc.componentType = kAudioUnitType_Output
    outDesc.componentSubType = kAudioUnitSubType_DefaultOutput
    outDesc.componentManufacturer = kAudioUnitManufacturer_Apple
    outDesc.componentFlags = 0
    outDesc.componentFlagsMask = 0

    //////////////////////////
    /// MAKE NODES
    // This creates a node in the graph that is an AudioUnit, using
    // the supplied ComponentDescription to find and open that unit
    if let err = checkErr(AUGraphAddNode(graph!, &varispeedDesc, &varispeedNode)) {
      return err
    }
    if let err = checkErr(AUGraphAddNode(graph!, &outDesc, &outputNode)) {
      return err
    }
    // Get Audio Units from AUGraph node
    if let err = checkErr(AUGraphNodeInfo(graph!, varispeedNode, nil, &varispeedUnit)) {
      return err
    }
    if let err = checkErr(AUGraphNodeInfo(graph!, outputNode, nil, &outputUnit)) {
      return err
    }
    // don't connect nodes until the varispeed unit has input and output formats set
    return noErr
  }

  func setupAUHAL(_ input: AudioDeviceID) -> OSStatus {
    var comp: AudioComponent?
    var desc = AudioComponentDescription()

    // There are several different types of Audio Units.
    // Some audio units serve as Outputs, Mixers, or DSP
    // units. See AUComponent.h for listing
    desc.componentType = kAudioUnitType_Output

    // Every Component has a subType, which will give a clearer picture
    // of what this components function will be.
    desc.componentSubType = kAudioUnitSubType_HALOutput

    // all Audio Units in AUComponent.h must use
    // "kAudioUnitManufacturer_Apple" as the Manufacturer
    desc.componentManufacturer = kAudioUnitManufacturer_Apple
    desc.componentFlags = 0
    desc.componentFlagsMask = 0

    // Finds a component that meets the desc spec's
    comp = AudioComponentFindNext(nil, &desc)
    if comp == nil {
      exit(-1)
    }

    // gains access to the services provided by the component
    if let err = checkErr(AudioComponentInstanceNew(comp!, &inputUnit)) {
      return err
    }

    // AUHAL needs to be initialized before anything is done to it
    if let err = checkErr(AudioUnitInitialize(inputUnit!)) {
      return err
    }

    if let err = checkErr(enableIO()) {
      return err
    }

    if let err = checkErr(setInputDeviceAsCurrent(input)) {
      return err
    }

    if let err = checkErr(callbackSetup()) {
      return err
    }

    // Don't setup buffers until you know what the
    // input and output device audio streams look like.

    if let err = checkErr(AudioUnitInitialize(inputUnit!)) {
      return err
    }
    return noErr
  }

  func setupBufferSizeFrames(bufferSizeFrames: inout UInt32, bufferSizeBytes: inout UInt32) -> OSStatus {
    var propertySize = UInt32(MemoryLayout<UInt32>.size)
    let err = AudioUnitGetProperty(inputUnit!, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,
                                   &bufferSizeFrames, &propertySize)
    if err != noErr {
      return err
    }
    bufferSizeBytes = bufferSizeFrames * UInt32(MemoryLayout<Float32>.size)
    return noErr
  }

  func setupAsbd(asbd: inout AudioStreamBasicDescription, asbdDev1In: inout AudioStreamBasicDescription,
                 asbdDev2Out: inout AudioStreamBasicDescription) -> OSStatus {
    // Get the Stream Format (Output client side)
    var propertySize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    var err = AudioUnitGetProperty(inputUnit!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1,
                                   &asbdDev1In, &propertySize)
    if err != noErr {
      return err
    }
    // printf("=====Input DEVICE stream format\n" );
    // asbd_dev1_in.Print();

    // Get the Stream Format (client side)
    propertySize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    err = AudioUnitGetProperty(inputUnit!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &asbd,
                               &propertySize)
    if err != noErr {
      return err
    }
    // printf("=====current Input (Client) stream format\n");
    // asbd.Print();

    // Get the Stream Format (Output client side)
    propertySize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    err = AudioUnitGetProperty(outputUnit!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &asbdDev2Out,
                               &propertySize)
    if err != noErr {
      return err
    }
    // printf("=====Output (Device) stream format\n");
    // asbd_dev2_out.Print();
    return noErr
  }

  func getRate(device: AudioDevice, rate: inout Float64) -> OSStatus {
    // We must get the sample rate of the input device and set it to the stream format of AUHAL
    var propertySize = UInt32(MemoryLayout<Float64>.size)
    var theAddress = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyNominalSampleRate,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMaster
    )

    let err = AudioObjectGetPropertyData(device.identifier, &theAddress, 0, nil, &propertySize, &rate)
    if err != noErr {
      return err
    }
    return noErr
  }

  func getMaxFramePerSlice(maxFramesPerSlice: inout UInt32) -> OSStatus {
    maxFramesPerSlice = 4096

    var err = AudioUnitSetProperty(inputUnit!, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                   &maxFramesPerSlice, UInt32(MemoryLayout<UInt32>.size))
    if err != noErr {
      return err
    }

    var propSize = UInt32(MemoryLayout<UInt32>.size)
    err = AudioUnitGetProperty(inputUnit!, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                               &maxFramesPerSlice, &propSize)
    if err != noErr {
      return err
    }
    return noErr
  }

  func setupAudioFormats(asbd: inout AudioStreamBasicDescription) -> OSStatus {
    let propertySize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

    // Set the new formats to the AUs...
    if let err = checkErr(AudioUnitSetProperty(inputUnit!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                               &asbd, propertySize)) {
      return err
    }

    if let err = checkErr(AudioUnitSetProperty(varispeedUnit!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input,
                                               0, &asbd, propertySize)) {
      return err
    }

    var rate: Float64 = 0
    if let err = checkErr(getRate(device: outputDevice, rate: &rate)) {
      return err
    }

    asbd.mSampleRate = rate

    // Set the new audio stream formats for the rest of the AUs...
    if let err = checkErr(AudioUnitSetProperty(varispeedUnit!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output,
                                               0, &asbd, propertySize)) {
      return err
    }

    if let err = checkErr(AudioUnitSetProperty(outputUnit!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input,
                                               0, &asbd, propertySize)) {
      return err
    }

    return noErr
  }

  func setupBuffers() -> OSStatus {
    var bufferSizeFrames: UInt32 = 0
    var bufferSizeBytes: UInt32 = 0

    var asbd = AudioStreamBasicDescription()
    var asbdDev1In = AudioStreamBasicDescription()
    var asbdDev2Out = AudioStreamBasicDescription()

    if let err = checkErr(setupBufferSizeFrames(bufferSizeFrames: &bufferSizeFrames,
                                                bufferSizeBytes: &bufferSizeBytes)) {
      return err
    }

    if let err = checkErr(setupAsbd(asbd: &asbd, asbdDev1In: &asbdDev1In, asbdDev2Out: &asbdDev2Out)) {
      return err
    }

    //////////////////////////////////////
    // Set the format of all the AUs to the input/output devices channel count
    // For a simple case, you want to set this to the lower of count of the channels
    // in the input device vs output device
    //////////////////////////////////////
    if asbdDev1In.mChannelsPerFrame < asbdDev2Out.mChannelsPerFrame {
      asbd.mChannelsPerFrame = asbdDev1In.mChannelsPerFrame
    } else {
      asbd.mChannelsPerFrame = asbdDev2Out.mChannelsPerFrame
    }

    var rate: Float64 = 0
    if let err = checkErr(getRate(device: inputDevice, rate: &rate)) {
      return err
    }

    var maxFramesPerSlice: UInt32 = 0
    if let err = checkErr(getMaxFramePerSlice(maxFramesPerSlice: &maxFramesPerSlice)) {
      return err
    }

    bufferManager = BufferManager(inMaxFramesPerSlice: Int(maxFramesPerSlice), sampleRate: rate)
    dcRejectionFilter = DCRejectionFilter()

    asbd.mSampleRate = rate
    let err = setupAudioFormats(asbd: &asbd)
    if err != noErr {
      return err
    }

    inputBuffer = AudioBufferList.allocate(maximumBuffers: Int(asbd.mChannelsPerFrame))

    for var buf in inputBuffer! {
      buf.mNumberChannels = 1
      buf.mDataByteSize = bufferSizeBytes
    }

    // Alloc ring buffer that will hold data between the two audio devices
    buffer = CARingBuffer()
    buffer.allocate(Int(asbd.mChannelsPerFrame), bytesPerFrame: asbd.mBytesPerFrame,
                    capacityFrames: bufferSizeFrames * 20)

    return noErr
  }
}
