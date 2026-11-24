//
//  Created by Cyandev on 11/21/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import Foundation
import RemoTransport
import Testing

@testable import RemoEngine

@Test func pointerMessagesRoundTripAndRejectInvalidPositions() throws {
    let position = CGPoint(x: 0.125, y: 0.875)
    let messages: [PointerMessage] = [
        .move(sequence: 4, afterButton: 3, position: position),
        .button(sequence: 5, afterButton: 3, action: .rightClick, position: position),
        .scroll(lines: -3),
        .button(sequence: 7, afterButton: 5, action: .leftDown, clickCount: 2, position: position),
        .button(sequence: 8, afterButton: 7, action: .rightDown, position: position),
        .scrollVector(unit: .pixel, x: -13, y: 6, position: position),
        .scrollVector(unit: .line, x: 2, y: 0, position: position),
    ]
    for message in messages {
        let decoded = try PointerMessage(decoding: message.encoded)
        #expect(decoded == message)
        #expect(throws: WireFormatError.self) {
            try PointerMessage(decoding: message.encoded.dropLast())
        }
    }
    var badCount = messages[3].encoded
    badCount[19] = 0
    #expect(throws: WireFormatError.self) {
        try PointerMessage(decoding: badCount)
    }
    for badScroll in [
        PointerMessage.scrollVector(unit: .line, x: 0, y: 0, position: position),
        .scrollVector(unit: .line, x: 101, y: 0, position: position),
        .scrollVector(unit: .pixel, x: -1, y: 1, position: CGPoint(x: 1.1, y: 0)),
    ] {
        #expect(throws: WireFormatError.self) {
            try PointerMessage(decoding: badScroll.encoded)
        }
    }
    let invalid = PointerMessage.button(
        sequence: 1, afterButton: 0, action: .leftClick, position: CGPoint(x: CGFloat.nan, y: 0))
    #expect(throws: WireFormatError.self) { try PointerMessage(decoding: invalid.encoded) }
    let selfReferential = PointerMessage.button(
        sequence: 4, afterButton: 4, action: .leftClick, position: position)
    #expect(throws: WireFormatError.self) { try PointerMessage(decoding: selfReferential.encoded) }
    // Button changes must arrive; a move only matters while it is fresh.
    #expect(messages[1].delivery.retryBudget == .infinity)
    // The newest move must arrive too: the client already draws the cursor there.
    #expect(messages[0].delivery.retryBudget == .infinity && messages[0].delivery.priority == .high)
    #expect(messages[0].delivery.replacing != nil && messages[2].delivery.replacing == nil)
    #expect(messages[5].delivery.retryBudget == 0 && messages[5].delivery.replacing == nil)
}

@Test @MainActor func pointerMovesRespectButtonOrderAndClickPositions() {
    let start = CGPoint(x: 0.1, y: 0.2)
    let dragged = CGPoint(x: 0.5, y: 0.6)
    let end = CGPoint(x: 0.7, y: 0.8)
    let clicked = CGPoint(x: 0.95, y: 0.9)
    let id = UUID()
    var events: [PointerControlServer.Event] = []
    let server = PointerControlServer(
        initialState: { .init(position: start, width: 1512, height: 982) },
        emit: { events.append($0) })
    #expect(server.begin(for: id) != nil)

    func send(_ input: PointerMessage) {
        server.receive(input.encoded, from: id)
    }
    send(.move(sequence: 4, afterButton: 2, position: dragged))
    send(.move(sequence: 3, afterButton: 2, position: start))
    #expect(events.isEmpty)
    send(.button(sequence: 2, afterButton: 0, action: .leftDown, position: start))
    // The final move at sequence 5 arrives only after the button is released.
    send(.button(sequence: 6, afterButton: 2, action: .leftUp, position: end))
    send(.move(sequence: 5, afterButton: 2, position: dragged))
    send(.button(sequence: 8, afterButton: 6, action: .rightClick, position: clicked))
    send(.button(sequence: 8, afterButton: 6, action: .rightClick, position: clicked))
    send(.scroll(lines: -3))

    #expect(events == [
        .button(.leftDown, start), .move(dragged, dragging: .leftDown),
        .move(end, dragging: .leftDown), .button(.leftUp, end),
        .button(.rightClick, clicked), .scroll(lines: -3),
    ])
}

