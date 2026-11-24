//
//  Created by Cyandev on 11/21/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import CoreMedia
import CoreVideo
import Foundation
import Network
import RemoTransport
import Testing

@testable import RemoEngine

/// A flat picture whose brightness steps every time it is polled.
private final class SteppingSource: ScreenFrameSource {
    let width: Int
    let height: Int
    private(set) var started = 0
    private var step: Int64 = 0

    let firstFrameAt: SuspendingClock.Instant

    init(width: Int = 320, height: Int = 180, delay: Duration = .zero) {
        self.width = width
        self.height = height
        firstFrameAt = .now + delay
    }

    func latestFrame() throws -> ScreenFrame? {
        guard .now >= firstFrameAt else { return nil }
        step += 1
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(
            CVPixelBufferGetBaseAddressOfPlane(pixels, 0), Int32(16 + step % 200),
            CVPixelBufferGetBytesPerRowOfPlane(pixels, 0) * height)
        memset(
            CVPixelBufferGetBaseAddressOfPlane(pixels, 1), 128,
            CVPixelBufferGetBytesPerRowOfPlane(pixels, 1) * height / 2)
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return ScreenFrame(pixels: pixels, timestamp: CMTime(value: step, timescale: 30))
    }

    nonisolated(nonsending) func stop() async throws {}
}

@Test(arguments: [false, true]) @MainActor
func clientReceivesACustomSourceOverLoopback(delayedVideo: Bool) async throws {
    var sources: [SteppingSource] = []
    var port: UInt16?
    var disconnects: [(reason: String, failed: Bool)] = []
    var serverStatistics: ServerStatistics?
    let server = try await RemoteScreenServer(
        configuration: .init(
            source: .custom { _ in
                let source = SteppingSource(delay: delayedVideo ? .seconds(5) : .zero)
                sources.append(source)
                return source
            })
    ) { event in
        switch event {
        case .listening(let value): port = value
        case .clientDisconnected(_, let reason, let failed): disconnects.append((reason, failed))
        case .statistics(_, let statistics): serverStatistics = statistics
        default: break
        }
    }
    let listening = Task { try await server.listen(on: 0) }
    defer { server.stop() }
    while port == nil { try await Task.sleep(nanoseconds: 10_000_000) }

    var states: [RemoteScreenClient.State] = []
    var clientStatistics: ClientStatistics?
    var frames = 0
    var client: RemoteScreenClient!
    let (recoveries, recoveryEvents) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    client = RemoteScreenClient(
        configuration: .init(requestsRemoteControl: false, diagnostics: .init { event in
            if event.message.hasPrefix("recovery requested lastDecoded=0 ") { recoveryEvents.yield(()) }
        }),
        onFrame: { frame in
            #expect(CVPixelBufferGetWidth(frame.pixels) == 320)
            frames += 1
            if frames == 45 { client.disconnect() }
        },
        onEvent: { event in
            switch event {
            case .state(let state): states.append(state)
            case .statistics(let statistics): clientStatistics = statistics
            default: break
            }
        })
    let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: port!)!)
    let failure = await client.run(.udp(endpoint))

    recoveryEvents.finish()
    if delayedVideo {
        var iterator = recoveries.makeAsyncIterator()
        let requestedFirstFrame = await iterator.next() != nil
        #expect(requestedFirstFrame)
        #expect(clientStatistics.map { $0.controlsReceived > 0 } == true)
    } else {
        #expect(serverStatistics?.controlsSent == 0)
    }
    #expect(failure == nil)
    #expect(states == [.connecting, .waitingForVideo, .streaming, .idle])
    #expect(frames == 45)
    // One source for the one client, started when it asked for video.
    #expect(sources.count == 1)
    #expect(clientStatistics.map { $0.framesDecoded > 0 } == true)
    #expect(serverStatistics.map { $0.framesQueued > 0 && $0.heartbeatsReceived > 0 } == true)
    // The goodbye ends the server's side cleanly.
    for _ in 0..<100 where disconnects.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(disconnects.map(\.reason) == ["client left"])
    #expect(disconnects.first?.failed == false)

    server.stop()
    try await listening.value
}

