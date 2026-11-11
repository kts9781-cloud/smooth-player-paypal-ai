import CoreGraphics
import CoreText
import Foundation

/// Text layout and the supplied font stay identical in both outline modes.
/// Called only when the TV caption cache changes, not for each video frame.
enum TVCaptionDrawing {
    static func draw(_ text: NSAttributedString, in context: CGContext, path: CGPath, outline: Bool) {
        let paint = NSMutableAttributedString(attributedString: text)
        let range = NSRange(location: 0, length: paint.length)
        let stroke = NSAttributedString.Key(kCTStrokeWidthAttributeName as String)
        func drawPass() {
            let setter = CTFramesetterCreateWithAttributedString(paint)
            CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil), context)
        }
        if outline {
            // Fill-and-stroke (-5) paints black over the inside of the glyph and
            // makes the white text thin. Paint the border first, then restore the
            // full original fill. Keep the outer border, font and layout intact.
            paint.addAttribute(NSAttributedString.Key(kCTStrokeColorAttributeName as String), value: CGColor(gray: 0, alpha: 1), range: range)
            paint.addAttribute(stroke, value: 5, range: range)
            drawPass()
        }
        paint.addAttribute(stroke, value: 0, range: range)
        drawPass()
    }
}
