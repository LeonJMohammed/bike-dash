import Foundation

/// Version details shown on screen, so it's clear which build is on the phone.
enum AppInfo {
    static var version: String { string("CFBundleShortVersionString") ?? "?" }
    static var build: String { string("CFBundleVersion") ?? "?" }
    static var commit: String { string("BikeDashCommit") ?? "dev" }

    /// For example "v0.1.0 (12) 3f2a9c1".
    static var summary: String { "v\(version) (\(build)) \(commit)" }

    private static func string(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}
