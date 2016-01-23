//
//  BufferManager.swift
//  CAPlayThroughSwift
//
//  Created by Jasmin Lapalme on 16-01-16.
//  Copyright © 2016 jPense. All rights reserved.
//

import Foundation

class BufferManager {
	var fftInputBuffer: [Float];
	var fftHelper: FFTHelper;
	var needsNewFFTData: Int32;
	var hasNewFFTData: Int32;
	let fftInputBufferLen: Int;
	
	init(inMaxFramesPerSlice: Int) {
		fftInputBufferLen = inMaxFramesPerSlice;
		fftInputBuffer = [];
		fftHelper = FFTHelper(inMaxFramesPerSlice: inMaxFramesPerSlice);
		needsNewFFTData = 0;
		hasNewFFTData = 0;
		OSAtomicIncrement32Barrier(&needsNewFFTData);
	}
	
	func fftOutputBufferLength() -> Int { return fftInputBufferLen / 2; }

	func copyAudioDataToFFTInputBuffer(inData: [Float])
	{
		let framesToCopy = min(inData.count, fftInputBufferLen - fftInputBuffer.count);
		fftInputBuffer.appendContentsOf(inData.prefix(framesToCopy));
		if (fftInputBuffer.count >= fftInputBufferLen) {
			OSAtomicIncrement32(&hasNewFFTData);
			OSAtomicDecrement32(&needsNewFFTData);
		}
	}
	
	func fftOutput() -> [Float]
	{
		let outFFTData = fftHelper.computeFFT(fftInputBuffer);
		fftInputBuffer.removeAll();
		OSAtomicDecrement32Barrier(&hasNewFFTData);
		OSAtomicIncrement32Barrier(&needsNewFFTData);
		return outFFTData;
	}
}