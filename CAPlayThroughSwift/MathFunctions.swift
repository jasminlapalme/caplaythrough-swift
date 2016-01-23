//
//  MathFunctions.swift
//  CAPlayThroughSwift
//
//  Created by Jasmin Lapalme on 16-01-23.
//  Copyright © 2016 jPense. All rights reserved.
//

import Foundation

func clamp<T where T: Comparable>(min min: T, x: T, max: T) -> T {
	return x < min ? min : (x > max ? max : x);
}
