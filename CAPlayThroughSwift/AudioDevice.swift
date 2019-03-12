//
//  AudioDevice.swift
//  CAPlayThroughSwift
//
//  Created by Jasmin Lapalme on 15-12-30.
//  Copyright © 2016 jPense. All rights reserved.
//

import Foundation
import CoreAudioKit

class AudioDevice {
	var identifier: AudioDeviceID
	var isInput: Bool
	var safetyOffset: UInt32
	var bufferSizeFrames: UInt32
	var format: AudioStreamBasicDescription

	init(devid: AudioDeviceID, isInput: Bool) {
		self.identifier = devid
		self.isInput = isInput
		self.safetyOffset = 0
		self.bufferSizeFrames = 0
		self.format = AudioStreamBasicDescription()

		if self.identifier == kAudioDeviceUnknown {
			return
		}

		var propsize = UInt32(MemoryLayout<Float32>.size)

		let theScope = isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput

		var theAddress = AudioObjectPropertyAddress(
			mSelector: kAudioDevicePropertySafetyOffset,
			mScope: theScope,
			mElement: 0
		)

		checkErr(AudioObjectGetPropertyData(self.identifier, &theAddress, 0, nil, &propsize, &safetyOffset))

		propsize = UInt32(MemoryLayout<UInt32>.size)
		theAddress.mSelector = kAudioDevicePropertyBufferFrameSize

		checkErr(AudioObjectGetPropertyData(self.identifier, &theAddress, 0, nil, &propsize, &bufferSizeFrames))

		propsize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
		theAddress.mSelector = kAudioDevicePropertyStreamFormat

		checkErr(AudioObjectGetPropertyData(self.identifier, &theAddress, 0, nil, &propsize, &format))
	}

	func setBufferSize(_ size: UInt32) {
		var size = size
		var propsize = UInt32(MemoryLayout<UInt32>.size)

		let theScope = isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput

		var theAddress = AudioObjectPropertyAddress(
			mSelector: kAudioDevicePropertyBufferFrameSize,
			mScope: theScope,
			mElement: 0
		)

		checkErr(AudioObjectSetPropertyData(self.identifier, &theAddress, 0, nil, propsize, &size))

		checkErr(AudioObjectGetPropertyData(self.identifier, &theAddress, 0, nil, &propsize, &bufferSizeFrames))
	}

	func countChannels() -> Int {
		var result: Int = 0

		let theScope = isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput

		var theAddress = AudioObjectPropertyAddress(
			mSelector: kAudioDevicePropertyStreamConfiguration,
			mScope: theScope,
			mElement: 0
		)

		var propSize: UInt32 = 0
		var err = AudioObjectGetPropertyDataSize(self.identifier, &theAddress, 0, nil, &propSize)
		if err != noErr {
			return 0
		}

		let bufList = AudioBufferList.allocate(maximumBuffers: Int(propSize))
		err = AudioObjectGetPropertyData(self.identifier, &theAddress, 0, nil, &propSize, bufList.unsafeMutablePointer)
		if err == noErr {
			result = bufList.reduce(0, { $0 + Int($1.mNumberChannels) })
		}
		free(bufList.unsafeMutablePointer)
		return result
	}

	func name() -> String {
		let theScope = isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
		var theAddress = AudioObjectPropertyAddress(
			mSelector: kAudioDevicePropertyDeviceName,
			mScope: theScope,
			mElement: 0
		)

		var maxlen = UInt32(1024)
		let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(maxlen))
		checkErr(AudioObjectGetPropertyData(self.identifier, &theAddress, 0, nil, &maxlen, buf))
		if let str = String(bytesNoCopy: buf, length: Int(maxlen), encoding: String.Encoding.utf8, freeWhenDone: true) {
			return str
		}
		return ""
	}
}
