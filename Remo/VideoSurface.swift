//
//  Created by Cyandev on 11/20/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import CoreImage
import Metal
import QuartzCore
import RemoEngine
import UIKit

@MainActor
final class VideoSurface: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    private var display: CAMetalLayer { layer as! CAMetalLayer }
    private let queue: (any MTLCommandQueue)?
    private let context: CIContext?
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    /// The last frame, kept so a resolution change can redraw while the remote screen is still.
    private var lastImage: CIImage?
    private var redrawPending = false
    /// Extra drawable resolution while zoomed in, never beyond the remote picture’s own pixels.
    private var detail: CGFloat = 1
    /// Draws the remote cursor over the picture. Being a sublayer, it zooms with the picture,
    /// and it moves without redrawing the video.
    private let cursorLayer = CALayer()

    /// The remote cursor, which the video no longer shows.
    var cursor: RemoteCursor? {
        didSet {
            guard cursor != oldValue else { return }
            layoutCursor()
            if let cursor, !cursorLayer.isHidden, cursor.position != oldValue?.position {
                onCursorMoved?(cursorLayer.frame)
            }
        }
    }
    /// Hears the cursor's frame, in this view's bounds, each time it moves.
    var onCursorMoved: ((CGRect) -> Void)?
    /// The hardware pointer style changes only when the remote cursor appears or disappears.
    var onCursorVisibilityChanged: (() -> Void)?

    /// Magnification applied by the zooming scroll view this view sits in; 1 shows the whole
    /// remote screen.
    var zoom: CGFloat { bounds.width > 0 ? frame.width / bounds.width : 1 }
    /// Where the remote picture is fitted inside this view, letterboxed; `nil` before the
    /// first frame or while the view has no size. Input and cursor placement share it.
    var pictureRect: CGRect? {
        guard let extent = lastImage?.extent, extent.width > 0, extent.height > 0,
            !bounds.isEmpty
        else { return nil }
        let scale = min(bounds.width / extent.width, bounds.height / extent.height)
        return CGRect(
            x: bounds.midX - extent.width * scale / 2,
            y: bounds.midY - extent.height * scale / 2,
            width: extent.width * scale, height: extent.height * scale)
    }

    /// Whether a remote cursor picture is being drawn, for hiding the local pointer.
    var showsRemoteCursor: Bool { !cursorLayer.isHidden }

    init() {
        let device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        context = device.map { CIContext(mtlDevice: $0, options: [.cacheIntermediates: false]) }
        super.init(frame: .zero)
        backgroundColor = .black
        display.device = device
        display.pixelFormat = .bgra8Unorm
        display.framebufferOnly = false
        display.colorspace = colorSpace
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Remote video")
        cursorLayer.isHidden = true
        cursorLayer.zPosition = 1
        display.addSublayer(cursorLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let screen = window?.windowScene?.screen, !bounds.isEmpty else { return }
        let scale = screen.nativeScale * detail
        if contentScaleFactor != scale { contentScaleFactor = scale }
        display.drawableSize = CGSize(
            width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        setNeedsRedraw()
        layoutCursor()
    }

    /// Places the cursor on the picture as `render` fits it into the view.
    private func layoutCursor() {
        let wasHidden = cursorLayer.isHidden
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let cursor, cursor.visible, let image = cursor.image, let picture = pictureRect {
            cursorLayer.contents = image
            cursorLayer.frame = cursor.frame(in: picture)
            cursorLayer.isHidden = false
        } else {
            cursorLayer.isHidden = true
        }
        CATransaction.commit()
        if cursorLayer.isHidden != wasHidden { onCursorVisibilityChanged?() }
    }

    /// Re-renders sharper once a zoom settles. While zooming, the layer is simply scaled, which
    /// is smooth and costs no redraw but magnifies the drawable’s pixels.
    func zoomDidSettle() {
        guard let screen = window?.windowScene?.screen, let extent = lastImage?.extent,
            !bounds.isEmpty
        else { return }
        let sourceLimit = max(1, extent.width / (bounds.width * screen.nativeScale))
        let wanted = min(zoom, sourceLimit)
        guard abs(wanted - detail) > 0.01 else { return }
        detail = wanted
        setNeedsLayout()
    }

    /// Coalesces redraws into one per run loop turn.
    private func setNeedsRedraw() {
        guard !redrawPending else { return }
        redrawPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self, redrawPending, let lastImage else { return }
            redrawPending = false
            _ = try? render(lastImage)
        }
    }

    func present(_ frame: VideoFrame) throws -> Bool {
        let image = CIImage(cvPixelBuffer: frame.pixels)
        let resized = lastImage?.extent != image.extent
        lastImage = image
        redrawPending = false
        if resized { layoutCursor() }
        return try render(image)
    }

    /// Clears the rendered picture and hides the cursor while reconnecting at a new resolution.
    func clear() {
        lastImage = nil
        redrawPending = false
        cursor = nil
        detail = 1
        guard window != nil, !bounds.isEmpty,
            let queue, let context,
            let drawable = display.nextDrawable(), let commands = queue.makeCommandBuffer()
        else { return }
        let canvas = CGRect(x: 0, y: 0, width: drawable.texture.width, height: drawable.texture.height)
        context.render(
            CIImage(color: .black), to: drawable.texture, commandBuffer: commands, bounds: canvas,
            colorSpace: colorSpace)
        commands.present(drawable)
        commands.commit()
    }

    private func render(_ image: CIImage) throws -> Bool {
        guard let queue, let context else { throw CocoaError(.featureUnsupported) }
        guard window != nil, !bounds.isEmpty,
            let drawable = display.nextDrawable(), let commands = queue.makeCommandBuffer()
        else { return false }

        let canvas = CGRect(x: 0, y: 0, width: drawable.texture.width, height: drawable.texture.height)
        let extent = image.extent
        let scale = min(canvas.width / extent.width, canvas.height / extent.height)
        let transform = CGAffineTransform(
            a: scale, b: 0, c: 0, d: scale,
            tx: canvas.midX - extent.midX * scale, ty: canvas.midY - extent.midY * scale)
        let fitted = image.transformed(by: transform).composited(over: CIImage(color: .black))
        context.render(
            fitted, to: drawable.texture, commandBuffer: commands, bounds: canvas,
            colorSpace: colorSpace)
        commands.present(drawable)
        commands.commit()
        return true
    }
}
