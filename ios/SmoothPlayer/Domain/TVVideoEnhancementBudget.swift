import Foundation

/// TV rendering owns this state independently of the handset presenter. These
/// timings describe the app's encode pipeline, not the receiving TV's display.
struct TVVideoEnhancementBudget: Sendable {
    private var budget = VideoEnhancementBudget(mode: .off, automaticReduction: false)
    private var requestedEdgeUpscaling = false
    var effective: VideoEnhancementMode { budget.effective }
    var allowsEdgeUpscaling: Bool { requestedEdgeUpscaling && !budget.isLimited }
    var allowsLowResolution: Bool { !budget.lowResolutionLimited && !budget.isLimited }
    mutating func requestLowResolution(_ value: Bool) { budget.lowResolutionRequested = value }

    mutating func configure(mode: VideoEnhancementMode, edgeUpscaling: Bool,
                            automaticReduction: Bool, thermalLimited: Bool) {
        budget.select(mode)
        budget.setAutomaticReduction(automaticReduction)
        requestedEdgeUpscaling = edgeUpscaling
        // Thermal pressure must affect this frame, without resetting the timing
        // observation window on every ordinary frame.
        budget.applyThermalLimit(thermalLimited)
    }

    mutating func observe(queueMilliseconds: Double, processingMilliseconds: Double,
                          thermalLimited: Bool, stable: Bool) {
        budget.applyThermalLimit(thermalLimited)
        guard queueMilliseconds.isFinite, queueMilliseconds >= 0,
              processingMilliseconds.isFinite, processingMilliseconds >= 0 else { return }
        // TV measures total queue + render/encode work, whereas the local presenter
        // reports excess presentation delay. A healthy one-frame encode must not
        // demote maintained quality just because it uses most of that frame's time.
        budget.observe(delayMilliseconds: queueMilliseconds + processingMilliseconds,
                       refreshRate: 60, thermalLimited: thermalLimited, stable: stable,
                       lateThresholdMilliseconds: budget.automaticReduction ? nil : 1_000.0 / 60 * 1.15)
    }

    func status(applied: Bool, edgeApplied: Bool, shaderAvailable: Bool) -> String {
        let appliedMode = applied ? budget.effective : .off
        if budget.requested == .off { return SPText("TV 현재 적용: 끔") }
        if !shaderAvailable { return SPText("TV 보정 셰이더를 사용할 수 없습니다. TV 현재 적용: 끔") }
        if budget.isLimited { return SPText("TV \(budget.limitationDescription) TV 현재 적용: \(appliedMode.label)") }
        if !applied {
            return budget.requested == .natural
                ? SPText("TV 현재 적용: 끔 · 자연스럽게는 영상을 확대할 때 적용됩니다.")
                : SPText("TV 현재 적용: 끔 · 보정 프레임을 만들지 못했습니다.")
        }
        return SPText("TV 현재 적용: \(appliedMode.label)") + (edgeApplied ? SPText(" · 윤곽 확대") : (requestedEdgeUpscaling ? SPText(" · 윤곽 확대 미적용") : ""))
    }
}
