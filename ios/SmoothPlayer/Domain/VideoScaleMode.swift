import CoreGraphics
import Foundation

enum VideoScaleMode: String, CaseIterable, Sendable {
    case fit, fill, stretch
    var label: String {
        switch self { case .fit: SPText("원본 비율"); case .fill: SPText("꽉 채우기"); case .stretch: SPText("화면에 늘리기") }
    }
    var hint: String {
        switch self { case .fit: SPText("영상 비율을 유지합니다."); case .fill: SPText("화면을 채우며 가장자리가 일부 잘립니다."); case .stretch: SPText("화면 비율에 맞춰 영상 모양을 늘립니다.") }
    }
    func rectangle(source: CGSize, canvas: CGSize) -> CGRect {
        guard source.width > 0, source.height > 0, canvas.width > 0, canvas.height > 0,
              source.width.isFinite, source.height.isFinite, canvas.width.isFinite, canvas.height.isFinite else { return .zero }
        let sx = canvas.width / source.width, sy = canvas.height / source.height
        let scale = self == .fill ? max(sx, sy) : min(sx, sy)
        let size = self == .stretch ? canvas : CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2, width: size.width, height: size.height)
    }
}

/// Translation is a fraction of the viewport, so rotation/resizing keeps the
/// same framing. `from` and `to` are the previous/current finger centroids.
struct VideoViewport: Equatable, Sendable {
    var scale: CGFloat = 1
    var x: CGFloat = 0
    var y: CGFloat = 0

    func transformed(by factor: CGFloat, from: CGPoint, to: CGPoint) -> Self {
        guard factor.isFinite, factor > 0, from.x.isFinite, from.y.isFinite,
              to.x.isFinite, to.y.isFinite else { return self }
        let next = min(4, max(1, scale * factor))
        let ratio = next / scale
        return Self(scale: next,
                    x: to.x - 0.5 - (from.x - 0.5 - x) * ratio,
                    y: to.y - 0.5 - (from.y - 0.5 - y) * ratio).bounded()
    }

    func panned(x dx: CGFloat, y dy: CGFloat) -> Self {
        guard dx.isFinite, dy.isFinite else { return self }
        return Self(scale: scale, x: x + dx, y: y + dy).bounded()
    }

    private func bounded() -> Self {
        let limit = (scale - 1) / 2
        return Self(scale: scale, x: min(limit, max(-limit, x)), y: min(limit, max(-limit, y)))
    }
}
