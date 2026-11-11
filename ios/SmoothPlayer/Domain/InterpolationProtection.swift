import Foundation

/// Displayed video coordinates from the top, independent of letterboxing and window orientation.
struct BurnedSubtitleProtection: Codable, Equatable, Sendable {
    var enabled = false
    var top: Float = 0.70
    var bottom: Float = 1
    var sanitized: Self {
        let t = min(0.95, max(0, top.isFinite ? top : 0.70))
        return Self(enabled: enabled, top: t, bottom: min(1, max(t + 0.05, bottom.isFinite ? bottom : 1)))
    }
}

/// Android's duplicate test: a grain-level whole-picture mean is insufficient on its own.
/// Every 4×4 RGB block must also be unchanged so a small moving mouth remains live.
enum InterpolationDuplicate {
    static func detected<A: RandomAccessCollection, B: RandomAccessCollection>(first: A, second: B, width: Int, height: Int, contentWidth: Int, contentHeight: Int) -> Bool
        where A.Element == Float, B.Element == Float, A.Index == Int, B.Index == Int {
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              (1...width).contains(contentWidth), (1...height).contains(contentHeight),
              first.startIndex == 0, second.startIndex == 0,
              first.count >= 3 * width * height, second.count >= 3 * width * height else { return false }
        var sum = 0.0
        for by in stride(from: 0, to: contentHeight, by: 4) {
            for bx in stride(from: 0, to: contentWidth, by: 4) {
                var blockSum = 0.0, count = 0
                for channel in 0..<3 { for y in by..<min(by + 4, contentHeight) {
                    let row = channel * width * height + y * width
                    for x in bx..<min(bx + 4, contentWidth) {
                        let difference = abs(first[row + x] - second[row + x])
                        guard difference.isFinite else { return false }
                        blockSum += Double(difference); count += 1
                    }
                } }
                guard blockSum / Double(count) < 1.0 / 255 else { return false }
                sum += blockSum
            }
        }
        return sum / Double(3 * contentWidth * contentHeight) < 0.5 / 255
    }
}

/// Content-only 32×32 thumbnail structure and color-distribution cut protection.
/// Call once per immutable source pair and reuse the result for its intermediate frames.
enum InterpolationSceneCut {
    enum Decision: Equatable { case interpolate, cut, blendOcclusion }

    static func detected<A: RandomAccessCollection, B: RandomAccessCollection>(first: A, second: B, width: Int, height: Int, contentWidth: Int, contentHeight: Int) -> Bool
        where A.Element == Float, B.Element == Float, A.Index == Int, B.Index == Int {
        decision(first: first, second: second, width: width, height: height,
                 contentWidth: contentWidth, contentHeight: contentHeight) == .cut
    }

