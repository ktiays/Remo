//
//  Created by Cyandev on 11/20/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import Network
import Observation
import RemoEngine
import UIKit

@MainActor
@Observable
final class StreamPlayer {
    enum Phase: Equatable {
        case idle, connecting, waitingForVideo, streaming, failed(String)
    }

    private(set) var surface: VideoSurface?
    private(set) var phase = Phase.idle
    /// Pixel size of the remote picture once the first frame arrives.
    private(set) var videoSize: CGSize?
    /// Stream parameters currently active or queued for an in-place reconnect.
    var targetStream: StreamParameters? { pendingStream ?? activeStream }
    var remoteControlAvailable: Bool { controlDisplaySize != nil }
    /// Authoritative Caps Lock indicator echoed from the remote Mac.
    private(set) var capsLockActive = false
    /// Persisted modifier UI states (kept across keyboard hide/show until changed or backgrounded).
    private(set) var modifierStates: [RemoteModifierKey: RemoteModifierState] = [:]

    private var controlDisplaySize: CGSize?
    private var activeStream: StreamParameters?
    private var pendingStream: StreamParameters?
    private var isUserDisconnecting = false
    @ObservationIgnored private var lastModifierSelectTime: [RemoteModifierKey: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var client: RemoteScreenClient?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastPixels: CVPixelBuffer?
    @ObservationIgnored private var log: SessionLog?

    private static let modifierDoubleTapWindow: Duration = .milliseconds(350)

    /// Starts a session; `onFinalFrame` receives a JPEG of the last frame shown once it ends.
    /// `log` receives the same diagnostics and statistics the CLI prints.
    func connect(
        to endpoint: NWEndpoint, wireGuard: WireGuardConfiguration? = nil,
        stream: StreamParameters = StreamParameters(), log: SessionLog? = nil,
        onFinalFrame: ((Data) -> Void)? = nil
    ) {
        guard task == nil else { return }
        let surface = VideoSurface()
        self.surface = surface
        self.log = log
        isUserDisconnecting = false
        activeStream = stream
        pendingStream = nil
        phase = .connecting
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        task = Task {
            var nextStream = stream
            var finalFailure: RemoteScreenClient.Failure?
            while true {
                activeStream = nextStream
                videoSize = nil
                controlDisplaySize = nil
                capsLockActive = false
                modifierStates.removeAll()
                lastModifierSelectTime.removeAll()
                phase = .connecting
                let client = makeClient(stream: nextStream, surface: surface, log: log)
                self.client = client
                let sizeText = nextStream.maximumSize.map { "\($0.width)x\($0.height)" } ?? "default"
                let virtualText =
                    nextStream.virtualDisplay.map {
                        " virtualDisplay=\($0.logicalWidth)x\($0.logicalHeight)@2x(\($0.pixelWidth)x\($0.pixelHeight))"
                    } ?? ""
                log?.write(
                    "Remo \(version) connecting to \(endpoint)\(wireGuard == nil ? "" : " through WireGuard") (size=\(sizeText)\(virtualText) fps=\(nextStream.framesPerSecond) maxBps=\(nextStream.maximumVideoBitRate) audio=\(nextStream.streamsAudio))"
                )
                let failure = await client.run(
                    wireGuard.map { .datagrams(WireGuardDatagramConnection($0, log: log)) } ?? .udp(endpoint))
                self.client = nil
                if let pending = pendingStream, !isUserDisconnecting {
                    pendingStream = nil
                    nextStream = pending
                    surface.clear()
                    log?.write("reconnecting with updated stream parameters")
                    continue
                }
                finalFailure = failure
                break
            }
            log?.write(finalFailure.map { "ended: \($0)" } ?? "disconnected")
            log?.close()
            self.log = nil
            if let pixels = lastPixels, let onFinalFrame {
                Task {
                    if let jpeg = await Self.thumbnail(of: pixels) { onFinalFrame(jpeg) }
                }
            }
            lastPixels = nil
            self.surface = nil
            self.client = nil
            activeStream = nil
            pendingStream = nil
            isUserDisconnecting = false
            videoSize = nil
            controlDisplaySize = nil
            capsLockActive = false
            modifierStates.removeAll()
            lastModifierSelectTime.removeAll()
            phase = finalFailure.map { .failed(Self.message(for: $0, wireGuard: wireGuard != nil)) } ?? .idle
            task = nil
        }
    }

    /// Reconnects the active session in place with updated stream parameters (for example, after
    /// rotation or window resizing changes the virtual display size) without dismissing the player.
    func reconnect(stream: StreamParameters) {
        guard task != nil, !isUserDisconnecting, stream != targetStream else { return }
        pendingStream = stream
        surface?.clear()
        phase = .connecting
        client?.disconnect()
    }

    func disconnect() {
        isUserDisconnecting = true
        pendingStream = nil
        client?.disconnect()
    }

    private func makeClient(
        stream: StreamParameters, surface: VideoSurface, log: SessionLog?
    ) -> RemoteScreenClient {
        let diagnostics = Diagnostics(handler: log.map { log in { log.write($0.description) } })
        return RemoteScreenClient(
            configuration: .init(stream: stream, diagnostics: diagnostics),
            onFrame: { [weak self] in try self?.present($0, on: surface) },
            onEvent: { [weak self] in self?.handle($0) })
    }

    private func handle(_ event: RemoteScreenClient.Event) {
        switch event {
        case .state(.connecting): phase = .connecting
        case .state(.waitingForVideo):
            phase = .waitingForVideo
            log?.write("connected; waiting for video")
        case .state(.streaming):
            phase = .streaming
            log?.write("streaming")
        case .state(.idle): break
        case .statistics(let statistics): log?.write(statistics.description)
        case .cursor(let cursor):
            surface?.cursor = cursor
        case let .controlAvailable(size, capsLock):
            controlDisplaySize = size
            capsLockActive = capsLock
            log?.write("remote control granted for a \(Int(size.width))x\(Int(size.height)) display")
        case .capsLockChanged(let isOn):
            capsLockActive = isOn
        }
    }

    func handleTrackpad(_ gesture: TrackpadGesture) {
        guard let client, let displaySize = controlDisplaySize, let surface, !surface.bounds.isEmpty
        else { return }
        switch gesture {
        case let .move(delta):
            // Finger travel follows the picture, so a zoomed view moves the pointer less. The
            // client moves the cursor drawn on the surface at once.
            let bounds = surface.bounds
            let scale =
                min(bounds.width / displaySize.width, bounds.height / displaySize.height)
                * surface.zoom
            client.movePointer(by: CGVector(dx: delta.x / scale, dy: delta.y / scale))
        case let .button(action, clickCount):
            client.pressPointer(action, clickCount: clickCount)
        case let .scroll(lines):
            client.scroll(lines: lines)
        case let .point(position):
            // Hardware reports where the pointer is, not how far it went.
            client.movePointer(to: position)
        case let .scrollAt(delta, unit, position):
            client.scrollPointer(by: delta, unit: unit, at: position)
        }
    }

    // MARK: Keyboard

    func toggleModifier(_ key: RemoteModifierKey) {
        let now = ContinuousClock.now
        switch modifierStates[key] ?? .idle {
        case .idle:
            modifierStates[key] = .selected
            lastModifierSelectTime[key] = now
        case .selected:
            if let previous = lastModifierSelectTime[key],
                previous.duration(to: now) <= Self.modifierDoubleTapWindow
            {
                modifierStates[key] = .locked
            } else {
                modifierStates[key] = .idle
            }
            lastModifierSelectTime[key] = nil
        case .locked:
            modifierStates[key] = .idle
            lastModifierSelectTime[key] = nil
        }
        syncModifiers()
    }

    func sendKeystroke(_ key: KeyboardKeyCode) {
        client?.pressKeystroke(key)
        clearOneShotModifiers()
    }

    func sendKeyDown(_ key: KeyboardKeyCode) {
        client?.keyDown(key)
    }

    func sendKeyUp(_ key: KeyboardKeyCode) {
        client?.keyUp(key)
        clearOneShotModifiers()
    }

    func sendCursorScrubStep(_ key: KeyboardKeyCode) {
        client?.pressKeystroke(key)
    }

    func finishCursorScrub() {
        clearOneShotModifiers()
    }

    /// Releases held keys when the keyboard closes without clearing active modifiers, or clears
    /// everything when backgrounding/leaving.
    func releaseKeyboard(includingModifiers: Bool) {
        client?.releaseKeyboard(includingModifiers: includingModifiers)
        if includingModifiers {
            modifierStates.removeAll()
            lastModifierSelectTime.removeAll()
        }
    }

    private func clearOneShotModifiers() {
        var changed = false
        for key in RemoteModifierKey.allCases where modifierStates[key] == .selected {
            modifierStates[key] = .idle
            lastModifierSelectTime[key] = nil
            changed = true
        }
        if changed { syncModifiers() }
    }

    private func syncModifiers() {
        var flags: KeyboardModifiers = []
        for (key, state) in modifierStates where state != .idle {
            flags.insert(key.wireFlag)
        }
        client?.setKeyboardModifiers(flags)
    }

    private func present(_ frame: VideoFrame, on surface: VideoSurface) throws {
        guard try surface.present(frame) else { return }
        lastPixels = frame.pixels
        let size = CGSize(
            width: CVPixelBufferGetWidth(frame.pixels), height: CVPixelBufferGetHeight(frame.pixels))
        if videoSize != size { videoSize = size }
    }

    private static func message(for failure: RemoteScreenClient.Failure, wireGuard: Bool) -> String {
        switch failure {
        case .invalidConfiguration(let problem): problem
        case .setupTimedOut:
            wireGuard ? "The WireGuard handshake timed out." : "Couldn’t open a connection to the server."
        case .connectionFailed(let error), .sendFailed(let error): error.localizedDescription
        case .network(let error): error.localizedDescription
        case .connectionClosed: "The connection to the server closed."
        case .serverNotResponding: "The server stopped responding."
        case .noVideo: "The server responded but no video arrived."
        case .videoFailed(let error): "Video decoding failed. \(error.localizedDescription)"
        case .presentationFailed(let error): "Video display failed. \(error.localizedDescription)"
        case .inputFailed(let error): "Remote input couldn’t be sent. \(error.localizedDescription)"
        }
    }

    @concurrent
    private nonisolated static func thumbnail(of pixels: CVPixelBuffer) async -> Data? {
        let image = CIImage(cvPixelBuffer: pixels)
        let longest = max(image.extent.width, image.extent.height)
        guard longest > 0, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let scale = CIFilter.lanczosScaleTransform()
        scale.inputImage = image
        scale.scale = Float(min(1, 1280 / longest))
        scale.aspectRatio = 1
        guard let output = scale.outputImage else { return nil }
        let options = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.8
        ]
        return CIContext().jpegRepresentation(of: output, colorSpace: colorSpace, options: options)
    }
}
