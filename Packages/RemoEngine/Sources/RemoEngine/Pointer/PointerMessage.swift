//
//  Created by Cyandev on 11/21/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import CoreGraphics
import Foundation
import RemoTransport

/// Positions are normalized to the captured display, with the origin at its upper left.
enum PointerMessage: Equatable {
    case move(sequence: UInt64, afterButton: UInt64, position: CGPoint)
    /// `afterButton` is the previous button change, or zero for the first.
    case button(
        sequence: UInt64, afterButton: UInt64, action: PointerButton, clickCount: Int = 1,
        position: CGPoint)
    /// Whole lines; positive values move the content down, following the finger.
    case scroll(lines: Int32)
    /// Two axes in `unit` steps at an explicit location, signed like `scroll(lines:)`.
    case scrollVector(unit: PointerScrollUnit, x: Int32, y: Int32, position: CGPoint)

    /// Button changes must arrive. The newest move must arrive too, since the client already
    /// shows the cursor there, but it makes an older one pointless. A late scroll is only noise;
    /// a scroll vector carries its own position, so it needn't wait behind a replaceable move.
    var delivery: MessageTransport.Delivery {
        switch self {
        case .button: .essential
        case .move:
            .untilDelivered(priority: .high, replacing: ReplaceableMessage.pointerMove.rawValue)
        case .scroll:
            .retrying(sendWithin: SessionTiming.pointerDeadline)
        case .scrollVector:
            .retrying(sendWithin: SessionTiming.pointerDeadline, priority: .high)
        }
    }

    private enum Input: UInt8 {
        case move = 1, button, scroll, scrollVector
    }

    var encoded: Data {
        var data = Data()
        data.put(MessageKind.pointerInput.rawValue)
        switch self {
        case let .move(sequence, afterButton, position):
            data.put(Input.move.rawValue)
            data.put(sequence)
            data.put(afterButton)
            data.putPosition(position)
        case let .button(sequence, afterButton, action, clickCount, position):
            data.put(Input.button.rawValue)
            data.put(sequence)
            data.put(afterButton)
            data.put(action.rawValue)
            data.put(UInt8(clamping: max(1, clickCount)))
            data.putPosition(position)
        case let .scroll(lines):
            data.put(Input.scroll.rawValue)
            data.put(lines)
        case let .scrollVector(unit, x, y, position):
            data.put(Input.scrollVector.rawValue)
            data.put(unit.rawValue)
            data.put(x)
            data.put(y)
            data.putPosition(position)
        }
        return data
    }

    init(decoding bytes: Data) throws {
        var data = bytes
        guard MessageKind(rawValue: try data.take(UInt8.self)) == .pointerInput else {
            throw WireFormatError.invalid
        }
        switch Input(rawValue: try data.take(UInt8.self)) {
        case .move:
            let sequence = try data.take(UInt64.self)
            let afterButton = try data.take(UInt64.self)
            guard sequence > afterButton else { throw WireFormatError.invalid }
            self = .move(
                sequence: sequence, afterButton: afterButton, position: try data.takePosition())
        case .button:
            let sequence = try data.take(UInt64.self)
            let afterButton = try data.take(UInt64.self)
            guard sequence > afterButton,
                let button = PointerButton(rawValue: try data.take(UInt8.self))
            else { throw WireFormatError.invalid }
            let count = try data.take(UInt8.self)
            guard count >= 1 else { throw WireFormatError.invalid }
            self = .button(
                sequence: sequence, afterButton: afterButton, action: button,
                clickCount: Int(count), position: try data.takePosition())
        case .scroll:
            let lines = try data.take(Int32.self)
            guard (-100...100).contains(lines), lines != 0 else {
                throw WireFormatError.invalid
            }
            self = .scroll(lines: lines)
        case .scrollVector:
            guard let unit = PointerScrollUnit(rawValue: try data.take(UInt8.self)) else {
                throw WireFormatError.invalid
            }
            let x = try data.take(Int32.self)
            let y = try data.take(Int32.self)
            let limit = Int64(unit.wireLimit)
            guard abs(Int64(x)) <= limit, abs(Int64(y)) <= limit, x != 0 || y != 0 else {
                throw WireFormatError.invalid
            }
            self = .scrollVector(unit: unit, x: x, y: y, position: try data.takePosition())
        case nil: throw WireFormatError.invalid
        }
        guard data.isEmpty else { throw WireFormatError.invalid }
    }
}
