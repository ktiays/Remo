//
//  Created by Cyandev on 11/21/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import QuartzCore
import RemoEngine
import SwiftUI
import UIKit

enum TrackpadGesture {
    /// Finger travel in view points.
    case move(CGPoint)
    /// A hardware pointer position, normalized to the picture from its upper left.
    case point(CGPoint)
    /// Whole lines; positive values move the content down, following the finger.
    case scroll(lines: Int)
    /// A physical scroll: continuous deltas in points, or one unit per wheel notch.
    /// The position is normalized to the picture and stays where scrolling began.
    case scrollAt(delta: CGVector, unit: PointerScrollUnit, position: CGPoint)
    case button(PointerButton, clickCount: Int = 1)
}

struct TrackpadView: View {
    let onInput: (TrackpadGesture) -> Void
    /// Window-space frames of SwiftUI controls drawn over the trackpad.
    var excludedRects: [CGRect] = []
    /// The wheel only makes sense while the remote mouse can be controlled.
    var showsWheel = true
    /// Whether the session granted remote pointer control; hardware forwards only then.
    var controlsPointer = false
    /// The picture, which this view zooms and pans.
    let surface: VideoSurface
    /// Pixel size of the remote picture, which the zoomed view is sized from.
    var videoSize: CGSize?
    /// Height obscured at the bottom (e.g. the on-screen keyboard).
    var bottomInset: CGFloat = 0

    @State private var wheelFrame = CGRect.zero

    var body: some View {
        // The trackpad fills the entire screen (with the video aspect-fitted inside it). On
        // iOS 27.1+, the scroll wheel avoids exact hardware occlusions and corner insets instead
        // of the full-edge rectangular safe area. The trackpad’s UIKit view excludes the wheel’s
        // frame so touches meant for the wheel reach it.
        ZStack(alignment: .trailing) {
            TrackpadRegion(
                onInput: onInput, excludedRects: excludedRects + (wheelShown ? [wheelFrame] : []),
                surface: surface, videoSize: videoSize, bottomInset: bottomInset,
                controlsPointer: controlsPointer
            )
            .ignoresSafeArea()
            if wheelShown {
                wheelOverlay
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The on-screen wheel is for fingers; a Mac already has real scrolling.
    private var wheelShown: Bool {
        #if targetEnvironment(macCatalyst)
            false
        #else
            showsWheel
        #endif
    }

    @ViewBuilder
    private var wheelOverlay: some View {
        if #available(iOS 27.1, *) {
            GeometryReader { proxy in
                let layout = ScreenOcclusionLayout(proxy: proxy)
                let wheelHeight = min(proxy.size.height * 0.6, 120)
                let trailing = layout.trailingInset(
                    forCenteredHeight: wheelHeight,
                    width: ScrollWheel.hitWidth,
                    bottomInset: bottomInset)
                ScrollWheel(onInput: onInput)
                    .frame(height: wheelHeight)
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .global)
                    } action: {
                        wheelFrame = $0
                    }
                    .padding(.trailing, trailing)
                    .padding(.bottom, bottomInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .animation(.spring(duration: 0.36, bounce: 0.06), value: bottomInset)
                    .animation(.spring(duration: 0.36, bounce: 0.06), value: trailing)
            }
            .ignoresSafeArea()
        } else {
            ScrollWheel(onInput: onInput)
                .containerRelativeFrame(.vertical) { height, _ in min(height * 0.6, 120) }
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .global)
                } action: {
                    wheelFrame = $0
                }
                .padding(.trailing, 16)
                .padding(.bottom, bottomInset)
                .animation(.spring(duration: 0.36, bounce: 0.06), value: bottomInset)
        }
    }
}

/// A detented wheel: each step of finger travel scrolls one line with a haptic tick.
///
/// SwiftUI only draws it. Touches are tracked by `WheelTouchArea`, because a SwiftUI gesture laid
/// over the trackpad’s UIKit view stopped every other button on the screen from responding.
private struct ScrollWheel: View {
    let onInput: (TrackpadGesture) -> Void

