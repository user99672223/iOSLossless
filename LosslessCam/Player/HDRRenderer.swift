import Foundation
import Metal
import MetalKit
import CoreVideo
import QuartzCore
import UIKit
import simd
import SwiftUI

enum CompareMode: Int, CaseIterable, Identifiable {
    case single = 0, sideBySide = 1, abFlip = 2, wipe = 3, difference = 4
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .single: return "Single"
        case .sideBySide: return "Side by side"
        case .abFlip: return "A/B flip"
        case .wipe: return "Wipe"
        case .difference: return "Difference"
        }
    }
}

/// Zoom / pan / comparison parameters shared by both players.
struct RenderParams: Equatable {
    var mode: CompareMode = .single
    var showB = false
    var divider: Float = 0.5
    var gain: Float = 8
    var zoom: Float = 1
    var pan = SIMD2<Float>(0, 0)      // texture-space offset
    var nearest = true
}

/// Metal renderer for x420 / 420v frames with HLG EDR output.
final class HDRRenderer {
    struct Uniforms {
        var transform: simd_float3x3
        var mode: UInt32
        var showB: UInt32
        var hasB: UInt32
        var bitDepth: UInt32
        var fullRange: UInt32
        var colorspace: UInt32
        var nearest: UInt32
        var pad0: UInt32
        var divider: Float
        var gain: Float
        var sdrWhite: Float
        var pad1: Float
    }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private let lock = NSLock()
    private(set) var lastTransform = matrix_identity_float3x3
    private(set) var lastViewportSize = CGSize(width: 1, height: 1)

    init?(pixelFormat: MTLPixelFormat) {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue(),
              let lib = dev.makeDefaultLibrary(),
              let vs = lib.makeFunction(name: "fullscreenVertex"),
              let fs = lib.makeFunction(name: "compareFragment") else { return nil }
        device = dev
        queue = q
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vs
        desc.fragmentFunction = fs
        desc.colorAttachments[0].pixelFormat = pixelFormat
        guard let p = try? dev.makeRenderPipelineState(descriptor: desc) else { return nil }
        pipeline = p
        CVMetalTextureCacheCreate(nil, nil, dev, nil, &textureCache)
    }