@Test @MainActor func deliveryAcksAloneKeepClientAliveUntilSilent() async throws {
    var port: UInt16?
    var reason: String?
    let server = try await RemoteScreenServer(
        configuration: .init(source: .custom { _ in SteppingSource(delay: .seconds(30)) })
    ) { event in
        switch event {
        case .listening(let value): port = value
        case .clientDisconnected(_, let value, _): reason = value
        default: break
        }
    }
    let listening = Task { try await server.listen(on: 0) }
    defer { server.stop() }
    while port == nil { try await Task.sleep(for: .milliseconds(10)) }

    let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: port!)!)
    var controls = 0
    let client = try await NetworkMessageSession(connection: NWConnection(to: endpoint, using: .udp)) {
        data in
        if (try? ControlMessage(decoding: data)) != nil { controls += 1 }
    } closeHandler: { _ in }
    let hello = SessionHandshake.hello(requestsControl: false)
    try client.send(hello.encoded, delivery: hello.delivery)
    try await Task.sleep(for: .seconds(5))
    #expect(reason == nil)
    #expect(controls >= 4)
    client.cancel()
    try await Task.sleep(for: .seconds(2))
    #expect(reason == nil)
    for _ in 0..<40 where reason == nil { try await Task.sleep(for: .milliseconds(100)) }
    #expect(reason == "client timed out")
    server.stop()
    try await listening.value
}

@Test @MainActor func clientNegotiatesStreamParametersInHandshake() async throws {
    let requested = StreamParameters(
        maximumSize: .init(width: 480, height: 270),
        framesPerSecond: 30,
        maximumVideoBitRate: 2_500_000,
        streamsAudio: true)
    var receivedParameters: StreamParameters?
    var startedSession: RemoteScreenServer.SessionInfo?
    var port: UInt16?
    let server = try await RemoteScreenServer(
        configuration: .init(
            source: .custom { parameters in
                receivedParameters = parameters
                let size = parameters.maximumSize ?? .init(width: 320, height: 180)
                return SteppingSource(width: size.width, height: size.height)
            })
    ) { event in
        switch event {
        case .listening(let value): port = value
        case .streamingStarted(_, let session): startedSession = session
        default: break
        }
    }
    let listening = Task { try await server.listen(on: 0) }
    defer { server.stop() }
    while port == nil { try await Task.sleep(for: .milliseconds(10)) }

    var decodedSize: (Int, Int)?
    var client: RemoteScreenClient!
    client = RemoteScreenClient(
        configuration: .init(requestsRemoteControl: false, stream: requested),
        onFrame: { frame in
            decodedSize = (
                CVPixelBufferGetWidth(frame.pixels), CVPixelBufferGetHeight(frame.pixels)
            )
            client.disconnect()
        })
    let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: port!)!)
    let failure = await client.run(.udp(endpoint))

    #expect(failure == nil)
    #expect(receivedParameters == requested)
    #expect(
        startedSession
            == RemoteScreenServer.SessionInfo(
                width: 480, height: 270, framesPerSecond: 30, maximumVideoBitRate: 2_500_000,
                streamsAudio: false))
    #expect(decodedSize?.0 == 480 && decodedSize?.1 == 270)

    server.stop()
    try await listening.value
}

@Test @MainActor func clientNegotiatesVirtualDisplayParametersInHandshake() async throws {
    let requested = StreamParameters(
        virtualDisplay: .init(logicalWidth: 890, logicalHeight: 626),
        framesPerSecond: 60,
        maximumVideoBitRate: 6_000_000,
        streamsAudio: false)
    var receivedParameters: StreamParameters?
    var port: UInt16?
    let server = try await RemoteScreenServer(
        configuration: .init(
            source: .custom { parameters in
                receivedParameters = parameters
                let vd = try #require(parameters.virtualDisplay)
                return SteppingSource(width: vd.pixelWidth, height: vd.pixelHeight)
            })
    ) { event in
        if case .listening(let value) = event { port = value }
    }
    let listening = Task { try await server.listen(on: 0) }
    defer { server.stop() }
    while port == nil { try await Task.sleep(for: .milliseconds(10)) }

    var decodedSize: (Int, Int)?
    var client: RemoteScreenClient!
    client = RemoteScreenClient(
        configuration: .init(requestsRemoteControl: false, stream: requested),
        onFrame: { frame in
            decodedSize = (
                CVPixelBufferGetWidth(frame.pixels), CVPixelBufferGetHeight(frame.pixels)
            )
            client.disconnect()
        })
    let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: port!)!)
    let failure = await client.run(.udp(endpoint))

    #expect(failure == nil)
    #expect(receivedParameters == requested)
    #expect(decodedSize?.0 == 1780 && decodedSize?.1 == 1252)

    server.stop()
    try await listening.value
}

