//
//  Atomic.swift
//  CAPlayThroughSwift
//
//  Created by Jasmin Lapalme on 2019-03-12.
//  Copyright © 2019 jPense. All rights reserved.
//

import Foundation

class Atomic<T> {
  var value: T
  var queue: DispatchQueue

  init(_ value: T) {
    self.value = value
    self.queue = DispatchQueue(label: "net.jpense.CAPlayThrough.Atomic")
  }

  func get() -> T {
    var safeValue: T!
    self.queue.sync {
      safeValue = self.value
    }
    return safeValue
  }

  func set(_ newValue: T) {
    self.queue.sync {
      self.value = newValue
    }
  }
}

extension Atomic where T: Equatable {
  @discardableResult
  func compareAndSwap(_ oldValue: T, _ newValue: T) -> Bool {
    var equalOldValue = false
    self.queue.sync {
      equalOldValue = self.value == oldValue
      if equalOldValue {
        self.value = newValue
      }
    }
    return equalOldValue
  }
}
