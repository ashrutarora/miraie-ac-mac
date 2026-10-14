import AppKit
import Charts
import SwiftUI

/// View-local state. `@State` is a macro in this SDK and its plugin ships
/// only with full Xcode, so views keep small state in one of these instead.
final class Box<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}

/// Control Center's look: translucent modules, the system accent for
/// anything selected, 13 pt rows. No custom brand colour.
enum Theme {
    static let module = Color.primary.opacity(0.07)
    static let control = Color.primary.opacity(0.09)
    static let radius: CGFloat = 13
}

struct Module<Content: View>: View {
    var padding: CGFloat = 10
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.module))
    }
}

struct MenuLabel: View {
    @ObservedObject var store: ACStore

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "snowflake")
            if store.device != nil, !store.state.online {
                Text("–")
            } else if store.state.power {
                Text("\(Int(store.state.setTemp))°")
            }
        }
    }
}

struct PanelView: View {
    @EnvironmentObject var store: ACStore

    var body: some View {
        VStack(spacing: 8) {
            if let device = store.device {
                Header(device: device)
                if let notice = store.notice { NoticeBar(text: notice) }
                if store.state.online {
                    DialModule()
                    SleepModule()
                    ModeModule()
                    FanModule()
                    MoreModule()
                } else {
                    Module {
                        Label("The AC is offline. Check it has power and Wi-Fi.", systemImage: "wifi.slash")
                            .font(.system(size: 12))
                    }
                }
                Footer()
            } else {
                SignedOut()
            }
        }
        .padding(12)
        .frame(width: 340)
        .onAppear { Task { await store.loadEnergy() } }
    }
}

// MARK: - Header

struct Header: View {
    @EnvironmentObject var store: ACStore
    let device: Device

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                if store.devices.count > 1 {
                    Menu(device.name) {
                        ForEach(store.devices) { d in Button(d.name) { store.select(d) } }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .font(.system(size: 13, weight: .semibold))
                } else {
                    Text(device.name).font(.system(size: 13, weight: .semibold))
                }
                Text(subtitle(device)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Power", isOn: Binding(get: { store.state.power }, set: store.setPower))
                .toggleStyle(.switch).labelsHidden()
                .disabled(!store.state.online)
                .keyboardShortcut("p", modifiers: .command)
                .help("Power (⌘P)")
        }
        .padding(.horizontal, 4)
    }

