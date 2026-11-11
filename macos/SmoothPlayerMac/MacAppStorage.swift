import Foundation

/// The public Sandbox demo never opens the installed app's account or NAS data.
enum MacAppStorage {
    #if SMOOTH_HACKATHON_DEMO
    static let isDemo = true
    static let namespace = "com.nodelabs.smoothplayer.mac.paypal-demo"
    static let directory = "SmoothPlayerPayPalDemo"
    static let accountService = namespace + ".account"
    static let privacyService = namespace + ".folder-privacy"
    #else
    static let isDemo = false
    static let namespace = "com.nodelabs.smoothplayer.mac"
    static let directory = "SmoothPlayerMac"
    static let accountService = "com.nodelabs.smoothplayer.account"
    static let privacyService = "com.nodelabs.smoothplayer.folder-privacy"
    #endif
    static func file(_ name: String) -> URL {
        URL.applicationSupportDirectory.appending(path: directory + "/" + name)
    }
}
