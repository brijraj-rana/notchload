import NotchloadCore
import SwiftUI

// MARK: Geometry

struct NotchGeometry: Equatable {
    var notchWidth: CGFloat = 185
    var notchHeight: CGFloat = 32          // 0 on a screen without a notch
    var collapsedHeight: CGFloat = 24
    var expandedWidth: CGFloat = 372
    var expandedHeight: CGFloat = 430
    var margin: CGFloat = 40               // room for the shadow

    var windowSize: CGSize {
        CGSize(width: expandedWidth + margin * 2, height: notchHeight + expandedHeight + margin)
    }
}

final class PanelState: ObservableObject {
    @Published var expanded = false
    @Published var pinned = false          // held open by a click instead of the pointer
    @Published var geo = NotchGeometry()

    /// Where each process row sits in the window (top-left origin), so a right-click can find its process.
    var rowFrames: [Int: CGRect] = [:]
}

struct RowFramesKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: Shape

/// The notch column at the top, flaring out into a body below it. progress 0 = tab, 1 = full panel.
struct NotchShape: Shape {
    var progress: CGFloat
    var geo: NotchGeometry

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let p = max(0, progress)
        let nw = geo.notchWidth
        let nh = geo.notchHeight
        let w = nw + (geo.expandedWidth - nw) * p
        let h = geo.collapsedHeight + (geo.expandedHeight - geo.collapsedHeight) * p
        let bottomRadius = 10 + 10 * min(1, p)
        let cx = rect.midX
        let ext = (w - nw) / 2
        let bottom = nh + h

        var path = Path()
        path.move(to: CGPoint(x: cx - nw / 2, y: 0))
        if ext > 1, nh > 0 {
            let r = min(10, ext / 2)
            path.addArc(tangent1End: CGPoint(x: cx - nw / 2, y: nh), tangent2End: CGPoint(x: cx - w / 2, y: nh), radius: r)
            path.addArc(tangent1End: CGPoint(x: cx - w / 2, y: nh), tangent2End: CGPoint(x: cx - w / 2, y: bottom), radius: r)
        } else if ext > 1 {
            path.move(to: CGPoint(x: cx - w / 2, y: 0))
        }
        path.addArc(tangent1End: CGPoint(x: cx - w / 2, y: bottom), tangent2End: CGPoint(x: cx + w / 2, y: bottom), radius: bottomRadius)
        path.addArc(tangent1End: CGPoint(x: cx + w / 2, y: bottom), tangent2End: CGPoint(x: cx + w / 2, y: nh), radius: bottomRadius)
        if ext > 1, nh > 0 {
            let r = min(10, ext / 2)
            path.addArc(tangent1End: CGPoint(x: cx + w / 2, y: nh), tangent2End: CGPoint(x: cx + nw / 2, y: nh), radius: r)
            path.addArc(tangent1End: CGPoint(x: cx + nw / 2, y: nh), tangent2End: CGPoint(x: cx + nw / 2, y: 0), radius: r)
            path.addLine(to: CGPoint(x: cx + nw / 2, y: 0))
        } else if ext > 1 {
            path.addLine(to: CGPoint(x: cx + w / 2, y: 0))
        } else {
            path.addLine(to: CGPoint(x: cx + nw / 2, y: 0))
        }
        path.closeSubpath()
        return path
    }
}

// MARK: Styling helpers

enum Tone {
    static let calm = Color(red: 0.42, green: 0.90, blue: 0.62)
    static let warm = Color(red: 1.00, green: 0.74, blue: 0.26)
    static let hot = Color(red: 1.00, green: 0.36, blue: 0.33)

    static let app = Color(red: 0.38, green: 0.66, blue: 1.00)
    static let wired = Color(red: 1.00, green: 0.62, blue: 0.30)
    static let compressed = Color(red: 0.72, green: 0.55, blue: 1.00)

    static func level(_ v: Double) -> Color {
        v >= 0.85 ? hot : (v >= 0.6 ? warm : calm)
    }

    static func pressure(_ level: Int) -> Color {
        level >= 4 ? hot : (level >= 2 ? warm : calm)
    }
}

struct Sparkline: View {
    let values: [Double]
    let color: Color
    var filled = true

    var body: some View {
        GeometryReader { g in
            let line = linePath(in: g.size)
            if filled {
                var area = line
                let _ = {
                    area.addLine(to: CGPoint(x: g.size.width, y: g.size.height))
                    area.addLine(to: CGPoint(x: 0, y: g.size.height))
                    area.closeSubpath()
                }()
                area.fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
            }
            line.stroke(color, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        }
    }

    private func linePath(in size: CGSize) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let step = size.width / CGFloat(values.count - 1)
        for (i, v) in values.enumerated() {
            let y = (size.height - 1) * (1 - CGFloat(min(1, max(0, v)))) + 0.5
            let pt = CGPoint(x: CGFloat(i) * step, y: y)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        return path
    }
}

// MARK: Collapsed tab

struct CollapsedView: View {
    let snap: Snapshot
    var culprit: String? = nil      // shown in place of the trace while load is sustained

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                Image(systemName: "cpu").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                Text(Fmt.percent(snap.cpu)).foregroundStyle(Tone.level(snap.cpu))
            }
            .frame(width: 46, alignment: .leading)

