//
//  CABitOperations.swift
//  CAPlayThroughSwift
//
//  Created by Jasmin Lapalme on 15-12-30.
//  Copyright © 2016 jPense. All rights reserved.
//

import Foundation

func countLeadingZeroes(_ number: UInt32) -> UInt32 {
	var number = number
	var count: UInt32 = 32
	var shift: UInt32

	shift = number >> 16
  if shift != 0 {
    count -= 16
    number = shift
  }
	shift = number >> 8
  if shift != 0 {
    count -= 8
    number = shift
  }
	shift = number >> 4
  if shift != 0 {
    count -= 4
    number = shift
  }
	shift = number >> 2
  if shift != 0 {
    count -= 2
    number = shift
  }
	shift = number >> 1
  if shift != 0 {
    return count - 2
  }

	return count - number
}

// base 2 log of next power of two greater or equal to x
func log2Ceil(_ val: UInt32) -> UInt32 {
	return 32 - countLeadingZeroes(val - 1)
}

func nextPowerOfTwo(_ val: UInt32) -> UInt32 {
	return 1 << log2Ceil(val)
}
