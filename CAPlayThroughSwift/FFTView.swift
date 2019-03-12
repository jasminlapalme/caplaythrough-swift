//
//  FFTView.swift
//  CAPlayThroughSwift
//
//  Created by Jasmin Lapalme on 16-01-16.
//  Copyright © 2016 jPense. All rights reserved.
//

import AppKit

class FFTView: NSView {
	let kNumberBars = 40

	let kMinFrequency = 40
	let kMaxFrequency = 20000

	let kExpFuncBase: Double
	let kExpFuncConstant: Double

	var timer: Timer!
	var playThroughHost: CAPlayThroughHost!

	required init?(coder: NSCoder) {
		// Calculate the a (kExpFuncBase) and b (kExpFuncConstant) of a quadratic function (ax^2 + b) so that
		// f(0) = kMinFrequency and f(kNumberBars) = kMaxFrequency
		kExpFuncBase = Double(kMaxFrequency - kMinFrequency) / (pow(Double(kNumberBars), 2))
		kExpFuncConstant = Double(kMinFrequency)

		timer = nil
		super.init(coder: coder)
		self.canDrawConcurrently = true
		timer = Timer(timeInterval: 1.0/20.0, target: self, selector: #selector(FFTView.fire), userInfo: nil, repeats: true)
    RunLoop.main.add(timer, forMode: .default)
	}

	override var intrinsicContentSize: NSSize {
    return NSSize(width: NSView.noIntrinsicMetric, height: 100)
	}

	func fft() -> [Float] {
		var fftDraw: [Float] = []
		if self.playThroughHost.playThrough.bufferManager.hasNewFFTData == 0 {
			return fftDraw
		}
		let bufferManager = self.playThroughHost.playThrough.bufferManager
		let outFFTData = bufferManager?.fftOutput()
		if (outFFTData?.isEmpty)! {
			return fftDraw
		}
		for idx in 0..<kNumberBars {
			let targetFreq = kExpFuncBase * pow(Double(idx), 2) + kExpFuncConstant
			let yFract = Float(targetFreq) / (Float((bufferManager?.sampleRate)!))

			let fftIdx = yFract * Float((outFFTData?.count)! - 1)
			var fftIdxi: Float = 0
			var fftIdxf: Float = 0
			fftIdxf = modff(fftIdx, &fftIdxi)

			let lowerIndex = Int(fftIdxi)
			var upperIndex = Int(fftIdxi + 1)
			upperIndex = (upperIndex == (outFFTData?.count)!) ? (outFFTData?.count)! - 1 : upperIndex

			let fftlfl = Float(((outFFTData?[lowerIndex])! + 80) / 64.0)
			let fftrfl = Float(((outFFTData?[upperIndex])! + 80) / 64.0)
			let interpVal = fftlfl * (1.0 - fftIdxf) + fftrfl * fftIdxf

			fftDraw.append(clamp(min: Float(0.0), val: interpVal, max: Float(1.0)))
		}
		return fftDraw
	}

	override func draw(_ dirtyRect: NSRect) {
		NSColor.lightGray.set()
		let box = NSBezierPath(rect: self.bounds)
		box.lineWidth = 1.0
		box.stroke()

		let margin = CGFloat(2)
		let colWidth = (self.bounds.width - 2.0 * margin) / CGFloat(kNumberBars)
		let colMaxHeight = self.bounds.height
		let fftDraw = fft()
		if fftDraw.isEmpty {
			return
		}

		// Draw each bars
		for idx in 0..<kNumberBars {
			let colHeight = CGFloat(fftDraw[idx]) * colMaxHeight
			let path = NSBezierPath(rect: NSRect(
        x: colWidth * CGFloat(idx) + 2 * margin, y: 0,
        width: colWidth - margin, height: colHeight)
			)
			NSColor.darkGray.set()
			path.lineWidth = 1.0
			path.fill()
		}
	}

  @objc func fire() {
		if self.playThroughHost.playThrough.bufferManager.hasNewFFTData > 0 {
			self.needsDisplay = true
		}
	}
}
