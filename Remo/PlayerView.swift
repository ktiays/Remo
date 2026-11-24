//
//  Created by Cyandev on 11/21/26.
//

import RemoEngine
import SwiftUI
import UIKit

/// The remote screen with system chrome hidden and a compact control pill that fades while streaming.
struct PlayerView: View {
    let player: StreamPlayer
    let surface: VideoSurface
    let title: String

    private static let controlsHitPadding: CGFloat = 12

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.scenePhase) private var scenePhase
    @State private var controlsDimmed = false
    @State private var controlsFrame = CGRect.zero
    @State private var keyboardVisible = false
    @State private var keyboardFrame = CGRect.zero
    @State private var fadeTask: Task<Void, Never>?
    @State private var resizeReconnectTask: Task<Void, Never>?
    @State private var measuredSceneSize = CGSize.zero

    var body: some View {
        // The backdrop and video fill the full screen. On iOS 27.1+, floating controls and the
        // scroll wheel position themselves against exact hardware occlusions and corner insets
        // instead of the full-edge rectangular safe area.
        ZStack {
            // Hosts the video as the view it zooms, so it stays up from the moment the session
            // starts: the surface only draws frames while it is in a window. The trackpad canvas
            // fills the entire screen (ignoring all safe areas) and aspect-fits the picture inside
            // it.
            TrackpadView(
                onInput: player.handleTrackpad,
                excludedRects: [controlsFrame] + (keyboardVisible ? [keyboardFrame] : []),
                showsWheel: player.phase == .streaming && player.remoteControlAvailable,
                controlsPointer: player.phase == .streaming && player.remoteControlAvailable,
                surface: surface, videoSize: player.videoSize,
                bottomInset: keyboardVisible ? keyboardFrame.height : 0)

            if let status {
                ProgressView(status)
                    .tint(.white)
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Color.black
                .onGeometryChange(for: CGSize.self) {
                    $0.size
                } action: { newSize in
                    measuredSceneSize = newSize
                    handleSceneResize(newSize)
                }
                .ignoresSafeArea()
        }
        .overlay {
            if keyboardVisible {
                ZStack(alignment: .bottom) {
                    Color.clear.allowsHitTesting(false)
                    RemoteKeyboardView(
                        modifierStates: player.modifierStates,
                        capsLockActive: player.capsLockActive,
                        onToggleModifier: { player.toggleModifier($0) },
                        onKeystroke: { player.sendKeystroke($0) },
                        onKeyDown: { player.sendKeyDown($0) },
                        onKeyUp: { player.sendKeyUp($0) },
                        onScrubStep: { player.sendCursorScrubStep($0) },
                        onScrubEnd: { player.finishCursorScrub() },
                        onDismiss: { setKeyboardVisible(false) }
                    )
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .global)
                    } action: {
                        keyboardFrame = $0
                    }
                }
                .ignoresSafeArea(edges: [.bottom, .horizontal])
                .transition(.move(edge: .bottom))
            }
        }
        .overlay {
            controlsOverlay
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        // Watching or driving the remote screen doesn’t touch the phone’s own screen often enough
        // to keep it awake, so auto-lock is off for as long as the player is up.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            fadeTask?.cancel()
            resizeReconnectTask?.cancel()
            resizeReconnectTask = nil
            player.releaseKeyboard(includingModifiers: true)
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                resizeReconnectTask?.cancel()
                resizeReconnectTask = nil
                player.releaseKeyboard(includingModifiers: true)
            } else if measuredSceneSize.width > 0, measuredSceneSize.height > 0 {
                handleSceneResize(measuredSceneSize)
            }
        }
        .onChange(of: player.remoteControlAvailable) { _, available in
            if !available && keyboardVisible {
                setKeyboardVisible(false)
            }
        }
        .task(id: player.phase) {
            withAnimation { controlsDimmed = false }
            guard player.phase == .streaming, !voiceOver else { return }
            scheduleFadeOut()
        }
    }

    private var status: String? {
        switch player.phase {
        case .connecting: String(localized: "Connecting…")
        case .waitingForVideo: String(localized: "Waiting for video…")
        default: nil
        }
    }

    @ViewBuilder
    private var controlsOverlay: some View {
        if #available(iOS 27.1, *) {
            GeometryReader { proxy in
                let layout = ScreenOcclusionLayout(proxy: proxy)
                let insets = layout.topLeadingInsets(
                    for: controlsFrame.size,
                    innerPadding: Self.controlsHitPadding)
                controls
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .global)
                    } action: {
                        controlsFrame = $0
                    }
                    .padding(.leading, insets.leading)
                    .padding(.top, insets.top)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .ignoresSafeArea()
        } else {
            controls
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .global)
                } action: {
                    controlsFrame = $0
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var controls: some View {
        let showKeyboardButton =
            player.remoteControlAvailable && (!controlsDimmed || keyboardVisible)

        return HStack(spacing: 0) {
            Button {
                player.disconnect()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .padding(.trailing, showKeyboardButton ? 10 : 14)
                }
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Disconnect from \(title)")

            if showKeyboardButton {
                Rectangle()
                    .fill(.white.opacity(0.2))
                    .frame(width: 1, height: 18)

                Button {
                    setKeyboardVisible(!keyboardVisible)
                } label: {
                    Image(systemName: "keyboard")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(keyboardVisible ? Color(white: 0.08) : .white)
                        .frame(width: 34, height: 34)
                        .background(
                            keyboardVisible ? Color(white: 0.96) : .white.opacity(0.14),
                            in: .circle)
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
                .padding(.trailing, 5)
                .accessibilityLabel(keyboardVisible ? "Hide keyboard" : "Show keyboard")
            }
        }
        .glassEffect(.regular.tint(.black.opacity(0.45)).interactive(), in: .capsule)
        .opacity(controlsDimmed && !keyboardVisible ? 0.4 : 1)
        .overlay {
            if controlsDimmed && !keyboardVisible {
                Capsule()
                    .fill(.clear)
                    .contentShape(.capsule)
                    .onTapGesture {
                        withAnimation(.spring(duration: 0.32, bounce: 0.1)) {
                            controlsDimmed = false
                        }
                        scheduleFadeOut()
                    }
            }
        }
        .padding(Self.controlsHitPadding)
    }

    private func setKeyboardVisible(_ visible: Bool) {
        if !visible {
            // Release any key mid-hold without clearing active modifiers, so modified trackpad
            // actions (e.g. ⌘+Click) continue to work after dismissing the keyboard.
            player.releaseKeyboard(includingModifiers: false)
        }
        withAnimation(.spring) {
            keyboardVisible = visible
            if visible {
                controlsDimmed = false
            }
        }
        if visible {
            fadeTask?.cancel()
        } else {
            scheduleFadeOut()
        }
    }

    private func handleSceneResize(_ size: CGSize) {
        guard scenePhase == .active, size.width > 0, size.height > 0,
            let current = player.targetStream,
            let currentVirtualDisplay = current.virtualDisplay
        else { return }
        let target = RemoteServer.StreamSettings.virtualDisplay(for: size)
        if target == currentVirtualDisplay {
            resizeReconnectTask?.cancel()
            resizeReconnectTask = nil
            return
        }
        resizeReconnectTask?.cancel()
        resizeReconnectTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, scenePhase == .active,
                let latest = player.targetStream, latest.virtualDisplay != nil
            else { return }
            let settledTarget = RemoteServer.StreamSettings.virtualDisplay(for: measuredSceneSize)
            guard settledTarget != latest.virtualDisplay else { return }
            var updated = latest
            updated.virtualDisplay = settledTarget
            player.reconnect(stream: updated)
        }
    }

    private func scheduleFadeOut() {
        fadeTask?.cancel()
        guard player.phase == .streaming, !voiceOver, !keyboardVisible else { return }
        fadeTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, !keyboardVisible else { return }
            withAnimation(.easeOut(duration: 0.6)) { controlsDimmed = true }
        }
    }
}
