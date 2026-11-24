//
//  Created by Cyandev on 11/21/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import Foundation

/// Serializes remote pointer input from one controlling peer at a time.
@MainActor
final class PointerControlServer {
    enum Event: Equatable {
        /// The button held while moving, or nil for a plain move; `clickCount` is that
        /// button's click state so multi-click drags keep their count.
        case move(CGPoint, dragging: PointerButton? = nil, clickCount: Int = 1)
        case button(PointerButton, CGPoint, clickCount: Int = 1)
        case scroll(lines: Int32)
        /// Two axes in `unit` steps at an explicit location, signed like `scroll(lines:)`.
        /// The location stays out of pointer state: a scroll has no sequence, so an old
        /// one arriving late must not roll a newer position back.
        case scrollVector(unit: PointerScrollUnit, x: Int32, y: Int32, at: CGPoint)
    }

    private struct Move {
        let sequence: UInt64
        let afterButton: UInt64
        let position: CGPoint
    }

    struct InitialState: Equatable {
        let position: CGPoint
        let width: UInt32
        let height: UInt32
    }

    private let initialState: () -> InitialState?
    private let emit: @MainActor (Event) -> Void
    #if os(macOS)
        private final class DisplayTarget {
            var displayID: CGDirectDisplayID
            var onPost: @MainActor (CGPoint) -> Void

            init(displayID: CGDirectDisplayID, onPost: @escaping @MainActor (CGPoint) -> Void) {
                self.displayID = displayID
                self.onPost = onPost
            }
        }
        private var displayTarget: DisplayTarget?
    #endif
    private var owner: UUID?
    private var position = CGPoint.zero
    /// The button whose press is still down, and its click state.
    private var heldButton: PointerButton?
    private var heldClickCount = 1
    private var latestPosition: UInt64 = 0
    private var latestButton: UInt64 = 0
    private var pendingMove: Move?
    /// Button changes that arrived before the one they follow, keyed by that one's sequence.
    private var pendingButtons: [UInt64: PointerMessage] = [:]

    init(initialState: @escaping () -> InitialState?, emit: @escaping @MainActor (Event) -> Void) {
        self.initialState = initialState
        self.emit = emit
    }

    func begin(for peer: UUID) -> InitialState? {
        guard owner == nil, let state = initialState() else { return nil }
        owner = peer
        self.position = state.position
        return state
    }

    @discardableResult
    func receive(_ bytes: Data, from peer: UUID) -> Bool {
        guard owner == peer, let input = try? PointerMessage(decoding: bytes) else { return false }
        switch input {
        case let .move(sequence, afterButton, position):
            receiveMove(Move(sequence: sequence, afterButton: afterButton, position: position))
        case let .scroll(lines):
            emit(.scroll(lines: lines))
        case let .scrollVector(unit, x, y, position):
            emit(.scrollVector(unit: unit, x: x, y: y, at: position))
        case .button:
            receiveButton(input)
        }
        return true
    }

    /// Applies button changes in the order they were made. One that overtook its predecessor
    /// waits for it, which always arrives: button changes are sent until delivered.
    private func receiveButton(_ input: PointerMessage) {
        var next: PointerMessage? = input
        while let current = next,
            case let .button(sequence, afterButton, action, clickCount, position) = current
        {
            next = nil
            guard afterButton >= latestButton, sequence > latestPosition else { return }
            if afterButton > latestButton {
                if pendingButtons.count < 64 { pendingButtons[afterButton] = current }
                return
            }
            latestButton = sequence
            latestPosition = sequence
            switch action {
            case .leftDown, .rightDown:
                guard heldButton == nil else { break }
                heldButton = action
                heldClickCount = clickCount
                self.position = position
                emit(.button(action, position, clickCount: clickCount))
            case .leftUp, .rightUp:
                guard action == heldButton?.released else { break }
                if self.position != position {
                    emit(.move(position, dragging: heldButton, clickCount: heldClickCount))
                }
                heldButton = nil
                self.position = position
                emit(.button(action, position, clickCount: heldClickCount))
                heldClickCount = 1
            case .leftClick, .rightClick:
                if heldButton == nil {
                    self.position = position
                    emit(.button(action, position, clickCount: clickCount))
                }
            }
            if let pendingMove, pendingMove.afterButton <= sequence {
                self.pendingMove = nil
                receiveMove(pendingMove)
            }
            next = pendingButtons.removeValue(forKey: sequence)
        }
    }

    private func receiveMove(_ move: Move) {
        guard move.sequence > latestPosition, move.afterButton >= latestButton else { return }
        // A move can overtake the button change it follows. Keep only the latest such move.
        if move.afterButton > latestButton {
            if move.sequence > (pendingMove?.sequence ?? 0) { pendingMove = move }
            return
        }
        latestPosition = move.sequence
        position = move.position
        emit(.move(position, dragging: heldButton, clickCount: heldClickCount))
    }

    func end(for peer: UUID) {
        if owner == peer { stop() }
    }

