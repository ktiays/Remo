//
//  Created by Cyandev on 11/21/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import CoreGraphics
import Dispatch
import Foundation
import Network
import RemoCodec
import RemoTransport

/// Views a server's screen: keeps the session alive, decodes video, plays audio and, once the
/// server grants it, drives the remote pointer.
@MainActor
public final class RemoteScreenClient {
    /// How to reach the server.
    public enum Link {
        case udp(NWEndpoint)
        /// An unstarted datagram driver, such as a tunnel, that the session takes ownership of.
        case datagrams(any DatagramConnection)
    }

    public struct Configuration: Sendable {
        /// How long opening the link may take, including any tunnel handshake.
        public var setupTimeout = Duration.seconds(8)
        /// How long the server may answer without sending a single frame.
        public var noVideoTimeout = Duration.seconds(15)
        /// Asks the server for remote pointer and keyboard control. A server grants it to one client at a time.
        public var requestsRemoteControl = true
        /// Video and audio settings requested during the session handshake.
        public var stream = StreamParameters()
        public var diagnostics = Diagnostics()

        public init(
            setupTimeout: Duration = .seconds(8), noVideoTimeout: Duration = .seconds(15),
            requestsRemoteControl: Bool = true, stream: StreamParameters = StreamParameters(),
            diagnostics: Diagnostics = Diagnostics()
        ) {
            self.setupTimeout = setupTimeout
            self.noVideoTimeout = noVideoTimeout
            self.requestsRemoteControl = requestsRemoteControl
            self.stream = stream
            self.diagnostics = diagnostics
        }
    }

    public enum State: Sendable, Equatable {
        case idle, connecting, waitingForVideo, streaming
    }

    public enum Failure: Error {
        case invalidConfiguration(String)
        case setupTimedOut
        case connectionFailed(any Error)
        case connectionClosed
        case network(NWError)
        case serverNotResponding
        case noVideo
        case sendFailed(any Error)
        case videoFailed(any Error)
        /// The `onFrame` handler threw.
        case presentationFailed(any Error)
        case inputFailed(any Error)
    }

    public enum Event {
        case state(State)
        /// The server granted remote control. Sizes are in remote display points.
        case controlAvailable(displaySize: CGSize, capsLock: Bool)
        /// The remote Mac's Caps Lock indicator state changed.
        case capsLockChanged(Bool)
        /// The cursor to draw over the picture changed: the server's, or where this client's
        /// pointer input put it.
        case cursor(RemoteCursor)
        case statistics(ClientStatistics)
    }

    public private(set) var state = State.idle
    /// The remote display's size in points while this client has remote control.
    public var remoteControlDisplaySize: CGSize? { pointer.displaySize }
    /// The host Mac's latest Caps Lock indicator state.
    public var capsLock: Bool { keyboard.capsLock }
    /// The cursor to draw over the picture, once the server has described it.
    public private(set) var cursor: RemoteCursor?

    private let configuration: Configuration
    private let onFrame: (VideoFrame) throws -> Void
    private let onEvent: (Event) -> Void
    private let trace: HeartbeatTrace
    private var work: Task<Void, Never>?
    private var failure: Failure?
    private var transport: NetworkMessageSession?
    private var video: VideoSession?
    private var playback: AudioPlayback?
    private var audioDisabled = false
    private var pointer = PointerControlClient()
    private var keyboard = KeyboardControlClient()
    private var cursorTracker = CursorTracker()
    /// Whether this client has moved the pointer since it last took the server's position.
    private var pointerMovedLocally = false
    private var lastMoveSent: Instant?
    private var moveFlush: Task<Void, Never>?
    private var lastSeen = Instant.now
    private var lastFrame = Instant.now
    private var counters = Counters()