    private func texture(from pb: CVPixelBuffer, plane: Int, bitDepth: Int) -> MTLTexture? {
        guard let cache = textureCache else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(pb, plane), h = CVPixelBufferGetHeightOfPlane(pb, plane)
        let fmt: MTLPixelFormat = plane == 0 ? (bitDepth == 10 ? .r16Unorm : .r8Unorm) : (bitDepth == 10 ? .rg16Unorm : .rg8Unorm)
        var tex: CVMetalTexture?
        let r = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, fmt, w, h, plane, &tex)
        guard r == kCVReturnSuccess, let t = tex else { return nil }
        return CVMetalTextureGetTexture(t)
    }

    /// Transform from (sub)viewport uv to texture uv with aspect fit, zoom and pan.
    static func transform(imageSize: CGSize, viewportSize: CGSize, params: RenderParams) -> simd_float3x3 {
        let imgAspect = Float(imageSize.width / max(imageSize.height, 1))
        let viewAspect = Float(viewportSize.width / max(viewportSize.height, 1))
        var fx: Float = 1, fy: Float = 1
        if imgAspect > viewAspect { fy = imgAspect / viewAspect } else { fx = viewAspect / imgAspect }
        let z = max(params.zoom, 0.05)
        let sx = fx / z, sy = fy / z
        let tx = 0.5 - 0.5 * sx + params.pan.x
        let ty = 0.5 - 0.5 * sy + params.pan.y
        return simd_float3x3(columns: (SIMD3<Float>(sx, 0, 0), SIMD3<Float>(0, sy, 0), SIMD3<Float>(tx, ty, 1)))
    }

    func render(to layer: CAMetalLayer, frameA: CVPixelBuffer?, frameB: CVPixelBuffer?, bitDepth: Int, fullRange: Bool,
                isBT2020: Bool, params: RenderParams, isHDRLayer: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard let a = frameA else { return }
        let size = layer.drawableSize
        guard size.width > 0, size.height > 0 else { return }
        let viewport = params.mode == .sideBySide ? CGSize(width: size.width / 2, height: size.height) : size
        let img = CGSize(width: CVPixelBufferGetWidth(a), height: CVPixelBufferGetHeight(a))
        let xf = HDRRenderer.transform(imageSize: img, viewportSize: viewport, params: params)
        lastTransform = xf
        lastViewportSize = viewport

        guard let yA = texture(from: a, plane: 0, bitDepth: bitDepth), let cA = texture(from: a, plane: 1, bitDepth: bitDepth) else { return }
        var yB: MTLTexture? = nil, cB: MTLTexture? = nil
        if let b = frameB, CVPixelBufferGetWidth(b) == Int(img.width), CVPixelBufferGetHeight(b) == Int(img.height) {
            yB = texture(from: b, plane: 0, bitDepth: bitDepth)
            cB = texture(from: b, plane: 1, bitDepth: bitDepth)
        }
        var u = Uniforms(transform: xf, mode: UInt32(params.mode.rawValue), showB: params.showB ? 1 : 0, hasB: yB != nil ? 1 : 0,
                         bitDepth: UInt32(bitDepth), fullRange: fullRange ? 1 : 0, colorspace: isBT2020 ? 1 : 0,
                         nearest: params.nearest ? 1 : 0, pad0: 0, divider: params.divider, gain: params.gain,
                         sdrWhite: isHDRLayer ? 0.75 : 1.0, pad1: 0)

        guard let drawable = layer.nextDrawable(), let cmd = queue.makeCommandBuffer() else { return }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = drawable.texture
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentTexture(yA, index: 0)
        enc.setFragmentTexture(cA, index: 1)
        enc.setFragmentTexture(yB ?? yA, index: 2)
        enc.setFragmentTexture(cB ?? cA, index: 3)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

/// UIView hosting the CAMetalLayer, handling pinch/pan/tap/long-press and
/// presenting frames from any thread.
final class VideoRenderView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    private(set) var renderer: HDRRenderer?
    private(set) var frameA: CVPixelBuffer?
    private(set) var frameB: CVPixelBuffer?
    var params = RenderParams() { didSet { if params != oldValue { redraw() } } }
    var bitDepth = 10
    var fullRange = false
    var isBT2020 = true
    private(set) var isHDRLayer = true

    var onTap: (() -> Void)?
    var onHold: ((Bool) -> Void)?
    var onInspect: ((CGPoint?) -> Void)?          // view point while inspecting (nil = ended)
    var onParamsChanged: ((RenderParams) -> Void)?
    var dividerDragEnabled = false

    private var pinchStartZoom: Float = 1
    private var panStart = SIMD2<Float>(0, 0)

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        backgroundColor = .black
        metalLayer.pixelFormat = .rgba16Float
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        renderer = HDRRenderer(pixelFormat: .rgba16Float)
        metalLayer.device = renderer?.device
        configureColor(isHDR: true)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 2
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))
        hold.minimumPressDuration = 0.35
        let inspect = UILongPressGestureRecognizer(target: self, action: #selector(handleInspect(_:)))
        inspect.minimumPressDuration = 0.35
        inspect.numberOfTouchesRequired = 2
        addGestureRecognizer(pinch)
        addGestureRecognizer(pan)
        addGestureRecognizer(tap)
        addGestureRecognizer(hold)
        addGestureRecognizer(inspect)
        isMultipleTouchEnabled = true
    }

    func configureColor(isHDR: Bool) {
        isHDRLayer = isHDR
        if isHDR {
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)
            metalLayer.wantsExtendedDynamicRangeContent = true
            metalLayer.edrMetadata = CAEDRMetadata.hlg
        } else {
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.itur_709)
            metalLayer.wantsExtendedDynamicRangeContent = false
            metalLayer.edrMetadata = nil
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? UIScreen.main.scale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        redraw()
    }

    /// Thread-safe: may be called from decode threads.
    func present(frameA: CVPixelBuffer?, frameB: CVPixelBuffer?) {
        self.frameA = frameA
        self.frameB = frameB
        redraw()
    }

    func redraw() {
        guard let r = renderer else { return }
        r.render(to: metalLayer, frameA: frameA, frameB: frameB, bitDepth: bitDepth, fullRange: fullRange,
                 isBT2020: isBT2020, params: params, isHDRLayer: isHDRLayer)
    }

    /// Maps a point in view coordinates to a pixel position in the frame (nil if outside).
    func pixelPosition(for point: CGPoint) -> (x: Int, y: Int, isB: Bool)? {
        guard let a = frameA, let r = renderer else { return nil }
        var u = Float(point.x / max(bounds.width, 1))
        let v = Float(point.y / max(bounds.height, 1))
        var isB = false
        if params.mode == .sideBySide {
            isB = u >= 0.5
            u = isB ? (u - 0.5) * 2 : u * 2
        } else if params.mode == .wipe {
            isB = u >= params.divider
        } else if params.mode == .abFlip {
            isB = params.showB
        }
        let t = r.lastTransform * SIMD3<Float>(u, v, 1)
        guard t.x >= 0, t.x < 1, t.y >= 0, t.y < 1 else { return nil }
        let w = CVPixelBufferGetWidth(a), h = CVPixelBufferGetHeight(a)
        return (Int(t.x * Float(w)), Int(t.y * Float(h)), isB && frameB != nil)
    }

    // MARK: Gestures

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began: pinchStartZoom = params.zoom
        case .changed:
            var p = params
            p.zoom = min(max(pinchStartZoom * Float(g.scale), 0.25), 64)
            p.pan = clampPan(p.pan, zoom: p.zoom)
            params = p
            onParamsChanged?(p)
        default: break
        }
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let tr = g.translation(in: self)
        if dividerDragEnabled && params.mode == .wipe && g.numberOfTouches <= 1 {
            var p = params
            p.divider = min(max(Float(g.location(in: self).x / max(bounds.width, 1)), 0.02), 0.98)
            params = p
            onParamsChanged?(p)
            return
        }
        switch g.state {
        case .began: panStart = params.pan
        case .changed:
            var p = params
            // Translate in texture units: full view width == 1/zoom of texture (after fit).
            let fx = Float(renderer?.lastTransform.columns.0.x ?? 1)
            let fy = Float(renderer?.lastTransform.columns.1.y ?? 1)
            let vw = params.mode == .sideBySide ? bounds.width / 2 : bounds.width
            p.pan = SIMD2<Float>(panStart.x - Float(tr.x / max(vw, 1)) * fx, panStart.y - Float(tr.y / max(bounds.height, 1)) * fy)
            p.pan = clampPan(p.pan, zoom: p.zoom)
            params = p
            onParamsChanged?(p)
        default: break
        }
    }

    private func clampPan(_ pan: SIMD2<Float>, zoom: Float) -> SIMD2<Float> {
        let limit: Float = 0.5 + 0.5 / max(zoom, 0.05)
        return SIMD2<Float>(min(max(pan.x, -limit), limit), min(max(pan.y, -limit), limit))
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        if g.state == .ended { onTap?() }
    }

    @objc private func handleHold(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began: onHold?(true)
        case .ended, .cancelled, .failed: onHold?(false)
        default: break
        }
    }

    @objc private func handleInspect(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began, .changed: onInspect?(g.location(in: self))
        default: onInspect?(nil)
        }
    }
}

/// SwiftUI wrapper. The view instance is created by the owner (model) so it can
/// present frames into it from decode threads.
struct VideoRenderViewRepresentable: UIViewRepresentable {
    let view: VideoRenderView
    func makeUIView(context: Context) -> VideoRenderView { view }
    func updateUIView(_ uiView: VideoRenderView, context: Context) {}
}
