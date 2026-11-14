import BikeDashCore
import SwiftUI

/// Spotify along the bottom: the cover to the side, the song, and play/pause
/// and skip. In the OLED black theme the bar is black with a hairline on top
/// and outlined buttons, unless Settings asks for the album colour behind it.
struct NowPlayingPanel: View {
    let spotify: SpotifyController
    @AppStorage(Theme.rideThemeKey) private var themeSetting = RideTheme.default.rawValue
    @AppStorage(Theme.albumColourKey) private var albumColourSetting = false

    private var theme: RideTheme { RideTheme(stored: themeSetting) }
    private var usesAlbumColour: Bool { theme.musicBarUsesAlbumColour(albumColourSetting: albumColourSetting) }

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
        .background {
            if usesAlbumColour {
                UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20)
                    .fill(backgroundColor)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                Color.black
                    .ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .top) { HorizontalRule() }
            }
        }
        // The colour change is the bar's only animation; black has none.
        .animation(usesAlbumColour ? .easeInOut(duration: 0.6) : nil, value: backgroundColor)
    }

    private var playing: SpotifyController.NowPlaying? {
        spotify.status == .connected ? spotify.nowPlaying : nil
    }

    private var backgroundColor: Color {
        guard usesAlbumColour else { return .black }
        guard playing != nil else { return Color(white: 0.12) }
        return spotify.artworkTint ?? Color(white: 0.16)
    }

    private var title: String {
        if let playing { return playing.title }
        return spotify.showsReconnectPrompt ? "Reconnect Spotify" : "Spotify"
    }

    private var subtitle: String {
        if let playing { return playing.subtitle }
        if spotify.showsReconnectPrompt { return "Spotify isn't answering" }
        if spotify.signingIn { return "Signing in" }
        if spotify.status == .disconnected && spotify.canSignIn && !spotify.isSignedIn {
            return spotify.lastError ?? "Sign in once to stay connected"
        }
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
                .fill(theme.outlinesControls ? Color.black : Color.white.opacity(0.12))
                .strokeBorder(theme.outlinesControls ? Theme.outline : .clear, lineWidth: 1.5)
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
        } else if spotify.showsReconnectPrompt {
            pill("RECONNECT") { spotify.connectViaSpotifyApp() }
        } else if spotify.canSignIn && !spotify.isSignedIn && spotify.status == .disconnected {
            if !spotify.signingIn {
                pill("SIGN IN") { spotify.signIn() }
            }
        } else if spotify.isConfigured && spotify.status != .connecting {
            pill("CONNECT") { spotify.connectViaSpotifyApp() }
        }
    }

    private func pill(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Theme.pillLabel)
                .padding(.horizontal, 18)
                .frame(height: 48)
                .background {
                    if theme.outlinesControls {
                        Capsule().strokeBorder(Theme.red, lineWidth: 2)
                    } else {
                        Capsule().fill(Theme.red)
                    }
                }
                .foregroundStyle(Color.white)
        }
        .buttonStyle(.plain)
    }

    private func circleButton(_ symbol: String, diameter: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: diameter * 0.38, weight: .bold))
                .frame(width: diameter, height: diameter)
                .background {
                    if theme.outlinesControls {
                        Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 1.5)
                    } else {
                        Circle().fill(Color.white.opacity(0.18))
                    }
                }
                .foregroundStyle(Color.white)
        }
        .buttonStyle(.plain)
    }
}
