import SwiftUI

struct RootView: View {
    let heartRate: HeartRateService

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack {
                Spacer()
                HeartRateScreen(heartRate: heartRate)
                Spacer()
                Text(AppInfo.summary)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Color.gray)
                    .padding(.bottom, 8)
            }
        }
    }
}