    private struct Counters {
        var framesDecoded: UInt64 = 0
        var latestFrame: UInt64 = 0
        var videoBytes = 0
        var controls: UInt64 = 0
        var latestControl: UInt64 = 0
        var heartbeats = 0
        var previousFrames: UInt64 = 0
        var previousBytes = 0
        var lastReport = Instant.now
    }

    /// `onFrame` receives each decoded picture; throwing ends the session.
    public init(
        configuration: Configuration = Configuration(),
        onFrame: @escaping @MainActor (VideoFrame) throws -> Void,
        onEvent: @escaping @MainActor (Event) -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.onFrame = onFrame
        self.onEvent = onEvent
        trace = HeartbeatTrace(layer: "session", diagnostics: configuration.diagnostics)
    }

    /// Runs one session until `disconnect()`, cancellation or a failure, which it returns.
    public func run(_ link: Link) async -> Failure? {
        guard work == nil else { return nil }
        failure = nil
        let work = Task { await session(link) }
        self.work = work
        await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        self.work = nil
        return failure
    }

    /// Leaves the session. `run` then returns without a failure.
    public func disconnect() {
        work?.cancel()
    }

    // MARK: Pointer

    /// Moves the remote pointer by a distance in remote display points. The cursor follows at
    /// once; the server hears of it at most 30 times a second, or 60 while dragging.
    public func movePointer(by delta: CGVector) {
        guard isRunning, state == .streaming, pointer.move(by: delta) else { return }
        pointerMovedLocally = true
        publishCursor()
        scheduleMove()
    }

    /// Moves the remote pointer to an absolute position, normalized to the display with the
    /// origin at its upper left. The same pacing and coalescing as `movePointer(by:)` apply.
    public func movePointer(to position: CGPoint) {
        guard isRunning, state == .streaming, pointer.move(to: position) else { return }
        pointerMovedLocally = true
        publishCursor()
        scheduleMove()
    }

    public func pressPointer(_ button: PointerButton, clickCount: Int = 1) {
        // The button lands where the cursor is drawn; send the move first so hover is right.
        flushMove()
        sendPointer { $0.press(button, clickCount: clickCount) }
    }

    /// Whole lines; positive values move the content down, following the finger.
    public func scroll(lines: Int) {
        sendPointer { $0.scroll(lines: lines) }
    }

    /// Scrolls both axes at `position`, normalized like `movePointer(to:)`, in `unit` steps
    /// signed like `scroll(lines:)`.
    public func scrollPointer(
        by delta: CGVector, unit: PointerScrollUnit, at position: CGPoint
    ) {
        sendPointer { $0.scroll(by: delta, unit: unit, at: position) }
    }

    private func scheduleMove() {
        guard moveFlush == nil else { return }
        let interval =
            pointer.dragging ? SessionTiming.dragInterval : SessionTiming.pointerMoveInterval
        guard let last = lastMoveSent, !Instant.now.hasElapsed(interval, since: last) else {
            flushMove()
            return
        }
        moveFlush = Task { [weak self] in
            try? await Task.sleep(until: last + interval, clock: .suspending)
            guard !Task.isCancelled, let self else { return }
            moveFlush = nil
            flushMove()
        }
    }

    private func flushMove() {
        moveFlush?.cancel()
        moveFlush = nil
        guard pointer.moved else { return }
        lastMoveSent = .now
        sendPointer { $0.takeMove() }
    }

    private func publishCursor() {
        let controlling = pointer.displaySize != nil
        guard
            let next = cursorTracker.cursor(
                at: controlling ? pointer.position : nil,
                forceVisible: controlling && pointerMovedLocally),
            next != cursor
        else { return }
        cursor = next
        onEvent(.cursor(next))
    }

    private func receiveCursor(_ data: Data) {
        guard let message = try? CursorMessage(decoding: data) else { return }
        lastSeen = .now
        switch message {
        case .shape(let shape):
            guard cursorTracker.receive(shape) else { return }
        case .state(let sequence, let state):
            if let position = cursorTracker.receive(sequence: sequence, state),
                pointer.displaySize != nil
            {
                pointer.adopt(position)
                pointerMovedLocally = false
            }
        }
        publishCursor()
    }