            ZStack {
                if let culprit {
                    Text(CulpritTracker.displayName(culprit))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity)
                        .transition(.opacity)
                } else {
                    Sparkline(values: Array(snap.history.suffix(30)), color: Tone.level(snap.cpu), filled: false)
                        .frame(height: 11)
                        .opacity(0.9)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.25), value: culprit)

            HStack(spacing: 3) {
                Text(Fmt.percent(snap.memFraction)).foregroundStyle(Tone.pressure(snap.memPressure))
                Image(systemName: "memorychip").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
            }
            .frame(width: 46, alignment: .trailing)
        }
        .font(.system(size: 10.5, weight: .semibold, design: .rounded).monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.bottom, 3)
    }
}

// MARK: Expanded panel

struct ExpandedView: View {
    let snap: Snapshot
    let processes: [ProcRow]
    let efficiencyCores: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            cpuSection
            Divider().overlay(.white.opacity(0.08))
            memorySection
            Divider().overlay(.white.opacity(0.08))
            statsRow
            Divider().overlay(.white.opacity(0.08))
            powerRow
            Divider().overlay(.white.opacity(0.08))
            processSection
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .foregroundStyle(.white)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.white.opacity(0.45))
    }

    private var cpuSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    label("CPU")
                    Text(Fmt.percent(snap.cpu))
                        .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Tone.level(snap.cpu))
                        .contentTransition(.numericText())
                }
                .frame(width: 82, alignment: .leading)

                Sparkline(values: snap.history, color: Tone.level(snap.cpu))
                    .frame(height: 40)
            }

            HStack(alignment: .bottom, spacing: 5) {
                ForEach(Array(snap.cores.enumerated()), id: \.offset) { index, value in
                    VStack(spacing: 3) {
                        CoreBar(value: value)
                        Text(coreLabel(index))
                            .font(.system(size: 8, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
            }
            .frame(height: 42)

            HStack {
                Text("Load ")
                    .foregroundStyle(.white.opacity(0.45))
                + Text(snap.load.map { String(format: "%.2f", $0) }.joined(separator: "  "))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                Circle().fill(thermalColor).frame(width: 5, height: 5)
                Text(thermalText).foregroundStyle(.white.opacity(0.8))
            }
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
        }
    }

    private func coreLabel(_ index: Int) -> String {
        guard efficiencyCores > 0 else { return "\(index + 1)" }
        return index < efficiencyCores ? "E\(index + 1)" : "P\(index - efficiencyCores + 1)"
    }

    private var thermalText: String {
        switch snap.thermal {
        case .nominal: return "Cool"
        case .fair: return "Warm"
        case .serious: return "Hot"
        case .critical: return "Throttling"
        @unknown default: return "Unknown"
        }
    }

    private var thermalColor: Color {
        switch snap.thermal {
        case .nominal: return Tone.calm
        case .fair: return Tone.warm
        default: return Tone.hot
        }
    }

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                label("MEMORY")
                Spacer()
                (Text(Fmt.gb(snap.memUsed)).foregroundStyle(.white)
                 + Text(" / \(Fmt.gb(snap.memTotal)) GB").foregroundStyle(.white.opacity(0.45)))
                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
            }

            GeometryReader { g in
                let total = max(1, Double(snap.memTotal))
                HStack(spacing: 1.5) {
                    Tone.app.frame(width: g.size.width * Double(snap.memApp) / total)
                    Tone.wired.frame(width: g.size.width * Double(snap.memWired) / total)
                    Tone.compressed.frame(width: g.size.width * Double(snap.memCompressed) / total)
                    Spacer(minLength: 0)
                }
                .background(.white.opacity(0.1))
                .clipShape(Capsule())
            }
            .frame(height: 6)

            HStack(spacing: 10) {
                legend(Tone.app, "App \(Fmt.gb(snap.memApp))")
                legend(Tone.wired, "Wired \(Fmt.gb(snap.memWired))")
                legend(Tone.compressed, "Comp \(Fmt.gb(snap.memCompressed))")
                Spacer(minLength: 0)
                legend(Tone.pressure(snap.memPressure), pressureText)
            }
            .font(.system(size: 9.5, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var pressureText: String {
        snap.memPressure >= 4 ? "Critical" : (snap.memPressure >= 2 ? "Pressure" : "Healthy")
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text).lineLimit(1).fixedSize()
        }
    }

    private var statsRow: some View {
        HStack(spacing: 0) {
            stat("GPU", snap.gpu.map(Fmt.percent) ?? "–", color: snap.gpu.map(Tone.level) ?? .white)
            stat("SWAP", Fmt.mem(snap.swapUsed), color: .white)
            stat("DOWN", Fmt.rate(snap.netDown), color: .white)
            stat("UP", Fmt.rate(snap.netUp), color: .white)
        }
    }

    @ViewBuilder
    private var powerRow: some View {
        HStack(spacing: 0) {
            if let battery = snap.battery {
                stat("BATTERY", Fmt.percent(battery.level), color: batteryColor(battery))
                stat("POWER", powerText(battery), color: .white)
                stat(battery.source == .battery ? "TIME LEFT" : "TO FULL", timeText(battery), color: .white)
            }
            if let disk = snap.disk {
                if snap.battery == nil {
                    stat("DISK FREE", "\(Fmt.disk(disk.free)) of \(Fmt.disk(disk.total))", color: Tone.level(disk.usedFraction))
                } else {
                    stat("DISK FREE", Fmt.disk(disk.free), color: Tone.level(disk.usedFraction))
                }
            } else {
                stat("DISK FREE", "Unknown", color: .white)
            }
        }
    }

    /// A low battery is the only time the level takes a warning colour, and only while it is draining.
    private func batteryColor(_ battery: Battery) -> Color {
        guard battery.source == .battery else { return .white }
        return battery.level <= 0.1 ? Tone.hot : (battery.level <= 0.2 ? Tone.warm : .white)
    }

    private func powerText(_ battery: Battery) -> String {
        switch battery.source {
        case .battery: return "Battery"
        case .charging: return "Charging"
        case .pluggedIn: return "Plugged in"
        }
    }

    private func timeText(_ battery: Battery) -> String {
        if let minutes = battery.minutesRemaining { return Fmt.clock(minutes: minutes) }
        if battery.source == .pluggedIn { return battery.level >= 0.995 ? "Full" : "On hold" }
        return "Estimating"
    }

    private func stat(_ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            label(title)
            Text(value)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var processSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                label("TOP PROCESSES")
                Spacer()
                label("CPU").frame(width: 48, alignment: .trailing)
                label("MEM").frame(width: 58, alignment: .trailing)
            }
            if processes.isEmpty {
                Text("Sampling…")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }
            ForEach(processes) { proc in
                HStack {
                    Text(proc.name).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 6)
                    Text(String(format: "%.1f%%", proc.cpu))
                        .foregroundStyle(Tone.level(proc.cpu / 100))
                        .frame(width: 48, alignment: .trailing)
                    Text(Fmt.mem(proc.memBytes))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 58, alignment: .trailing)
                }
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .background(GeometryReader { g in
                    Color.clear.preference(key: RowFramesKey.self, value: [proc.id: g.frame(in: .named("notchload.root"))])
                })
            }
        }
    }
}

