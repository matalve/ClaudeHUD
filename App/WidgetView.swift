import SwiftUI

// Root widget layout. The original is a wide 514x250 with flasks beside the
// trackers; this port stacks them vertically instead — flasks on top, a
// scrollable tracker list below — so the widget is a narrow column that can
// park at the screen edge. Everything is laid out in design units and scaled
// as one unit.

let designWidth: CGFloat = 244
let designHeight: CGFloat = 416

/// The only part of the widget that catches clicks: the strip where the
/// chrome bar fades in (it counts even while invisible — stopping there
/// reveals it). Everything else is click-through: flasks and cards are pure
/// display, so clicks over them fall to whatever is underneath.
let chromeStripRect = CGRect(x: 8, y: 8, width: designWidth - 16, height: 26)

struct WidgetView: View {
    @EnvironmentObject var store: MonitorStore
    @EnvironmentObject var appDelegate: AppDelegate

    @AppStorage("cm-opacity") private var contentOpacity = 70.0
    @AppStorage("cm-volume") private var ringVolume = 60.0
    @AppStorage("cm-scale") private var scale = 1.0
    // The scale slider lives inside the content it scales — applying the
    // value live moves the slider under a stationary cursor and the value
    // runs away to an extreme. Track the drag here, commit on release.
    @State private var scaleDraft: Double?

    var body: some View {
        TimelineView(.animation(paused: !store.alarmActive)) { timeline in
            root.offset(shakeOffset(timeline.date))
        }
        // topLeading so the 514x250 layout box lands where the topLeading-
        // anchored scaleEffect renders it — centering (the default) makes the
        // scaled content drift diagonally as the scale changes
        .frame(
            width: designWidth * scale, height: designHeight * scale,
            alignment: .topLeading
        )
        .onChange(of: scale) { _, k in appDelegate.applyScale(k) }
        .onChange(of: ringVolume, initial: true) { _, v in
            store.synth.ringVolume = Float(v / 100)
        }
    }

    private var root: some View {
        ZStack(alignment: .topLeading) {
            content
                .opacity(contentOpacity / 100)
            chrome
                .opacity(appDelegate.hovering ? 1 : 0)
                .animation(.easeOut(duration: 0.18), value: appDelegate.hovering)
        }
        .frame(width: designWidth, height: designHeight, alignment: .topLeading)
        .coordinateSpace(name: "widgetRoot")
        .scaleEffect(scale, anchor: .topLeading)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            flasks
            trackers
        }
        // top padding reserves the strip where the control bar fades in
        .padding(EdgeInsets(top: 36, leading: 8, bottom: 8, trailing: 8))
        .frame(width: designWidth, height: designHeight, alignment: .topLeading)
    }

    private var flasks: some View {
        FlasksPanel()
            .padding(EdgeInsets(top: 8, leading: 6, bottom: 6, trailing: 6))
        .background(Color(red: 13 / 255, green: 17 / 255, blue: 27 / 255).opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(rgb: (148, 163, 184)).opacity(0.15), lineWidth: 1)
        )
    }

    private var trackers: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 6) {
                if store.sessions.isEmpty {
                    Text(store.monitorAvailable ? "no active sessions" : "waiting for Claude Code…")
                        .font(.system(size: 11.5))
                        .italic()
                        .foregroundColor(Color(rgb: (148, 163, 184)))
                        .padding(EdgeInsets(top: 14, leading: 12, bottom: 14, trailing: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(red: 13 / 255, green: 17 / 255, blue: 27 / 255).opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(rgb: (148, 163, 184)).opacity(0.12), lineWidth: 1)
                        )
                }
                ForEach(store.sessions) { session in
                    SessionCardView(session: session, stopwatch: store.stopwatches[session.id])
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var chrome: some View {
        HStack(spacing: 6) {
            // the only drag handle — the rest of the widget is click-through
            Image(systemName: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(Color(rgb: (203, 213, 225)))
                .frame(width: 22, height: 18)
                .background(Color(rgb: (148, 163, 184)).opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .gesture(WindowDragGesture())
            chromeGroup {
                Text("⤢").font(.system(size: 10))
                Slider(
                    value: Binding(
                        get: { scaleDraft ?? scale },
                        set: { scaleDraft = $0 }
                    ),
                    in: 0.5...2
                ) { editing in
                    if !editing, let draft = scaleDraft {
                        scale = draft
                        scaleDraft = nil
                    }
                }
            }
            chromeGroup {
                Text("👁").font(.system(size: 10)).grayscale(1)
                Slider(value: $contentOpacity, in: 30...100)
            }
            chromeGroup {
                Text("🔊").font(.system(size: 10))
                Slider(value: $ringVolume, in: 0...100)
            }
            Button("✕") { appDelegate.hidePanel() }
                .buttonStyle(ChromeButtonStyle(hoverColor: Color(red: 190 / 255, green: 50 / 255, blue: 60 / 255)))
        }
        .padding(.horizontal, 5)
        .frame(width: designWidth - 16, height: 26)
        .background(Color(red: 20 / 255, green: 24 / 255, blue: 34 / 255).opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color(rgb: (148, 163, 184)).opacity(0.18), lineWidth: 1)
        )
        .offset(x: 8, y: 8)
    }

    private func chromeGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 3, content: content)
            .controlSize(.mini)
            .frame(maxWidth: .infinity)
    }

    // phone-vibrator pattern: buzz .. buzz .... (2s loop, like the ringtone)
    private func shakeOffset(_ date: Date) -> CGSize {
        guard store.alarmActive else { return .zero }
        let t = date.timeIntervalSinceReferenceDate
        let cycle = t.truncatingRemainder(dividingBy: 2)
        let buzzing = cycle < 0.44 || (cycle >= 0.64 && cycle < 1.04)
        guard buzzing else { return .zero }
        return CGSize(width: 2 * sin(t * 90), height: sin(t * 61 + 1))
    }
}

private struct ChromeButtonStyle: ButtonStyle {
    var hoverColor = Color(rgb: (148, 163, 184)).opacity(0.35)
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11))
            .foregroundColor(hovered ? .white : Color(rgb: (203, 213, 225)))
            .frame(width: 26, height: 18)
            .background(hovered ? hoverColor : Color(rgb: (148, 163, 184)).opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .onHover { hovered = $0 }
    }
}
