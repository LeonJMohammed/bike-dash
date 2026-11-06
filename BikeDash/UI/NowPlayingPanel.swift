import SwiftUI

/// Spotify along the bottom: the cover to the side on a background taken from
/// its colours, the song, and play/pause and skip.
struct NowPlayingPanel: View {
    let spotify: SpotifyController

    var body: some View {
        HStack(spacing: 14) {
            cover
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 21, weight: .bold).width(.condensed))
                    .lineLimit(2)
                Text(subtitle)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(Color.white)
            controls
        }
        .padding(14)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20)
                .fill(backgroundColor)
                .ignoresSafeArea(edges: .bottom)
        )
        .animation(.easeInOut(duration: 0.6), value: backgroundColor)
    }

    private var playing: SpotifyController.NowPlaying? {
        spotify.status == .connected ? spotify.nowPlaying : nil
    }

    private var backgroundColor: Color {
        guard playing != nil else { return Color(white: 0.12) }
        return spotify.artworkTint ?? Color(white: 0.16)
    }

    private var title: String {
        playing?.title ?? "Spotify"
    }

    private var subtitle: String {
        if let playing { return playing.subtitle }
        switch spotify.status {
        case .notConfigured: return "Not set up"
        case .connecting: return "Connecting"
        case .connected: return "Nothing playing"
        case .disconnected: return spotify.lastError ?? "Not connected"
        }
    }

    @ViewBuilder private var cover: some View {
        if playing != nil, let image = spotify.artwork {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.12))
                .frame(width: 84, height: 84)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.6))
                )
        }
    }

    @ViewBuilder private var controls: some View {
        if let playing {
            let canSkip = playing.isEpisode || playing.canSkipNext
            HStack(spacing: 10) {
                circleButton(playing.isPaused ? "play.fill" : "pause.fill", diameter: 62) {
                    spotify.togglePlayPause()
                }
                circleButton(playing.isEpisode ? "goforward.15" : "forward.fill", diameter: 52) {
                    spotify.next()
                }
                .disabled(!canSkip)
                .opacity(canSkip ? 1 : 0.4)
            }
        } else if spotify.isConfigured && spotify.status != .connecting {
            Button {
                spotify.connectViaSpotifyApp()
            } label: {
                Text("CONNECT")
                    .font(Theme.pillLabel)
                    .padding(.horizontal, 18)
                    .frame(height: 48)
                    .background(Theme.red, in: Capsule())
                    .foregroundStyle(Color.white)
            }
            .buttonStyle(.plain)
        }
    }

    private func circleButton(_ symbol: String, diameter: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: diameter * 0.38, weight: .bold))
                .frame(width: diameter, height: diameter)
                .background(Color.white.opacity(0.18), in: Circle())
                .foregroundStyle(Color.white)
        }
        .buttonStyle(.plain)
    }
}
