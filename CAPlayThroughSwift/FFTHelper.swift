//
//  FFTHelper.swift
//  CAPlayThroughSwift
//
//  Created by Jasmin Lapalme on 16-01-16.
//  Copyright © 2016 jPense. All rights reserved.
//

import Foundation
import Accelerate

class FFTHelper {
	var spectrumAnalysis: FFTSetup;
	var dspSplitComplex: DSPSplitComplex;
	var fftNormFactor: Float32;
	var fftLength: vDSP_Length;
	var log2N : vDSP_Length;
	var kAdjust0DB: Float = 1.5849e-13;
	
	init(inMaxFramesPerSlice: Int) {
		fftNormFactor = 1.0 / (2 * Float32(inMaxFramesPerSlice));
		fftLength = vDSP_Length(inMaxFramesPerSlice / 2);
		log2N = vDSP_Length(Log2Ceil(UInt32(inMaxFramesPerSlice)));
		dspSplitComplex = DSPSplitComplex(
			realp: UnsafeMutablePointer<Float>.alloc(Int(fftLength)),
			imagp: UnsafeMutablePointer<Float>.alloc(Int(fftLength))
		);
		spectrumAnalysis = vDSP_create_fftsetup(log2N, FFTRadix(kFFTRadix2));
	}
	
	deinit {
		vDSP_destroy_fftsetup(spectrumAnalysis);
		dspSplitComplex.realp.dealloc(Int(fftLength))
		dspSplitComplex.imagp.dealloc(Int(fftLength))
	}
	
	func computeFFT(inAudioData: [Float]) -> [Float] {
		if (inAudioData.isEmpty) {
			return [];
		}
		
		inAudioData.withUnsafeBufferPointer { (buf: UnsafeBufferPointer<Float>) -> Void in
			let ptr = UnsafePointer<DSPComplex>(buf.baseAddress);
			vDSP_ctoz(ptr, 2, &dspSplitComplex, 1, fftLength);
		}
		
		//Generate a split complex vector from the real data
		
		//Take the fft and scale appropriately
		vDSP_fft_zrip(spectrumAnalysis, &dspSplitComplex, 1, log2N, FFTDirection(kFFTDirection_Forward));
		vDSP_vsmul(dspSplitComplex.realp, 1, &fftNormFactor, dspSplitComplex.realp, 1, fftLength);
		vDSP_vsmul(dspSplitComplex.imagp, 1, &fftNormFactor, dspSplitComplex.imagp, 1, fftLength);
		
		//Zero out the nyquist value
		dspSplitComplex.imagp[0] = 0.0;
		
		//Convert the fft data to dB
		var outFFTData = Array<Float>(count: Int(fftLength), repeatedValue: 0.0);
		outFFTData.withUnsafeMutableBufferPointer { (inout buf: UnsafeMutableBufferPointer<Float>) -> Void in
			vDSP_zvmags(&dspSplitComplex, 1, buf.baseAddress, 1, fftLength);
		}
		
		//In order to avoid taking log10 of zero, an adjusting factor is added in to make the minimum value equal -128dB
		outFFTData.withUnsafeMutableBufferPointer { (inout buf: UnsafeMutableBufferPointer<Float>) -> Void in
			vDSP_vsadd(buf.baseAddress, 1, &kAdjust0DB, buf.baseAddress, 1, fftLength);
		}
		var one : Float = 1;
		outFFTData.withUnsafeMutableBufferPointer { (inout buf: UnsafeMutableBufferPointer<Float>) -> Void in
			vDSP_vdbcon(buf.baseAddress, 1, &one, buf.baseAddress, 1, fftLength, 0);
		}
		return outFFTData;
	}
}