import CoreImage

enum FrameProxyImage {
    /// Core Image has a bottom-left origin; CVPixelBuffer row zero and the model's CHW
    /// planes start at the top. Put padding below/right in both representations.
    static func canvas(source: CIImage, width: Int, height: Int, modelWidth: Int, modelHeight: Int) -> CIImage {
        let normalized = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
        // Transform downsampling defaults differ between iOS and macOS, and even
        // its high-quality mode can alias diagonal reflections. Explicit Lanczos
        // filtering keeps thin lines stable in the flow model's small input.
        // Presentation pixels and their color processing are not changed here.
        let scaleX = Double(width) / normalized.extent.width
        let scaleY = Double(height) / normalized.extent.height
        let image = normalized.clampedToExtent().applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: scaleY, kCIInputAspectRatioKey: scaleX / scaleY
        ])
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
            .transformed(by: CGAffineTransform(translationX: 0, y: CGFloat(modelHeight - height)))
        let canvas = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: modelWidth, height: modelHeight))
        return image.composited(over: canvas)
    }
}
