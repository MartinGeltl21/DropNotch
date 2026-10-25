import SwiftUI

struct NowPlayingView: View {
    @ObservedObject var spotify: SpotifyController

    var body: some View {
        if !spotify.isInstalled {
            placeholder(icon: "music.note", text: "Spotify ist nicht installiert")
        } else if spotify.permissionDenied {
            placeholder(icon: "lock", text: "Erlaube NotchStash, Spotify zu steuern",
                        button: "Einstellungen öffnen", action: spotify.openAutomationSettings)
        } else if !spotify.isRunning {
            placeholder(icon: "music.note", text: "Spotify ist nicht geöffnet",
                        button: "Spotify öffnen", action: spotify.openSpotify)
        } else {
            player
        }
    }

    private var player: some View {
        HStack(spacing: 14) {
            artwork
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(spotify.track?.title ?? "Nichts läuft")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(spotify.track?.artist ?? " ")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let duration = spotify.track?.duration ?? 0
                    let current = spotify.currentPosition(at: context.date)
                    VStack(spacing: 3) {
                        ProgressBar(progress: duration > 0 ? current / duration : 0) { fraction in
                            spotify.seek(toFraction: fraction)
                        }
                        HStack {
                            Text(Self.format(current))
                            Spacer()
                            Text(Self.format(duration))
                        }
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 22) {
                    ControlButton(systemImage: "backward.fill", size: 14, action: spotify.previousTrack)
                    ControlButton(systemImage: spotify.isPlaying ? "pause.fill" : "play.fill", size: 20,
                                  action: spotify.playPause)
                    ControlButton(systemImage: "forward.fill", size: 14, action: spotify.nextTrack)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var artwork: some View {
        Group {
            if let image = spotify.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "music.note").font(.system(size: 28)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 96, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: spotify.openSpotify)
        .help("Spotify öffnen")
    }

    private func placeholder(icon: String, text: String, button: String? = nil,
                             action: (() -> Void)? = nil) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 24)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let button, let action {
                Button(button, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.05)))
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct ControlButton: View {
    let systemImage: String
    let size: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
                .scaleEffect(hovering ? 1.12 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hover in withAnimation(.easeOut(duration: 0.12)) { hovering = hover } }
    }
}

struct ProgressBar: View {
    let progress: Double
    let onSeek: (Double) -> Void
    @State private var dragValue: Double?

    var body: some View {
        GeometryReader { geo in
            let value = min(max(dragValue ?? progress, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2)).frame(height: 4)
                Capsule().fill(.white).frame(width: max(4, geo.size.width * value), height: 4)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in dragValue = drag.location.x / max(geo.size.width, 1) }
                    .onEnded { _ in
                        if let dragValue { onSeek(min(max(dragValue, 0), 1)) }
                        dragValue = nil
                    }
            )
        }
        .frame(height: 10)
    }
}
