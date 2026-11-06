import SwiftUI

struct RootView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "bicycle")
                    .font(.system(size: 72, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                Text("Bike Dash")
                    .font(.largeTitle.bold())
                    .foregroundStyle(Color.white)
                Text(AppInfo.summary)
                    .font(.footnote.monospaced())
                    .foregroundStyle(Color.gray)
            }
        }
    }
}
