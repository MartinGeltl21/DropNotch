import SwiftUI

struct NowPlayingView: View {
    @ObservedObject var music: MusicController

    var body: some View {
        if music.installedPlayers.isEmpty {
            placeholder(icon: "music.note", text: "Neither Spotify nor Music is installed")
        } else if let player = music.player {
            if music.permissionDenied {
                placeholder(icon: "lock", text: "Allow DropNotch to control \(player.name)") {
                    actionButton("Open System Settings", tint: player.accent, action: music.openAutomationSettings)
                }
            } else {
                playerView(player)
                    .onAppear(perform: music.startPolling)
                    .onDisappear(perform: music.stopPolling)
            }
        } else {
            placeholder(icon: "music.note", text: "No music player open") {
                HStack(spacing: 8) {
                    ForEach(music.installedPlayers) { player in
                        actionButton("Open \(player.name)", tint: player.accent) { music.open(player) }
                    }
                }
            }
        }
    }

    private func playerView(_ player: MusicPlayer) -> some View {
        HStack(spacing: 14) {
            artwork(player)
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        // Shows which app is currently being controlled.
                        if let icon = player.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 13, height: 13)
                                .help(player.name)
                        }
                        Text(music.track?.title ?? "Not Playing")
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                    }
                    Text(music.track?.artist ?? " ")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let duration = music.track?.duration ?? 0
                    let current = music.currentPosition(at: context.date)
                    VStack(spacing: 3) {
                        ProgressBar(progress: duration > 0 ? current / duration : 0) { fraction in
                            music.seek(toFraction: fraction)
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
                    ControlButton(systemImage: "backward.fill", size: 14, action: music.previousTrack)
                    ControlButton(systemImage: music.isPlaying ? "pause.fill" : "play.fill", size: 20,
                                  action: music.playPause)
                    ControlButton(systemImage: "forward.fill", size: 14, action: music.nextTrack)
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 6) {
                    Image(systemName: "speaker.wave.3.fill", variableValue: music.volume / 100)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Slider(value: Binding(get: { music.volume }, set: music.setVolume), in: 0...100)
                        .controlSize(.mini)
                        .tint(player.accent)
                }
                .help("Volume")
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func artwork(_ player: MusicPlayer) -> some View {
        Group {
            if let image = music.artwork {
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
        .onTapGesture { music.open(player) }
        .help("Open \(player.name)")
    }

    private func placeholder<Buttons: View>(icon: String, text: String,
                                            @ViewBuilder buttons: () -> Buttons = { EmptyView() }) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 24)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            buttons()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.05)))
    }

    private func actionButton(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .tint(tint)
            .controlSize(.small)
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
