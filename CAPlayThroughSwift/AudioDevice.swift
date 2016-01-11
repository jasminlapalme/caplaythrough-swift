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
	var id: AudioDeviceID;
	var isInput: Bool;
	var safetyOffset: UInt32;
	var bufferSizeFrames: UInt32;
	var format: AudioStreamBasicDescription;
	
	init(devid: AudioDeviceID , isInput: Bool) {
		self.id = devid;
		self.isInput = isInput;
		self.safetyOffset = 0;
		self.bufferSizeFrames = 0;
		self.format = AudioStreamBasicDescription();

		if (self.id == kAudioDeviceUnknown) {
			return;
		}
	
		var propsize = UInt32(sizeof(Float32));
	
		let theScope = isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput;
	
		var theAddress = AudioObjectPropertyAddress(
			mSelector: kAudioDevicePropertySafetyOffset,
			mScope: theScope,
			mElement: 0
		);
	
		checkErr(AudioObjectGetPropertyData(self.id, &theAddress, 0, nil, &propsize, &safetyOffset));

		propsize = UInt32(sizeof(UInt32));
		theAddress.mSelector = kAudioDevicePropertyBufferFrameSize;
	
		checkErr(AudioObjectGetPropertyData(self.id, &theAddress, 0, nil, &propsize, &bufferSizeFrames));
	
		propsize = UInt32(sizeof(AudioStreamBasicDescription));
		theAddress.mSelector = kAudioDevicePropertyStreamFormat;
	
		checkErr(AudioObjectGetPropertyData(self.id, &theAddress, 0, nil, &propsize, &format));
	}
	
	func setBufferSize(var size: UInt32) {
		var propsize = UInt32(sizeof(UInt32));
	
		let theScope = isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput;
	
		var theAddress = AudioObjectPropertyAddress(
			mSelector: kAudioDevicePropertyBufferFrameSize,
			mScope: theScope,
			mElement: 0
		);
	
		checkErr(AudioObjectSetPropertyData(self.id, &theAddress, 0, nil, propsize, &size));
	
		checkErr(AudioObjectGetPropertyData(self.id, &theAddress, 0, nil, &propsize, &bufferSizeFrames));
	}
	
	func CountChannels() -> Int {
		var result : Int = 0;
	
		let theScope = isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput;
	
		var theAddress = AudioObjectPropertyAddress(
			mSelector: kAudioDevicePropertyStreamConfiguration,
			mScope: theScope,
			mElement: 0
		);
		
		var propSize: UInt32 = 0;
		var err = AudioObjectGetPropertyDataSize(self.id, &theAddress, 0, nil, &propSize);
		if (err != noErr) {
			return 0;
		}
	
		let bufList = AudioBufferList.allocate(maximumBuffers: Int(propSize));
		err = AudioObjectGetPropertyData(self.id, &theAddress, 0, nil, &propSize, bufList.unsafeMutablePointer);
		if (err == noErr) {
			result = bufList.reduce(0, combine: { $0 + Int($1.mNumberChannels) });
		}
		free(bufList.unsafeMutablePointer);
		return result;
	}
	
	func name() -> String {
		let theScope = isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput;
		var theAddress = AudioObjectPropertyAddress(
			mSelector: kAudioDevicePropertyDeviceName,
			mScope: theScope,
			mElement: 0
		);
		
		var maxlen = UInt32(1024);
		let buf = UnsafeMutablePointer<UInt8>.alloc(Int(maxlen));
		checkErr(AudioObjectGetPropertyData(self.id, &theAddress, 0, nil, &maxlen, buf));
		if let str = String(bytesNoCopy: buf, length: Int(maxlen), encoding: NSUTF8StringEncoding, freeWhenDone: true) {
			return str;
		}
		return "";
	}
}