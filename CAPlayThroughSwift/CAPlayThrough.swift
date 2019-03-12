//
//  CAPlayThrough.swift
//  CAPlayThroughSwift
//
//  Created by Jasmin Lapalme on 15-12-30.
//  Copyright © 2016 jPense. All rights reserved.
//

import Foundation
import AudioUnit
import CoreAudio
import AudioToolbox

func mergeAudioBufferList(_ abl: UnsafeMutableAudioBufferListPointer, inNumberFrames: UInt32) -> [Float] {
  let umpab = abl.map({ return UnsafeMutableRawPointer($0.mData!).assumingMemoryBound(to: Float32.self) })
  var buffer = [Float](repeating: 0, count: Int(inNumberFrames))
  for idx in buffer.indices {
    buffer[idx] = umpab.reduce(Float(0), { (total: Float, abp: UnsafeMutablePointer<Float32>) -> Float in
      return total + abp[idx]
    })
  }
  return buffer
}

func makeBufferSilent(_ ioData: UnsafeMutableAudioBufferListPointer) {
  for buf in ioData {
    memset(buf.mData, 0, Int(buf.mDataByteSize))
  }
}

class CAPlayThrough {
  var inputUnit: AudioUnit?
  var inputBuffer = UnsafeMutableAudioBufferListPointer(nil)
  var inputDevice: AudioDevice!
  var outputDevice: AudioDevice!

  var buffer = CARingBuffer()
  var bufferManager: BufferManager!
  var dcRejectionFilter: DCRejectionFilter!

  // AudioUnits and Graph
  var graph: AUGraph?
  var varispeedNode: AUNode = 0
  var varispeedUnit: AudioUnit?
  var outputNode: AUNode = 0
  var outputUnit: AudioUnit?

  // Buffer sample info
  var firstInputTime: Float64 = -1
  var firstOutputTime: Float64 = -1
  var inToOutSampleOffset: Float64 = 0

  var outputProc: AURenderCallback = { (inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames,
    ioData) -> OSStatus in
    let this = Unmanaged<CAPlayThrough>.fromOpaque(inRefCon).takeUnretainedValue()
    var rate: Float64 = 0.0
    var inTS = AudioTimeStamp()
    var outTS = AudioTimeStamp()
    let abl = UnsafeMutableAudioBufferListPointer(ioData)

    if this.firstInputTime < 0 {
      // input hasn't run yet -> silence
      makeBufferSilent (abl!)
      return noErr
    }

    // use the varispeed playback rate to offset small discrepancies in sample rate
    // first find the rate scalars of the input and output devices
    // this callback may still be called a few times after the device has been stopped
    if (AudioDeviceGetCurrentTime(this.inputDevice.identifier, &inTS) != noErr) {
      makeBufferSilent (abl!)
      return noErr
    }

    if let err = checkErr(AudioDeviceGetCurrentTime(this.outputDevice.identifier, &outTS)) {
      return err
    }

    rate = inTS.mRateScalar / outTS.mRateScalar
    let result = AudioUnitSetParameter(this.varispeedUnit!, kVarispeedParam_PlaybackRate, kAudioUnitScope_Global,
                                       0, AudioUnitParameterValue(rate), 0)
    if let err = checkErr(result) {
      return err
    }

    // get Delta between the devices and add it to the offset
    if this.firstOutputTime < 0 {
      this.firstOutputTime = inTimeStamp.pointee.mSampleTime
      let delta = (this.firstInputTime - this.firstOutputTime)
      this.computeThruOffset()
      // changed: 3865519 11/10/04
      if delta < 0.0 {
        this.inToOutSampleOffset -= delta
      } else {
        this.inToOutSampleOffset = -delta + this.inToOutSampleOffset
      }

      makeBufferSilent (abl!)
      return noErr
    }

    // copy the data from the buffers
    let err = this.buffer.fetch(abl!, nFrames: inNumberFrames,
                                startRead: Int64(inTimeStamp.pointee.mSampleTime - this.inToOutSampleOffset))
    if err != .noError {
      makeBufferSilent (abl!)
      var bufferStartTime: Int64 = 0
      var bufferEndTime: Int64 = 0
      this.buffer.getTimeBounds(startTime: &bufferStartTime, endTime: &bufferEndTime)
      this.inToOutSampleOffset = inTimeStamp.pointee.mSampleTime - Float64(bufferStartTime)
    }

    return noErr
  }

  var inputProc: AURenderCallback = { (inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames,
    ioData) -> OSStatus in

    let this = Unmanaged<CAPlayThrough>.fromOpaque(inRefCon).takeUnretainedValue()
    if this.firstInputTime < 0 {
      this.firstInputTime = inTimeStamp.pointee.mSampleTime
    }

    // Get the new audio data
    if let err = checkErr(AudioUnitRender(this.inputUnit!, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames,
                                          (this.inputBuffer?.unsafeMutablePointer)!)) {
      return err
    }

    var samples = mergeAudioBufferList(this.inputBuffer!, inNumberFrames: inNumberFrames)

    if this.bufferManager.needsNewFFTData > 0 {
      this.dcRejectionFilter.processInplace(&samples)
      this.bufferManager.copyAudioDataToFFTInputBuffer(samples)
    }

    let ringBufferErr = this.buffer.store(this.inputBuffer!, framesToWrite: inNumberFrames,
                                          startWrite: CARingBuffer.SampleTime(inTimeStamp.pointee.mSampleTime))

    return ringBufferErr.toOSStatus()

  }