@Test @MainActor func buttonChangesApplyInOrderHoweverTheyArrive() {
    let down = CGPoint(x: 0.1, y: 0.2)
    let up = CGPoint(x: 0.3, y: 0.4)
    let clicked = CGPoint(x: 0.5, y: 0.6)
    let id = UUID()
    var events: [PointerControlServer.Event] = []
    let server = PointerControlServer(
        initialState: { .init(position: .zero, width: 1512, height: 982) },
        emit: { events.append($0) })
    #expect(server.begin(for: id) != nil)
    func send(_ input: PointerMessage) { server.receive(input.encoded, from: id) }

    // A whole drag and the click after it arrive back to front, with a move in between.
    send(.button(sequence: 9, afterButton: 5, action: .rightClick, position: clicked))
    send(.move(sequence: 7, afterButton: 5, position: clicked))
    send(.button(sequence: 5, afterButton: 2, action: .leftUp, position: up))
    #expect(events.isEmpty)
    send(.button(sequence: 2, afterButton: 0, action: .leftDown, position: down))
    #expect(events == [
        .button(.leftDown, down), .move(up, dragging: .leftDown), .button(.leftUp, up),
        .move(clicked), .button(.rightClick, clicked),
    ])
    // Duplicates and anything older than what has been applied change nothing.
    send(.button(sequence: 5, afterButton: 2, action: .leftUp, position: up))
    send(.button(sequence: 4, afterButton: 2, action: .leftClick, position: down))
    #expect(events.count == 5)
}

@Test @MainActor func closingPointerSessionReleasesDragAndAllowsNewOwner() {
    let position = CGPoint(x: 0.2, y: 0.3)
    let owner = UUID()
    let viewer = UUID()
    var events: [PointerControlServer.Event] = []
    let server = PointerControlServer(
        initialState: { .init(position: .zero, width: 1512, height: 982) },
        emit: { events.append($0) })
    #expect(server.begin(for: owner) != nil)
    #expect(server.begin(for: viewer) == nil)
    let input = PointerMessage.button(
        sequence: 1, afterButton: 0, action: .leftDown, position: position
    ).encoded
    server.receive(input, from: viewer)
    #expect(events.isEmpty)
    server.receive(input, from: owner)
    server.end(for: viewer)
    #expect(events == [.button(.leftDown, position)])
    server.end(for: owner)
    #expect(events == [.button(.leftDown, position), .button(.leftUp, position)])
    #expect(server.begin(for: viewer) != nil)
    server.receive(input, from: viewer)
    #expect(events.last == .button(.leftDown, position))
    server.stop()
    #expect(events.last == .button(.leftUp, position))
}

