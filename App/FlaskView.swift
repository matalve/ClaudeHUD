import SwiftUI

// The flask SVG from the original, redrawn natively. ViewBox is 60x100;
// the liquid surface sits at y=92 (empty) … y=12 (full). All three flasks
// render in a single Canvas driven by one TimelineView — per-flask canvases
// triple the redraw overhead of the always-moving ripple.

private let surfaceBottom = 92.0
private let surfaceTop = 12.0
private let waveLength = 15.0
private let waveAmplitude = 1.5
private let waveSpeed = 30.0 / 3.2 // translateX -30px per 3.2s loop

private let columnWidth = 68.0
private let columnSpacing = 6.0
private let bowlWidth = 62.0
private let bowlHeight = 104.0

// liquid shifts hue as it fills: green→yellow (5h), blue→dark purple (7d),
// orange→red (weekly Fable)
enum FlaskKind: String, CaseIterable {
    case five, seven, fable

    var colors: (base: (Double, Double, Double), hot: (Double, Double, Double)) {
        switch self {
        case .five: ((74, 222, 128), (250, 204, 21))
        case .seven: ((96, 165, 250), (109, 40, 217))
        case .fable: ((251, 146, 60), (220, 38, 38))
        }
    }

    var label: String {
        switch self {
        case .five: "session · 5h"
        case .seven: "week · 7d"
        case .fable: "fable · 7d"
        }
    }
}

func flaskRGB(_ kind: FlaskKind, pct: Double) -> (Double, Double, Double) {
    let (base, hot) = kind.colors
    let t = max(0, min(1, (pct - 70) / 25)) // shift over 70%→95%
    return (
        base.0 + (hot.0 - base.0) * t,
        base.1 + (hot.1 - base.1) * t,
        base.2 + (hot.2 - base.2) * t
    )
}

/// All flask animation dynamics — wave phase, splash ramp, fill-level easing,
/// falling drops. A plain class so the per-frame draw loop never touches
/// SwiftUI state: mutating @State every frame schedules extra view updates on
/// top of the timeline ticks and burns CPU for nothing.
final class FlaskMotion {
    struct ActiveDrop {
        let start: Double
        let targetY: Double
        let rgb: (Double, Double, Double)
    }

    private var phase = 0.0
    private var lastTick: Double?
    private var splashStart: Double?
    var shownY = surfaceBottom // eased-toward-target fill level
    var drops: [ActiveDrop] = []

    func addDrop(targetY: Double, rgb: (Double, Double, Double), at now: Double) {
        drops.append(ActiveDrop(start: now, targetY: targetY, rgb: rgb))
    }

    /// Advance one frame: returns the wave phase. A drop hitting the surface
    /// kicks the ripple to 4x speed and eases it back — ramping the rate
    /// keeps the phase continuous.
    func advance(_ now: Double, target: Double?) -> Double {
        var rate = 1.0
        if let t0 = splashStart {
            let p = (now - t0) / 0.9
            if p >= 1 {
                splashStart = nil
            } else {
                rate = 1 + 3 * (1 - p) * (1 - p)
            }
        }
        // clamped so resuming after a pause doesn't leap the phase or snap
        // the level easing
        let dt = min(now - (lastTick ?? now), 0.1)
        phase += dt * waveSpeed * rate
        lastTick = now

        // stands in for the CSS 1.1s fill transition
        if let target, abs(target - shownY) > 0.01 {
            shownY += (target - shownY) * min(1, dt * 3.5)
        }

        drops.removeAll { drop in
            if now - drop.start >= 0.95 {
                splashStart = now
                return true
            }
            return false
        }
        return phase
    }
}

struct FlasksPanel: View {
    @EnvironmentObject var store: MonitorStore
    @EnvironmentObject var appDelegate: AppDelegate

    @State private var motions: [FlaskKind: FlaskMotion] = [
        .five: FlaskMotion(), .seven: FlaskMotion(), .fable: FlaskMotion(),
    ]
    // The ripple animates only around activity (drops, splashes, level
    // changes) and freezes otherwise: a perpetual 30fps ripple re-renders the
    // whole SwiftUI view graph every tick and shows up as constant CPU. The
    // original's CSS wave is GPU-composited, so it gets its loop for free.
    @State private var waveAnimating = false
    @State private var animationGeneration = 0

    private var infos: [(FlaskKind, FlaskInfo?)] {
        [(.five, store.fiveHour), (.seven, store.sevenDay), (.fable, store.fable)]
    }

