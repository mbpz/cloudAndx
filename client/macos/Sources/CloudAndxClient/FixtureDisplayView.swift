import AppKit
import CloudAndxClientCore
import CoreVideo
import MetalKit
import SwiftUI

/// Fixture-only MTKView. It accepts a CVPixelBuffer presentation seam but never
/// opens an endpoint; the synthetic frame makes no live Android claim.
struct FixtureDisplayView: NSViewRepresentable {
    func makeNSView(context: Context) -> FixtureMetalView {
        let view = FixtureMetalView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        // The fixture deliberately uses the same decoded-buffer presentation
        // seam as a future endpoint owner. It never creates an endpoint.
        if let pixelBuffer = FixturePixelBuffer.make() { view.present(pixelBuffer: pixelBuffer) }
        return view
    }
    func updateNSView(_ view: FixtureMetalView, context: Context) {}
}

private enum FixturePixelBuffer {
    /// CPU-backed by design: fixture rendering must not require IOSurface
    /// allocation, an entitlement, or a display service.
    static func make() -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: CFDictionary = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, attributes, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer
        else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, 0x2a, CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }
}

final class FixtureMetalView: MTKView {
    private var source = CGSize.zero
    private let renderer: ScrcpyPixelBufferRenderer
    private var lastControl: ScrcpyControlMessage?
    private var pixelBuffer: CVPixelBuffer?
    override init(frame: CGRect, device: MTLDevice?) {
        guard let device else { fatalError("Metal device unavailable") }
        guard let renderer = ScrcpyPixelBufferRenderer(device: device) else { fatalError("Core Image renderer unavailable") }
        self.renderer = renderer
        super.init(frame: frame, device: device)
        framebufferOnly = false; enableSetNeedsDisplay = true; isPaused = true
        layer?.backgroundColor = NSColor.black.cgColor
    }
    required init(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let drawable = currentDrawable, let commandQueue = device?.makeCommandQueue(), let command = commandQueue.makeCommandBuffer() else { return }
        renderer.render(pixelBuffer: pixelBuffer, to: drawable.texture, commandBuffer: command)
        command.present(drawable); command.commit()
    }
    /// Future endpoint owner may pass only decoded buffers; this view has no
    /// file-handle or network authority.
    func present(pixelBuffer: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(pixelBuffer); let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return }
        source = CGSize(width: width, height: height)
        self.pixelBuffer = pixelBuffer
        setNeedsDisplay(bounds)
    }
    override func mouseDown(with event: NSEvent) { send(.down, event) }
    override func mouseDragged(with event: NSEvent) { send(.move, event) }
    override func mouseUp(with event: NSEvent) { send(.up, event) }
    private func send(_ action: ScrcpyControl.Action, _ event: NSEvent) {
        let size = bounds.size
        guard size.width > 0, size.height > 0, source.width > 0, source.height > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let mapped = ScrcpyCoordinateMapper(source: source, view: size).map(point)
        lastControl = try? ScrcpyControl.touch(action, x: Int(mapped.x), y: Int(mapped.y), width: Int(source.width), height: Int(source.height))
    }
}

struct FixtureDisplayPanel: View {
    var body: some View {
        GroupBox("Fixture demo — not live Android") {
            VStack(alignment: .leading, spacing: 8) {
                FixtureDisplayView().frame(minHeight: 280, maxHeight: 420).clipShape(RoundedRectangle(cornerRadius: 8))
                Text("Synthetic Metal frame only. It exercises aspect-fit input mapping and constrained scrcpy-control serialization; it does not open endpoints or enable runtime controls.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
    }
}
