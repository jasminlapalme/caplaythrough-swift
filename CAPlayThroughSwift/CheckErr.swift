//
//  VerifyNoErr.swift
//  CAPlayThroughSwift
//
//  Created by Jasmin Lapalme on 15-12-30.
//  Copyright © 2016 jPense. All rights reserved.
//

import Foundation

func checkErr(_ err : @autoclosure () -> OSStatus, file: String = #file, line: Int = #line) -> OSStatus! {
	let error = err()
	if (error != noErr) {
		print("CAPlayThrough Error: \(error) ->  \(file):\(line)\n");
		return error
	}
	return nil;
}
