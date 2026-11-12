import MetalKit
import SwiftUI

/// Vue 3D de la grille : glisser pour tourner, molette ou pincement pour zoomer,
/// double-clic pour revenir à la vue par défaut.
struct MetalView: NSViewRepresentable {
    let snapshot: RenderSnapshot
    let displayMode: DisplayMode

    /// Garde le renderer en vie aussi longtemps que la vue.
    final class Coordinator {
        var renderer: SandpileRenderer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> OrbitMTKView {
        let view = OrbitMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColor(red: 0.05, green: 0.055, blue: 0.07, alpha: 1)
        view.preferredFramesPerSecond = 60
        if let device = view.device,
           let renderer = SandpileRenderer(device: device, colorFormat: view.colorPixelFormat,
                                           depthFormat: view.depthStencilPixelFormat) {
            renderer.camera.reset(for: displayMode)
            renderer.update(snapshot: snapshot, displayMode: displayMode)
            view.delegate = renderer
            view.renderer = renderer
            context.coordinator.renderer = renderer
        }
        return view
    }

    func updateNSView(_ view: OrbitMTKView, context: Context) {
        context.coordinator.renderer?.update(snapshot: snapshot, displayMode: displayMode)
    }
}

/// MTKView qui transmet la souris et le trackpad à la caméra orbitale.
final class OrbitMTKView: MTKView {
    weak var renderer: SandpileRenderer?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { renderer?.resetCamera() }
    }

    override func mouseDragged(with event: NSEvent) {
        renderer?.camera.orbit(dx: Float(event.deltaX), dy: Float(event.deltaY))
    }

    override func scrollWheel(with event: NSEvent) {
        renderer?.camera.zoom(by: 1 + Float(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.005 : 0.05))
    }

    override func magnify(with event: NSEvent) {
        renderer?.camera.zoom(by: 1 - Float(event.magnification))
    }
}
