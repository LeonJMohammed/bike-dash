import SwiftUI

/// The "Eat / Drink" reminder: a large banner across the top of the ride
/// screen. An alert, so it's allowed a bright fill in the OLED black theme.
/// A tap dismisses it; otherwise it clears itself after 15 seconds.
struct ReminderBanner: View {
    let onDismiss: () -> Void

    var body: some View {
        Button(action: onDismiss) {
            VStack(spacing: 4) {
                Text("EAT / DRINK")
                    .font(.system(size: 52, weight: .heavy).width(.condensed))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("Tap to dismiss")
                    .font(.system(size: 16, weight: .semibold))
                    .opacity(0.75)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(Theme.warning, in: RoundedRectangle(cornerRadius: 18))
            .foregroundStyle(Color.black)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .accessibilityLabel("Eat and drink reminder. Tap to dismiss.")
    }
}
