//
//  FFTView.swift
//  CAPlayThroughSwift
//
//  Created by Jasmin Lapalme on 16-01-16.
//  Copyright © 2016 jPense. All rights reserved.
//

import AppKit

class FFTView: NSView {
	let kNumber = 20;
	var timer: NSTimer!;
	var playThroughHost: CAPlayThroughHost!;
	
	required init?(coder: NSCoder) {
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
		let outFFTData = self.playThroughHost.playThrough.bufferManager.fftOutput();
		if outFFTData.isEmpty {
			return fftDraw;
		}
		for k in 0...kNumber-1 {
			let yFract = Float(k) / Float(kNumber - 1);
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
		let colWidth = (NSWidth(self.bounds) - 1.0) / CGFloat(kNumber);
		let colMaxHeight = NSHeight(self.bounds);
		let margin = colWidth / 6;
		let fftDraw = fft();
		if fftDraw.isEmpty {
			return;
		}
		for k in 0...kNumber-1 {
			let colHeight = CGFloat(fftDraw[k]) * colMaxHeight;
			let path = NSBezierPath(rect: NSMakeRect(
				colWidth * CGFloat(k) + margin, 0,
				colWidth - margin, colHeight)
			);
			path.lineWidth = 1.0;
			path.stroke();
		}
	}
	
	func fire() {
		if self.playThroughHost.playThrough.bufferManager.hasNewFFTData > 0 {
			self.needsDisplay = true;
		}
	}
}