@Test @MainActor func pointerClientOrdersInputForTheServer() throws {
    var client = PointerControlClient()
    let early = (client.move(by: CGVector(dx: 10, dy: 10)), client.press(.leftClick))
    #expect(!early.0 && early.1 == nil)

    let start = CGPoint(x: 0.5, y: 0.5)
    var events: [PointerControlServer.Event] = []
    let server = PointerControlServer(
        initialState: { .init(position: start, width: 1000, height: 500) },
        emit: { events.append($0) })
    let id = UUID()
    let ready = try #require(server.begin(for: id))
    let size = CGSize(width: Int(ready.width), height: Int(ready.height))
    let granted = [
        client.begin(position: ready.position, displaySize: size),
        client.begin(position: ready.position, displaySize: size),
    ]
    #expect(granted == [true, false])
    #expect(client.displaySize == CGSize(width: 1000, height: 500))

    func send(_ message: PointerMessage?) throws {
        let message = try #require(message)
        server.receive(message.encoded, from: id)
    }
    // Moves add up locally and go out as one.
    let steps = [client.move(by: CGVector(dx: 62.5, dy: -25)), client.move(by: CGVector(dx: 62.5, dy: -25))]
    #expect(steps == [true, true])
    try send(client.takeMove())
    let repeated = client.takeMove()
    #expect(repeated == nil)
    try send(client.press(.leftDown))
    #expect(client.dragging)
    // Moves past the edge stop there.
    let edge = [client.move(by: CGVector(dx: 10_000, dy: 10_000)), client.move(by: CGVector(dx: 1, dy: 1))]
    #expect(edge == [true, false])
    try send(client.takeMove())
    try send(client.press(.leftUp))
    #expect(!client.dragging)
    try send(client.scroll(lines: 1_000))
    let still = client.move(by: .zero)
    #expect(client.scroll(lines: 0) == nil && !still)
    // Taking the server's position replaces an unsent move.
    _ = client.move(by: CGVector(dx: -10, dy: 0))
    client.adopt(CGPoint(x: 0.25, y: 0.75))
    let replaced = client.takeMove()
    #expect(replaced == nil)
    #expect(client.position == CGPoint(x: 0.25, y: 0.75))

    let moved = CGPoint(x: 0.625, y: 0.4)
    let corner = CGPoint(x: 1, y: 1)
    #expect(events == [
        .move(moved), .button(.leftDown, moved),
        .move(corner, dragging: .leftDown), .button(.leftUp, corner), .scroll(lines: 100),
    ])
}

@Test func pointerClientQuantizesScrollVectorsAndMovesAbsolutely() {
    let start = CGPoint(x: 0.25, y: 0.75)
    let target = CGPoint(x: 0.75, y: 0.25)
    var client = PointerControlClient()
    let accepted = client.begin(position: start, displaySize: CGSize(width: 640, height: 360))
    let moved = client.move(to: target)
    let move = client.takeMove()
    let primary = client.press(.leftDown, clickCount: 2)
    #expect(accepted && moved)
    #expect(move == .move(sequence: 1, afterButton: 0, position: target))
    #expect(
        primary == .button(
            sequence: 2, afterButton: 0, action: .leftDown, clickCount: 2, position: target))
    #expect(client.dragging)
    _ = client.press(.leftUp, clickCount: 2)
    #expect(!client.dragging)

    let step = CGVector(dx: 0.5, dy: -0.75)
    let fraction = client.scroll(by: step, unit: .pixel, at: target)
    let lines = client.scroll(by: CGVector(dx: 2, dy: 0), unit: .line, at: start)
    let pixels = client.scroll(by: step, unit: .pixel, at: target)
    let moveAfterScroll = client.takeMove()
    #expect(fraction == nil)
    #expect(lines == .scrollVector(unit: .line, x: 2, y: 0, position: start))
    #expect(pixels == .scrollVector(unit: .pixel, x: 1, y: -1, position: target))
    #expect(moveAfterScroll == nil)
}

@Test @MainActor func secondaryDragIsOrderedAndScrollDoesNotMoveThePointer() {
    let initial = CGPoint(x: 0.25, y: 0.25)
    let dragged = CGPoint(x: 0.4, y: 0.4)
    let scrollTarget = CGPoint(x: 0.9, y: 0.9)
    let owner = UUID()
    var events: [PointerControlServer.Event] = []
    let server = PointerControlServer(
        initialState: { .init(position: initial, width: 640, height: 360) },
        emit: { events.append($0) })
    #expect(server.begin(for: owner) != nil)

    func send(_ input: PointerMessage) { server.receive(input.encoded, from: owner) }
    send(.move(sequence: 2, afterButton: 1, position: dragged))
    #expect(events.isEmpty)
    send(.button(sequence: 1, afterButton: 0, action: .rightDown, clickCount: 2, position: initial))
    send(.scrollVector(unit: .pixel, x: 8, y: -7, position: scrollTarget))
    server.end(for: owner)
    #expect(events == [
        .button(.rightDown, initial, clickCount: 2),
        .move(dragged, dragging: .rightDown, clickCount: 2),
        .scrollVector(unit: .pixel, x: 8, y: -7, at: scrollTarget),
        .button(.rightUp, dragged, clickCount: 2),
    ])
}
