import Foundation

/// How the ride screen looks. OLED black keeps every pixel off except the
/// ones that carry meaning: numbers, alerts and thin outlines.
public enum RideTheme: String, CaseIterable, Codable, Sendable {
    case oledBlack
    case standard

    public static let `default` = RideTheme.oledBlack

    /// From the saved setting; anything unknown or missing is the default.
    public init(stored: String?) {
        self = stored.flatMap(RideTheme.init(rawValue:)) ?? .default
    }

    public var title: String {
        switch self {
        case .oledBlack: return "OLED black"
        case .standard: return "Standard"
        }
    }

    /// Buttons and panels drawn as thin outlines instead of filled shapes.
    public var outlinesControls: Bool { self == .oledBlack }

    /// Whether the music bar sits on a colour taken from the album cover.
    /// Standard always does; OLED black keeps it black unless asked.
    public func musicBarUsesAlbumColour(albumColourSetting: Bool) -> Bool {
        self == .standard || albumColourSetting
    }
}
