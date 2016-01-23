//
//  DCRejectionFilter.swift
//  CAPlayThroughSwift
//
//  Created by Jasmin Lapalme on 16-01-18.
//  Copyright © 2016 jPense. All rights reserved.
//

import Foundation

class DCRejectionFilter {
	var x1: Float = 0;
	var y1: Float = 0;
	let kDefaultPoleDist: Float = 0.975;
	
	func processInplace(inout ioData: [Float])
	{
		for i in 0...ioData.count-1
		{
			let xCurr = ioData[i];
			ioData[i] = ioData[i] - x1 + (kDefaultPoleDist * y1);
			x1 = xCurr;
			y1 = ioData[i];
		}
	}
}
