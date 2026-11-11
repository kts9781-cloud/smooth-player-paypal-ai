import CoreImage
import Foundation
import Metal

/// GPU reconstruction with a direct local presenter and a lazy Core Image fallback.
/// Neither path copies pixels to the CPU or waits for the GPU.
/// Keep one instance with the presenter and match its explicit Core Image working color space.
/// Apply after video orientation, before placement and subtitle/UI composition.
final class VideoEnhancer {
    enum WorkingSpace {
        case linearSRGB, sRGB
        var kernelName: String { self == .sRGB ? "smoothVideoEnhanceSRGB" : "smoothVideoEnhance" }
    }
    struct Output {
        let image: CIImage
        let applied: Bool
        var edgeAdaptiveApplied = false
        var lowResolutionApplied = false
    }
    private let kernel: CIKernel?
    private let edgeKernel: CIKernel?
    private let canvasKernel: CIKernel?
    private var presentationPipeline: MTLRenderPipelineState?
    private var edgePresentationPipeline: MTLRenderPipelineState?
    private var presentationSource: MTLTexture?
    // Off/ineligible output selects a separate compiled baseline, preserving its GPU cost.
    private let edgeAdaptive: Bool
    var isAvailable: Bool { kernel != nil }

    init(device: MTLDevice, bundle: Bundle = .main, workingSpace: WorkingSpace = .linearSRGB, edgeAdaptive: Bool = false) {
        self.edgeAdaptive = edgeAdaptive
        if device.supportsDynamicLibraries,
           let url = bundle.url(forResource: "default", withExtension: "metallib"),
           let data = try? Data(contentsOf: url) {
            kernel = try? CIKernel(functionName: workingSpace.kernelName, fromMetalLibraryData: data)
            edgeKernel = try? CIKernel(functionName: workingSpace.kernelName + "Edge", fromMetalLibraryData: data)
            canvasKernel = try? CIKernel(functionName: "smoothVideoCanvas", fromMetalLibraryData: data)
            if workingSpace == .sRGB { preparePresentation(device: device, url: url) }
        } else { kernel = nil; edgeKernel = nil; canvasKernel = nil }
    }

    /// Explicit compiled library injection lets deterministic GPU tests exercise the shipped kernel.
    init(device: MTLDevice, libraryURL: URL, workingSpace: WorkingSpace = .linearSRGB, edgeAdaptive: Bool = false) throws {
        self.edgeAdaptive = edgeAdaptive
        guard device.supportsDynamicLibraries else { throw EnhancementError.unsupportedDevice }
        let data = try Data(contentsOf: libraryURL)
        kernel = try CIKernel(functionName: workingSpace.kernelName, fromMetalLibraryData: data)
        edgeKernel = try? CIKernel(functionName: workingSpace.kernelName + "Edge", fromMetalLibraryData: data)
        canvasKernel = try CIKernel(functionName: "smoothVideoCanvas", fromMetalLibraryData: data)
        if workingSpace == .sRGB { preparePresentation(device: device, url: libraryURL) }
    }

    private func preparePresentation(device: MTLDevice, url: URL) {
        guard let library = try? device.makeLibrary(URL: url),
              let vertex = library.makeFunction(name: "smoothEnhancementVertex") else { return }
        func pipeline(_ name: String) -> MTLRenderPipelineState? {
            guard let fragment = library.makeFunction(name: name) else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex; descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }
        presentationPipeline = pipeline("smoothEnhancementFragment")
        edgePresentationPipeline = pipeline("smoothEnhancementEdgeFragment")
    }

    /// Reconstruct at actual destination pixel centers. A fractional intermediate
    /// followed by a fractional placement adds another interpolation of already
    /// enhanced edges. Moving each boundary by at most half a pixel avoids it.
    func presentationRectangle(_ rectangle: CGRect, mode: VideoEnhancementMode) -> CGRect {
        guard mode != .off, presentationPipeline != nil, edgePresentationPipeline != nil else { return rectangle }
        let left = rectangle.minX.rounded(), top = rectangle.minY.rounded()
        return CGRect(x: left, y: top, width: max(1, rectangle.maxX.rounded()-left),
                      height: max(1, rectangle.maxY.rounded()-top))
    }