    static func decision<A: RandomAccessCollection, B: RandomAccessCollection>(first: A, second: B, width: Int, height: Int, contentWidth: Int, contentHeight: Int) -> Decision
        where A.Element == Float, B.Element == Float, A.Index == Int, B.Index == Int {
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              (1...width).contains(contentWidth), (1...height).contains(contentHeight),
              first.count >= 3 * width * height, second.count >= 3 * width * height else { return .cut }
        // Encoded letterbox/pillarbox bars are part of the decoded picture, unlike
        // model padding. Their shared structure must not mask a cut in the movie.
        let bounds = sharedPictureBounds(first, second, width: width, height: height,
                                         cw: contentWidth, ch: contentHeight)
        let a = thumbnail(first, width: width, height: height, bounds: bounds)
        let b = thumbnail(second, width: width, height: height, bounds: bounds)
        var similarity = 0.0, difference = 0.0
        for channel in 0..<3 { for by in stride(from: 0, to: 32, by: 8) { for bx in stride(from: 0, to: 32, by: 8) {
            var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0
            for y in by..<by+8 { for x in bx..<bx+8 {
                let index = channel * 1024 + y * 32 + x
                let av = Double(a[index]), bv = Double(b[index])
                guard av.isFinite, bv.isFinite else { return .cut }
                sa += av; sb += bv; saa += av * av; sbb += bv * bv; sab += av * bv
                difference += abs(av - bv)
            } }
            let ma = sa / 64, mb = sb / 64
            let va = max(0, saa / 64 - ma * ma), vb = max(0, sbb / 64 - mb * mb)
            let covariance = sab / 64 - ma * mb
            similarity += ((2 * ma * mb + 0.0001) * (2 * covariance + 0.0009)) /
                          ((ma * ma + mb * mb + 0.0001) * (va + vb + 0.0009))
        } } }
        let meanDifference = difference / (3 * 1024)
        let meanSimilarity = similarity / 48
        if (meanSimilarity < 0.2 && meanDifference > 0.04) || meanDifference > 0.35 {
            return motionExplainsChange(a, b, meanDifference: meanDifference) ? .interpolate : .cut
        }
        // A shared background can hide a wide/close edit in mean SSIM. Require both
        // a structural change and substantial color redistribution. A pan preserves
        // the distribution; a gentle fade preserves structure. Soft bins avoid
        // flickering decisions when grain or exposure crosses a bin boundary.
        if meanSimilarity < 0.7 && meanDifference > 0.04 && distributionDistance(a, b) > 0.15 {
            return foregroundMotionExplainsChange(a, b, meanDifference: meanDifference) ? .blendOcclusion : .cut
        }
        // Reverse-angle dialogue can retain the same overall palette while the
        // subjects/background swap places. Preserve that spatial information.
        // A coherent camera pan can also move colors between quadrants, so reject
        // this additional cut rule when translation explains most of the change.
        if meanSimilarity < 0.5 && meanDifference > 0.04 &&
            distributionDistance(a, b, tilesPerSide: 2) > 0.25 &&
            !translationExplainsChange(a, b, maximumDifference: meanDifference * 0.35) {
            return foregroundMotionExplainsChange(a, b, meanDifference: meanDifference) ? .blendOcclusion : .cut
        }
        return .interpolate
    }

    /// A fast pan or independently moving foreground can have very low SSIM.
    /// First try the existing whole-picture translation. For local motion, require
    /// preserved spatial color placement AND a large reduction of RGB error in
    /// both directions together. This guard stays on the low-structure/large-change
    /// rule. Secondary palette rules use the scale-aware guard below.
    private static func motionExplainsChange(_ a: [Float], _ b: [Float], meanDifference: Double) -> Bool {
        let budget = meanDifference * 0.35
        if translationExplainsChange(a, b, maximumDifference: budget) { return true }
        // Retain the existing spatial-cut evidence for same-palette reframing.
        guard distributionDistance(a, b, tilesPerSide: 2) <= 0.25 else { return false }
        let totalBudget = 2 * 3 * 1024 * budget
        let forward = localMotionError(a, b, stopAfter: totalBudget)
        guard forward <= totalBudget else { return false }
        return localMotionError(b, a, stopAfter: totalBudget - forward) <= totalBudget - forward
    }

    /// Bounded 4×4 patch search on the existing 32×32 RGB thumbnails only.
    /// Each full patch stays inside both images; no repeated/clamped border pixels.
    /// Early rejection bounds work on unrelated shots. No optical-flow inference,
    /// persistent state, frame timing, or generated pixels are changed here.
    private static func localMotionError(_ a: [Float], _ b: [Float], stopAfter: Double) -> Double {
        var total = 0.0
        for y in stride(from: 0, to: 32, by: 4) { for x in stride(from: 0, to: 32, by: 4) {
            var best = Double.infinity
            for dy in max(-8, -y)...min(8, 28 - y) { for dx in max(-8, -x)...min(8, 28 - x) {
                var error = 0.0
                channels: for c in 0..<3 { for yy in 0..<4 {
                    let ar = c * 1024 + (y + yy) * 32 + x
                    let br = c * 1024 + (y + dy + yy) * 32 + x + dx
                    for xx in 0..<4 { error += abs(Double(a[ar + xx]) - Double(b[br + xx])) }
                    if error >= best { break channels }
                } }
                best = min(best, error)
            } }
            total += best
            if total > stopAfter { return total }
        } }
        return total
    }