    private func animateWave(for seconds: Double) {
        waveAnimating = true
        animationGeneration += 1
        let generation = animationGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if generation == animationGeneration { waveAnimating = false }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TimelineView(.animation(
                minimumInterval: 1 / 30,
                paused: !waveAnimating || !appDelegate.panelVisible
            )) { timeline in
                Canvas { context, _ in
                    let now = timeline.date.timeIntervalSinceReferenceDate
                    for (index, (kind, info)) in infos.enumerated() {
                        var flask = context
                        flask.translateBy(
                            x: Double(index) * (columnWidth + columnSpacing)
                                + (columnWidth - bowlWidth) / 2,
                            y: 0
                        )
                        flask.scaleBy(x: bowlWidth / 60, y: bowlHeight / 100)
                        drawFlask(&flask, kind: kind, info: info, now: now)
                    }
                }
            }
            .frame(
                width: columnWidth * 3 + columnSpacing * 2, height: bowlHeight
            )

            HStack(alignment: .top, spacing: columnSpacing) {
                ForEach(FlaskKind.allCases, id: \.self) { kind in
                    FlaskLabels(
                        kind: kind,
                        info: infos.first { $0.0 == kind }?.1 ?? nil
                    )
                }
            }
        }
        .onChange(of: store.fiveHour?.usedPercentage) { old, new in
            spawnDrop(.five, old: old, new: new)
        }
        .onChange(of: store.sevenDay?.usedPercentage) { old, new in
            spawnDrop(.seven, old: old, new: new)
        }
        .onChange(of: store.fable?.usedPercentage) { old, new in
            spawnDrop(.fable, old: old, new: new)
        }
        .onAppear { animateWave(for: 2.5) } // initial fill-up ease
    }

    // a rising percentage spawns a falling drop; any change eases the level
    private func spawnDrop(_ kind: FlaskKind, old: Double?, new: Double?) {
        animateWave(for: 2)
        guard let new, let old, new > old + 0.5 else { return }
        let clamped = min(100, max(0, new))
        motions[kind]?.addDrop(
            targetY: surfaceY(clamped),
            rgb: flaskRGB(kind, pct: clamped),
            at: Date.timeIntervalSinceReferenceDate
        )
        animateWave(for: 3) // fall + splash decay
    }

    private func drawFlask(
        _ context: inout GraphicsContext, kind: FlaskKind, info: FlaskInfo?, now: Double
    ) {
        guard let motion = motions[kind] else { return }
        let pct = info.map { max(0, min(100, $0.usedPercentage)) }
        let phase = motion.advance(now, target: pct.map(surfaceY))
        let flask = flaskPath()

        // liquid, clipped to the glass
        if let pct, pct.rounded() > 0 {
            let rgb = flaskRGB(kind, pct: pct)
            var liquid = context
            liquid.clip(to: flask)
            liquid.fill(
                wavePath(surface: motion.shownY, phase: phase),
                with: .color(Color(rgb: rgb).opacity(0.85))
            )
        }

        // falling drops — matches the original's CSS dropfall keyframes:
        //   0%  opacity 0, translateY(-8), scale .5
        //   22% opacity 1, translateY(0),  scale 1     (settles at the top)
        //   100% opacity .9, translateY(fall), scale .9 (falls to the surface)
        // over 0.95s with cubic-bezier(0.5, 0.05, 0.9, 0.4).
        for drop in motion.drops {
            let p = (now - drop.start) / 0.95
            guard p < 1 else { continue }
            let y: Double, opacity: Double, scale: Double
            if p < 0.22 {
                let t = dropEase(p / 0.22)
                y = -8 + 8 * t
                opacity = t
                scale = 0.5 + 0.5 * t
            } else {
                let t = dropEase((p - 0.22) / 0.78)
                y = drop.targetY * t
                opacity = 1 - 0.1 * t
                scale = 1 - 0.1 * t
            }
            let rect = CGRect(x: 30 - 4 * scale, y: y, width: 8 * scale, height: 11 * scale)
            let (r, g, b) = drop.rgb
            let light = (r + (255 - r) * 0.55, g + (255 - g) * 0.55, b + (255 - b) * 0.55)
            var dropCtx = context
            dropCtx.opacity = opacity
            dropCtx.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(
                    Gradient(colors: [Color(rgb: light), Color(rgb: drop.rgb)]),
                    center: CGPoint(x: rect.midX - 1, y: rect.minY + 3),
                    startRadius: 0, endRadius: 6 * scale
                )
            )
        }

        // glass on top
        context.fill(flask, with: .color(Color(rgb: (226, 232, 240)).opacity(0.07)))
        context.stroke(
            flask,
            with: .color(Color(rgb: (203, 213, 225)).opacity(0.55)),
            style: StrokeStyle(lineWidth: 1.6, lineJoin: .round)
        )
    }

    // M24 4 L36 4 L36 38 L54 84 Q56 92 48 92 L12 92 Q4 92 6 84 L24 38 Z
    private func flaskPath() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 24, y: 4))
        p.addLine(to: CGPoint(x: 36, y: 4))
        p.addLine(to: CGPoint(x: 36, y: 38))
        p.addLine(to: CGPoint(x: 54, y: 84))
        p.addQuadCurve(to: CGPoint(x: 48, y: 92), control: CGPoint(x: 56, y: 92))
        p.addLine(to: CGPoint(x: 12, y: 92))
        p.addQuadCurve(to: CGPoint(x: 6, y: 84), control: CGPoint(x: 4, y: 92))
        p.addLine(to: CGPoint(x: 24, y: 38))
        p.closeSubpath()
        return p
    }

    private func wavePath(surface: Double, phase: Double) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: surface + waveValue(0, phase)))
        var x = 0.0
        while x < 60 {
            x += 1.5
            p.addLine(to: CGPoint(x: x, y: surface + waveValue(x, phase)))
        }
        p.addLine(to: CGPoint(x: 60, y: 100))
        p.addLine(to: CGPoint(x: 0, y: 100))
        p.closeSubpath()
        return p
    }

    private func waveValue(_ x: Double, _ phase: Double) -> Double {
        -waveAmplitude * sin((x + phase) * 2 * .pi / waveLength)
    }
}