    private func sendPointer(_ make: (inout PointerControlClient) -> PointerMessage?) {
        guard isRunning, state == .streaming, let transport, let message = make(&pointer) else {
            return
        }
        do {
            try transport.send(message.encoded, delivery: message.delivery)
        } catch {
            // A move or scroll that finds no room is simply late. A button change must not vanish.
            guard case .button = message else { return }
            fail(.inputFailed(error))
        }
    }

    // MARK: Keyboard

    /// Synchronizes the active modifier keys immediately, in strict order with all key events.
    public func setKeyboardModifiers(_ modifiers: KeyboardModifiers) {
        sendKeyboard { $0.setModifiers(modifiers) }
    }

    /// Sends an atomic key press + release (short tap).
    public func pressKeystroke(_ key: KeyboardKeyCode) {
        sendKeyboard { $0.keystroke(key) }
    }

    /// Sends a key-down event for a held key; pair with `keyUp(_:)` on release.
    public func keyDown(_ key: KeyboardKeyCode) {
        sendKeyboard { $0.keyDown(key) }
    }

    /// Sends a key-up event for a previously held key.
    public func keyUp(_ key: KeyboardKeyCode) {
        sendKeyboard { $0.keyUp(key) }
    }

    /// Releases any held keys and optionally clears all active modifiers.
    public func releaseKeyboard(includingModifiers: Bool = true) {
        guard isRunning, state == .streaming, let transport else { return }
        for message in keyboard.releaseAll(includingModifiers: includingModifiers) {
            do {
                try transport.send(message.encoded, delivery: message.delivery)
            } catch {
                fail(.inputFailed(error))
                return
            }
        }
    }

    private func sendKeyboard(_ make: (inout KeyboardControlClient) -> KeyboardMessage?) {
        guard isRunning, state == .streaming, let transport, let message = make(&keyboard) else {
            return
        }
        do {
            try transport.send(message.encoded, delivery: message.delivery)
        } catch {
            fail(.inputFailed(error))
        }
    }

    // MARK: Session

    private var isRunning: Bool { work.map { !$0.isCancelled } ?? false }

    private func setState(_ state: State) {
        guard state != self.state else { return }
        self.state = state
        onEvent(.state(state))
    }

    /// Only the first failure counts, and none after the client chose to leave.
    private func fail(_ failure: Failure) {
        guard let work, !work.isCancelled else { return }
        self.failure = failure
        work.cancel()
    }

    private func session(_ link: Link) async {
        audioDisabled = false
        pointer = PointerControlClient()
        keyboard = KeyboardControlClient()
        cursorTracker = CursorTracker()
        cursor = nil
        pointerMovedLocally = false
        lastMoveSent = nil
        counters = Counters()
        setState(.connecting)
        trace.write(nil, "client opening")
        await stream(link)
        moveFlush?.cancel()
        moveFlush = nil
        trace.write(nil, "client stop failure=\(failure.map { "\($0)" } ?? "none")")
        playback?.stop()
        playback = nil
        video?.close()
        video = nil
        if let session = transport {
            // Without the goodbye, the server holds the capture and pointer until it times out.
            // Keep the link open long enough to send and retry it; nothing else is processed.
            if (try? session.send(MessageKind.goodbye.encoded, delivery: .essential)) != nil {
                let roundTrip = session.statistics.roundTripTime.map(Duration.seconds)
                await linger(
                    min(.milliseconds(250), max(.milliseconds(50), (roundTrip ?? .milliseconds(100)) * 2)))
            }
            transport = nil
            session.cancel()
        }
        setState(.idle)
    }

    /// Waits even though the session task is already cancelled.
    private func linger(_ duration: Duration) async {
        // A new task, so the session task's cancellation doesn't cut it short.
        await Task { try? await Task.sleep(for: duration) }.value
    }