    /// Finger travel for one detent.
    private static let step: CGFloat = 6
    private static let capsuleWidth: CGFloat = 36
    private static let horizontalHitPadding: CGFloat = 4
    static let hitWidth: CGFloat = capsuleWidth + horizontalHitPadding * 2
    private static let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    /// Where the ticks sit; follows the finger and springs onto a detent when it lifts.
    @State private var travel: CGFloat = 0
    @State private var dragBase: CGFloat = 0
    @State private var sentSteps = 0
    @State private var detents = 0
    @State private var pressed = false

    var body: some View {
        ZStack {
            Self.shape.fill(.black.opacity(0.35))
            Ticks(offset: travel, step: Self.step)
                .fill(.white.opacity(0.7))
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0), .init(color: .black, location: 0.25),
                            .init(color: .black, location: 0.75), .init(color: .clear, location: 1),
                        ], startPoint: .top, endPoint: .bottom))
            Self.shape.strokeBorder(.white.opacity(0.25), lineWidth: 1)
        }
        .clipShape(Self.shape)
        .frame(width: Self.capsuleWidth)
        .scaleEffect(pressed ? 1.12 : 1)
        .opacity(pressed ? 1 : 0.45)
        .animation(.spring(duration: 0.35, bounce: 0.45), value: pressed)
        .allowsHitTesting(false)
        .padding(.horizontal, Self.horizontalHitPadding)
        .overlay {
            WheelTouchArea(onBegan: { pressed = true }, onMoved: moved, onEnded: ended)
        }
        .sensoryFeedback(.selection, trigger: detents)
        .accessibilityElement()
        .accessibilityLabel("Scroll wheel")
        .accessibilityHint("Swipe up or down to scroll one line. Double-tap to right-click.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onInput(.scroll(lines: -1))
            case .decrement: onInput(.scroll(lines: 1))
            @unknown default: break
            }
        }
        .accessibilityAction { onInput(.button(.rightClick)) }
    }

    private func moved(_ translation: CGFloat) {
        travel = dragBase + translation
        let steps = Int((translation / Self.step).rounded(.towardZero))
        let delta = steps - sentSteps
        guard delta != 0 else { return }
        sentSteps = steps
        // One command per detent, never a batched count.
        for _ in 0..<abs(delta) { onInput(.scroll(lines: delta.signum())) }
        detents += abs(delta)
    }

    /// A touch that barely moved is a right-click.
    private func ended(_ translation: CGSize, cancelled: Bool) {
        pressed = false
        if !cancelled, sentSteps == 0, abs(translation.width) < 4, abs(translation.height) < 4 {
            onInput(.button(.rightClick))
        }
        let settled = dragBase + CGFloat(sentSteps) * Self.step
        dragBase = settled
        sentSteps = 0
        withAnimation(.spring(duration: 0.4, bounce: 0.35)) { travel = settled }
    }
}

/// Follows one finger from the moment it lands, reporting its travel to the wheel.
private struct WheelTouchArea: UIViewRepresentable {
    let onBegan: () -> Void
    let onMoved: (CGFloat) -> Void
    let onEnded: (CGSize, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        // A zero-duration long press tracks the touch from touch-down, unlike a pan.
        let press = UILongPressGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.press))
        press.minimumPressDuration = 0
        press.allowableMovement = .greatestFiniteMagnitude
        // The wheel is for fingers; a hardware click here shouldn't animate it.
        press.allowedTouchTypes = TouchSurface.fingerTouchTypes
        view.addGestureRecognizer(press)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.area = self
    }

    final class Coordinator: NSObject {
        var area: WheelTouchArea?
        private var start = CGPoint.zero

        @objc func press(_ gesture: UILongPressGestureRecognizer) {
            guard let area else { return }
            let location = gesture.location(in: gesture.view)
            let translation = CGSize(width: location.x - start.x, height: location.y - start.y)
            switch gesture.state {
            case .began:
                start = location
                area.onBegan()
            case .changed:
                area.onMoved(translation.height)
            case .ended:
                area.onEnded(translation, false)
            case .cancelled, .failed:
                area.onEnded(translation, true)
            default: break
            }
        }
    }
}

