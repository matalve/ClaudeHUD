import SwiftUI

// One card per Claude Code session — a port of the original's card markup:
// [timer] title — Model — effort · ctx N%   /   state icon + detail line.

private let accentColors: [String: (Double, Double, Double)] = [
    "thinking": (167, 139, 250),
    "bash": (96, 165, 250),
    "editing": (74, 222, 128),
    "reading": (56, 189, 248),
    "tool": (129, 140, 248),
    "web": (45, 212, 191),
    "planning": (192, 132, 252),
    "compacting": (148, 163, 184),
    "waiting": (100, 116, 139),
    "done": (52, 211, 153),
    "interrupted": (251, 146, 60),
    "permission": (251, 191, 36),
]

struct SessionCardView: View {
    let session: MonitorSession
    let stopwatch: Stopwatch?

    private var accent: Color {
        Color(rgb: accentColors[session.state] ?? (100, 116, 139))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            titleRow
            statusRow
        }
        .padding(EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 9))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            session.state == "permission"
                // same dark glass as normal cards, nudged toward red
                ? Color(red: 42 / 255, green: 19 / 255, blue: 25 / 255).opacity(0.75)
                : Color(red: 13 / 255, green: 17 / 255, blue: 27 / 255).opacity(0.72)
        )
        .overlay(alignment: .leading) {
            accent.frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(rgb: (148, 163, 184)).opacity(0.15), lineWidth: 1)
        )
        .opacity(session.stale ? 0.5 : 1)
    }

    private var titleRow: some View {
        // tick each second only while the stopwatch is actually counting
        TimelineView(.periodic(from: .now, by: stopwatch?.runningSince != nil ? 1 : 3600)) { timeline in
            HStack(spacing: 5) {
                let timerText = stopwatch?.text(now: Int(timeline.date.timeIntervalSince1970 * 1000)) ?? ""
                if !timerText.isEmpty {
                    Text(timerText)
                        .monospacedDigit()
                        .foregroundColor(timerColor)
                }
                (Text(session.title).foregroundColor(Color(rgb: (226, 232, 240)))
                    + Text(metaText).fontWeight(.regular).foregroundColor(Color(rgb: (148, 163, 184))))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.system(size: 11, weight: .semibold))
        }
    }

    private var metaText: String {
        let meta = [session.model, session.effort].compactMap { $0 }.joined(separator: " — ")
        let ctx = session.contextPct.map { " · ctx \($0)%" } ?? ""
        if meta.isEmpty && ctx.isEmpty { return "" }
        return " — \(meta)\(ctx)"
    }

    private var timerColor: Color {
        switch stopwatchClass(session.state) {
        case "run": Color(rgb: (143, 167, 201))
        case "pause": Color(rgb: (201, 180, 120))
        default: Color(rgb: (122, 132, 148)) // inactive: last run's time
        }
    }

    private var statusRow: some View {
        // the fast cadence exists only for the animated thinking ellipsis
        TimelineView(.periodic(from: .now, by: session.state == "thinking" ? 0.3 : 3600)) { timeline in
            statusText(now: timeline.date)
                .font(.system(size: 11))
                .foregroundColor(Color(rgb: (203, 213, 225)))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var msgColor: Color { Color(rgb: (148, 163, 184)) }

    private func msg(_ s: String) -> Text {
        Text(" " + s).italic().foregroundColor(msgColor)
    }

    private func statusText(now: Date) -> Text {
        let d = session.detail
        switch session.state {
        case "thinking":
            let dots = String(repeating: ".", count: Int(now.timeIntervalSince1970 * 3) % 4)
            return Text("💭 Thinking") + Text(dots)
        case "permission":
            if d.plan {
                return Text("📋 ") + Text("Plan ready").bold()
                    + (d.message.isEmpty ? Text("") : msg(d.message))
            }
            return Text("📞 ") + Text("Claude is calling !").bold()
                + (d.message.isEmpty ? Text("") : msg(d.message))
        case "bash":
            return Text("❯ ") + Text(d.command.isEmpty ? d.description : d.command)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(Color(rgb: (165, 180, 252)))
        case "editing":
            return Text("✎ \(d.file) ")
                + Text("+\(d.added)").bold().foregroundColor(Color(rgb: (74, 222, 128)))
                + Text(" ")
                + Text("−\(d.removed)").bold().foregroundColor(Color(rgb: (248, 113, 113)))
        case "reading":
            return Text("📖 \(d.target.isEmpty ? "reading" : d.target)")
        case "tool":
            return Text("\(d.mcp ? "🔌" : "🔧") \(d.name.isEmpty ? "tool" : d.name)")
                + (d.info.isEmpty ? Text("") : msg(d.info))
        case "web":
            if !d.query.isEmpty { return Text("🔎") + msg(d.query) }
            return Text("🌐 \(d.url.isEmpty ? "fetching" : d.url)")
        case "planning":
            return Text("📋 Planning") + (d.step.isEmpty ? Text("") : msg(d.step))
        case "compacting":
            return Text("🗜 Compacting context…")
        case "done":
            return Text("✅ ") + Text("Done !").bold()
                + (d.message.isEmpty ? Text("") : msg(d.message))
        case "interrupted":
            return Text("🛑 ") + Text("Interrupted").bold()
                + (session.lastAction.map { msg($0) } ?? Text(""))
        default:
            let extra = d.message.isEmpty ? session.lastAction ?? "" : d.message
            return Text("💤 Waiting") + (extra.isEmpty ? Text("") : msg(extra))
        }
    }

}
