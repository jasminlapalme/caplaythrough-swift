//
//  FFTView.swift
//  CAPlayThroughSwift
//
//  Created by Jasmin Lapalme on 16-01-16.
//  Copyright © 2016 jPense. All rights reserved.
//

import AppKit

class FFTView: NSView {
	let kNumberBars = 40;
	
	let kMinFrequency = 40;
	let kMaxFrequency = 20000;
	
	let kExpFuncBase: Double;
	let kExpFuncConstant: Double;
	
	var timer: NSTimer!;
	var playThroughHost: CAPlayThroughHost!;
	
	required init?(coder: NSCoder) {
		// Calculate the a (kExpFuncBase) and b (kExpFuncConstant) of a quadratic function (ax^2 + b) so that
		// f(0) = kMinFrequency and f(kNumberBars) = kMaxFrequency
		kExpFuncBase = Double(kMaxFrequency - kMinFrequency) / (pow(Double(kNumberBars), 2));
		kExpFuncConstant = Double(kMinFrequency);
		
		timer = nil;
		super.init(coder: coder);
		self.canDrawConcurrently = true;
		timer = NSTimer(timeInterval: 1.0/20.0, target: self, selector: "fire", userInfo: nil, repeats: true);
		NSRunLoop.mainRunLoop().addTimer(timer, forMode: NSDefaultRunLoopMode);
	}
	
	override var intrinsicContentSize : NSSize {
		get {
			return NSMakeSize(NSViewNoInstrinsicMetric, 100);
		}
	}
	
	func fft() -> [Float] {
		var fftDraw: [Float] = [];
		if (self.playThroughHost.playThrough.bufferManager.hasNewFFTData == 0) {
			return fftDraw;
		}
		let bufferManager = self.playThroughHost.playThrough.bufferManager;
		let outFFTData = bufferManager.fftOutput();
		if outFFTData.isEmpty {
			return fftDraw;
		}
		for k in 0..<kNumberBars {
			let targetFreq = kExpFuncBase * pow(Double(k), 2) + kExpFuncConstant;
			let yFract = Float(targetFreq) / (Float(bufferManager.sampleRate));
			
			let fftIdx = yFract * Float(outFFTData.count - 1);
			var fftIdx_i : Float = 0;
			var fftIdx_f : Float = 0;
			fftIdx_f = modff(fftIdx, &fftIdx_i);
			
			let lowerIndex = Int(fftIdx_i);
			var upperIndex = Int(fftIdx_i + 1);
			upperIndex = (upperIndex == outFFTData.count) ? outFFTData.count - 1 : upperIndex;
			
			let fft_l_fl = Float((outFFTData[lowerIndex] + 80) / 64.0);
			let fft_r_fl = Float((outFFTData[upperIndex] + 80) / 64.0);
			let interpVal = fft_l_fl * (1.0 - fftIdx_f) + fft_r_fl * fftIdx_f;
			
			fftDraw.append(clamp(min: Float(0.0), x: interpVal, max: Float(1.0)));
		}
		return fftDraw;
	}
	
	override func drawRect(dirtyRect: NSRect) {
		NSColor.lightGrayColor().set();
		let box = NSBezierPath(rect: self.bounds);
		box.lineWidth = 1.0;
		box.stroke();

		let margin = CGFloat(2);
		let colWidth = (NSWidth(self.bounds) - 2.0 * margin) / CGFloat(kNumberBars);
		let colMaxHeight = NSHeight(self.bounds);
		let fftDraw = fft();
		if fftDraw.isEmpty {
			return;
		}
		
		// Draw each bars
		for k in 0..<kNumberBars {
			let colHeight = CGFloat(fftDraw[k]) * colMaxHeight;
			let path = NSBezierPath(rect: NSMakeRect(
				colWidth * CGFloat(k) + 2 * margin, 0,
				colWidth - margin, colHeight)
			);
			NSColor.darkGrayColor().set();
			path.lineWidth = 1.0;
			path.fill();
		}
	}
	
	func fire() {
		if self.playThroughHost.playThrough.bufferManager.hasNewFFTData > 0 {
			self.needsDisplay = true;
		}
	}
}