  init(input: AudioDeviceID, output: AudioDeviceID) {
    // Note: You can interface to input and output devices with "output" audio units.
    // Please keep in mind that you are only allowed to have one output audio unit per graph (AUGraph).
    // As you will see, this sample code splits up the two output units.  The "output" unit that will
    // be used for device input will not be contained in a AUGraph, while the "output" unit that will
    // interface the default output device will be in a graph.

    // Setup AUHAL for an input device
    if checkErr(setupAUHAL(input)) != nil {
      exit(1)
    }
    // Setup Graph containing Varispeed Unit & Default Output Unit
    if checkErr(setupGraph(output)) != nil {
      exit(1)
    }
    if checkErr(setupBuffers()) != nil {
      exit(1)
    }
    // the varispeed unit should only be conected after the input and output formats have been set
    if checkErr(AUGraphConnectNodeInput(graph!, varispeedNode, 0, outputNode, 0)) != nil {
      exit(1)
    }
    if checkErr(AUGraphInitialize(graph!)) != nil {
      exit(1)
    }
    // Add latency between the two devices
    computeThruOffset()
  }

  deinit {
    cleanup()
  }

  func getInputDeviceID()	-> AudioDeviceID { return inputDevice.identifier;	}
  func getOutputDeviceID() -> AudioDeviceID { return outputDevice.identifier; }

  func cleanup() {
    stop()
    if inputBuffer?.unsafePointer != nil {
      free(inputBuffer?.unsafeMutablePointer)
    }
  }

  @discardableResult
  func start() -> OSStatus {
    if isRunning() {
      return noErr
    }
    // Start pulling for audio data
    if let err = checkErr(AudioOutputUnitStart(inputUnit!)) {
      return err
    }

    if let err = checkErr(AUGraphStart(graph!)) {
      return err
    }

    // reset sample times
    firstInputTime = -1
    firstOutputTime = -1
    return noErr
  }

  @discardableResult
  func stop() -> OSStatus {
    if !isRunning() {
      return noErr
    }
    if let err = checkErr(AudioOutputUnitStop(inputUnit!)) {
      return err
    }
    if let err = checkErr(AUGraphStop(graph!)) {
      return err
    }
    firstInputTime = -1
    firstOutputTime = -1
    return noErr
  }

  func isRunning() -> Bool {
    var auhalRunning: UInt32 = 0
    var graphRunning: DarwinBoolean = false
    var size: UInt32 = UInt32(MemoryLayout<UInt32>.size)

    if inputUnit != nil {
      if checkErr(AudioUnitGetProperty(inputUnit!, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0,
                                       &auhalRunning, &size)) != nil {
        return false
      }
    }
    if graph != nil {
      if checkErr(AUGraphIsRunning(graph!, &graphRunning)) != nil {
        return false
      }
    }
    return (auhalRunning > 0 || graphRunning.boolValue)
  }

  func setOutputDeviceAsCurrent(_ out: AudioDeviceID) -> OSStatus {
    var out = out
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var theAddress = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMaster
    )

    if out == kAudioDeviceUnknown {
      if let err = checkErr(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &theAddress, 0, nil,
                                                       &size, &out)) {
        return err
      }
    }
    outputDevice = AudioDevice(devid: out, isInput: false)

    // Set the Current Device to the Default Output Unit.
    return AudioUnitSetProperty(outputUnit!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                &outputDevice.identifier, UInt32(MemoryLayout<AudioDeviceID>.size))
  }

  func setInputDeviceAsCurrent(_ input: AudioDeviceID) -> OSStatus {
    var input = input
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var theAddress = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMaster
    )

    if input == kAudioDeviceUnknown {
      if let err = checkErr(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &theAddress, 0, nil,
                                                       &size, &input)) {
        return err
      }
    }
    inputDevice = AudioDevice(devid: input, isInput: true)

    // Set the Current Device to the AUHAL.
    // this should be done only after IO has been enabled on the AUHAL.
    if let err = checkErr(AudioUnitSetProperty(inputUnit!, kAudioOutputUnitProperty_CurrentDevice,
                                               kAudioUnitScope_Global, 0, &inputDevice.identifier,
                                               UInt32(MemoryLayout<AudioDeviceID>.size))) {
      return err
    }
    return noErr
  }

  func enableIO() -> OSStatus {
    var enableIO: UInt32 = 1

    ///////////////
    // ENABLE IO (INPUT)
    // You must enable the Audio Unit (AUHAL) for input and disable output
    // BEFORE setting the AUHAL's current device.

    // Enable input on the AUHAL
    if let err = checkErr(AudioUnitSetProperty(inputUnit!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input,
                                               1, &enableIO, UInt32(MemoryLayout<UInt32>.size))) {
      return err
    }

    // disable Output on the AUHAL
    enableIO = 0
    if let err = checkErr(AudioUnitSetProperty(inputUnit!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output,
                                               0, &enableIO, UInt32(MemoryLayout<UInt32>.size))) {
      return err
    }
    return noErr
  }

  func callbackSetup() -> OSStatus {
    var input = AURenderCallbackStruct(
      inputProc: inputProc,
      inputProcRefCon: UnsafeMutableRawPointer(Unmanaged<CAPlayThrough>.passUnretained(self).toOpaque())
    )

    // Setup the input callback.
    if let err = checkErr(AudioUnitSetProperty(inputUnit!, kAudioOutputUnitProperty_SetInputCallback,
                                               kAudioUnitScope_Global, 0, &input,
                                               UInt32(MemoryLayout<AURenderCallbackStruct>.size))) {
      return err
    }
    return noErr
  }

  func computeThruOffset() {
    // The initial latency will at least be the safety offset's of the devices + the buffer sizes
    inToOutSampleOffset = Float64(inputDevice.safetyOffset + inputDevice.bufferSizeFrames + outputDevice.safetyOffset +
      outputDevice.bufferSizeFrames)
  }
}