struct CoreBar: View {
    let value: Double

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.1))
                RoundedRectangle(cornerRadius: 3)
                    .fill(Tone.level(value))
                    .frame(height: max(2, g.size.height * min(1, value)))
            }
        }
        .animation(.easeOut(duration: 0.4), value: value)
    }
}

// MARK: Root

struct RootView: View {
    @ObservedObject var state: PanelState
    @ObservedObject var metrics: Metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let g = state.geo
        let shape = NotchShape(progress: state.expanded ? 1 : 0, geo: g)

        ZStack(alignment: .top) {
            shape
                .fill(.black)
                .shadow(color: .black.opacity(state.expanded ? 0.4 : 0), radius: 14, y: 6)

            ZStack(alignment: .top) {
                if state.expanded {
                    ExpandedView(snap: metrics.snap, processes: metrics.processes, efficiencyCores: metrics.efficiencyCores)
                        .frame(width: g.expandedWidth, height: g.expandedHeight)
                        .overlay(alignment: .topTrailing) {
                            if state.pinned {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.55))
                                    .padding(.top, 7)
                                    .padding(.trailing, 10)
                                    .transition(.opacity)
                                    .accessibilityLabel("Pinned open")
                            }
                        }
                        .transition(.opacity)
                } else {
                    CollapsedView(snap: metrics.snap, culprit: metrics.culprit)
                        .frame(width: g.notchWidth, height: g.collapsedHeight)
                        .transition(.opacity)
                }
            }
            .padding(.top, g.notchHeight)
            .frame(width: g.windowSize.width, height: g.windowSize.height, alignment: .top)
            .mask(shape)
        }
        .frame(width: g.windowSize.width, height: g.windowSize.height, alignment: .top)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.36, dampingFraction: 0.82), value: state.expanded)
        .animation(.easeOut(duration: 0.15), value: state.pinned)
        .coordinateSpace(name: "notchload.root")
        .onPreferenceChange(RowFramesKey.self) { state.rowFrames = $0 }
        .ignoresSafeArea()
    }
}
