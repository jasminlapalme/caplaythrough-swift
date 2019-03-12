//
//  MathFunctions.swift
//  CAPlayThroughSwift
//
//  Created by Jasmin Lapalme on 16-01-23.
//  Copyright © 2016 jPense. All rights reserved.
//

import Foundation

func clamp<T>(min: T, val: T, max: T) -> T where T: Comparable {
	return val < min ? min : (val > max ? max : val)
}