private func surfaceY(_ pct: Double) -> Double {
    surfaceBottom - (pct / 100) * (surfaceBottom - surfaceTop)
}

// The drop's timing function: CSS cubic-bezier(0.5, 0.05, 0.9, 0.4).
// Maps a linear time fraction to the eased fraction by solving the curve's
// x for its parameter, then evaluating y.
private func dropEase(_ x: Double) -> Double {
    func bez(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let mt = 1 - t
        return 3 * mt * mt * t * a + 3 * mt * t * t * b + t * t * t
    }
    var lo = 0.0, hi = 1.0, t = x
    for _ in 0..<18 {
        t = (lo + hi) / 2
        if bez(t, 0.5, 0.9) < x { lo = t } else { hi = t }
    }
    return bez(t, 0.05, 0.4)
}

private struct FlaskLabels: View {
    let kind: FlaskKind
    let info: FlaskInfo?

    private var pct: Double? {
        info.map { max(0, min(100, $0.usedPercentage)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(pct.map { "\(Int($0.rounded()))%" } ?? "–")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(pctColor)
                .shadow(color: .black.opacity(0.8), radius: 3, y: 1)
                .padding(.top, 2)
            Text(kind.label)
                .font(.system(size: 9.5))
                .foregroundColor(Color(rgb: (148, 163, 184)))
                .kerning(0.4)
            TimelineView(.periodic(from: .now, by: info?.resetsAt != nil ? 1 : 3600)) { _ in
                VStack(spacing: 0) {
                    Text(info?.resetsAt.map(formatReset) ?? " ")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(rgb: (203, 213, 225)))
                        .padding(.top, 2)
                    Text(info?.resetsAt.map(countdownText) ?? " ")
                        .font(.system(size: 9.5))
                        .monospacedDigit()
                        .foregroundColor(Color(rgb: (125, 211, 252)))
                }
            }
        }
        .frame(width: columnWidth)
    }

    private var pctColor: Color {
        guard let pct else { return Color(rgb: (226, 232, 240)) }
        if pct >= 90 { return Color(rgb: (248, 113, 113)) } // crit
        if pct >= 70 { return Color(rgb: (251, 191, 36)) }  // warn
        return Color(rgb: (226, 232, 240))
    }
}

private func formatReset(_ epochSec: Int) -> String {
    let date = Date(timeIntervalSince1970: Double(epochSec))
    let time = date.formatted(date: .omitted, time: .shortened)
    if date.timeIntervalSinceNow < 24 * 60 * 60 {
        return "resets at \(time)"
    }
    let weekday = date.formatted(.dateTime.weekday(.abbreviated))
    return "resets \(weekday) \(time)"
}

private func countdownText(_ epochSec: Int) -> String {
    var seconds = epochSec - Int(Date().timeIntervalSince1970)
    if seconds <= 0 { return "" }
    let h = seconds / 3600
    let m = (seconds % 3600) / 60
    seconds %= 60
    if h >= 24 { return "in \(h / 24)d \(h % 24)h" }
    if h > 0 { return "in \(h)h \(String(format: "%02d", m))m" }
    if m > 0 { return "in \(m)m \(String(format: "%02d", seconds))s" }
    return "in \(seconds)s"
}

extension Color {
    init(rgb: (Double, Double, Double)) {
        self.init(red: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255)
    }
}
