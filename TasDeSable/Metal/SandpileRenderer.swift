import Foundation
import Metal
import MetalKit
import simd

/// Uniformes du rendu (même disposition que `RenderUniforms` dans Render.metal).
struct RenderUniforms {
    var viewProjection: simd_float4x4
    var width: UInt32
    var height: UInt32
    var threshold: UInt32
    var flags: UInt32
    var heightScale: Float
    var gap: Float
    var pad0: Float = 0
    var pad1: Float = 0
}

/// Caméra qui tourne autour du centre de la grille.
struct OrbitCamera {
    static let defaultYaw: Float = .pi / 5
    static let perspectivePitch: Float = 0.9
    static let topPitch: Float = 1.56

    /// Angle autour de l'axe vertical, en radians.
    var yaw: Float = defaultYaw
    /// Hauteur de vue : 0 = à l'horizontale, π/2 = vue de dessus.
    var pitch: Float = perspectivePitch
    /// Facteur de distance (molette).
    var zoom: Float = 1

    mutating func orbit(dx: Float, dy: Float) {
        yaw -= dx * 0.01
        pitch = min(max(pitch + dy * 0.01, 0.05), Self.topPitch)
    }

    mutating func zoom(by factor: Float) {
        zoom = min(max(zoom * factor, 0.15), 4)
    }

    mutating func reset(for mode: DisplayMode) {
        yaw = mode == .colorOnly ? 0 : Self.defaultYaw
        pitch = mode == .colorOnly ? Self.topPitch : Self.perspectivePitch
        zoom = 1
    }

    func viewProjection(aspect: Float, extent: Float) -> simd_float4x4 {
        let distance = extent * 2.1 * zoom
        let eye = SIMD3<Float>(distance * cos(pitch) * sin(yaw),
                               distance * sin(pitch),
                               distance * cos(pitch) * cos(yaw))
        let view = Matrix.lookAt(eye: eye, center: .zero, up: SIMD3(0, 1, 0))
        let projection = Matrix.perspective(fovyRadians: .pi / 4, aspect: aspect,
                                            near: max(0.05, distance * 0.01), far: distance * 4 + extent)
        return projection * view
    }
}

/// Matrices de projection et de vue (repère main droite, profondeur de 0 à 1).
enum Matrix {
    static func perspective(fovyRadians: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let ys = 1 / tan(fovyRadians * 0.5)
        let xs = ys / aspect
        let zs = far / (near - far)
        return simd_float4x4(columns: (SIMD4(xs, 0, 0, 0), SIMD4(0, ys, 0, 0),
                                       SIMD4(0, 0, zs, -1), SIMD4(0, 0, zs * near, 0)))
    }

    static func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let z = normalize(eye - center)
        let x = normalize(cross(up, z))
        let y = cross(z, x)
        return simd_float4x4(columns: (SIMD4(x.x, y.x, z.x, 0), SIMD4(x.y, y.y, z.y, 0),
                                       SIMD4(x.z, y.z, z.z, 0),
                                       SIMD4(-dot(x, eye), -dot(y, eye), -dot(z, eye), 1)))
    }
}

/// Dessine la grille : une colonne (cube instancié) par case.
@MainActor
final class SandpileRenderer: NSObject, MTKViewDelegate {
    let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let pipeline: any MTLRenderPipelineState
    private let depthState: any MTLDepthStencilState

    private var valuesBuffer: (any MTLBuffer)?
    private var snapshot: RenderSnapshot?
    private var displayMode: DisplayMode = .heightAndColor
    var camera = OrbitCamera()

    init?(device: any MTLDevice, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat) {
        guard let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Colonnes du tas de sable"
        descriptor.vertexFunction = library.makeFunction(name: "cellVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "cellFragment")
        descriptor.colorAttachments[0].pixelFormat = colorFormat
        descriptor.depthAttachmentPixelFormat = depthFormat
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .less
        depth.isDepthWriteEnabled = true
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor),
              let depthState = device.makeDepthStencilState(descriptor: depth) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.depthState = depthState
    }

    /// Reçoit la grille à afficher ; ne recopie les valeurs que si leur version a changé.
    func update(snapshot newSnapshot: RenderSnapshot, displayMode newMode: DisplayMode) {
        if newMode != displayMode {
            displayMode = newMode
            camera.reset(for: newMode)
        }
        guard newSnapshot.version != snapshot?.version || valuesBuffer == nil else { return }
        let length = max(newSnapshot.values.count, 1) * MemoryLayout<Float>.stride
        if valuesBuffer == nil || valuesBuffer!.length != length {
            valuesBuffer = device.makeBuffer(length: length, options: .storageModeShared)
        }
        if let buffer = valuesBuffer {
            newSnapshot.values.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress { buffer.contents().copyMemory(from: base, byteCount: bytes.count) }
            }
        }
        snapshot = newSnapshot
    }

    /// Remet la caméra dans la position par défaut du mode d'affichage courant.
    func resetCamera() {
        camera.reset(for: displayMode)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let snapshot, let valuesBuffer,
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }

        let size = view.drawableSize
        let aspect = Float(size.width / max(size.height, 1))
        let extent = Float(max(snapshot.width, snapshot.height))
        var flags: UInt32 = displayMode == .heightAndColor ? 1 : 0
        if snapshot.kind == .mass { flags |= 2 }
        var uniforms = RenderUniforms(
            viewProjection: camera.viewProjection(aspect: aspect, extent: extent),
            width: UInt32(snapshot.width), height: UInt32(snapshot.height),
            threshold: UInt32(snapshot.threshold), flags: flags,
            heightScale: min(max(extent * 0.08, 2), 40),
            gap: extent > 256 ? 0 : 0.06)

        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<RenderUniforms>.stride, index: 0)
        encoder.setVertexBuffer(valuesBuffer, offset: 0, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 36,
                               instanceCount: snapshot.width * snapshot.height)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}
