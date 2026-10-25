import SwiftUI

/// Notch-Form: oben links/rechts nach außen gebogene "Ohren", unten abgerundet.
struct NotchShape: Shape {
    var earRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(earRadius, bottomRadius) }
        set {
            earRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let e = earRadius
        let b = min(bottomRadius, (rect.height - e) / 2, rect.width / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + e, y: rect.minY + e),
                       control: CGPoint(x: rect.minX + e, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + e, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + e + b, y: rect.maxY),
                       control: CGPoint(x: rect.minX + e, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - e - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - e, y: rect.maxY - b),
                       control: CGPoint(x: rect.maxX - e, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - e, y: rect.minY + e))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - e, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

struct NotchView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var shelf: ShelfStore
    @ObservedObject var music: MusicController

    private var isOpen: Bool { vm.state == .open }

    var body: some View {
        let size = vm.shapeSize
        let ear = isOpen ? vm.earRadius + 4 : vm.earRadius * 0.6
        let bottom: CGFloat = isOpen ? 28 : (vm.state == .peek ? 18 : 10)

        ZStack(alignment: .top) {
            NotchShape(earRadius: ear, bottomRadius: bottom)
                .fill(Color.black)
                .frame(width: size.width + ear * 2, height: size.height)
                .shadow(color: .black.opacity(isOpen ? 0.45 : 0), radius: 14, y: 4)

            content
                .padding(.horizontal, ear)
                .frame(width: size.width + ear * 2, height: size.height, alignment: .top)
                .clipShape(NotchShape(earRadius: ear, bottomRadius: bottom))
        }
        // Auf Macs ohne Notch ist die geschlossene Form unsichtbar.
        .opacity(vm.state == .closed && !vm.hasPhysicalNotch ? 0 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Drops nimmt NotchHostingView entgegen (wegen Datei-Versprechen).
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        switch vm.state {
        case .closed:
            if vm.showsLiveActivity {
                LiveActivityView(music: music, notchWidth: vm.notchSize.width, wing: vm.liveActivityWing)
                    .frame(height: vm.notchSize.height)
                    .transition(.opacity)
            }
        case .peek:
            VStack {
                Spacer(minLength: vm.notchSize.height)
                HStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down.fill")
                    Text("Hier ablegen")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.bottom, 10)
            }
            .transition(.opacity)
        case .open:
            OpenNotchView(vm: vm, shelf: shelf, music: music)
                .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
        }
    }
}

/// Inhalt der aufgeklappten Notch: Kopfzeile neben der Kamera, darunter Musik + Ablage.
struct OpenNotchView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var shelf: ShelfStore
    @ObservedObject var music: MusicController

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("\(shelf.items.count)", systemImage: "tray.full")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: vm.notchSize.width + 20)
                if !shelf.items.isEmpty {
                    HeaderButton(systemImage: "trash", help: "Ablage leeren") { shelf.clear() }
                }
                HeaderButton(systemImage: vm.isPinned ? "pin.fill" : "pin",
                             help: vm.isPinned ? "Lösen" : "Offen halten") {
                    vm.isPinned.toggle()
                }
            }
            .padding(.horizontal, 20)
            .frame(height: vm.notchSize.height)

            HStack(spacing: 16) {
                NowPlayingView(music: music)
                    .frame(width: 280)
                ShelfView(shelf: shelf, vm: vm)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 18)
        }
        .foregroundStyle(.white)
    }
}

struct HeaderButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(hovering ? 0.18 : 0.08)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.85))
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Mini-Anzeige in der geschlossenen Notch: Cover links, Equalizer rechts.
struct LiveActivityView: View {
    @ObservedObject var music: MusicController
    let notchWidth: CGFloat
    let wing: CGFloat

    var body: some View {
        let accent = music.player?.accent ?? .green
        HStack(spacing: 0) {
            Group {
                if let artwork = music.artwork {
                    Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note").foregroundStyle(accent)
                }
            }
            .frame(width: wing - 12, height: wing - 12)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .frame(width: wing)

            Spacer(minLength: notchWidth)

            EqualizerView(color: accent)
                .frame(width: 16, height: 12)
                .frame(width: wing)
        }
    }
}

struct EqualizerView: View {
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let phase = sin(t * (5 + Double(i) * 1.7) + Double(i) * 1.3)
                    Capsule()
                        .fill(color)
                        .frame(width: 2.5, height: 4 + 8 * CGFloat((phase + 1) / 2))
                }
            }
        }
    }
}
