import CoreImage
import CoreML
import CoreVideo
import Foundation
import Metal
import Darwin

enum FrameGenerationError: Error {
    case unsupportedOS, missingModel, missingMetal, mismatchedFrames, unsupportedPixels, unsupportedDynamicRange, unsupportedResolution, invalidModelContract, invalidPrediction, gpuFailure
}

extension FrameGenerationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unsupportedDynamicRange: SPText("HDR 영상은 일반 재생을 사용합니다. 현재 부드러운 재생은 SDR 영상에서 지원합니다.")
        case .unsupportedResolution: SPText("영상 크기를 읽지 못했습니다. 일반 재생을 계속합니다.")
        default: SPText("이 영상에서 부드러운 재생을 시작하지 못했습니다. 일반 재생을 계속합니다.")
        }
    }
}

/// The real Core ML flow + Metal warp implementation. Kept unavailable to purchases until
/// playback scheduling, thermal/device qualification and redistribution review are complete.
actor FrameInterpolator {
    static let modelWidth = 256
    static let modelHeight = 192
    private let model: MLModel
    private let modelRefinementBlocks: Double
    private let selectedModelName: String
    private let selectedComputeUnits: MLComputeUnits
    private let device: MTLDevice
    private let commands: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let context: CIContext
    private let textureCache: CVMetalTextureCache
    private var normalizedCache: [(source: CVPixelBuffer, pixels: CVPixelBuffer)] = []
    private var proxyCache: [(pixels: CVPixelBuffer, tensors: [Int: MLMultiArray])] = []
    private var outputPool: CVPixelBufferPool?
    private var outputPoolSize: (width: Int, height: Int)?
    private var predictionCount = 0
    private var normalizationCount = 0
    private var normalizationSeconds = 0.0
    private var proxySeconds = 0.0
    private var predictionSeconds = 0.0
    private var warpSeconds = 0.0
    private var protection = BurnedSubtitleProtection()
    private var protectionTransform = CGAffineTransform.identity
    private var protectedPair: (first: CVPixelBuffer, second: CVPixelBuffer, decision: InterpolationSceneCut.Decision, duplicate: Bool)?
    private var occlusionBlendFrames = 0
    private var sceneCutPairs = 0
    private var sceneCutHolds = 0
    private var duplicatePairs = 0
    private var duplicateHolds = 0
    private var modelContentWidth = 0
    private var modelContentHeight = 0

    func setProtection(_ value: BurnedSubtitleProtection, displayTransform: CGAffineTransform = .identity) {
        protection = value.sanitized
        protectionTransform = displayTransform
    }

    func diagnosticMetrics() -> [String: Double] {
        ["modelRefinementBlocks": modelRefinementBlocks,
         "modelComputeUnits": Double(selectedComputeUnits.rawValue),
         "modelContentWidth": Double(modelContentWidth), "modelContentHeight": Double(modelContentHeight),
         "predictionCount": Double(predictionCount), "normalizationCount": Double(normalizationCount),
         "normalizationSeconds": normalizationSeconds, "proxySeconds": proxySeconds,
         "predictionSeconds": predictionSeconds, "warpSeconds": warpSeconds,
         "occlusionBlendFrames": Double(occlusionBlendFrames), "sceneCutPairs": Double(sceneCutPairs), "sceneCutHolds": Double(sceneCutHolds),
         "duplicatePairs": Double(duplicatePairs), "duplicateHolds": Double(duplicateHolds)]
    }

    func diagnosticModelConfiguration() -> (name: String, units: MLComputeUnits) {
        (selectedModelName, selectedComputeUnits)
    }

    private let maximumOutputPixels: Int

    nonisolated static func preferredModelName(deviceModel: String, hasRefinedModel: Bool, preserve4K: Bool) -> String {
        // Qualification is for this physical M4 iPad and the existing 1080p working
        // size. Other Apple devices and the full-resolution 4K path retain their model.
        hasRefinedModel && deviceModel == "iPad16,6" && !preserve4K ? "IFNet4Block" : "IFNet3Block"
    }

    private nonisolated static var physicalDeviceModel: String {
        #if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        guard !ProcessInfo.processInfo.isiOSAppOnMac else { return "" }
        var system = utsname()
        guard uname(&system) == 0 else { return "" }
        return withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        #else
        return ""
        #endif
    }

    init(bundle: Bundle = .main, computeUnits: MLComputeUnits? = nil, preserve4K: Bool = false) throws {
        maximumOutputPixels = preserve4K ? 3840 * 2160 : 1920 * 1080
        guard #available(iOS 18, macOS 15, *) else { throw FrameGenerationError.unsupportedOS }
        let modelName = Self.preferredModelName(deviceModel: Self.physicalDeviceModel,
            hasRefinedModel: bundle.url(forResource: "IFNet4Block", withExtension: "mlmodelc") != nil, preserve4K: preserve4K)
        guard let url = bundle.url(forResource: modelName, withExtension: "mlmodelc") else { throw FrameGenerationError.missingModel }
        modelRefinementBlocks = modelName == "IFNet4Block" ? 4 : 3
        selectedModelName = modelName
        let configuration = MLModelConfiguration()
        // The qualified M4 refined model must leave GPU time for the full-size
        // warp and 120 Hz presentation. CPU/GPU inference fell behind in the
        // playback measurement at a serious thermal state. Keep the same
        // four refinement blocks, tensors and output size on CPU/Neural Engine.
        configuration.computeUnits = computeUnits ?? (modelName == "IFNet4Block" ? .cpuAndNeuralEngine : .all)
        #if SMOOTH_TEST_HOST
        // Qualification-only comparison. Normal builds never read these overrides.
        if ProcessInfo.processInfo.environment["SMOOTH_MODEL_COMPUTE"] == "cpuAndNeuralEngine" {
            configuration.computeUnits = .cpuAndNeuralEngine
        } else if ProcessInfo.processInfo.environment["SMOOTH_MODEL_COMPUTE"] == "cpuAndGPU" {
            configuration.computeUnits = .cpuAndGPU
        }
        #endif
        let loadedModel: MLModel
        do {
            loadedModel = try MLModel(contentsOf: url, configuration: configuration)
        } catch {
            #if os(macOS)
            // Some macOS/Core ML versions cannot build this model's Neural
            // Engine plan. Preserve explicit qualification choices, but let
            // normal Mac playback retry the same model on CPU/GPU.
            guard computeUnits == nil, configuration.computeUnits == .all else { throw error }
            configuration.computeUnits = .cpuAndGPU
            loadedModel = try MLModel(contentsOf: url, configuration: configuration)
            #else
            throw error
            #endif
        }
        selectedComputeUnits = configuration.computeUnits
        model = loadedModel
        let contract: [String: [Int]] = ["img0": [1, 3, 192, 256], "img1": [1, 3, 192, 256], "t": [1, 1, 192, 256]]
        for (name, shape) in contract {
            guard model.modelDescription.inputDescriptionsByName[name]?.multiArrayConstraint?.shape.map(\.intValue) == shape else {
                throw FrameGenerationError.invalidModelContract
            }
        }
        guard let device = MTLCreateSystemDefaultDevice(), let commands = device.makeCommandQueue(),
              let function = device.makeDefaultLibrary()?.makeFunction(name: "flowWarpBlend") else { throw FrameGenerationError.missingMetal }
        self.device = device
        self.commands = commands
        pipeline = try device.makeComputePipelineState(function: function)
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { throw FrameGenerationError.missingMetal }
        textureCache = cache
    }

    func interpolate(first: CVPixelBuffer, second: CVPixelBuffer, fraction: Float) async throws -> CVPixelBuffer {
        guard fraction.isFinite, (0...1).contains(fraction) else { throw FrameGenerationError.invalidPrediction }
        guard CVPixelBufferGetWidth(first) == CVPixelBufferGetWidth(second),
              CVPixelBufferGetHeight(first) == CVPixelBufferGetHeight(second) else { throw FrameGenerationError.mismatchedFrames }
        if fraction == 0 { return first }
        if fraction == 1 { return second }
        let originalFirst = first
        let normalizationStart = Date.timeIntervalSinceReferenceDate
        let first = try normalizedPixels(first)
        let second = try normalizedPixels(second)
        let width = CVPixelBufferGetWidth(first), height = CVPixelBufferGetHeight(first)
        normalizationSeconds += Date.timeIntervalSinceReferenceDate - normalizationStart
        let proxy = Self.proxySize(width: width, height: height, refined: modelRefinementBlocks == 4)
        let proxyWidth = proxy.width, proxyHeight = proxy.height
        modelContentWidth = proxyWidth; modelContentHeight = proxyHeight
        let proxyStart = Date.timeIntervalSinceReferenceDate
        let decision: InterpolationSceneCut.Decision, duplicate: Bool
        if let cached = protectedPair, cached.first === first, cached.second === second {
            decision = cached.decision; duplicate = cached.duplicate
        }
        else {
            // Keep shot/duplicate decisions on the original aspect-preserving
            // input. More detail for flow estimation must not change cut timing.
            let analysis = Self.proxySize(width: width, height: height, refined: false)
            let input0 = try cachedProxy(first, width: analysis.width, height: analysis.height)
            let input1 = try cachedProxy(second, width: analysis.width, height: analysis.height)
            // makeProxy owns dense float32 RGB planes. Read them directly; no full-frame copy.
            let a = UnsafeBufferPointer(start: input0.dataPointer.assumingMemoryBound(to: Float.self), count: input0.count)
            let b = UnsafeBufferPointer(start: input1.dataPointer.assumingMemoryBound(to: Float.self), count: input1.count)
            duplicate = InterpolationDuplicate.detected(first: a, second: b, width: Self.modelWidth, height: Self.modelHeight,
                                                        contentWidth: analysis.width, contentHeight: analysis.height)
            decision = duplicate ? .interpolate : InterpolationSceneCut.decision(first: a, second: b, width: Self.modelWidth, height: Self.modelHeight,
                                                 contentWidth: analysis.width, contentHeight: analysis.height)
            protectedPair = (first, second, decision, duplicate)
            if decision == .cut { sceneCutPairs += 1 }
            if duplicate { duplicatePairs += 1 }
        }
        if decision == .cut || duplicate {
            proxySeconds += Date.timeIntervalSinceReferenceDate - proxyStart
            if decision == .cut { sceneCutHolds += 1 }
            if duplicate { duplicateHolds += 1 }
            // Return the original object so the source can classify this as a hold, not generated time.
            return originalFirst
        }
        if decision == .blendOcclusion {
            // Only the newly rescued, ambiguous occlusion pairs use a temporal
            // blend. Flow can tear baked captions here; holding A causes judder.
            // Existing motion/cut decisions, source timing and output size stay intact.
            proxySeconds += Date.timeIntervalSinceReferenceDate - proxyStart
            let warpStart = Date.timeIntervalSinceReferenceDate
            let output = try await blendOcclusion(first: first, second: second, fraction: fraction)
            warpSeconds += Date.timeIntervalSinceReferenceDate - warpStart
            occlusionBlendFrames += 1
            return output
        }
        let input0 = try cachedProxy(first, width: proxyWidth, height: proxyHeight)
        let input1 = try cachedProxy(second, width: proxyWidth, height: proxyHeight)
        let timestep = try MLMultiArray(shape: [1, 1, 192, 256], dataType: .float32)
        let t = timestep.dataPointer.bindMemory(to: Float.self, capacity: timestep.count)
        t.initialize(repeating: fraction, count: timestep.count)
        let input = try MLDictionaryFeatureProvider(dictionary: ["img0": input0, "img1": input1, "t": timestep])
        proxySeconds += Date.timeIntervalSinceReferenceDate - proxyStart
        let predictionStart = Date.timeIntervalSinceReferenceDate
        let result = try await model.prediction(from: input)
        predictionSeconds += Date.timeIntervalSinceReferenceDate - predictionStart
        predictionCount += 1
        guard let rawFlow = result.featureValue(for: "flow")?.multiArrayValue,
              let rawMask = result.featureValue(for: "mask")?.multiArrayValue else { throw FrameGenerationError.invalidPrediction }
        let flow = try planarFloats(rawFlow, channels: 4)
        let mask = try planarFloats(rawMask, channels: 1)
        let warpStart = Date.timeIntervalSinceReferenceDate
        let output = try await warp(first: first, second: second, flow: flow, mask: mask, proxyWidth: proxyWidth, proxyHeight: proxyHeight)
        warpSeconds += Date.timeIntervalSinceReferenceDate - warpStart
        return output
    }

    func blendOcclusion(first: CVPixelBuffer, second: CVPixelBuffer, fraction: Float) async throws -> CVPixelBuffer {
        guard fraction.isFinite, (0...1).contains(fraction) else { throw FrameGenerationError.invalidPrediction }
        return try await warp(first: first, second: second,
                              flow: [Float](repeating: 0, count: 4 * Self.modelWidth * Self.modelHeight),
                              mask: [Float](repeating: 1 - fraction, count: Self.modelWidth * Self.modelHeight),
                              proxyWidth: Self.modelWidth, proxyHeight: Self.modelHeight, protectStaticDetails: false)
    }

    /// Also used by deterministic GPU tests to verify displacement, blending and orientation independently of ML.
    func warp(first: CVPixelBuffer, second: CVPixelBuffer, flow: [Float], mask: [Float], proxyWidth: Int, proxyHeight: Int,
              protectStaticDetails: Bool = true) async throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(first), height = CVPixelBufferGetHeight(first)
        guard width == CVPixelBufferGetWidth(second), height == CVPixelBufferGetHeight(second),
              flow.count == 4 * Self.modelWidth * Self.modelHeight, mask.count == Self.modelWidth * Self.modelHeight,
              (1...Self.modelWidth).contains(proxyWidth), (1...Self.modelHeight).contains(proxyHeight),
              flow.allSatisfy(\.isFinite), mask.allSatisfy(\.isFinite) else { throw FrameGenerationError.invalidPrediction }
        let output = try pooledOutput(width: width, height: height)
        let a = try makeTexture(first), b = try makeTexture(second), target = try makeTexture(output)
        guard let aTexture = CVMetalTextureGetTexture(a), let bTexture = CVMetalTextureGetTexture(b),
              let targetTexture = CVMetalTextureGetTexture(target),
              let flowBuffer = device.makeBuffer(bytes: flow, length: flow.count * MemoryLayout<Float>.stride),
              let maskBuffer = device.makeBuffer(bytes: mask, length: mask.count * MemoryLayout<Float>.stride),
              let command = commands.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { throw FrameGenerationError.gpuFailure }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(aTexture, index: 0)
        encoder.setTexture(bTexture, index: 1)
        encoder.setTexture(targetTexture, index: 2)
        encoder.setBuffer(flowBuffer, offset: 0, index: 0)
        encoder.setBuffer(maskBuffer, offset: 0, index: 1)
        let size: [UInt32] = [UInt32(width), UInt32(height), UInt32(proxyWidth), UInt32(proxyHeight)]
        size.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 2) }
        var uniforms = WarpProtectionUniforms(value: protection, transform: protectionTransform, width: width, height: height,
                                              staticDetails: protectStaticDetails)
        encoder.setBytes(&uniforms, length: MemoryLayout<WarpProtectionUniforms>.stride, index: 3)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        await withCheckedContinuation { continuation in
            command.addCompletedHandler { _ in continuation.resume() }
            command.commit()
        }
        withExtendedLifetime((a, b, target)) {}
        guard command.status == .completed, command.error == nil else { throw FrameGenerationError.gpuFailure }
        return output
    }

    nonisolated static func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var output: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &output) == kCVReturnSuccess,
              let output else { throw FrameGenerationError.gpuFailure }
        return output
    }

    nonisolated static func processingSize(width: Int, height: Int, maximumPixels: Int = 1920 * 1080) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (0, 0) }
        let scale = min(1, sqrt(Double(max(1, min(3840 * 2160, maximumPixels))) / (Double(width) * Double(height))))
        return (max(1, Int((Double(width) * scale).rounded(.down))), max(1, Int((Double(height) * scale).rounded(.down))))
    }

    nonisolated static func proxySize(width: Int, height: Int, refined: Bool) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (0, 0) }
        let scale = min(Double(modelWidth) / Double(width), Double(modelHeight) / Double(height))
        let w = max(1, Int((Double(width) * scale).rounded(.down)))
        let h = max(1, Int((Double(height) * scale).rounded(.down)))
        // Wide cinema inputs waste over a third of the tensor height on padding.
        // The qualified four-block model can use these rows to retain vertical
        // detail at foreground/background boundaries. This changes only
        // the motion input: the final warp already maps X/Y with separate scales.
        // Bound the stretch for extremely wide clips. Display pixels keep their
        // original dimensions/aspect, and the three-block/4K paths keep their proxy.
        let usePaddedRows = refined && h < modelHeight * 2 / 3
        return (w, usePaddedRows ? min(modelHeight, h * 2) : h)
    }

    /// Original and generated frames use the same working size while smoothing, avoiding
    /// alternating full-resolution/downsized sharpness on high-resolution input.
    func presentationPixels(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        let size = Self.processingSize(width: width, height: height, maximumPixels: maximumOutputPixels)
        if size.width == width, size.height == height { return source }
        return try normalizedPixels(source)
    }

    private func normalizedPixels(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        let size = Self.processingSize(width: width, height: height, maximumPixels: maximumOutputPixels)
        guard size.width > 0, size.height > 0 else { throw FrameGenerationError.unsupportedResolution }
        if CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA,
           size.width == width, size.height == height { return source }
        if let cached = normalizedCache.first(where: { $0.source === source }) { return cached.pixels }
        normalizationCount += 1
        let pixels = try pooledOutput(width: size.width, height: size.height)
        let image = CIImage(cvPixelBuffer: source).transformed(by: CGAffineTransform(
            scaleX: Double(size.width) / Double(width), y: Double(size.height) / Double(height)))
        context.render(image, to: pixels, bounds: image.extent, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        normalizedCache.append((source, pixels))
        if normalizedCache.count > 2 { normalizedCache.removeFirst(normalizedCache.count - 2) }
        return pixels
    }

    private func makeTexture(_ pixels: CVPixelBuffer) throws -> CVMetalTexture {
        var texture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pixels, nil, .bgra8Unorm,
                                                       CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels), 0, &texture) == kCVReturnSuccess,
              let texture else { throw FrameGenerationError.unsupportedPixels }
        return texture
    }

    private func pooledOutput(width: Int, height: Int) throws -> CVPixelBuffer {
        if outputPoolSize?.width != width || outputPoolSize?.height != height {
            let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                             kCVPixelBufferWidthKey as String: width,
                                             kCVPixelBufferHeightKey as String: height,
                                             kCVPixelBufferMetalCompatibilityKey as String: true,
                                             kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            var pool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess,
                  let pool else { throw FrameGenerationError.gpuFailure }
            outputPool = pool
            outputPoolSize = (width, height)
        }
        var pixels: CVPixelBuffer?
        guard let pool = outputPool, CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixels) == kCVReturnSuccess,
              let pixels else { throw FrameGenerationError.gpuFailure }
        return pixels
    }

    private func cachedProxy(_ pixels: CVPixelBuffer, width: Int, height: Int) throws -> MLMultiArray {
        // AVAssetReader buffers are immutable. Retain both source frames while the model
        // produces several timestamps between them, so their proxy need only be made once.
        let layout = height * (Self.modelWidth + 1) + width
        if let tensor = proxyCache.first(where: { $0.pixels === pixels })?.tensors[layout] { return tensor }
        let tensor = try makeProxy(pixels, width: width, height: height)
        if let index = proxyCache.firstIndex(where: { $0.pixels === pixels }) {
            proxyCache[index].tensors[layout] = tensor
        } else {
            proxyCache.append((pixels, [layout: tensor]))
        }
        if proxyCache.count > 2 { proxyCache.removeFirst(proxyCache.count - 2) }
        return tensor
    }

    private func makeProxy(_ pixels: CVPixelBuffer, width: Int, height: Int) throws -> MLMultiArray {
        let proxy = try Self.makePixelBuffer(width: Self.modelWidth, height: Self.modelHeight)
        let canvas = FrameProxyImage.canvas(source: CIImage(cvPixelBuffer: pixels), width: width, height: height,
                                            modelWidth: Self.modelWidth, modelHeight: Self.modelHeight)
        context.render(canvas, to: proxy, bounds: canvas.extent, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let array = try MLMultiArray(shape: [1, 3, 192, 256], dataType: .float32)
        CVPixelBufferLockBaseAddress(proxy, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(proxy, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(proxy) else { throw FrameGenerationError.unsupportedPixels }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(proxy)
        let output = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
        let area = Self.modelWidth * Self.modelHeight
        for y in 0..<Self.modelHeight {
            for x in 0..<Self.modelWidth {
                let p = y * rowBytes + x * 4, index = y * Self.modelWidth + x
                output[index] = Float(bytes[p + 2]) / 255
                output[area + index] = Float(bytes[p + 1]) / 255
                output[2 * area + index] = Float(bytes[p]) / 255
            }
        }
        return array
    }

    private func planarFloats(_ value: MLMultiArray, channels: Int) throws -> [Float] {
        guard value.shape.map(\.intValue) == [1, channels, Self.modelHeight, Self.modelWidth], value.dataType == .float32 else {
            throw FrameGenerationError.invalidPrediction
        }
        let source = value.dataPointer.assumingMemoryBound(to: Float.self)
        let strides = value.strides.map(\.intValue)
        let area = Self.modelWidth * Self.modelHeight
        if strides[1] == area, strides[2] == Self.modelWidth, strides[3] == 1 {
            // The warp entry point validates finiteness for this contiguous copy too.
            return Array(UnsafeBufferPointer(start: source, count: channels * area))
        }
        var output = [Float](repeating: 0, count: channels * Self.modelWidth * Self.modelHeight)
        for c in 0..<channels {
            for y in 0..<Self.modelHeight {
                for x in 0..<Self.modelWidth {
                    let v = source[c * strides[1] + y * strides[2] + x * strides[3]]
                    guard v.isFinite else { throw FrameGenerationError.invalidPrediction }
                    output[(c * Self.modelHeight + y) * Self.modelWidth + x] = v
                }
            }
        }
        return output
    }
}