/// Evenly spaced tick marks shifted by `offset`, animatable so they can spring between detents.
private struct Ticks: Shape {
    var offset: CGFloat
    let step: CGFloat

    var animatableData: CGFloat {
        get { offset }
        set { offset = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let phase = (offset.truncatingRemainder(dividingBy: step) + step)
            .truncatingRemainder(dividingBy: step)
        let width: CGFloat = 14
        var y = rect.minY + phase - step / 2
        while y < rect.maxY + step {
            path.addRoundedRect(
                in: CGRect(x: rect.midX - width / 2, y: y - 1, width: width, height: 2),
                cornerSize: CGSize(width: 1, height: 1))
            y += step
        }
        return path
    }
}

/// The trackpad: one finger drives the remote pointer, two fingers zoom and pan the picture.
///
/// It is a scroll view so UIKit handles pinching, panning, deceleration and bounce. The video
/// surface is the zoomed view, so zooming is a layer transform rather than a redraw. The scroll
/// view’s pan needs two fingers, leaving single touches to the pointer gestures.
///
/// A mouse or trackpad drives the pointer absolutely instead: hover moves it, its real buttons
/// press, and wheel and two-finger scrolls go to the remote screen. A physical scroll never
/// pans the local picture; a physical pinch still zooms it.
///
/// Touches inside `excludedRects` (window space) are left to the SwiftUI controls drawn over it.
/// Taps are read from raw touches rather than a `UITapGestureRecognizer`: SwiftUI makes buttons
/// drawn over this view wait for such a recognizer to fail, which it never does for touches it
/// isn’t given, so those buttons stopped responding.
private final class TouchSurface: UIScrollView {
    var excludedRects: [CGRect] = [] {
        didSet { if excludedRects != oldValue { invalidatePointerStyle() } }
    }
    var onTap: (() -> Void)?
    var onGesture: ((TrackpadGesture) -> Void)?
    var videoSize: CGSize? {
        didSet { if videoSize != oldValue { resetZoom() } }
    }
    /// Height obscured along the bottom edge, such as an active on-screen keyboard.
    var bottomInset: CGFloat = 0 {
        didSet {
            guard abs(bottomInset - oldValue) > 0.5 else { return }
            updateBottomInset()
        }
    }
    /// The picture at its fitted size; zooming scales it.
    var zoomContent: UIView? {
        didSet {
            guard zoomContent !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let zoomContent {
                // Touches land on the scroll view itself, where the trackpad gestures live.
                zoomContent.isUserInteractionEnabled = false
                addSubview(zoomContent)
            }
            resetZoom()
        }
    }

    private var videoSurface: VideoSurface? { zoomContent as? VideoSurface }

    /// Whether the session granted remote control; hardware input forwards only then.
    var controlsPointer = false {
        didSet {
            guard controlsPointer != oldValue else { return }
            if !controlsPointer { endHardwareCapture() }
            invalidatePointerStyle()
        }
    }

    private var tapStart: (location: CGPoint, time: TimeInterval)?
    private var laidOutSize = CGSize.zero
    /// Hardware moves the cursor directly, so panning the zoomed view after it would chase the
    /// user's own input; finger input still lets the picture follow the cursor.
    private var lastInputWasHardware = false

    static let hardwareTouchTypes: Set<UITouch.TouchType> = [.indirectPointer]
    static let fingerTouchTypes: [NSNumber] = [
        NSNumber(value: UITouch.TouchType.direct.rawValue),
        NSNumber(value: UITouch.TouchType.pencil.rawValue),
    ]

