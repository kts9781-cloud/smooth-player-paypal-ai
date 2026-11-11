import Foundation
import CryptoKit
import AVFoundation
#if os(macOS)
import CoreAudio
#endif

/// Signed AUDIO delay: positive = later sound, negative = earlier sound.
/// Apply to PCM timestamps once, never to the saved media position or subtitle clock.
public enum AudioSyncAdjustment {
    public static func bounded(_ hundredths: Int) -> Int { min(110, max(-110, hundredths)) }
    public static func seconds(_ hundredths: Int) -> Double { Double(bounded(hundredths)) / 100 }
    public static func key(type: String, uid: String) -> String? {
        guard !uid.isEmpty else { return nil }
        return SHA256.hash(data: Data((type + "\u{0}" + uid).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct AudioSyncOutput: Equatable {
    let key: String
    let name: String
    static func current() -> AudioSyncOutput? {
        #if os(macOS)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        func string(_ selector: AudioObjectPropertySelector) -> String? {
            let value = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
            value.initialize(to: nil)
            defer { value.deinitialize(count: 1); value.deallocate() }
            var bytes = UInt32(MemoryLayout<CFString?>.size)
            var property = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(device, &property, 0, nil, &bytes, value) == noErr else { return nil }
            return value.pointee as String?
        }
        guard let uid = string(kAudioDevicePropertyDeviceUID), let key = AudioSyncAdjustment.key(type: "CoreAudio", uid: uid) else { return nil }
        return AudioSyncOutput(key: key, name: string(kAudioObjectPropertyName) ?? SPText("현재 출력 기기"))
        #else
        let ports = AVAudioSession.sharedInstance().currentRoute.outputs
        guard ports.count == 1, let port = ports.first,
              let key = AudioSyncAdjustment.key(type: port.portType.rawValue, uid: port.uid) else { return nil }
        return AudioSyncOutput(key: key, name: port.portName)
        #endif
    }
}
