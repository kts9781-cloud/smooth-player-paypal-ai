import CoreGraphics

/// ABI must match FlowWarp.metal buffer(3): six Float followed by two UInt32 = 32 bytes.
struct WarpProtectionUniforms {
    var top: Float
    var bottom: Float
    var yFromX: Float
    var yFromY: Float
    var yOffset: Float
    var feather: Float
    var staticDetails: UInt32
    var reserved: UInt32 = 0

    init(value: BurnedSubtitleProtection, transform: CGAffineTransform, width: Int, height: Int, staticDetails: Bool) {
        let value = value.sanitized
        top = value.enabled ? value.top : -1
        bottom = value.enabled ? value.bottom : -1
        self.staticDetails = staticDetails ? 1 : 0
        let bounds = CGRect(x: 0, y: 0, width: width, height: height).applying(transform)
        let valid = width > 0 && height > 0 && bounds.height.isFinite && bounds.height > 0 &&
            [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty].allSatisfy { $0.isFinite }
        if valid {
            // Texture row zero is the top; CI display transforms use a bottom-left origin.
            yFromX = Float(-transform.b * Double(width) / bounds.height)
            yFromY = Float(transform.d * Double(height) / bounds.height)
            yOffset = Float((bounds.maxY - transform.d * Double(height) - transform.ty) / bounds.height)
            feather = Float(8 / bounds.height)
        } else {
            top = -1; bottom = -1
            yFromX = 0; yFromY = 1; yOffset = 0; feather = 0
        }
    }
}
