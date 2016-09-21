//
//  AudioDeviceList.swift
//  CAPlayThroughSwift
//
//  Created by Jasmin Lapalme on 15-12-30.
//  Copyright © 2016 Jasmin Lapalme. All rights reserved.
//

import Foundation
import CoreAudio

class Device : NSObject {
	var name: String;
	var id: AudioDeviceID;
	
	init(name: String, id: AudioDeviceID) {
		self.name = name;
		self.id = id;
	}
}

class AudioDeviceList {
	var devices: [Device] = [];
	var areInputs: Bool = false;
	
	init(areInputs: Bool) {
		self.areInputs = areInputs;
		buildList();
	}
	
	func buildList() {
		var theAddress = AudioObjectPropertyAddress(
			mSelector: kAudioHardwarePropertyDevices,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMaster
		);
		
		var propsize: UInt32 = 0;
		checkErr(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &theAddress, 0, nil, &propsize));
		let nDevices = Int(propsize) / MemoryLayout<AudioDeviceID>.size;
		
		var devids = Array<AudioDeviceID>(repeating: 0, count: nDevices);
		devids.withUnsafeMutableBufferPointer {
			(buffer: inout UnsafeMutableBufferPointer<AudioDeviceID>) -> () in
			checkErr(AudioObjectGetPropertyData(
				AudioObjectID(kAudioObjectSystemObject),
				&theAddress,
				0,
				nil,
				&propsize,
				buffer.baseAddress! )
			);
		}
		
		devices = devids
			.map { AudioDevice(devid: $0, isInput: areInputs) }
			.filter { $0.CountChannels() > 0 }
			.map { Device(name: $0.name(), id: $0.id) }
	}
}
