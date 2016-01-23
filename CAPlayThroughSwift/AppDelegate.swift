//
//  AppDelegate.swift
//  CAPlayThroughSwift
//
//  Created by Jasmin Lapalme on 15-12-29.
//  Copyright © 2016 jPense. All rights reserved.
//

import Cocoa
import CoreAudio

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

	@IBOutlet weak var window: NSWindow!
	@IBOutlet weak var inputDeviceController: NSArrayController!
	@IBOutlet weak var outputDeviceController: NSArrayController!
	@IBOutlet weak var stopStartButton: NSButton!
	@IBOutlet weak var progress: NSProgressIndicator!
	@IBOutlet weak var fftView: FFTView!;
	
	var inputDeviceList: AudioDeviceList;
	var outputDeviceList: AudioDeviceList;
	var inputDevice: AudioDeviceID = 0;
	var outputDevice: AudioDeviceID = 0;
	dynamic var selectedInputDevice: Device!;
	dynamic var selectedOutputDevice: Device!;
	var playThroughHost: CAPlayThroughHost!;
	
	override init() {
		self.inputDeviceList = AudioDeviceList(areInputs: true);
		self.outputDeviceList = AudioDeviceList(areInputs: false);
	}
	
	override func awakeFromNib() {
		var propsize = UInt32(sizeof(AudioDeviceID));
		
		var theAddress = AudioObjectPropertyAddress(
			mSelector: kAudioHardwarePropertyDefaultInputDevice,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMaster
		);
		
		checkErr(AudioObjectGetPropertyData(
			AudioObjectID(kAudioObjectSystemObject),
			&theAddress,
			0,
			nil,
			&propsize,
			&inputDevice)
		);
		
		propsize = UInt32(sizeof(AudioDeviceID));
		theAddress.mSelector = kAudioHardwarePropertyDefaultOutputDevice;
		checkErr(AudioObjectGetPropertyData(
			AudioObjectID(kAudioObjectSystemObject),
			&theAddress,
			0,
			nil,
			&propsize,
			&outputDevice)
		);
		
		self.inputDeviceController.content = self.inputDeviceList.devices;
		self.outputDeviceController.content = self.outputDeviceList.devices;
		
		self.selectedInputDevice = self.inputDeviceList.devices.filter({ return $0.id == inputDevice }).first
		self.selectedOutputDevice = self.outputDeviceList.devices.filter({ return $0.id == outputDevice }).first

		playThroughHost = CAPlayThroughHost(input: inputDevice,output: outputDevice);
		self.fftView.playThroughHost = playThroughHost;
	}

	func applicationDidFinishLaunching(aNotification: NSNotification) {
		// Insert code here to initialize your application
	}

	func applicationWillTerminate(aNotification: NSNotification) {
		// Insert code here to tear down your application
	}

	func start() {
		if playThroughHost.isRunning() {
			return;
		}
		stopStartButton.title = "Stop";
		playThroughHost.start();
		progress.hidden = false;
		progress.startAnimation(self);
	}
	
	func stop() {
		if !playThroughHost.isRunning() {
			return;
		}
		stopStartButton.title = "Start";
		playThroughHost.stop();
		progress.hidden = true;
		progress.stopAnimation(self);
	}
	
	func resetPlayThrough() {
		if playThroughHost.playThroughExists() {
			playThroughHost.deletePlayThrough();
		}
		playThroughHost.createPlayThrough(inputDevice, outputDevice);
	}

	@IBAction func startStop(sender: NSButton) {
		if !playThroughHost.playThroughExists() {
			self.playThroughHost.createPlayThrough(inputDevice, outputDevice);
		}
		
		if !playThroughHost.isRunning() {
			start();
		} else {
			stop();
		}
	}

	@IBAction func inputDeviceSelected(sender: NSPopUpButton) {
		if (selectedInputDevice.id == inputDevice) {
			return;
		}

		stop();
		inputDevice = selectedInputDevice.id;
		resetPlayThrough();
	}
	
	@IBAction func outputDeviceSelected(sender: NSPopUpButton) {
		if (selectedOutputDevice.id == outputDevice) {
			return;
		}

		stop();
		outputDevice = selectedOutputDevice.id;
		resetPlayThrough();
	}
}

