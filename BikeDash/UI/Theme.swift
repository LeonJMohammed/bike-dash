import SwiftUI

/// The bike-computer look: black, big white condensed numbers, red buttons.
enum Theme {
    static let red = Color(red: 0.80, green: 0.0, blue: 0.0)
    static let darkRed = Color(red: 0.55, green: 0.0, blue: 0.0)
    static let divider = Color(white: 0.25)
    static let dim = Color(white: 0.55)
    static let warning = Color.orange
    static let paused = Color.yellow

    /// Tall bold numbers.
    static func number(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold).width(.condensed).monospacedDigit()
    }

    static let label = Font.system(size: 17, weight: .medium)
    static let buttonTitle = Font.system(size: 30, weight: .heavy).width(.condensed)
    static let buttonSubtitle = Font.system(size: 16, weight: .semibold).width(.condensed)
    static let barLabel = Font.system(size: 22, weight: .heavy).width(.condensed)
    static let tileLabel = Font.system(size: 14, weight: .semibold).width(.condensed)
    static let pillLabel = Font.system(size: 17, weight: .heavy).width(.condensed)
}

struct HorizontalRule: View {
    var body: some View {
        Theme.divider.frame(height: 1)
    }
}

struct VerticalRule: View {
    var body: some View {
        Theme.divider.frame(width: 1)
    }
}

/// A label over a big number, centred in its cell.
struct MetricTile: View {
    let label: String
    let value: String
    let size: CGFloat
    var labelColor: Color = .white

    var body: some View {
        VStack(spacing: size * 0.06) {
            Text(label)
                .font(Theme.label)
                .foregroundStyle(labelColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(value)
                .font(Theme.number(size))
                .foregroundStyle(value == "--" ? Theme.dim : Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
