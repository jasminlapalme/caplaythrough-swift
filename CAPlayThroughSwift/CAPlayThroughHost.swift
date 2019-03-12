//
//  CAPlayThroughHost.swift
//  CAPlayThroughSwift
//
//  Created by Jasmin Lapalme on 2019-03-02.
//  Copyright © 2019 jPense. All rights reserved.
//

import Foundation
import AudioUnit

class CAPlayThroughHost {
  var streamListenerQueue: DispatchQueue!
  var streamListenerBlock: AudioObjectPropertyListenerBlock!
  var playThrough: CAPlayThrough!

  init(input: AudioDeviceID, output: AudioDeviceID) {
    createPlayThrough(input, output)
  }

  func createPlayThrough(_ input: AudioDeviceID, _ output: AudioDeviceID) {
    playThrough = CAPlayThrough(input: input, output: output)
    streamListenerQueue = DispatchQueue(label: "com.CAPlayThough.StreamListenerQueue", attributes: [])
    addDeviceListeners(input)
  }

  func deletePlayThrough() {
    if playThrough == nil {
      return
    }
    playThrough.stop()
    removeDeviceListeners(playThrough.getInputDeviceID())
    streamListenerQueue = nil
    playThrough = nil
  }

  func resetPlayThrough() {
    let input = playThrough.getInputDeviceID()
    let output = playThrough.getOutputDeviceID()

    deletePlayThrough()
    createPlayThrough(input, output)
    playThrough.start()
  }

  func playThroughExists() -> Bool {
    return (playThrough != nil) ? true : false
  }

  @discardableResult
  func start() -> OSStatus {
    if playThrough != nil {
      return playThrough.start()
    }
    return noErr
  }

  @discardableResult
  func stop() -> OSStatus {
    if playThrough != nil {
      return playThrough.stop()
    }
    return noErr
  }

  func isRunning() -> Bool {
    if playThrough != nil {
      return playThrough.isRunning()
    }
    return false
  }

  func addDeviceListeners(_ input: AudioDeviceID) {
    streamListenerBlock = { (inNumberAddresses: UInt32, inAddresses: UnsafePointer<AudioObjectPropertyAddress>) in
      self.resetPlayThrough()
    }

    var theAddress = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMaster
    )

    // StreamListenerBlock is called whenever the sample rate changes (as well as other format characteristics
    // of the device)
    var propSize: UInt32 = 0
    if checkErr(AudioObjectGetPropertyDataSize(input, &theAddress, 0, nil, &propSize)) != nil {
      return
    }

    let streams = UnsafeMutablePointer<AudioStreamID>.allocate(capacity: Int(propSize))
    let streamsBuf = UnsafeMutableBufferPointer<AudioStreamID>(start: streams,
                                                               count: Int(propSize) / MemoryLayout<AudioStreamID>.size)

    if checkErr(AudioObjectGetPropertyData(input, &theAddress, 0, nil, &propSize, streams)) != nil {
      return
    }

    for stream in streamsBuf {
      propSize = UInt32(MemoryLayout<UInt32>.size)
      theAddress.mSelector = kAudioStreamPropertyDirection
      theAddress.mScope = kAudioObjectPropertyScopeGlobal

      var isInput: UInt32 = 0
      if checkErr(AudioObjectGetPropertyData(stream, &theAddress, 0, nil, &propSize, &isInput)) != nil {
        continue
      }
      if isInput == 0 {
        continue
      }
      theAddress.mSelector = kAudioStreamPropertyPhysicalFormat

      checkErr(AudioObjectAddPropertyListenerBlock(stream, &theAddress, streamListenerQueue, streamListenerBlock))
    }
    free(streams)
  }

  func removeDeviceListeners(_ input: AudioDeviceID) {
    var theAddress = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMaster
    )

    var propSize: UInt32 = 0
    if checkErr(AudioObjectGetPropertyDataSize(input, &theAddress, 0, nil, &propSize)) != nil {
      return
    }

    let streams = UnsafeMutablePointer<AudioStreamID>.allocate(capacity: Int(propSize))
    let streamsBuf = UnsafeMutableBufferPointer<AudioStreamID>(start: streams,
                                                               count: Int(propSize) / MemoryLayout<AudioStreamID>.size)

    if checkErr(AudioObjectGetPropertyData(input, &theAddress, 0, nil, &propSize, streams)) != nil {
      return
    }

    for stream in streamsBuf {
      propSize = UInt32(MemoryLayout<UInt32>.size)
      theAddress.mSelector = kAudioStreamPropertyDirection
      theAddress.mScope = kAudioObjectPropertyScopeGlobal

      var isInput: UInt32 = 0
      if checkErr(AudioObjectGetPropertyData(stream, &theAddress, 0, nil, &propSize, &isInput)) != nil {
        continue
      }
      if isInput == 0 {
        continue
      }
      theAddress.mSelector = kAudioStreamPropertyPhysicalFormat

      checkErr(AudioObjectRemovePropertyListenerBlock(stream, &theAddress, streamListenerQueue, streamListenerBlock))
      streamListenerBlock = nil
    }
    free(streams)
  }
}