    private func stream(_ link: Link) async {
        if let problem = configuration.stream.validationProblem {
            fail(.invalidConfiguration(problem))
            return
        }
        let setupTimeout = Task { [weak self, configuration] in
            try await Task.sleep(for: configuration.setupTimeout)
            self?.fail(.setupTimedOut)
        }
        defer { setupTimeout.cancel() }

        let session: NetworkMessageSession
        do {
            session = try await open(link)
        } catch is CancellationError {
            return
        } catch {
            fail(.connectionFailed(error))
            return
        }
        transport = session
        setupTimeout.cancel()
        guard isRunning else { return }
        trace.write(nil, "client ready")

        do {
            video = VideoSession(
                send: { [weak self] data, delivery, onOutcome in
                    guard let session = self?.transport else {
                        throw NetworkMessageSession.SendError.closed
                    }
                    return try session.send(data, delivery: delivery, onOutcome: onOutcome)
                },
                cancel: { [weak self] in self?.transport?.cancelMessage($0) },
                patience: { [weak self] in
                    SessionTiming.framePatience(
                        roundTrip: self?.transport?.statistics.roundTripTime.map(Duration.seconds))
                },
                onFrame: { [weak self] id, frame, bytes in
                    self?.present(VideoFrame(frame), id: id, bytes: bytes)
                },
                onEvent: { [weak self] event in
                    guard let self, let line = event.diagnostic else { return }
                    configuration.diagnostics.info(nil, line)
                },
                onFailure: { [weak self] error in self?.fail(.videoFailed(error)) })
            let hello = SessionHandshake.hello(
                requestsControl: configuration.requestsRemoteControl,
                stream: configuration.stream)
            try session.send(hello.encoded, delivery: hello.delivery)
            trace.write(nil, "hello queued")
            setState(.waitingForVideo)
            try await keepAlive(session)
        } catch is CancellationError {
        } catch {
            fail(.sendFailed(error))
        }
    }

    private func open(_ link: Link) async throws -> NetworkMessageSession {
        let receive: (Data) -> Void = { [weak self] in self?.receive($0) }
        let close: (NetworkMessageSession.CloseReason) -> Void = { [weak self] reason in
            guard let self else { return }
            configuration.diagnostics.info(nil, "client connection closed: \(reason)")
            guard transport != nil else { return }
            if case .network(let error) = reason {
                fail(.network(error))
            } else {
                fail(.connectionClosed)
            }
        }
        switch link {
        case .udp(let endpoint):
            let parameters = DatagramMonitor.parameters(for: configuration.diagnostics)
            return try await NetworkMessageSession(
                connection: NWConnection(to: endpoint, using: parameters),
                dataHandler: receive, closeHandler: close)
        case .datagrams(let driver):
            return try await NetworkMessageSession(
                driver: driver, dataHandler: receive, closeHandler: close)
        }
    }

    private func keepAlive(_ session: NetworkMessageSession) async throws {
        let started = Instant.now
        lastSeen = started
        lastFrame = started
        counters.lastReport = started
        while isRunning {
            let now = Instant.now
            if now - lastSeen >= SessionTiming.serverTimeout {
                fail(.serverNotResponding)
                return
            }
            if state == .waitingForVideo, now - started >= configuration.noVideoTimeout {
                fail(.noVideo)
                return
            }
            if now - lastFrame >= SessionTiming.videoStall {
                try video?.requestRefresh()
            }
            do {
                try session.send(
                    MessageKind.heartbeat.encoded, delivery: .retrying(replacing: .heartbeat))
                counters.heartbeats += 1
                trace.write(nil, "heartbeat queued count=\(counters.heartbeats)")
            } catch NetworkMessageSession.SendError.backpressure {
                // The next heartbeat replaces this one.
            }
            report(session)
            try await Task.sleep(for: SessionTiming.heartbeatInterval)
        }
    }

