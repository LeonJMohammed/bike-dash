import Foundation

/// When this build's free signing profile runs out (7 days after it was made).
enum SigningInfo {
    /// Nil in the simulator, which has no profile.
    static let expiry: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8)) else { return nil }
        // The profile is a signed envelope around a plain plist.
        let plist = try? PropertyListSerialization.propertyList(
            from: data.subdata(in: start.lowerBound..<end.upperBound),
            format: nil
        ) as? [String: Any]
        return plist?["ExpirationDate"] as? Date
    }()

    static var expiryText: String {
        guard let expiry else { return "Unknown" }
        return expiry.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}