    private func subtitle(_ device: Device) -> String {
        var parts = [device.room]
        if !store.state.online { parts.append("Offline") }
        if let room = store.state.roomTemp { parts.append(String(format: "%.1f° in room", room)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct NoticeBar: View {
    @EnvironmentObject var store: ACStore
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Retry") { store.retryUnconfirmed() }.controlSize(.small)
            Button { store.dismissNotice() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Dismiss")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Color.orange.opacity(0.14)))
    }
}

// MARK: - Temperature

struct DialModule: View {
    @EnvironmentObject var store: ACStore

    var body: some View {
        let s = store.state
        let enabled = s.power && s.mode != "fan"
        Module(padding: 8) {
            HStack {
                StepButton(icon: "minus", label: "Cooler", enabled: enabled, key: .downArrow) {
                    store.setTemperature(s.setTemp - 1)
                }
                Spacer()
                TemperatureDial(value: s.setTemp, enabled: enabled, caption: caption(s)) {
                    store.setTemperature($0)
                }
                Spacer()
                StepButton(icon: "plus", label: "Warmer", enabled: enabled, key: .upArrow) {
                    store.setTemperature(s.setTemp + 1)
                }
            }
            .padding(.horizontal, 6)
        }
    }

    private func caption(_ s: ACState) -> String {
        if !s.power { return "Off" }
        if s.mode == "fan" { return "Fan only" }
        return s.eco ? "Eco" : s.powerful ? "Powerful" : "Set"
    }
}

struct TemperatureDial: View {
    let value: Double
    let enabled: Bool
    let caption: String
    let onChange: (Double) -> Void
    @StateObject private var hovering = Box(false)
    @StateObject private var scroll = ScrollWatcher()

    private let range = 16.0...30.0
    private let size: CGFloat = 176
    private let sweep = 270.0
    private let start = 135.0

    var body: some View {
        let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        let radius = size / 2 - 9
        let angle = Angle(degrees: start + sweep * fraction)
        ZStack {
            Circle().trim(from: 0, to: sweep / 360)
                .stroke(Theme.control, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(start))
            Circle().trim(from: 0, to: sweep / 360 * fraction)
                .stroke(enabled ? Color.accentColor : Color.secondary.opacity(0.5),
                        style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(start))
            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                .frame(width: 18, height: 18)
                .offset(x: radius * cos(angle.radians), y: radius * sin(angle.radians))
                .opacity(enabled ? 1 : 0)
            VStack(spacing: 0) {
                Text(caption).font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 1) {
                    Text("\(Int(value))")
                        .font(.system(size: 50, weight: .light))
                        .monospacedDigit()
                    Text("°").font(.system(size: 22, weight: .light)).padding(.top, 4)
                }
                .foregroundStyle(enabled ? .primary : .secondary)
                Text("Scroll or drag").font(.system(size: 9.5)).foregroundStyle(.tertiary)
                    .opacity(hovering.value && enabled ? 1 : 0)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .onHover { inside in
            hovering.value = inside
            scroll.active = inside && enabled
        }
        .onAppear { scroll.onStep = { step in onChange(value + Double(step)) } }
        .onChange(of: value) { _, new in scroll.onStep = { step in onChange(new + Double(step)) } }
        .gesture(
            DragGesture(minimumDistance: 0).onChanged { drag in
                guard enabled else { return }
                let dx = drag.location.x - size / 2, dy = drag.location.y - size / 2
                var degrees = atan2(dy, dx) * 180 / .pi - start
                while degrees < 0 { degrees += 360 }
                if degrees > sweep { degrees = degrees > sweep + (360 - sweep) / 2 ? 0 : sweep }
                let temp = (range.lowerBound + (degrees / sweep) * (range.upperBound - range.lowerBound)).rounded()
                if temp != value { onChange(temp) }
            }
        )
        .animation(.easeOut(duration: 0.15), value: value)
        .accessibilityElement()
        .accessibilityLabel("Temperature")
        .accessibilityValue("\(Int(value)) degrees")
        .accessibilityAdjustableAction { direction in
            guard enabled else { return }
            onChange(value + (direction == .increment ? 1 : -1))
        }
    }
}

/// Turns scroll-wheel or trackpad scrolling over the dial into ±1° steps.
final class ScrollWatcher: ObservableObject {
    var active = false
    var onStep: ((Int) -> Void)?
    private var monitor: Any?
    private var accumulated: CGFloat = 0

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, active else { return event }
            accumulated += event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 10)
            if abs(accumulated) >= 18 {
                onStep?(accumulated > 0 ? 1 : -1)
                accumulated = 0
            }
            return nil
        }
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

struct StepButton: View {
    let icon: String
    let label: String
    let enabled: Bool
    let key: KeyEquivalent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(Circle().fill(Theme.control))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: [])
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
        .help("\(label) (\(key == .upArrow ? "↑" : "↓"))")
    }
}

// MARK: - Sleep

struct SleepModule: View {
    @EnvironmentObject var store: ACStore

    var body: some View {
        let active = store.sleepSettingActive
        let step = store.sleepStep
        Button { store.applySleepSetting() } label: {
            HStack(spacing: 10) {
                Image(systemName: "moon.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(active ? .white : .primary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(active ? Color.accentColor : Theme.control))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sleep").font(.system(size: 13, weight: .semibold))
                    Text("Cool · Low fan · 50% · Swing")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let step {
                    ProgressView().controlSize(.small)
                    Text("\(step) of \(ACStore.sleepStepCount)")
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text(active ? "On" : "Start")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(active ? Color.secondary : Color.accentColor)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.module))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(step != nil)
        .keyboardShortcut("s", modifiers: .command)
        .help("Turn on with your bedtime settings (⌘S)")
        .accessibilityLabel(active ? "Sleep setting is on" : "Start sleep setting")
    }
}

// MARK: - Mode and fan

struct ModeModule: View {
    @EnvironmentObject var store: ACStore
    private let modes: [(String, String, String)] = [
        ("cool", "Cool", "snowflake"),
        ("dry", "Dry", "drop.fill"),
        ("fan", "Fan", "fan.fill"),
        ("auto", "Auto", "arrow.triangle.2.circlepath"),
    ]

    var body: some View {
        let s = store.state
        Module(padding: 10) {
            HStack(spacing: 0) {
                ForEach(modes, id: \.0) { value, label, icon in
                    RoundToggle(icon: icon, label: label, isOn: s.mode == value, enabled: s.power) {
                        store.setMode(value)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

struct RoundToggle: View {
    let icon: String
    let label: String
    let isOn: Bool
    let enabled: Bool
    var detail: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Group {
                    if let detail {
                        Text(detail).font(.system(size: 11, weight: .bold)).monospacedDigit()
                    } else {
                        Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                    }
                }
                .foregroundStyle(isOn ? .white : .primary)
                .frame(width: 38, height: 38)
                .background(Circle().fill(isOn ? Color.accentColor : Theme.control))
                Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

struct FanModule: View {
    @EnvironmentObject var store: ACStore
    private let speeds: [(String, String)] = [
        ("auto", "Auto"), ("quiet", "Quiet"), ("low", "Low"), ("medium", "Med"), ("high", "High"),
    ]

    var body: some View {
        let s = store.state
        let enabled = s.power && s.mode != "dry"
        Module(padding: 8) {
            HStack(spacing: 6) {
                Text("Fan").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .leading).padding(.leading, 4)
                ForEach(speeds, id: \.0) { value, label in
                    Pill(label: label, isOn: s.fan == value) { store.setFan(value) }
                }
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Fan speed")
    }
}

struct Pill: View {
    let label: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11.5, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? .white : .primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(isOn ? Color.accentColor : Theme.control))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn ? "Selected" : "")
    }
}

// MARK: - More (rows that open in place)

enum Section: String {
    case airflow, features, schedule, energy
}

struct MoreModule: View {
    @EnvironmentObject var store: ACStore
    @StateObject private var open = Box<Section?>(Snapshot.openSection)

    var body: some View {
        let s = store.state
        VStack(spacing: 0) {
            row(.airflow, "Airflow", "wind", airflowSummary(s)) { AirflowDetail() }
            divider
            row(.features, "Features", "square.grid.2x2", featureSummary(s)) { FeaturesDetail() }
            divider
            row(.schedule, "Timers & profile", "clock", scheduleSummary()) { ScheduleDetail() }
            divider
            row(.energy, "Energy", "bolt", energySummary()) { EnergyDetail() }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.module))
    }

    private var divider: some View {
        Divider().padding(.horizontal, 10).opacity(0.6)
    }

    @ViewBuilder
    private func row<Detail: View>(_ section: Section, _ title: String, _ icon: String, _ summary: String,
                                   @ViewBuilder detail: () -> Detail) -> some View {
        let isOpen = open.value == section
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { open.value = isOpen ? nil : section }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: icon).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
                    Text(title).font(.system(size: 13))
                    Spacer()
                    Text(summary).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(summary)")
            .accessibilityHint(isOpen ? "Collapse" : "Expand")
            if isOpen {
                detail()
                    .padding(.horizontal, 10).padding(.bottom, 10).padding(.top, 2)
                    .transition(.opacity)
            }
        }
    }

    private func airflowSummary(_ s: ACState) -> String {
        let name = { (v: Int) in v == 0 ? "Swing" : "\(v)" }
        return "↕ \(name(s.vSwing))  ↔ \(name(s.hSwing))"
    }

    private func featureSummary(_ s: ACState) -> String {
        var on: [String] = []
        if s.converti != 0 { on.append("Converti8 \(s.converti)%") }
        if s.eco { on.append("Eco") }
        if s.powerful { on.append("Powerful") }
        if s.nanoe { on.append("nanoe") }
        if s.clean { on.append("Clean") }
        if !s.display { on.append("Display off") }
        return on.isEmpty ? "None on" : on.joined(separator: " · ")
    }

    private func scheduleSummary() -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        var parts: [String] = []
        if let on = store.timerTarget(ACStore.switchOn) { parts.append("On \(f.string(from: on))") }
        if let off = store.timerTarget(ACStore.switchOff) { parts.append("Off \(f.string(from: off))") }
        if store.state.profile != "none" { parts.append("Profile") }
        return parts.isEmpty ? "None set" : parts.joined(separator: " · ")
    }

    private func energySummary() -> String {
        let total = store.energy.reduce(0) { $0 + ($1.kwh * 10).rounded() / 10 }
        let span = switch store.energyPeriod {
        case .daily: "7 days"
        case .weekly: "6 weeks"
        case .monthly: "6 months"
        }
        return String(format: "%.1f kWh, %@", total, span)
    }
}

// MARK: - Airflow

struct AirflowDetail: View {
    @EnvironmentObject var store: ACStore

    var body: some View {
        let s = store.state
        VStack(alignment: .leading, spacing: 8) {
            SwingRow(title: "Up–down", vertical: true, selected: s.vSwing, pick: store.setVerticalSwing)
            SwingRow(title: "Left–right", vertical: false, selected: s.hSwing, pick: store.setHorizontalSwing)
        }
        .disabled(!s.power)
        .opacity(s.power ? 1 : 0.4)
    }
}

struct SwingRow: View {
    let title: String
    let vertical: Bool
    let selected: Int
    let pick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(0...5, id: \.self) { position in
                    let isOn = position == selected
                    Button { pick(position) } label: {
                        VStack(spacing: 3) {
                            SwingGlyph(vertical: vertical, position: position).frame(width: 22, height: 18)
                            Text(position == 0 ? "Swing" : "\(position)").font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(isOn ? .white : .primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 8).fill(isOn ? Color.accentColor : Theme.control))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title) \(position == 0 ? "swing" : "position \(position)")")
                    .accessibilityValue(isOn ? "Selected" : "")
                }
            }
        }
    }
}

/// Draws where the air goes for one louvre position. Up–down is seen from the
/// side (1 = level, 5 = straight down); left–right from above (1 = far left).
/// Position 0 is the auto swing, drawn as a fan of all five directions.
struct SwingGlyph: View {
    let vertical: Bool
    let position: Int

