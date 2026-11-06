import SwiftUI
import UIKit

struct RootView: View {
    let heartRate: HeartRateService
    let location: LocationService

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                Spacer(minLength: 0)
                HeartRatePanel(heartRate: heartRate)
                Divider().overlay(Color.gray.opacity(0.4))
                GPSPanel(location: location)
                Spacer(minLength: 0)
                Text(AppInfo.summary)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Color.gray)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        // Keep the screen on while GPS is tracking (step 3 moves this to the ride).
        .onChange(of: location.isTracking) { _, tracking in
            UIApplication.shared.isIdleTimerDisabled = tracking
        }
    }
}
