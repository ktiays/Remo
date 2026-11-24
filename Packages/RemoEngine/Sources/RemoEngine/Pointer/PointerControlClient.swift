//
//  Created by Cyandev on 11/21/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import Foundation

/// The controlling peer's half of the pointer protocol, which `PointerControlServer` orders.
///
/// The pointer moves here first, where the client draws it; its position goes to the server
/// when the client chooses to send it. Messages arrive in no particular order, so every move
/// and button change carries the sequence of the button change it follows.
struct PointerControlClient {
    /// The remote display's size in points, once the server has granted control.
    private(set) var displaySize: CGSize?
    /// Normalized to the remote display, with the origin at its upper left.
    private(set) var position = CGPoint.zero
    /// Whether a button is held.
    private(set) var dragging = false
    /// Whether the position has moved since it was last sent.
    private(set) var moved = false
    private var sequence: UInt64 = 0
    private var buttonSequence: UInt64 = 0
    /// Scroll deltas too small to fill a whole wire unit, per unit kind.
    private var lineRemainder = CGVector.zero
    private var pixelRemainder = CGVector.zero

    /// Accepts the server's control grant. Returns false if control is already active.
    @discardableResult
    mutating func begin(position: CGPoint, displaySize: CGSize) -> Bool {
        guard self.displaySize == nil else { return false }
        self.position = position
        self.displaySize = displaySize
        return true
    }

    /// Moves by a distance in remote display points, stopping at the display's edges.
    /// Returns whether the position changed.
    mutating func move(by delta: CGVector) -> Bool {
        guard let displaySize, delta != .zero, delta.dx.isFinite, delta.dy.isFinite else {
            return false
        }
        return move(
            to: CGPoint(
                x: position.x + delta.dx / displaySize.width,
                y: position.y + delta.dy / displaySize.height))
    }

    /// Moves to an absolute normalized position, clamped to the display.
    /// Returns whether the position changed.
    mutating func move(to next: CGPoint) -> Bool {
        guard displaySize != nil, next.x.isFinite, next.y.isFinite else { return false }
        let clamped = CGPoint(x: min(1, max(0, next.x)), y: min(1, max(0, next.y)))
        guard clamped != position else { return false }
        position = clamped
        moved = true
        return true
    }

    /// Something other than this client moved the remote pointer; carry on from there.
    mutating func adopt(_ position: CGPoint) {
        self.position = position
        moved = false
    }

    /// The move to send, if the position changed since the last one.
    mutating func takeMove() -> PointerMessage? {
        guard displaySize != nil, moved else { return nil }
        moved = false
        sequence += 1
        return .move(sequence: sequence, afterButton: buttonSequence, position: position)
    }

    /// A button change carries the position, so it also stands for any unsent move.
    mutating func press(_ button: PointerButton, clickCount: Int = 1) -> PointerMessage? {
        guard displaySize != nil else { return nil }
        let previous = buttonSequence
        sequence += 1
        buttonSequence = sequence
        switch button {
        case .leftDown, .rightDown: dragging = true
        case .leftUp, .rightUp: dragging = false
        case .leftClick, .rightClick: break
        }
        let count = min(Int(UInt8.max), max(1, clickCount))
        return .button(
            sequence: sequence, afterButton: previous, action: button,
            clickCount: count, position: position)
    }

    /// Whole lines; positive values move the content down, following the finger.
    func scroll(lines: Int) -> PointerMessage? {
        guard displaySize != nil, lines != 0 else { return nil }
        // The server rejects larger steps.
        return .scroll(lines: Int32(min(100, max(-100, lines))))
    }

    /// Scrolls both axes at an explicit normalized location, in `unit` steps signed like
    /// `scroll(lines:)`. Sub-unit fractions accumulate until they fill a whole wire step.
    mutating func scroll(
        by delta: CGVector, unit: PointerScrollUnit, at location: CGPoint
    ) -> PointerMessage? {
        guard displaySize != nil, delta.dx.isFinite, delta.dy.isFinite,
            location.x.isFinite, location.y.isFinite
        else { return nil }
        let at = CGPoint(x: min(1, max(0, location.x)), y: min(1, max(0, location.y)))
        switch unit {
        case .line: return Self.scrollVector(delta, unit: unit, at: at, remainder: &lineRemainder)
        case .pixel: return Self.scrollVector(delta, unit: unit, at: at, remainder: &pixelRemainder)
        }
    }

    private static func scrollVector(
        _ delta: CGVector, unit: PointerScrollUnit, at position: CGPoint, remainder: inout CGVector
    ) -> PointerMessage? {
        let x = quantized(remainder.dx + delta.dx, limit: unit.wireLimit, remainder: &remainder.dx)
        let y = quantized(remainder.dy + delta.dy, limit: unit.wireLimit, remainder: &remainder.dy)
        guard x != 0 || y != 0 else { return nil }
        return .scrollVector(unit: unit, x: x, y: y, position: position)
    }

    /// Whole steps inside `total`, clamped to what the wire accepts. Only the sub-unit
    /// fraction keeps for next time; steps past the limit drop rather than queue up.
    private static func quantized(
        _ total: CGFloat, limit: Int32, remainder: inout CGFloat
    ) -> Int32 {
        let bounded = min(CGFloat(limit), max(-CGFloat(limit), total))
        remainder = bounded.truncatingRemainder(dividingBy: 1)
        return Int32(bounded.rounded(.towardZero))
    }
}