    private enum HardwareButton {
        case primary, secondary
        var down: PointerButton { self == .primary ? .leftDown : .rightDown }
        var up: PointerButton { self == .primary ? .leftUp : .rightUp }
    }

    private var capture: (touch: ObjectIdentifier, button: HardwareButton, clickCount: Int)?
    private var lastPointerLocation: CGPoint?
    private var scrollAnchor: CGPoint?
    private var scrollLast = CGPoint.zero
    private var scrollHasChanged = false
    private var momentumLink: CADisplayLink?
    private var momentumLast: CFTimeInterval = 0
    private var momentumVelocity = CGPoint.zero
    private var lastClick: (time: TimeInterval, point: CGPoint, count: Int)?
    private var pointerInteraction: UIPointerInteraction?

    override init(frame: CGRect) {
        super.init(frame: frame)
        minimumZoomScale = 1
        maximumZoomScale = 4
        bouncesZoom = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        delaysContentTouches = false
        panGestureRecognizer.minimumNumberOfTouches = 2
        // Only fingers pan the picture; two-finger trackpad scroll goes to the remote screen.
        panGestureRecognizer.allowedTouchTypes = Self.fingerTouchTypes
        panGestureRecognizer.allowedScrollTypesMask = []

        let pointerInteraction = UIPointerInteraction(delegate: self)
        addInteraction(pointerInteraction)
        self.pointerInteraction = pointerInteraction
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover)))
        for mask: UIScrollTypeMask in [.discrete, .continuous] {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(scrollGesture(_:)))
            pan.allowedTouchTypes = []
            pan.allowedScrollTypesMask = mask
            addGestureRecognizer(pan)
        }
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(sceneWillDeactivate(_:)),
            name: UIScene.willDeactivateNotification, object: nil)
        center.addObserver(
            self, selector: #selector(windowDidResignKey(_:)),
            name: UIWindow.didResignKeyNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func excludes(windowPoint: CGPoint) -> Bool {
        excludedRects.contains { $0.contains(windowPoint) }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { endHardwareCapture() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != laidOutSize {
            laidOutSize = bounds.size
            resetZoom()
        }
        invalidatePointerStyle()
    }

    /// Shows the whole picture, fitted and centered.
    private func resetZoom() {
        guard let zoomContent else { return }
        zoomScale = 1
        var size = bounds.size
        if let videoSize, videoSize.width > 0, videoSize.height > 0, !bounds.isEmpty {
            let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
            size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        }
        zoomContent.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        centerContent()
        contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
    }

    /// Scrolls as little as it takes to show `rect` of `view` whole, so a zoomed-in view
    /// follows the cursor to its edges. A zoom or pan the user is making is left alone.
    func reveal(_ rect: CGRect, in view: UIView) {
        guard !isZooming, !isZoomBouncing, !isDragging, !bounds.isEmpty, !lastInputWasHardware
        else { return }
        let target = view.convert(rect, to: self)
        let visible = CGRect(
            x: bounds.minX, y: bounds.minY,
            width: bounds.width, height: max(0, bounds.height - bottomInset))
        func shift(_ low: CGFloat, _ high: CGFloat, within start: CGFloat, _ end: CGFloat)
            -> CGFloat
        {
            if low < start { return low - start }
            if high > end { return high - end }
            return 0
        }
        let minimum = CGPoint(x: -contentInset.left, y: -contentInset.top)
        let maximum = CGPoint(
            x: max(minimum.x, contentSize.width + contentInset.right - bounds.width),
            y: max(minimum.y, contentSize.height + contentInset.bottom - bounds.height))
        let offset = CGPoint(
            x: min(
                maximum.x,
                max(
                    minimum.x,
                    contentOffset.x
                        + shift(target.minX, target.maxX, within: visible.minX, visible.maxX))),
            y: min(
                maximum.y,
                max(
                    minimum.y,
                    contentOffset.y
                        + shift(target.minY, target.maxY, within: visible.minY, visible.maxY))))
        if offset != contentOffset { contentOffset = offset }
    }

    /// Keeps the picture centered on any axis where it is smaller than the view.
    ///
    /// This uses content insets, updated from `scrollViewDidZoom`, because the scroll view
    /// calls that inside its own zoom-bounce animation and so animates the inset change too.
    /// Moving the view in `layoutSubviews` instead happened outside that animation, and the
    /// picture jumped to the corner the moment a pinch below the minimum was released.
    func centerContent() {
        let size = contentSize
        let x = max(0, (bounds.width - size.width) / 2)
        let visibleHeight = max(0, bounds.height - bottomInset)
        let y = max(0, (visibleHeight - size.height) / 2)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y + bottomInset, right: x)
    }

    private func updateBottomInset() {
        UIView.animate(.spring) {
            self.centerContent()
            let minimumY = -self.contentInset.top
            let maximumY = max(
                minimumY, self.contentSize.height + self.contentInset.bottom - self.bounds.height)
            let clampedY = min(maximumY, max(minimumY, self.contentOffset.y))
            if self.contentSize.height <= max(0, self.bounds.height - self.bottomInset) {
                self.contentOffset.y = minimumY
            } else if clampedY != self.contentOffset.y {
                self.contentOffset.y = clampedY
            }
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        !excludes(windowPoint: convert(point, to: nil)) && super.point(inside: point, with: event)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        stopMomentum()
        if let event, pointerTouchBegan(touches, event: event) { return }
        guard event?.allTouches?.count == 1, let touch = touches.first,
            !Self.hardwareTouchTypes.contains(touch.type)
        else {
            tapStart = nil
            return
        }
        tapStart = (touch.location(in: self), touch.timestamp)
        lastInputWasHardware = false
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        pointerTouchMoved(touches)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        pointerTouchFinished(touches)
        guard let start = tapStart,
            let touch = touches.first(where: { !Self.hardwareTouchTypes.contains($0.type) })
        else { return }
        tapStart = nil
        // The pan and hold recognizers cancel the touch once they begin, so a drag never ends here.
        let location = touch.location(in: self)
        if touch.timestamp - start.time < 0.35,
            hypot(location.x - start.location.x, location.y - start.location.y) < 10
        {
            onTap?()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        tapStart = nil
        pointerTouchFinished(touches)
    }

    // MARK: Hardware pointer

    /// A view point as a share of the remote picture, from its upper left. `clamping` lets a
    /// drag that leaves the picture keep reporting at its edge instead of going silent.
    private func normalizedPoint(_ point: CGPoint, clamping: Bool = false) -> CGPoint? {
        guard let surface = videoSurface, let picture = surface.pictureRect else { return nil }
        let local = convert(point, to: surface)
        guard clamping || picture.contains(local) else { return nil }
        let x = min(1, max(0, (local.x - picture.minX) / picture.width))
        let y = min(1, max(0, (local.y - picture.minY) / picture.height))
        return CGPoint(x: x, y: y)
    }

    private func emit(_ gesture: TrackpadGesture) {
        guard controlsPointer else { return }
        lastInputWasHardware = true
        onGesture?(gesture)
    }

    private func pressedButton(in event: UIEvent) -> HardwareButton? {
        let mask = event.buttonMask
        if mask.contains(.secondary) { return .secondary }
        if mask.contains(.primary) {
            return event.modifierFlags.contains(.control) ? .secondary : .primary
        }
        return nil
    }

    private func pointerTouchBegan(_ touches: Set<UITouch>, event: UIEvent) -> Bool {
        guard let touch = touches.first(where: { Self.hardwareTouchTypes.contains($0.type) })
        else { return false }
        let location = touch.location(in: self)
        lastPointerLocation = location
        guard capture == nil, let position = normalizedPoint(location),
            let button = pressedButton(in: event)
        else { return true }
        let count = clickCount(of: touch, button: button)
        capture = (ObjectIdentifier(touch), button, count)
        emit(.point(position))
        emit(.button(button.down, clickCount: count))
        return true
    }

    private func pointerTouchMoved(_ touches: Set<UITouch>) {
        guard let capture,
            let touch = touches.first(where: { ObjectIdentifier($0) == capture.touch })
        else { return }
        let location = touch.location(in: self)
        lastPointerLocation = location
        guard let position = normalizedPoint(location, clamping: true) else { return }
        emit(.point(position))
    }

    private func pointerTouchFinished(_ touches: Set<UITouch>) {
        guard let capture,
            let touch = touches.first(where: { ObjectIdentifier($0) == capture.touch })
        else { return }
        self.capture = nil
        let location = touch.location(in: self)
        lastPointerLocation = location
        if let position = normalizedPoint(location, clamping: true) {
            emit(.point(position))
        }
        emit(.button(capture.button.up, clickCount: capture.clickCount))
    }

    private func endHardwareCapture() {
        stopMomentum()
        scrollAnchor = nil
        guard let capture else { return }
        self.capture = nil
        if let location = lastPointerLocation,
            let position = normalizedPoint(location, clamping: true)
        {
            emit(.point(position))
        }
        emit(.button(capture.button.up, clickCount: capture.clickCount))
    }

    @objc private func sceneWillDeactivate(_ note: Notification) {
        guard note.object as? UIWindowScene === window?.windowScene else { return }
        endHardwareCapture()
    }

    @objc private func windowDidResignKey(_ note: Notification) {
        guard note.object as? UIWindow === window else { return }
        endHardwareCapture()
    }

    /// `tapCount` counts hardware presses, but a count the event leaves at one is rechecked
    /// against the last press: same place, inside a third of a second, means a repeat.
    private func clickCount(of touch: UITouch, button: HardwareButton) -> Int {
        guard button == .primary else { return 1 }
        if touch.tapCount > 1 { return touch.tapCount }
        let location = touch.location(in: self)
        var count = 1
        if let last = lastClick,
            touch.timestamp - last.time < 0.35,
            hypot(location.x - last.point.x, location.y - last.point.y) < 10
        {
            count = last.count + 1
        }
        lastClick = (touch.timestamp, location, count)
        return count
    }

    // MARK: Hover and scroll

    @objc private func hover(_ gesture: UIHoverGestureRecognizer) {
        guard gesture.state == .changed || gesture.state == .began else { return }
        let location = gesture.location(in: self)
        lastPointerLocation = location
        guard let position = normalizedPoint(location) else { return }
        emit(.point(position))
    }

    @objc private func scrollGesture(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            stopMomentum()
            scrollLast = .zero
            scrollHasChanged = false
            let location = gesture.location(in: self)
            let translation = gesture.translation(in: self)
            let pointer =
                lastPointerLocation
                ?? CGPoint(x: location.x - translation.x, y: location.y - translation.y)
            scrollAnchor =
                excludes(windowPoint: convert(pointer, to: nil)) ? nil : normalizedPoint(pointer)
            sendScrollDelta(from: gesture)
        case .changed:
            scrollHasChanged = true
            sendScrollDelta(from: gesture)
        case .ended:
            sendScrollDelta(from: gesture)
            guard gesture.allowedScrollTypesMask == .continuous, scrollHasChanged else {
                scrollAnchor = nil
                return
            }
            beginMomentum(gesture.velocity(in: self))
        case .cancelled, .failed:
            scrollAnchor = nil
            stopMomentum()
        default:
            break
        }
    }

    private func sendScrollDelta(from gesture: UIPanGestureRecognizer) {
        guard let position = scrollAnchor else {
            scrollLast = gesture.translation(in: self)
            return
        }
        let translation = gesture.translation(in: self)
        let delta = CGVector(
            dx: translation.x - scrollLast.x, dy: translation.y - scrollLast.y)
        scrollLast = translation
        guard delta != .zero else { return }
        if gesture.allowedScrollTypesMask == .discrete {
            var lines = CGVector.zero
            if delta.dx != 0 { lines.dx = delta.dx > 0 ? 1 : -1 }
            if delta.dy != 0 { lines.dy = delta.dy > 0 ? 1 : -1 }
            emit(.scrollAt(delta: lines, unit: .line, position: position))
        } else {
            emit(.scrollAt(delta: delta, unit: .pixel, position: position))
        }
    }

    /// UIKit reports no momentum phase for a scroll pan; coast from the release velocity.
    private func beginMomentum(_ velocity: CGPoint) {
        guard scrollAnchor != nil, controlsPointer, hypot(velocity.x, velocity.y) > 30 else {
            scrollAnchor = nil
            return
        }
        momentumVelocity = velocity
        momentumLast = 0
        let link = CADisplayLink(target: self, selector: #selector(momentum(_:)))
        link.add(to: .main, forMode: .common)
        momentumLink = link
    }

    func stopMomentum() {
        momentumLink?.invalidate()
        momentumLink = nil
    }

    @objc private func momentum(_ link: CADisplayLink) {
        let elapsed = momentumLast == 0 ? link.duration : link.timestamp - momentumLast
        momentumLast = link.timestamp
        guard let position = scrollAnchor else {
            stopMomentum()
            return
        }
        let decay = pow(UIScrollView.DecelerationRate.normal.rawValue, elapsed * 1000)
        let delta = CGVector(
            dx: momentumVelocity.x * elapsed * (1 + decay) / 2,
            dy: momentumVelocity.y * elapsed * (1 + decay) / 2)
        momentumVelocity.x *= decay
        momentumVelocity.y *= decay
        if hypot(momentumVelocity.x, momentumVelocity.y) < 1 {
            scrollAnchor = nil
            stopMomentum()
            return
        }
        if delta != .zero { emit(.scrollAt(delta: delta, unit: .pixel, position: position)) }
    }

    func invalidatePointerStyle() {
        pointerInteraction?.invalidate()
    }
}

extension TouchSurface: UIPointerInteractionDelegate {
    func pointerInteraction(
        _ interaction: UIPointerInteraction,
        regionFor request: UIPointerRegionRequest,
        defaultRegion: UIPointerRegion
    ) -> UIPointerRegion? {
        guard controlsPointer, let surface = videoSurface, let picture = surface.pictureRect else {
            return nil
        }
        let local = convert(request.location, to: surface)
        guard picture.contains(local), !excludes(windowPoint: convert(request.location, to: nil))
        else { return nil }
        let rect = surface.convert(picture, to: self).intersection(bounds)
        return rect.isEmpty ? nil : UIPointerRegion(rect: rect)
    }

    func pointerInteraction(
        _ interaction: UIPointerInteraction,
        styleFor region: UIPointerRegion
    ) -> UIPointerStyle? {
        controlsPointer && videoSurface?.showsRemoteCursor == true ? .hidden() : nil
    }
}

private struct TrackpadRegion: UIViewRepresentable {
    let onInput: (TrackpadGesture) -> Void
    let excludedRects: [CGRect]
    let surface: VideoSurface
    let videoSize: CGSize?
    let bottomInset: CGFloat
    let controlsPointer: Bool

    func makeCoordinator() -> Coordinator { Coordinator(onInput: onInput) }

    func makeUIView(context: Context) -> TouchSurface {
        let view = TouchSurface()
        let coordinator = context.coordinator
        coordinator.surface = view
        view.delegate = coordinator
        view.onTap = { [weak coordinator] in coordinator?.onInput(.button(.leftClick)) }
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.pan))
        pan.maximumNumberOfTouches = 1
        pan.allowedTouchTypes = TouchSurface.fingerTouchTypes
        let hold = UILongPressGestureRecognizer(
            target: coordinator, action: #selector(Coordinator.hold))
        hold.minimumPressDuration = 0.4
        hold.allowedTouchTypes = TouchSurface.fingerTouchTypes
        pan.require(toFail: hold)
        coordinator.pointerPan = pan
        for recognizer in [pan, hold] as [UIGestureRecognizer] {
            recognizer.delegate = coordinator
            view.addGestureRecognizer(recognizer)
        }
        return view
    }

    func updateUIView(_ uiView: TouchSurface, context: Context) {
        context.coordinator.onInput = onInput
        uiView.excludedRects = excludedRects
        uiView.zoomContent = surface
        uiView.videoSize = videoSize
        uiView.bottomInset = bottomInset
        uiView.onGesture = onInput
        uiView.controlsPointer = controlsPointer
        surface.onCursorMoved = { [weak uiView, weak surface] frame in
            guard let uiView, let surface else { return }
            uiView.reveal(frame, in: surface)
        }
        surface.onCursorVisibilityChanged = { [weak uiView] in uiView?.invalidatePointerStyle() }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate, UIScrollViewDelegate {
        var onInput: (TrackpadGesture) -> Void
        weak var surface: TouchSurface?
        weak var pointerPan: UIPanGestureRecognizer?
        private var dragLocation: CGPoint?
        private var touchDown = CGPoint.zero
        private var panIgnored = false

        init(onInput: @escaping (TrackpadGesture) -> Void) {
            self.onInput = onInput
        }

        // MARK: Zoom

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { surface?.zoomContent }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            surface?.centerContent()
            surface?.invalidatePointerStyle()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            surface?.invalidatePointerStyle()
        }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            surface?.stopMomentum()
            cancelPointerDrag()
        }

        func scrollViewDidEndZooming(
            _ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat
        ) {
            (view as? VideoSurface)?.zoomDidSettle()
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { cancelPointerDrag() }

        /// A second finger turns a pointer drag into a zoom; stop moving the pointer.
        private func cancelPointerDrag() {
            guard let pointerPan, pointerPan.state != .possible else { return }
            pointerPan.isEnabled = false
            pointerPan.isEnabled = true
        }

        // MARK: Pointer

        // Touches on the controls drawn over the trackpad still reach these recognizers. Refusing
        // them would leave the recognizers pending, and SwiftUI buttons wait on them, so they are
        // taken and later ignored instead. Hardware pointer buttons bypass these recognizers via
        // `allowedTouchTypes` and take the view's own press/release path.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
        ) -> Bool {
            guard !TouchSurface.hardwareTouchTypes.contains(touch.type) else { return false }
            touchDown = touch.location(in: nil)
            return true
        }

        /// Lets a pinch start even after a finger has begun moving the pointer.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            other === surface?.pinchGestureRecognizer || other === surface?.panGestureRecognizer
        }

        private var startedOnControl: Bool {
            surface?.excludes(windowPoint: touchDown) ?? false
        }

        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .began { panIgnored = startedOnControl }
            guard !panIgnored,
                gesture.state == .began || gesture.state == .changed || gesture.state == .ended
            else { return }
            let translation = gesture.translation(in: gesture.view)
            gesture.setTranslation(.zero, in: gesture.view)
            onInput(.move(translation))
        }

        @objc func hold(_ gesture: UILongPressGestureRecognizer) {
            let location = gesture.location(in: gesture.view)
            switch gesture.state {
            case .began:
                guard !startedOnControl else { return }
                dragLocation = location
                onInput(.button(.leftDown))
            case .changed, .ended:
                guard let previous = dragLocation else { return }
                dragLocation = location
                onInput(.move(CGPoint(x: location.x - previous.x, y: location.y - previous.y)))
                if gesture.state == .ended { endDrag() }
            case .cancelled, .failed:
                endDrag()
            default: break
            }
        }

        private func endDrag() {
            guard dragLocation != nil else { return }
            dragLocation = nil
            onInput(.button(.leftUp))
        }
    }
}
