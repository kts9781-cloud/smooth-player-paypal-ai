import Foundation

enum InterpolationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case hz60, hz120
    var id: Self { self }
    var requestedFramesPerSecond: Int { self == .hz60 ? 60 : 120 }
    var label: String { self == .hz60 ? "60 fps" : "120 fps" }
}

enum SmoothOutputPolicy {
    static func target(sourceFPS: Double, preferred: Int, displayMaximum: Int, remoteMaximum: Int? = nil) -> Int {
        let maximum = min(displayMaximum >= 120 ? 120 : 60, remoteMaximum ?? 120)
        let selected = min(preferred, maximum)
        // A 60-fps preference must not prevent 60→120 on a capable screen.
        if sourceFPS.isFinite, sourceFPS >= Double(selected) - 0.1 {
            return maximum
        }
        return selected
    }
    static func needsGeneration(sourceFPS: Double, target: Int) -> Bool {
        !sourceFPS.isFinite || sourceFPS <= 0 || sourceFPS < Double(target) - 0.1
    }
}