    var body: some View {
        Canvas { context, size in
            let origin = vertical ? CGPoint(x: 3, y: 3) : CGPoint(x: size.width / 2, y: 3)
            let length = vertical ? size.width - 5 : size.height - 4
            var unit = Path()
            if vertical {
                unit.move(to: CGPoint(x: 0, y: 1)); unit.addLine(to: CGPoint(x: 7, y: 1))
            } else {
                unit.move(to: CGPoint(x: size.width / 2 - 6, y: 1)); unit.addLine(to: CGPoint(x: size.width / 2 + 6, y: 1))
            }
            context.stroke(unit, with: .foreground, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            for p in position == 0 ? Array(1...5) : [position] {
                let radians = angle(p) * .pi / 180
                let tip = vertical
                    ? CGPoint(x: origin.x + cos(radians) * length, y: origin.y + sin(radians) * length)
                    : CGPoint(x: origin.x + sin(radians) * length, y: origin.y + cos(radians) * length)
                var ray = Path()
                ray.move(to: origin)
                ray.addLine(to: tip)
                context.opacity = position == 0 ? 0.6 : 1
                context.stroke(ray, with: .foreground, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                context.fill(Path(ellipseIn: CGRect(x: tip.x - 1.8, y: tip.y - 1.8, width: 3.6, height: 3.6)), with: .foreground)
            }
        }
        .accessibilityHidden(true)
    }

    private func angle(_ position: Int) -> Double {
        vertical ? 8 + Double(position - 1) * 17 : Double(3 - position) * 24
    }
}

// MARK: - Features

struct FeaturesDetail: View {
    @EnvironmentObject var store: ACStore

    var body: some View {
        let s = store.state
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                RoundToggle(icon: "lightbulb.fill", label: "Display", isOn: s.display, enabled: true) { store.setDisplay(!s.display) }
                    .frame(maxWidth: .infinity)
                RoundToggle(icon: "leaf.fill", label: "Eco", isOn: s.eco, enabled: s.power) { store.setEco(!s.eco) }
                    .frame(maxWidth: .infinity)
                RoundToggle(icon: "bolt.fill", label: "Powerful", isOn: s.powerful, enabled: s.power) { store.setPowerful(!s.powerful) }
                    .frame(maxWidth: .infinity)
                RoundToggle(icon: "aqi.medium", label: "nanoe", isOn: s.nanoe, enabled: true) { store.setNanoe(!s.nanoe) }
                    .frame(maxWidth: .infinity)
                RoundToggle(icon: "sparkles", label: "Clean", isOn: s.clean, enabled: !s.power) { store.setClean(!s.clean) }
                    .frame(maxWidth: .infinity)
                    .help(s.power ? "Clean runs only while the AC is off" : "Dry the indoor unit")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Converti8 capacity").font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    ForEach(ACStore.convertiLevels, id: \.self) { level in
                        Button { store.setConverti(level) } label: {
                            Text(level == 0 ? "Off" : "\(level)")
                                .font(.system(size: 10.5, weight: s.converti == level ? .semibold : .regular))
                                .monospacedDigit()
                                .foregroundStyle(s.converti == level ? .white : .primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 7)
                                    .fill(s.converti == level ? Color.accentColor : Theme.control))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(level == 0 ? "Converti8 off" : "Converti8 \(level) percent")
                    }
                }
                Text("Percent of full cooling power. 100 is normal, 110 is the extra-capacity mode.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Timers and profile

struct ScheduleDetail: View {
    @EnvironmentObject var store: ACStore

    var body: some View {
        VStack(spacing: 8) {
            TimerRow(index: ACStore.switchOn, title: "Switch on at")
            TimerRow(index: ACStore.switchOff, title: "Switch off at")
            Divider().opacity(0.6)
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Default profile").font(.system(size: 12.5))
                    Text("24° for 3 h, 25° for 3 h, then 26°").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Default profile", isOn: Binding(get: { store.state.profile != "none" }, set: store.setSleepProfile))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            .disabled(!store.state.power)
            .opacity(store.state.power ? 1 : 0.4)
        }
    }
}

struct TimerRow: View {
    @EnvironmentObject var store: ACStore
    let index: Int
    let title: String
    @StateObject private var time = Box(Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: Date())!)

    var body: some View {
        let target = store.timerTarget(index)
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12.5))
            Spacer()
            if let target {
                Text("in " + Self.remaining(target)).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            DatePicker(title, selection: $time.value, displayedComponents: .hourAndMinute)
                .labelsHidden().datePickerStyle(.stepperField).controlSize(.small)
                .opacity(target == nil ? 0.55 : 1)
                .onChange(of: time.value) { _, new in
                    if let target, !Self.sameMinute(new, target) { store.scheduleTimer(index, new) }
                }
            Toggle(title, isOn: Binding(get: { target != nil }, set: { store.setTimer(index, $0 ? time.value : nil) }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
        .onAppear { if let target { time.value = target } }
        .onChange(of: target) { _, new in
            if let new, !Self.sameMinute(new, time.value) { time.value = new }
        }
    }

    static func sameMinute(_ a: Date, _ b: Date) -> Bool {
        let parts: Set<Calendar.Component> = [.hour, .minute]
        return Calendar.current.dateComponents(parts, from: a) == Calendar.current.dateComponents(parts, from: b)
    }

    static func remaining(_ date: Date) -> String {
        let minutes = max(0, Int((date.timeIntervalSinceNow / 60).rounded()))
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }
}

// MARK: - Energy

struct EnergyDetail: View {
    @EnvironmentObject var store: ACStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(EnergyPeriod.allCases) { period in
                    Pill(label: period.rawValue, isOn: store.energyPeriod == period) { store.setEnergyPeriod(period) }
                }
            }
            Chart(store.energy) { bar in
                BarMark(x: .value("When", bar.label), y: .value("kWh", bar.kwh))
                    .foregroundStyle(Color.accentColor.gradient)
                    .cornerRadius(3)
                    .annotation(position: .top, spacing: 2) {
                        Text(bar.kwh, format: .number.precision(.fractionLength(1)))
                            .font(.system(size: 9.5)).foregroundStyle(.secondary)
                    }
            }
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...max(0.1, (store.energy.map(\.kwh).max() ?? 0) * 1.3))
            .chartXAxis { AxisMarks { AxisValueLabel().font(.system(size: 9.5)) } }
            .frame(height: 96)
            .accessibilityLabel("Energy use in kilowatt hours")
        }
    }
}

// MARK: - Footer and states

struct Footer: View {
    @EnvironmentObject var store: ACStore

    var body: some View {
        let s = store.state
        HStack(spacing: 10) {
            if s.filterDirty {
                Label("Filter needs cleaning", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if s.online, s.rssi < -80 {
                Label("Weak Wi-Fi", systemImage: "wifi.exclamationmark")
            }
            Spacer()
            Menu {
                Button("Refresh") { store.refresh() }.keyboardShortcut("r")
                Divider()
                if !store.model.isEmpty { Text("Model \(store.model)") }
                if !store.firmware.isEmpty { Text("Firmware v\(store.firmware)") }
                Text("Wi-Fi signal \(s.rssi) dBm")
                Divider()
                Button("Quit MirAIe AC") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("More")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }
}

struct SignedOut: View {
    @EnvironmentObject var store: ACStore

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "snowflake").font(.system(size: 26)).foregroundStyle(.secondary)
            Text(store.problem ?? "Connecting…").font(.system(size: 12)).multilineTextAlignment(.center)
            HStack {
                Button("Retry") { Task { await store.start() } }
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(.vertical, 10)
    }
}
