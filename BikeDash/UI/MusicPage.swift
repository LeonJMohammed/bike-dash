import SwiftUI

/// Swipe left from the numbers: Spotify now playing, with big buttons.
struct MusicPage: View {
    let spotify: SpotifyController

    var body: some View {
        VStack(spacing: 18) {
            Text("MUSIC")
                .font(Theme.label)
                .foregroundStyle(Color.white)
                .padding(.top, 16)
            if let now = spotify.nowPlaying, spotify.status == .connected {
                artwork
                    .frame(maxWidth: 260, maxHeight: 260)
                VStack(spacing: 6) {
                    Text(now.title)
                        .font(.system(size: 28, weight: .bold).width(.condensed))
                        .foregroundStyle(Color.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text(now.subtitle)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                }
                .padding(.horizontal, 20)
                HStack(spacing: 28) {
                    control(now.isEpisode ? "gobackward.15" : "backward.fill", enabled: now.isEpisode || now.canSkipPrevious) {
                        spotify.previous()
                    }
                    control(now.isPaused ? "play.fill" : "pause.fill", big: true, enabled: true) {
                        spotify.togglePlayPause()
                    }
                    control(now.isEpisode ? "goforward.15" : "forward.fill", enabled: now.isEpisode || now.canSkipNext) {
                        spotify.next()
                    }
                }
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                Image(systemName: "music.note")
                    .font(.system(size: 64, weight: .bold))
                    .foregroundStyle(Theme.dim)
                Text(statusText)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                if spotify.isConfigured && spotify.status != .connecting {
                    Button {
                        spotify.connectViaSpotifyApp()
                    } label: {
                        Text("CONNECT SPOTIFY")
                            .font(Theme.barLabel)
                            .frame(maxWidth: 280, minHeight: 64)
                            .background(Theme.red, in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(Color.white)
                    }
                    .buttonStyle(.plain)
                    Text("Opens Spotify, starts your music and comes back.")
                        .font(.footnote)
                        .foregroundStyle(Theme.dim)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var artwork: some View {
        if let image = spotify.artwork {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(white: 0.15))
                .aspectRatio(1, contentMode: .fit)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 64))
                        .foregroundStyle(Theme.dim)
                )
        }
    }

    private var statusText: String {
        switch spotify.status {
        case .notConfigured: return "Spotify isn't set up"
        case .connecting: return "Connecting to Spotify"
        case .connected: return "Nothing playing"
        case .disconnected: return spotify.lastError ?? "Spotify isn't connected"
        }
    }

    private func control(_ symbol: String, big: Bool = false, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: big ? 40 : 30, weight: .bold))
                .frame(width: big ? 96 : 76, height: big ? 96 : 76)
                .background(big ? Theme.red : Color(white: 0.15), in: Circle())
                .foregroundStyle(Color.white)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}