    private func receive(_ data: Data) {
        // Video first: it also uses unrelated messages to retry lost refresh requests.
        guard isRunning, let byte = data.first else { return }
        if video?.receive(data) == true {
            lastSeen = .now
            return
        }
        if byte == MessageKind.audio.rawValue {
            guard let packet = try? AudioMessage(decoding: data) else { return }
            lastSeen = .now
            guard configuration.stream.streamsAudio, !audioDisabled else { return }
            if playback == nil {
                playback = AudioPlayback(
                    traceDirectory: configuration.diagnostics.audioTraceDirectory
                ) { [weak self] error in
                    guard let self else { return }
                    audioDisabled = true
                    configuration.diagnostics.info(nil, "Audio playback failed: \(error)")
                }
            }
            playback?.receive(packet)
            return
        }
        switch MessageKind(rawValue: byte) {
        case .control:
            guard let control = try? ControlMessage(decoding: data) else { return }
            counters.controls += 1
            counters.latestControl = max(counters.latestControl, control.sequence)
            lastSeen = .now
        case .sessionReady:
            guard case let .ready(control) = try? SessionHandshake(decoding: data) else { return }
            lastSeen = .now
            guard let control else { return }
            let size = CGSize(width: Int(control.displayWidth), height: Int(control.displayHeight))
            if pointer.begin(position: control.pointerPosition, displaySize: size) {
                keyboard.begin(capsLock: control.capsLock)
                onEvent(.controlAvailable(displaySize: size, capsLock: control.capsLock))
                publishCursor()
            }
        case .keyboardState:
            lastSeen = .now
            if keyboard.receiveState(data) {
                onEvent(.capsLockChanged(keyboard.capsLock))
            }
        case .cursorShape, .cursorState:
            receiveCursor(data)
        default: break
        }
    }

    private func present(_ frame: VideoFrame, id: UInt64, bytes: Int) {
        guard isRunning else { return }
        lastFrame = .now
        lastSeen = lastFrame
        counters.framesDecoded += 1
        counters.latestFrame = max(counters.latestFrame, id)
        counters.videoBytes += bytes
        do { try onFrame(frame) } catch {
            fail(.presentationFailed(error))
            return
        }
        if state == .waitingForVideo { setState(.streaming) }
    }

    private func report(_ session: NetworkMessageSession) {
        let now = Instant.now
        let elapsed = now - counters.lastReport
        guard elapsed >= SessionTiming.reportInterval else { return }
        let seconds = elapsed / .seconds(1)
        let statistics = ClientStatistics(
            framesPerSecond: Double(counters.framesDecoded - counters.previousFrames) / seconds,
            videoBitsPerSecond: Double(counters.videoBytes - counters.previousBytes) * 8 / seconds,
            framesDecoded: counters.framesDecoded, latestFrame: counters.latestFrame,
            controlsReceived: counters.controls,
            latestControl: counters.latestControl, heartbeatsSent: counters.heartbeats,
            audio: playback?.statistics, link: LinkStatistics(session.statistics))
        counters.previousFrames = counters.framesDecoded
        counters.previousBytes = counters.videoBytes
        counters.lastReport = now
        onEvent(.statistics(statistics))
    }
}

extension RemoteScreenClient.Failure: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidConfiguration(let problem): "invalid configuration: \(problem)"
        case .setupTimedOut: "connection setup timed out"
        case .connectionFailed(let error): "connection setup: \(error)"
        case .connectionClosed: "connection closed"
        case .network(let error): "connection closed: \(error)"
        case .serverNotResponding: "server timed out"
        case .noVideo: "server responded but no video arrived"
        case .sendFailed(let error): "send failed: \(error)"
        case .videoFailed(let error): "video failed: \(error)"
        case .presentationFailed(let error): "frame handler failed: \(error)"
        case .inputFailed(let error): "remote input failed: \(error)"
        }
    }
}
