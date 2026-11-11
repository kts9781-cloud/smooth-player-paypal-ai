import SwiftUI

private enum SoundPalette {
    static let amber = Color(red: 214 / 255, green: 179 / 255, blue: 95 / 255)
    static let text = Color(red: 233 / 255, green: 233 / 255, blue: 230 / 255)
    static let muted = Color(red: 159 / 255, green: 162 / 255, blue: 164 / 255)
    static let line = Color.white.opacity(0.08)
}

struct SoundControls: View {
    @Binding var profile: SoundProfile
    var outputTarget: Binding<SoundPresetTarget>? = nil
    var comparison: Binding<SoundComparison>? = nil
    var audioSync: Binding<Int>? = nil
    var audioSyncDeviceName = ""
    var audioSyncEnabled = true
    private var enabled: Bool { profile.mode != .original }
    private var strength: Binding<Double> {
        Binding(get: { Double(profile.sanitized().strength) }, set: { profile.strength = Float($0) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let audioSync {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(SPText("음성 싱크")).font(.headline)
                        Spacer()
                        Text(String(format: "%+.2f", Double(audioSync.wrappedValue) / 100) + SPText("초"))
                            .monospacedDigit().accessibilityIdentifier("audioSyncValue")
                    }
                    Text(audioSyncDeviceName).font(.subheadline).foregroundStyle(SoundPalette.muted)
                    Slider(value: Binding(get: { Double(audioSync.wrappedValue) }, set: { audioSync.wrappedValue = Int($0.rounded()) }),
                        in: -110...110, step: 1).accessibilityLabel(SPText("음성 싱크"))
                    HStack {
                        Button(SPText("음성 더 일찍")) { audioSync.wrappedValue = max(-110, audioSync.wrappedValue - 1) }
                            .accessibilityIdentifier("audioSyncEarlier")
                        Spacer()
                        Button(SPText("초기화")) { audioSync.wrappedValue = 0 }.accessibilityIdentifier("audioSyncReset")
                        Spacer()
                        Button(SPText("음성 더 늦게")) { audioSync.wrappedValue = min(110, audioSync.wrappedValue + 1) }
                            .accessibilityIdentifier("audioSyncLater")
                    }.font(.system(size: 13))
                    Text(SPText(audioSyncEnabled ? "0.01초씩 조절 · 현재 출력 기기에 자동 저장" : "기기에서 소리를 재생할 때 조절할 수 있어요."))
                        .font(.system(size: 12)).foregroundStyle(SoundPalette.muted)
                }.disabled(!audioSyncEnabled).padding(.bottom, 16)
                Divider().padding(.bottom, 12)
            }
            if let outputTarget {
                Picker(SPText("사용하는 장치"), selection: outputTarget) {
                    ForEach(SoundPresetTarget.allCases, id: \.self) { target in Text(target.label).tag(target) }
                }.accessibilityIdentifier("soundOutputTarget")
                Text(SPText("장치를 직접 선택하면 해당 사운드 설정을 불러옵니다."))
                    .font(.system(size: 12)).foregroundStyle(SoundPalette.muted).padding(.bottom, 8)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 242), spacing: 8)], spacing: 8) {
                ForEach(SoundMode.allCases, id: \.self) { mode in
                    Button { profile.mode = mode } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(mode.label).font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(profile.mode == mode ? SoundPalette.amber : SoundPalette.text)
                                Text(mode.description).font(.system(size: 12)).foregroundStyle(SoundPalette.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: profile.mode == mode ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(profile.mode == mode ? SoundPalette.amber : SoundPalette.muted)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
                        .background(profile.mode == mode ? SoundPalette.amber.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(profile.mode == mode ? SoundPalette.amber.opacity(0.5) : SoundPalette.line.opacity(0.5), lineWidth: 1))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel(mode.label).accessibilityHint(mode.description)
                        .accessibilityAddTraits(profile.mode == mode ? .isSelected : [])
                }
            }
            HStack {
                Text(profile.customNight ? SPText("음색 보정 강도") : SPText("보정 강도")).font(.system(size: 16, weight: .medium))
                Spacer()
                Text(enabled ? "\(Int(profile.sanitized().strength * 100))%" : SPText("꺼짐"))
                    .font(.system(size: 15, design: .monospaced)).foregroundStyle(SoundPalette.amber)
            }.padding(.top, 16)
            Slider(value: strength, in: 0...1).disabled(!enabled).accessibilityLabel(SPText("사운드 보정 강도"))
            if profile.mode == .night {
                Toggle(SPText("야간 세부 조절"), isOn: Binding(get: { profile.customNight }, set: { enabled in
                    profile.nightReduction = enabled ? 0.5 : nil
                    profile.nightBoost = enabled ? 0.5 : nil
                }))
                if profile.customNight {
                    nightControl(SPText("큰 소리 줄이기"), value: Binding(get: { Double(profile.nightReduction ?? 0.5) }, set: { profile.nightReduction = Float($0) }))
                    nightControl(SPText("작은 소리 보강"), value: Binding(get: { Double(profile.nightBoost ?? 0.5) }, set: { profile.nightBoost = Float($0) }))
                    Text(SPText("음색 강도와 별도로 적용합니다.")).font(.system(size: 12)).foregroundStyle(SoundPalette.muted)
                }
            }
            Toggle(isOn: $profile.spacious) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(SPText("공간감")).font(.system(size: 16, weight: .medium))
                    Text(SPText("스테레오의 좌우 폭을 넓혀줍니다")).font(.system(size: 12)).foregroundStyle(SoundPalette.muted)
                }
            }.disabled(!enabled).accessibilityLabel(SPText("공간감"))
            Text(!enabled ? SPText("원음에서는 보정 강도와 공간감이 적용되지 않아요.") :
                    !profile.customNight && profile.strength == 0 ? SPText("강도가 0%여서 보정이 적용되지 않아요. 강도를 올려 주세요.") :
                    SPText("원음으로 바꾸면 보정 전 소리와 비교할 수 있어요."))
                .font(.system(size: 12)).foregroundStyle(SoundPalette.muted).padding(.vertical, 8)
            if let comparison {
                Divider()
                Toggle(SPText("평균 음량 맞춰 비교"), isOn: Binding(get: { comparison.wrappedValue != .off }, set: { comparison.wrappedValue = $0 ? .processed : .off }))
                    .disabled(!enabled)
                if comparison.wrappedValue != .off {
                    Picker(SPText("비교 듣기"), selection: comparison) {
                        Text(SPText("보정된 소리")).tag(SoundComparison.processed)
                        Text(SPText("보정 전 소리")).tag(SoundComparison.original)
                    }.pickerStyle(.segmented)
                    Text(SPText("큰 쪽의 평균 음량을 낮춰 비교합니다. 반영에 잠시 걸릴 수 있어요."))
                        .font(.system(size: 12)).foregroundStyle(SoundPalette.muted)
                }
            }
        }.onChange(of: profile) { _, _ in comparison?.wrappedValue = .off }
    }
    private func nightControl(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title); Spacer(); Text("\(Int(value.wrappedValue * 100))%") }
            Slider(value: value, in: 0...1).accessibilityLabel(title)
        }.font(.system(size: 14))
    }
}