@Test @MainActor func serverRejectsInvalidConfigurations() async {
    await #expect(throws: RemoteScreenServer.SetupError.self) {
        _ = try await RemoteScreenServer(
            configuration: .init(
                source: .custom { _ in SteppingSource() }, allowsRemoteControl: true))
    }
}

@Test @MainActor func clientRejectsInvalidStreamParameters() async {
    let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 7711)
    for stream in [
        StreamParameters(maximumSize: .init(width: 321, height: 240)),
        StreamParameters(virtualDisplay: .init(logicalWidth: 799, logicalHeight: 600)),
        StreamParameters(virtualDisplay: .init(logicalWidth: 800, logicalHeight: 599)),
        StreamParameters(virtualDisplay: .init(logicalWidth: 3601, logicalHeight: 1000)),
        StreamParameters(framesPerSecond: 0),
        StreamParameters(framesPerSecond: 241),
        StreamParameters(maximumVideoBitRate: 0),
    ] {
        let client = RemoteScreenClient(
            configuration: .init(requestsRemoteControl: false, stream: stream), onFrame: { _ in })
        let failure = await client.run(.udp(endpoint))
        if case .invalidConfiguration = failure {
            // Expected.
        } else {
            Issue.record("Expected invalidConfiguration failure, got \(String(describing: failure))")
        }
    }
}

@Test @MainActor func clientSendsPositionedHardwareInputOverLoopback() async throws {
    let firstClick = CGPoint(x: 0.2, y: 0.3)
    let secondClick = CGPoint(x: 0.8, y: 0.7)
    let scrollTarget = CGPoint(x: 0.4, y: 0.6)
    let lastButton = PointerControlServer.Event.button(.leftUp, secondClick, clickCount: 2)
    let scroll = PointerControlServer.Event.scrollVector(unit: .pixel, x: 9, y: -15, at: scrollTarget)
    var events: [PointerControlServer.Event] = []
    let pointer = PointerControlServer(
        initialState: { .init(position: .zero, width: 1920, height: 1080) },
        emit: { events.append($0) })
    let keyboard = KeyboardControlServer(readCapsLock: { true }, emit: { _ in })
    var port: UInt16?
    let server = try await RemoteScreenServer(
        configuration: .init(source: .custom { _ in SteppingSource() }, allowsRemoteControl: true),
        cursor: nil, pointer: pointer, keyboard: keyboard
    ) { event in
        if case .listening(let value) = event { port = value }
    }
    let listening = Task { try await server.listen(on: 0) }
    defer { server.stop() }
    for _ in 0..<100 where port == nil { try await Task.sleep(for: .milliseconds(10)) }
    let portValue = try #require(port.flatMap(NWEndpoint.Port.init(rawValue:)))
    let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: portValue)

    var capsLock: Bool?
    let client = RemoteScreenClient(onFrame: { _ in }, onEvent: { event in
        if case .controlAvailable(_, let isOn) = event { capsLock = isOn }
    })
    let run = Task { await client.run(.udp(endpoint)) }
    defer { run.cancel() }
    for _ in 0..<200 where client.state != .streaming || capsLock == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(client.state == .streaming && capsLock == true)
    client.movePointer(to: firstClick)
    client.pressPointer(.leftDown, clickCount: 1)
    client.pressPointer(.leftUp, clickCount: 1)
    client.movePointer(to: secondClick)
    client.pressPointer(.leftDown, clickCount: 2)
    client.pressPointer(.leftUp, clickCount: 2)
    client.scrollPointer(by: CGVector(dx: 9, dy: -15), unit: .pixel, at: scrollTarget)
    for _ in 0..<200 {
        if events.contains(lastButton), events.contains(scroll) { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    client.disconnect()
    #expect(await run.value == nil)
    #expect(events.contains(scroll))
    let buttons = events.filter { if case .button = $0 { true } else { false } }
    #expect(buttons == [
        .button(.leftDown, firstClick), .button(.leftUp, firstClick),
        .button(.leftDown, secondClick, clickCount: 2), lastButton,
    ])
    server.stop()
    try await listening.value
}
