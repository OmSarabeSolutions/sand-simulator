import Foundation
import Metal

/// Erreurs d'initialisation ou d'exécution Metal.
enum GPUSandpileError: LocalizedError {
    case noDevice
    case noLibrary
    case missingFunction(String)
    case allocationFailed
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDevice: "Aucun GPU compatible Metal."
        case .noLibrary: "Bibliothèque de shaders Metal introuvable."
        case .missingFunction(let name): "Fonction Metal « \(name) » introuvable."
        case .allocationFailed: "Allocation d'un tampon GPU impossible."
        case .commandFailed(let message): "Échec d'une commande GPU : \(message)"
        }
    }
}

/// Paramètres du kernel `topple` (même disposition que `ToppleParams` dans Sandpile.metal).
struct ToppleParams {
    var width: UInt32
    var height: UInt32
    var threshold: UInt32
    var pad: UInt32 = 0
}

/// Paramètres du kernel `divisible` (même disposition que `DivisibleParams` dans Sandpile.metal).
struct DivisibleParams {
    var width: UInt32
    var height: UInt32
    var epsilon: Float
    var pad: Float = 0
}

/// Moteur de tas de sable sur GPU (Metal compute).
///
/// Toutes les cases basculent en même temps à chaque ronde. Comme le modèle est abélien,
/// le résultat est le même que si elles basculaient une par une.
actor GPUSandpile: SandpileEngine {
    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let topplePipeline: any MTLComputePipelineState
    private let divisiblePipeline: any MTLComputePipelineState

    /// Nombre de rondes parallèles du dernier calcul.
    private(set) var lastRounds = 0

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw GPUSandpileError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw GPUSandpileError.allocationFailed }
        guard let library = device.makeDefaultLibrary() else { throw GPUSandpileError.noLibrary }
        func pipeline(_ name: String) throws -> any MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw GPUSandpileError.missingFunction(name)
            }
            return try device.makeComputePipelineState(function: function)
        }
        self.device = device
        self.queue = queue
        self.topplePipeline = try pipeline("topple")
        self.divisiblePipeline = try pipeline("divisible")
    }

    // MARK: - Tas abélien

    func relax(_ grid: Grid, threshold: Int) async throws -> Grid {
        guard !grid.isStable(threshold: threshold) else {
            lastRounds = 0
            return grid
        }
        let params = ToppleParams(width: UInt32(grid.width), height: UInt32(grid.height),
                                  threshold: UInt32(threshold))
        var result = grid
        result.cells = try await iterate(pipeline: topplePipeline, initial: grid.cells, params: params,
                                         width: grid.width, height: grid.height)
        return result
    }

    /// Stabilise `count` grains posés au centre d'une grille vide.
    ///
    /// Tous les grains sont posés d'un coup : la case centrale bascule ⌊(count − T)/4⌋ + 1 fois
    /// dès la première ronde, et la masse se répand en quelques milliers de rondes.
    func pourCenter(count: Int, width: Int, height: Int, threshold: Int) async throws -> Grid {
        var grid = Grid(width: width, height: height)
        grid.cells[grid.centerIndex] = UInt32(clamping: count)
        return try await relax(grid, threshold: threshold)
    }

    // MARK: - Tas divisible

    /// Masse `mass` posée au centre d'une grille vide, puis partagée jusqu'à ce que
    /// plus aucune case ne dépasse 1 + `epsilon`. La masse qui sort par le bord est perdue.
    func divisibleCenter(mass: Double, width: Int, height: Int,
                         epsilon: Float = 1e-3) async throws -> [Float] {
        var initial = [Float](repeating: 0, count: width * height)
        initial[(height / 2) * width + width / 2] = Float(mass)
        guard mass > 1 else { return initial }
        let params = DivisibleParams(width: UInt32(width), height: UInt32(height), epsilon: epsilon)
        return try await iterate(pipeline: divisiblePipeline, initial: initial, params: params,
                                 width: width, height: height)
    }

    // MARK: - Boucle de rondes

    /// Applique le kernel en double tampon, par lots de rondes de plus en plus longs, jusqu'à
    /// ce que la dernière ronde d'un lot ne laisse aucune case instable.
    private func iterate<Element: BitwiseCopyable, Params: BitwiseCopyable>(
        pipeline: any MTLComputePipelineState, initial: [Element], params: Params,
        width: Int, height: Int
    ) async throws -> [Element] {
        let length = initial.count * MemoryLayout<Element>.stride
        guard let a = initial.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: length,
                                                                  options: .storageModeShared) }),
              let b = device.makeBuffer(length: length, options: .storageModeShared),
              let flag = device.makeBuffer(length: 4, options: .storageModeShared),
              let ignoredFlag = device.makeBuffer(length: 4, options: .storageModeShared)
        else { throw GPUSandpileError.allocationFailed }

        var source: any MTLBuffer = a
        var destination: any MTLBuffer = b
        var parameters = params
        let grid = MTLSize(width: width, height: height, depth: 1)
        let threadWidth = pipeline.threadExecutionWidth
        let group = MTLSize(width: threadWidth,
                            height: max(1, pipeline.maxTotalThreadsPerThreadgroup / threadWidth), depth: 1)
        var batch = 8
        var rounds = 0

        while true {
            try Task.checkCancellation()
            flag.contents().storeBytes(of: UInt32(0), as: UInt32.self)
            guard let commands = queue.makeCommandBuffer(),
                  let encoder = commands.makeComputeCommandEncoder()
            else { throw GPUSandpileError.allocationFailed }
            encoder.setComputePipelineState(pipeline)
            encoder.setBytes(&parameters, length: MemoryLayout<Params>.stride, index: 3)
            for round in 0..<batch {
                encoder.setBuffer(source, offset: 0, index: 0)
                encoder.setBuffer(destination, offset: 0, index: 1)
                encoder.setBuffer(round == batch - 1 ? flag : ignoredFlag, offset: 0, index: 2)
                encoder.dispatchThreads(grid, threadsPerThreadgroup: group)
                swap(&source, &destination)
            }
            encoder.endEncoding()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                commands.addCompletedHandler { _ in continuation.resume() }
                commands.commit()
            }
            if let error = commands.error { throw GPUSandpileError.commandFailed(error.localizedDescription) }
            rounds += batch
            if flag.contents().load(as: UInt32.self) == 0 { break }
            batch = min(batch * 2, 4096)
        }

        lastRounds = rounds
        let pointer = source.contents().bindMemory(to: Element.self, capacity: initial.count)
        return Array(UnsafeBufferPointer(start: pointer, count: initial.count))
    }
}