    func stop() {
        if let heldButton {
            emit(.button(heldButton.released, position, clickCount: heldClickCount))
        }
        heldButton = nil
        heldClickCount = 1
        owner = nil
        #if os(macOS)
            displayTarget?.onPost = { _ in }
        #endif
        latestPosition = 0
        latestButton = 0
        pendingMove = nil
        pendingButtons.removeAll()
    }
}

private extension PointerButton {
    /// The release that matches a press.
    var released: PointerButton {
        switch self {
        case .leftDown: .leftUp
        case .rightDown: .rightUp
        default: self
        }
    }
}

#if os(macOS)
    import CoreGraphics

    extension PointerControlServer {
        /// `onPost` hears the position of every pointer event posted to the display.
        /// `modifierFlags` supplies active remote keyboard modifiers so `⌘+Click`, `⇧+Drag`, etc. work.
        convenience init(
            displayID: CGDirectDisplayID,
            modifierFlags: @escaping @MainActor () -> CGEventFlags = { [] },
            onPost: @escaping @MainActor (CGPoint) -> Void = { _ in }
        ) {
            nonisolated(unsafe) let source = CGEventSource(stateID: .hidSystemState)
            let target = DisplayTarget(displayID: displayID, onPost: onPost)
            self.init(initialState: {
                guard let geometry = DisplayGeometry(displayID: target.displayID),
                    let width = UInt32(exactly: geometry.bounds.width), width > 0,
                    let height = UInt32(exactly: geometry.bounds.height), height > 0,
                    let location = CGEvent(source: nil)?.location
                else { return nil }
                let position =
                    geometry.bounds.contains(location)
                    ? geometry.normalize(location)
                    : CGPoint(x: 0.5, y: 0.5)
                return InitialState(position: position, width: width, height: height)
            }, emit: { event in
                guard let geometry = DisplayGeometry(displayID: target.displayID) else { return }
                let remoteFlags = modifierFlags()
                let post: @MainActor (CGEventType, CGMouseButton, CGPoint, Int) -> Void = {
                    type, button, position, clickCount in
                    let event = CGEvent(
                        mouseEventSource: source, mouseType: type,
                        mouseCursorPosition: geometry.location(of: position), mouseButton: button)
                    if !remoteFlags.isEmpty, let event {
                        event.flags = event.flags.union(remoteFlags)
                    }
                    if type != .mouseMoved {
                        event?.setIntegerValueField(
                            .mouseEventClickState, value: Int64(clickCount))
                    }
                    event?.post(tap: .cghidEventTap)
                    target.onPost(position)
                }
                switch event {
                case let .move(position, dragging, clickCount):
                    switch dragging {
                    case .leftDown?:
                        post(.leftMouseDragged, .left, position, clickCount)
                    case .rightDown?:
                        post(.rightMouseDragged, .right, position, clickCount)
                    default:
                        post(.mouseMoved, .left, position, clickCount)
                    }
                case let .button(action, position, clickCount):
                    switch action {
                    case .leftClick, .rightClick:
                        // Multi-clicks post one pair per count, each stamped with it.
                        let button: CGMouseButton = action == .leftClick ? .left : .right
                        let down: CGEventType =
                            action == .leftClick ? .leftMouseDown : .rightMouseDown
                        let up: CGEventType =
                            action == .leftClick ? .leftMouseUp : .rightMouseUp
                        for count in 1...max(1, clickCount) {
                            post(down, button, position, count)
                            post(up, button, position, count)
                        }
                    case .leftDown:
                        post(.leftMouseDown, .left, position, clickCount)
                    case .leftUp:
                        post(.leftMouseUp, .left, position, clickCount)
                    case .rightDown:
                        post(.rightMouseDown, .right, position, clickCount)
                    case .rightUp:
                        post(.rightMouseUp, .right, position, clickCount)
                    }
                case let .scroll(lines):
                    let scrollEvent = CGEvent(
                        scrollWheelEvent2Source: source, units: .line, wheelCount: 1,
                        wheel1: lines, wheel2: 0, wheel3: 0)
                    if !remoteFlags.isEmpty, let scrollEvent {
                        scrollEvent.flags = scrollEvent.flags.union(remoteFlags)
                    }
                    scrollEvent?.post(tap: .cghidEventTap)
                case let .scrollVector(unit, x, y, position):
                    let scrollEvent = CGEvent(
                        scrollWheelEvent2Source: source,
                        units: unit == .line ? .line : .pixel, wheelCount: 2,
                        wheel1: y, wheel2: x, wheel3: 0)
                    if let scrollEvent {
                        scrollEvent.location = geometry.location(of: position)
                        if !remoteFlags.isEmpty {
                            scrollEvent.flags = scrollEvent.flags.union(remoteFlags)
                        }
                    }
                    scrollEvent?.post(tap: .cghidEventTap)
                }
            })
            self.displayTarget = target
        }

        /// Grants control targeting a specific display (main display or a per-client virtual
        /// display) without affecting an already-active controlling peer.
        func begin(
            for peer: UUID, displayID: CGDirectDisplayID,
            onPost: @escaping @MainActor (CGPoint) -> Void
        ) -> InitialState? {
            guard owner == nil else { return nil }
            displayTarget?.displayID = displayID
            displayTarget?.onPost = onPost
            return begin(for: peer)
        }
    }
#endif
