//
//  DCRejectionFilter.swift
//  CAPlayThroughSwift
//
//  Created by Jasmin Lapalme on 16-01-18.
//  Copyright © 2016 jPense. All rights reserved.
//

import Foundation

class DCRejectionFilter {
	var valX1: Float = 0
	var valY1: Float = 0
	let kDefaultPoleDist: Float = 0.975

	func processInplace(_ ioData: inout [Float]) {
		for idx in 0...ioData.count-1 {
			let xCurr = ioData[idx]
			ioData[idx] = ioData[idx] - valX1 + (kDefaultPoleDist * valY1)
			valX1 = xCurr
			valY1 = ioData[idx]
		}
	}
}
