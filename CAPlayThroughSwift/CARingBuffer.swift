//
//  CARingBuffer.swift
//  CAPlayThroughSwift
//
//  Created by Jasmin Lapalme on 15-12-30.
//  Copyright © 2016 jPense. All rights reserved.
//

import Foundation
import CoreAudio

enum CARingBufferError {
	case noError
	case tooMuch
	case cpuOverload

	func toOSStatus() -> OSStatus {
		switch self {
		case .noError:
			return noErr
		case .cpuOverload:
			return 4
		case .tooMuch:
			return 3
		}
	}
}

let kGeneralRingTimeBoundsQueueSize: Int32 = 32
let kGeneralRingTimeBoundsQueueMask = kGeneralRingTimeBoundsQueueSize - 1

func zeroRange(_ buffers: [ [UInt8] ], offset: Int, nbytes: Int) {
	if nbytes <= 0 {
		return
	}
	for var buffer in buffers {
		for idx in (offset...offset + nbytes - 1) {
			buffer[idx] = 0
		}
	}
}

func storeABL(_ buffers: inout [ [UInt8] ], destOffset: Int, abl: UnsafeMutableAudioBufferListPointer, srcOffset: Int,
              nbytes: Int) {
	for (idx, src) in abl.enumerated() {
		if srcOffset > Int(src.mDataByteSize) {
			continue
		}
		let count = min(nbytes, Int(src.mDataByteSize) - srcOffset)
    let srcBuffer = UnsafeBufferPointer<UInt8>(start: UnsafeRawPointer(src.mData!).assumingMemoryBound(to: UInt8.self),
                                               count: Int(src.mDataByteSize))
		for jdx in 0..<count {
			buffers[idx][destOffset + jdx] = srcBuffer[srcOffset + jdx]
		}
	}
}

func fetchABL(_ abl: UnsafeMutableAudioBufferListPointer, destOffset: Int, buffers: [ [UInt8] ], srcOffset: Int,
              nbytes: Int) {
	for (dest, var buffer) in zip(abl, buffers) {
		if destOffset > Int(dest.mDataByteSize) {
			continue
		}
		let count = min(nbytes, Int(dest.mDataByteSize) - destOffset)
    let start = UnsafeMutableRawPointer(dest.mData!).assumingMemoryBound(to: UInt8.self)
    let destBuffer = UnsafeMutableBufferPointer<UInt8>(start: start, count: Int(dest.mDataByteSize))
		for idx in 0..<count {
			destBuffer[destOffset + idx] = buffer[srcOffset + idx]
		}
	}
}

func zeroABL(_ abl: UnsafeMutableAudioBufferListPointer, destOffset: Int, nbytes: Int) {
	for dest in abl {
		if destOffset > Int(dest.mDataByteSize) {
			continue
		}
    let destPtr = UnsafeMutableRawPointer(dest.mData!).assumingMemoryBound(to: UInt8.self)
		memset(destPtr + destOffset, 0, min(nbytes, Int(dest.mDataByteSize) - destOffset))
	}
}

class CARingBuffer {
	typealias SampleTime = Int64
	typealias TimeBounds = (startTime: SampleTime, endTime: SampleTime, updateCounter: Int32)

	var buffers : [ [UInt8] ] = []
	var bytesPerFrame: UInt32 = 0
	var capacityFrames: UInt32 = 0
	var capacityFramesMask: UInt32 = 0
	var capacityBytes: UInt32 = 0

	var timeBoundsQueue: [TimeBounds] = []; // kGeneralRingTimeBoundsQueueSize
	var timeBoundsQueuePtr = Atomic<Int32>(0)

	func allocate(_ nChannels: Int, bytesPerFrame: UInt32, capacityFrames: UInt32) {
		self.bytesPerFrame = bytesPerFrame
		self.capacityFrames = nextPowerOfTwo(capacityFrames)
		self.capacityFramesMask = self.capacityFrames - 1
		self.capacityBytes = bytesPerFrame * self.capacityFrames
		self.buffers = (1...nChannels).map({ _ in [UInt8](repeating: 0, count: Int(self.capacityBytes))})
		self.timeBoundsQueue = (1...kGeneralRingTimeBoundsQueueSize).map({ _ in
			TimeBounds(0, 0, 0)})
		self.timeBoundsQueuePtr.set(0)
	}

	func deallocate() {
		self.buffers.removeAll()
		self.capacityFrames = 0
		self.capacityBytes = 0
	}

	func startTime() -> SampleTime {
		return self.timeBoundsQueue[Int(self.timeBoundsQueuePtr.get() & kGeneralRingTimeBoundsQueueMask)].startTime
	}

	func endTime() -> SampleTime {
		return self.timeBoundsQueue[Int(self.timeBoundsQueuePtr.get() & kGeneralRingTimeBoundsQueueMask)].endTime
	}

	func frameOffset(_ frameNumber: SampleTime) -> Int {
		return Int((frameNumber & SampleTime(self.capacityFramesMask)) * SampleTime(self.bytesPerFrame))
	}

	func setTimeBounds(_ startTime: SampleTime, _ endTime: SampleTime) {
    let queuePtr = self.timeBoundsQueuePtr.get()
		let nextPtr = queuePtr + 1
		let index = Int(nextPtr & kGeneralRingTimeBoundsQueueMask)

		self.timeBoundsQueue[index].startTime = startTime
		self.timeBoundsQueue[index].endTime = endTime
		self.timeBoundsQueue[index].updateCounter = nextPtr

    timeBoundsQueuePtr.compareAndSwap(queuePtr, nextPtr)
	}