    /// Secondary palette rules can mistake an occluding foreground for an edit.
    /// Require a strong two-way patch match, but retain scale edits: independently
    /// matching many patches on a small face to a large face is not motion proof.
    private static func foregroundMotionExplainsChange(_ a: [Float], _ b: [Float], meanDifference: Double) -> Bool {
        let limit = 2 * 3072 * meanDifference * 0.35
        let forward = patchMotion(a, b, stopAfter: limit)
        guard forward.error <= limit else { return false }
        let backward = patchMotion(b, a, stopAfter: limit - forward.error)
        guard backward.error <= limit - forward.error,
              let forwardArea = forward.areaScale, let backwardArea = backward.areaScale,
              forwardArea > 0, backwardArea > 0 else { return false }
        // A reciprocal expansion/contraction is the wide/close evidence that a
        // color-only local match loses. 25% area per source interval is retained
        // as an edit here; ordinary small zooms already pass the primary rules.
        return !((forwardArea > 1.25 && backwardArea < 0.8) ||
                 (backwardArea > 1.25 && forwardArea < 0.8))
    }

    private struct PatchMotion {
        var error = 0.0
        var weight = 0.0, x = 0.0, y = 0.0, dx = 0.0, dy = 0.0
        var xx = 0.0, yy = 0.0, xy = 0.0, xdx = 0.0, ydx = 0.0, xdy = 0.0, ydy = 0.0
        var areaScale: Double? {
            guard weight > 0 else { return nil }
            let vx = xx - x * x / weight, vy = yy - y * y / weight, cov = xy - x * y / weight
            let determinant = vx * vy - cov * cov
            guard determinant > 0.000_001 else { return nil }
            let xd = xdx - x * dx / weight, yd = ydx - y * dx / weight
            let xe = xdy - x * dy / weight, ye = ydy - y * dy / weight
            let ax = (xd * vy - yd * cov) / determinant, ay = (yd * vx - xd * cov) / determinant
            let bx = (xe * vy - ye * cov) / determinant, by = (ye * vx - xe * cov) / determinant
            let area = (1 + ax) * (1 + by) - ay * bx
            return area.isFinite ? area : nil
        }
        mutating func add(x px: Int, y py: Int, dx mx: Int, dy my: Int, original: Double, matched: Double) {
            error += matched
            guard original > 48 * 0.04 else { return }
            let w = max(0, original - matched), a = Double(px), b = Double(py), u = Double(mx), v = Double(my)
            weight += w; x += w * a; y += w * b; dx += w * u; dy += w * v
            xx += w * a * a; yy += w * b * b; xy += w * a * b
            xdx += w * a * u; ydx += w * b * u; xdy += w * a * v; ydy += w * b * v
        }
    }

    private static func patchMotion(_ a: [Float], _ b: [Float], stopAfter: Double) -> PatchMotion {
        var result = PatchMotion()
        for y in stride(from: 0, to: 32, by: 4) { for x in stride(from: 0, to: 32, by: 4) {
            var best = Double.infinity, original = 0.0
            var bestX = 0, bestY = 0
            for c in 0..<3 { for yy in 0..<4 { for xx in 0..<4 {
                let i = c * 1024 + (y + yy) * 32 + x + xx
                original += abs(Double(a[i]) - Double(b[i]))
            } } }
            for dy in max(-8, -y)...min(8, 28 - y) { for dx in max(-8, -x)...min(8, 28 - x) {
                var error = 0.0
                channels: for c in 0..<3 { for yy in 0..<4 {
                    let ar = c * 1024 + (y + yy) * 32 + x
                    let br = c * 1024 + (y + dy + yy) * 32 + x + dx
                    for xx in 0..<4 { error += abs(Double(a[ar + xx]) - Double(b[br + xx])) }
                    if error > best { break channels }
                } }
                if error < best || (error == best && dx * dx + dy * dy < bestX * bestX + bestY * bestY) {
                    best = error; bestX = dx; bestY = dy
                }
            } }
            result.add(x: x, y: y, dx: bestX, dy: bestY, original: original, matched: best)
            if result.error > stopAfter { return result }
        } }
        return result
    }