    /// The 16-tap filter runs directly over a color-converted source texture,
    /// then places the video and black bars in one pass. The source conversion
    /// and draw share the presenter's command buffer, with no CPU/GPU wait.
    /// This instance belongs to one serial presentation queue; texture hazards
    /// keep reuse ordered across its in-flight command buffers.
    func present(image: CIImage, output: Output, mode: VideoEnhancementMode, in rectangle: CGRect,
                 to target: MTLTexture, context: CIContext, command: MTLCommandBuffer) -> Bool {
        guard output.applied, target.pixelFormat == .bgra8Unorm,
              let pipeline = output.edgeAdaptiveApplied ? edgePresentationPipeline : presentationPipeline,
              image.extent.minX == 0, image.extent.minY == 0,
              rectangle == rectangle.integral else { return false }
        let width = Int(image.extent.width), height = Int(image.extent.height)
        guard width > 0, height > 0, Double(width) == image.extent.width,
              Double(height) == image.extent.height else { return false }
        if presentationSource?.width != width || presentationSource?.height != height {
            // Float preserves source color conversion precision before cleanup's
            // contrast thresholds; do not quantize this intermediate to 8 bits.
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
                width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            descriptor.storageMode = .private
            presentationSource = target.device.makeTexture(descriptor: descriptor)
        }
        guard let source = presentationSource else { return false }
        context.render(image, to: source, commandBuffer: command, bounds: image.extent,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        var rect = SIMD4<Float>(Float(rectangle.minX), Float(rectangle.minY), Float(rectangle.width), Float(rectangle.height))
        var detailCleanup = SIMD2<Float>(mode.sharpEnabled ? 1 : 0, mode.cleanupEnabled ? 1 : 0)
        // Core Image treats CAMetalDrawable textures as flipped destinations,
        // unlike ordinary intermediate textures. Match its logical coordinates
        // before both the video rectangle and source sampling are evaluated.
        var flippedHeight: Float = CIRenderDestination(mtlTexture: target, commandBuffer: nil).isFlipped
            ? Float(target.height) : 0
        encoder.setFragmentBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentBytes(&detailCleanup, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        encoder.setFragmentBytes(&flippedHeight, length: MemoryLayout<Float>.stride, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    /// Returns a zero-origin image with the requested video size. The caller positions it in the viewport.
    /// Off and unavailable-kernel cases use the existing transform; natural reconstructs only enlargement.
    func render(image source: CIImage, targetSize: CGSize, mode: VideoEnhancementMode, edgeAdaptive: Bool? = nil,
                lowResolution: LowResolutionSource? = nil, outputFPS: Double = 60) -> Output {
        let size = source.extent.size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              targetSize.width.isFinite, targetSize.height.isFinite, targetSize.width > 0, targetSize.height > 0 else {
            return Output(image: source, applied: false)
        }
        let image = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
        let sx = targetSize.width / size.width, sy = targetSize.height / size.height
        // Preserve native/downscale, one-axis scaling and aggressive enlargement.
        // Evaluated SD-only direct reconstruction. Reuses the existing 16 samples,
        // with no extra pass, sharpening gain, history or intermediate texture.
        let sd = lowResolution.map { $0.status(texture: size, output: targetSize, outputFPS: outputFPS) == nil } ?? false
        let adaptive = edgeKernel != nil && (sd || ((edgeAdaptive ?? self.edgeAdaptive) && sx > 1 && sy > 1 && max(sx, sy) <= 2 && abs(sx-sy) <= 0.01 * min(sx, sy)))
        let extent = CGRect(origin: .zero, size: targetSize)
        let fallback = image.transformed(by: CGAffineTransform(scaleX: sx, y: sy)).cropped(to: extent)
        guard mode != .off, (mode != .natural || (sx > 1 && sy > 1)), let kernel else { return Output(image: fallback, applied: false) }
        // A tile needs the 4×4 reconstruction footprint and one-pixel detail neighbours.
        guard let enhanced = (adaptive ? edgeKernel! : kernel).apply(extent: extent, roiCallback: { _, rect in
            CGRect(x: rect.minX / sx, y: rect.minY / sy, width: rect.width / sx, height: rect.height / sy)
                .insetBy(dx: -3, dy: -3).intersection(image.extent)
        }, arguments: [image, CIVector(x: size.width, y: size.height),
                       CIVector(x: targetSize.width, y: targetSize.height), mode.sharpEnabled ? 1.0 : 0.0, mode.cleanupEnabled ? 1.0 : 0.0]) else {
            return Output(image: fallback, applied: false)
        }
        return Output(image: enhanced.cropped(to: extent), applied: true, edgeAdaptiveApplied: adaptive, lowResolutionApplied: sd && adaptive)
    }

    /// Final placement mask runs at canvas coordinates after all scale/translation sampling.
    /// A plain CI crop can still have a filtering fringe when the graph is fused by Metal.
    func compose(_ image: CIImage, in rectangle: CGRect, canvasSize: CGSize) -> CIImage {
        let extent = CGRect(origin: .zero, size: canvasSize)
        let placed = image.transformed(by: CGAffineTransform(translationX: rectangle.minX, y: rectangle.minY))
        if let canvasKernel, let result = canvasKernel.apply(extent: extent, roiCallback: { _, region in
            region.intersection(rectangle)
        }, arguments: [placed, CIVector(x: rectangle.minX, y: rectangle.minY, z: rectangle.width, w: rectangle.height)]) {
            return result
        }
        return placed.cropped(to: rectangle).composited(over: CIImage(color: .black).cropped(to: extent)).cropped(to: extent)
    }

    enum EnhancementError: Error { case unsupportedDevice }
}