  func store(_ abl: UnsafeMutableAudioBufferListPointer, framesToWrite: UInt32,
             startWrite: SampleTime) -> CARingBufferError {
		if framesToWrite == 0 {
			return .noError
		}
		if framesToWrite > self.capacityFrames {
			return .tooMuch
		}

		let endWrite = startWrite + SampleTime(framesToWrite)

		if startWrite < endTime() {
			// going backwards, throw everything out
			setTimeBounds(startWrite, startWrite)
		} else if endWrite - startTime() <= SampleTime(self.capacityFrames) {
			// the buffer has not yet wrapped and will not need to
		} else {
			// advance the start time past the region we are about to overwrite
			let newStart = endWrite - SampleTime(capacityFrames);	// one buffer of time behind where we're writing
			let newEnd = max(newStart, endTime())
			setTimeBounds(newStart, newEnd)
		}

		// write the new frames
		var offset0 = 0
		var offset1 = 0
		let curEnd = endTime()

		if startWrite > curEnd {
			// we are skipping some samples, so zero the range we are skipping
			offset0 = frameOffset(curEnd)
			offset1 = frameOffset(startWrite)
			if offset0 < offset1 {
				zeroRange(buffers, offset: offset0, nbytes: offset1 - offset0)
			} else {
				zeroRange(buffers, offset: offset0, nbytes: Int(self.capacityBytes) - offset0)
				zeroRange(buffers, offset: 0, nbytes: offset1)
			}
			offset0 = offset1
		} else {
			offset0 = frameOffset(startWrite)
		}

		offset1 = frameOffset(endWrite)
		if offset0 < offset1 {
			storeABL(&buffers, destOffset: offset0, abl: abl, srcOffset: 0, nbytes: offset1 - offset0)
		} else {
			let nbytes = Int(capacityBytes) - offset0
			storeABL(&buffers, destOffset: offset0, abl: abl, srcOffset: 0, nbytes: nbytes)
			storeABL(&buffers, destOffset: 0, abl: abl, srcOffset: nbytes, nbytes: offset1)
		}

		// now update the end time
		setTimeBounds(startTime(), endWrite)

		return .noError;	// success
	}

	@discardableResult
	func getTimeBounds(startTime: inout SampleTime, endTime: inout SampleTime) -> CARingBufferError {
		for _ in 0...8 {
			let curPtr = self.timeBoundsQueuePtr.get()
			let index = curPtr & kGeneralRingTimeBoundsQueueMask
			let bounds = self.timeBoundsQueue[Int(index)]
			startTime = bounds.startTime
			endTime = bounds.endTime
			let newPtr = bounds.updateCounter
			if newPtr == curPtr {
				return .noError
			}
		}
		return .cpuOverload
	}

	func clipTimeBounds(startRead: inout SampleTime, endRead: inout SampleTime) -> CARingBufferError {
		var startTime: SampleTime = 0
		var endTime: SampleTime = 0
		let err = getTimeBounds(startTime: &startTime, endTime: &endTime)

		if err != .noError {
			return err
		}

		if startRead > endTime || endRead < startTime {
			endRead = startRead
			return .noError
		}

		startRead = max(startRead, startTime)
		endRead = min(endRead, endTime)
		endRead = max(endRead, startRead)

		return .noError;	// success
	}

	func fetch(_ abl: UnsafeMutableAudioBufferListPointer, nFrames: UInt32, startRead: SampleTime) -> CARingBufferError {
		var startRead = startRead
		if nFrames == 0 {
			return .noError
		}

		startRead = max(0, startRead)

		var endRead = startRead + SampleTime(nFrames)

		let startRead0 = startRead
		let endRead0 = endRead

		let err = clipTimeBounds(startRead: &startRead, endRead: &endRead)
		if err != .noError {
			return err
		}

		if startRead == endRead {
			zeroABL(abl, destOffset: 0, nbytes: Int(nFrames * bytesPerFrame))
			return .noError
		}

		let byteSize = (endRead - startRead) * SampleTime(bytesPerFrame)

		let destStartByteOffset = max(0, (startRead - startRead0) * SampleTime(bytesPerFrame))

		if destStartByteOffset > 0 {
			zeroABL(abl, destOffset: 0, nbytes: Int(min(SampleTime(nFrames * bytesPerFrame), destStartByteOffset)))
		}

		let destEndSize = max(0, endRead0 - endRead)
		if destEndSize > 0 {
			zeroABL(abl, destOffset: Int(destStartByteOffset + byteSize), nbytes: Int(destEndSize * SampleTime(bytesPerFrame)))
		}

		let offset0 = frameOffset(startRead)
		let offset1 = frameOffset(endRead)
		var nbytes: Int = 0

		if offset0 < offset1 {
			nbytes = offset1 - offset0
			fetchABL(abl, destOffset: Int(destStartByteOffset), buffers: buffers, srcOffset: offset0, nbytes: nbytes)
		} else {
			nbytes = Int(capacityBytes) - offset0
			fetchABL(abl, destOffset: Int(destStartByteOffset), buffers: buffers, srcOffset: offset0, nbytes: nbytes)
			fetchABL(abl, destOffset: Int(destStartByteOffset) + nbytes, buffers: buffers, srcOffset: 0, nbytes: offset1)
			nbytes += offset1
		}

		for var dest in abl {
			dest.mDataByteSize = UInt32(nbytes)
		}

		return .noError
	}
}