    private static func distributionDistance(_ a: [Float], _ b: [Float], tilesPerSide: Int = 1) -> Double {
        var distance = 0.0
        let size = 32 / tilesPerSide
        for channel in 0..<3 { for top in stride(from: 0, to: 32, by: size) { for left in stride(from: 0, to: 32, by: size) {
            var delta = [Double](repeating: 0, count: 16)
            for y in top..<top + size { for x in left..<left + size {
                let i = channel * 1024 + y * 32 + x
                let av = min(1, max(0, Double(a[i]))) * 15
                let bv = min(1, max(0, Double(b[i]))) * 15
                let ai = Int(av), bi = Int(bv)
                delta[ai] += 1 - (av - Double(ai)); delta[min(ai + 1, 15)] += av - Double(ai)
                delta[bi] -= 1 - (bv - Double(bi)); delta[min(bi + 1, 15)] -= bv - Double(bi)
            } }
            distance += delta.reduce(0) { $0 + abs($1) }
        } } }
        return distance / (2 * 3 * 1024)
    }

    private static func translationExplainsChange(_ a: [Float], _ b: [Float], maximumDifference: Double) -> Bool {
        func matches(dx: Int, dy: Int) -> Bool {
            let width = 32 - abs(dx), height = 32 - abs(dy)
            let ax = max(0, -dx), ay = max(0, -dy), bx = max(0, dx), by = max(0, dy)
            let budget = maximumDifference * Double(3 * width * height)
            var total = 0.0
            for c in 0..<3 { for y in 0..<height {
                let ar = c * 1024 + (ay + y) * 32 + ax, br = c * 1024 + (by + y) * 32 + bx
                for x in 0..<width { total += abs(Double(a[ar + x]) - Double(b[br + x])) }
                if total > budget { return false }
            } }
            return true
        }
        // Bounded thumbnail-only search, evaluated only for a cut candidate.
        for dy in -8...8 { for dx in -8...8 where dx != 0 || dy != 0 {
            if matches(dx: dx, dy: dy) { return true }
        } }
        return false
    }

    private static func sharedPictureBounds<A: RandomAccessCollection, B: RandomAccessCollection>(
        _ a: A, _ b: B, width: Int, height: Int, cw: Int, ch: Int
    ) -> (left: Int, top: Int, right: Int, bottom: Int)
        where A.Element == Float, B.Element == Float, A.Index == Int, B.Index == Int {
        func commonBlack(_ x: Int, _ y: Int) -> Bool {
            for channel in 0..<3 {
                let index = channel * width * height + y * width + x
                let av = a[index], bv = b[index]
                guard av.isFinite, bv.isFinite, av >= 0, bv >= 0, av <= 0.025, bv <= 0.025 else { return false }
            }
            return true
        }
        var left = 0, top = 0, right = cw, bottom = ch
        let minimumHeight = min(ch, max(8, ch / 3)), minimumWidth = min(cw, max(8, cw / 3))
        while bottom - top > minimumHeight && (0..<cw).allSatisfy({ commonBlack($0, top) }) { top += 1 }
        while bottom - top > minimumHeight && (0..<cw).allSatisfy({ commonBlack($0, bottom - 1) }) { bottom -= 1 }
        while right - left > minimumWidth && (top..<bottom).allSatisfy({ commonBlack(left, $0) }) { left += 1 }
        while right - left > minimumWidth && (top..<bottom).allSatisfy({ commonBlack(right - 1, $0) }) { right -= 1 }
        return (left, top, right, bottom)
    }

    private static func thumbnail<C: RandomAccessCollection>(_ source: C, width: Int, height: Int,
        bounds: (left: Int, top: Int, right: Int, bottom: Int)) -> [Float]
        where C.Element == Float, C.Index == Int {
        var result = [Float](repeating: 0, count: 3 * 1024)
        let cw = bounds.right - bounds.left, ch = bounds.bottom - bounds.top
        for channel in 0..<3 { for y in 0..<32 { for x in 0..<32 {
            let x0 = bounds.left + x * cw / 32, x1 = max(x0 + 1, bounds.left + (x + 1) * cw / 32)
            let y0 = bounds.top + y * ch / 32, y1 = max(y0 + 1, bounds.top + (y + 1) * ch / 32)
            var sum: Float = 0
            for sy in y0..<y1 { for sx in x0..<x1 { sum += source[channel * width * height + sy * width + sx] } }
            result[channel * 1024 + y * 32 + x] = sum / Float((x1 - x0) * (y1 - y0))
        } } }
        return result
    }
}
