import Foundation
import Observation

/// App-owned UI text only. Media titles, subtitle contents and stored identifiers never enter this catalog.
public struct AppLocalizedMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    public let key: String
    public let arguments: [String]
    public init(stringLiteral value: String) { key = value; arguments = [] }
    public init(stringInterpolation: StringInterpolation) { key = stringInterpolation.key; arguments = stringInterpolation.arguments }
    public struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []
        public init(literalCapacity: Int, interpolationCount: Int) { key.reserveCapacity(literalCapacity) }
        public mutating func appendLiteral(_ literal: String) { key += literal }
        public mutating func appendInterpolation<T>(_ value: T) {
            key += "__ARG_\(arguments.count)__"
            arguments.append(String(describing: value))
        }
    }
}

public final class AppLanguage: @unchecked Sendable, Observable {
    public static let shared = AppLanguage()
    public static let choices: [(id: String, name: String)] = [
        ("system", "System"), ("ko", "한국어"), ("en", "English"), ("zh-Hans", "简体中文"),
        ("es", "Español"), ("ja", "日本語"), ("vi", "Tiếng Việt"), ("th", "ไทย")
    ]
    public static let preferenceKey = "appLanguage.v1"
    private let registrar = ObservationRegistrar()
    private let lock = NSLock()
    private var selected = "system"
    private var resolved = "ko" // Domain tests do not read the real user's preferences.
    private var catalog: [String: String] = [:]
    public var selection: String {
        registrar.access(self, keyPath: \.selection)
        return lock.withLock { selected }
    }
    public var locale: Locale { Locale(identifier: code) }
    public var code: String {
        registrar.access(self, keyPath: \.selection)
        return lock.withLock { resolved }
    }
    public static func resolve(_ preferences: [String]) -> String {
        for tag in preferences {
            let base = tag.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").first.map(String.init) ?? ""
            if base == "zh" { return "zh-Hans" }
            if ["ko", "en", "es", "ja", "vi", "th"].contains(base) { return base }
        }
        return "en"
    }
    public func activate(defaults: UserDefaults = .standard) {
        apply(defaults.string(forKey: Self.preferenceKey) ?? "system", defaults: defaults, persist: false)
    }
    public func select(_ value: String, defaults: UserDefaults = .standard) { apply(value, defaults: defaults, persist: true) }
    private func apply(_ value: String, defaults: UserDefaults, persist: Bool) {
        let selected = Self.choices.contains { $0.id == value } ? value : "system"
        let resolved = selected == "system" ? Self.resolve(Locale.preferredLanguages) : selected
        let catalog = Self.loadCatalog(resolved)
        if persist { defaults.set(selected, forKey: Self.preferenceKey) }
        registrar.withMutation(of: self, keyPath: \.selection) {
            lock.withLock { self.selected = selected; self.resolved = resolved; self.catalog = catalog }
        }
    }
    public static func loadCatalog(_ language: String) -> [String: String] {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: language, withExtension: "json", subdirectory: "AppLocalization"),
              let data = try? Data(contentsOf: url), let result = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return result
    }
    public func text(_ message: AppLocalizedMessage) -> String {
        registrar.access(self, keyPath: \.selection)
        let template = lock.withLock { catalog[message.key] ?? message.key }
        return Self.render(template, arguments: message.arguments)
    }
    /// One pass: a file name containing __ARG_1__ must never be expanded a second time.
    public static func render(_ template: String, arguments: [String]) -> String {
        var result = "", rest = template[...]
        while let start = rest.range(of: "__ARG_") {
            result += rest[..<start.lowerBound]
            let tail = rest[start.upperBound...]
            guard let end = tail.range(of: "__"), let index = Int(tail[..<end.lowerBound]), arguments.indices.contains(index) else {
                result += rest[start.lowerBound...]; return result
            }
            result += arguments[index]; rest = tail[end.upperBound...]
        }
        return result + rest
    }
}

public func SPText(_ message: AppLocalizedMessage) -> String { AppLanguage.shared.text(message) }

/// Exact matches only for messages from our account service; never translate arbitrary user data.
public func SPServerText(_ value: String) -> String {
    AppLanguage.shared.text(AppLocalizedMessage(stringLiteral: value))
}
