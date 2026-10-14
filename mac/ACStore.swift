import Foundation

/// Holds the live state of the chosen AC and turns UI actions into MirAIe
/// commands. Field names and `ki` values are the ones the official iPhone app
/// sends (captured from its traffic on 15 Oct 2026).
@MainActor
final class ACStore: ObservableObject {
    @Published var state = ACState()
    @Published var devices: [Device] = []
    @Published var device: Device?
    @Published var model = ""
    @Published var firmware = ""
    @Published var problem: String? = "Connecting to MirAIe…"
    @Published var live = false
    /// True when there are no saved credentials, or MirAIe rejected them.
    @Published var needsSignIn = false
    @Published var energyPeriod = EnergyPeriod.daily
    @Published var energy: [EnergyBar] = []
    /// Shown when the AC hasn't confirmed a change; `retryUnconfirmed` resends it.
    @Published var notice: String?
    /// 1-based step while the Sleep setting is being applied, nil otherwise.
    @Published var sleepStep: Int?
    static let sleepStepCount = 6

    /// The app's "Default" sleep profile: one temperature per hour for 8 hours.
    static let sleepTemps = ["24.0", "24.0", "24.0", "25.0", "25.0", "25.0", "26.0", "26.0", "0.0"]
    static let convertiLevels = [0, 40, 50, 60, 70, 80, 90, 100, 110]

    private let api = MirAIeAPI()
    private let mqtt = MQTTClient()
    private var sid = 0
    private var pendingTemp: Task<Void, Never>?
    private var reconnect: Task<Void, Never>?
    private var energyLoadedAt: Date?
    /// Fields sent but not yet seen in a status from the AC: field -> (value, ki).
    private var unconfirmed: [String: (value: Any, ki: Int?)] = [:]
    private var confirmTimeout: Task<Void, Never>?

    init() {
        mqtt.onConnected = { [weak self] in
            Task { @MainActor in self?.live = true; self?.problem = nil }
        }
        mqtt.onDisconnected = { [weak self] in
            Task { @MainActor in
                self?.live = false
                self?.scheduleReconnect(after: 10)
            }
        }
        mqtt.onMessage = { [weak self] topic, data in
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            Task { @MainActor in self?.receive(topic: topic, json) }
        }
        Task { await start() }
    }

    // MARK: - Connection

    func start() async {
        reconnect = nil
        do {
            let credentials = try Credentials.load()
            try await api.login(credentials)
            devices = try await api.devices()
            let wanted = (Config.read()["default_ac"] as? String)?.lowercased()
            let chosen = devices.first { $0.name.lowercased() == wanted } ?? devices[0]
            if chosen != device { energyLoadedAt = nil }
            device = chosen
            try await refreshStatus()
            if let details = try? await api.details(chosen.id) {
                model = details["modelNumber"] as? String ?? ""
                firmware = details["firmwareVersion"] as? String ?? ""
            }
            mqtt.connect(
                host: "mqtt.miraie.in", port: 8883,
                clientId: "mac-miraie-\(UUID().uuidString.prefix(8))",
                username: api.homeId, password: api.token,
                topics: [chosen.topic + "/status", chosen.topic + "/connectionStatus"]
            )
            await loadEnergy()
            needsSignIn = false
        } catch MirAIeError.notSignedIn {
            needsSignIn = true
            problem = MirAIeError.notSignedIn.localizedDescription
        } catch MirAIeError.badLogin {
            needsSignIn = true
            problem = MirAIeError.badLogin.localizedDescription
        } catch {
            problem = error.localizedDescription
            scheduleReconnect(after: 30)
        }
    }

    /// Checks the login with MirAIe before saving it.
    func signIn(login: String, password: String) async {
        let credentials = Credentials(phone: Credentials.normalize(login), password: password)
        do {
            try await api.login(credentials)
            try credentials.save()
            problem = "Connecting to MirAIe…"
            needsSignIn = false
            await start()
        } catch {
            problem = error.localizedDescription
        }
    }

    func signOut() {
        mqtt.disconnect()
        Credentials.signOut()
        device = nil
        devices = []
        state = ACState()
        live = false
        needsSignIn = true
        problem = MirAIeError.notSignedIn.localizedDescription
    }

    private func scheduleReconnect(after seconds: UInt64) {
        guard reconnect == nil else { return }
        reconnect = Task {
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            await start()
        }
    }

    func refreshStatus() async throws {
        guard let device else { return }
        let status = try await api.status(device.id)
        apply(status)
    }

    func refresh() {
        Task {
            try? await refreshStatus()
            await loadEnergy(force: true)
        }
    }

    func select(_ device: Device) {
        Config.set("default_ac", device.name)
        Task { await start() }
    }

    private func receive(topic: String, _ json: [String: Any]) {
        if topic.hasSuffix("/status") || topic.hasSuffix("/connectionStatus") { apply(json) }
    }

    private func apply(_ json: [String: Any]) {
        let typedTemp = state.setTemp
        state.apply(json)
        for (field, sent) in unconfirmed {
            if let reported = json[field], Self.same(reported, sent.value) { unconfirmed[field] = nil }
        }
        if unconfirmed.isEmpty { notice = nil }
        // Don't let a status that crossed with an unsent drag snap the dial back.
        if pendingTemp != nil { state.setTemp = typedTemp }
    }

    // MARK: - Commands

    private func send(_ fields: [String: Any], ki: Int? = nil) {
        guard let device else { return }
        sid += 1
        var payload = fields
        payload["cnt"] = "an"
        payload["sid"] = String(sid)
        if let ki { payload["ki"] = ki }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        mqtt.publish(topic: device.topic + "/control", payload: data)
        // The AC echoes most fields back in its status. Profiles and timers come
        // back in another shape, so they aren't tracked.
        for (field, value) in fields where !["acsp", "pid", "temps", "actm"].contains(field) {
            unconfirmed[field] = (value, ki)
        }
        confirmTimeout?.cancel()
        confirmTimeout = Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, !unconfirmed.isEmpty else { return }
            notice = live ? "The AC didn't confirm the last change." : "Not connected to MirAIe, so the change wasn't sent."
        }
    }

    func retryUnconfirmed() {
        let pending = unconfirmed
        unconfirmed = [:]
        notice = nil
        for (field, sent) in pending { send([field: sent.value], ki: sent.ki) }
    }

    func dismissNotice() {
        unconfirmed = [:]
        notice = nil
    }

    private static func same(_ a: Any, _ b: Any) -> Bool {
        let text = { (x: Any) -> String in
            if let d = Double("\(x)") { return String(d) }
            return "\(x)"
        }
        return text(a) == text(b)
    }

    func setPower(_ on: Bool) {
        state.power = on
        send(["ps": on ? "on" : "off"], ki: 1)
    }

    /// Updates the dial at once, sends half a second after the last change.
    func setTemperature(_ value: Double) {
        let temp = min(30, max(16, value.rounded()))
        state.setTemp = temp
        pendingTemp?.cancel()
        pendingTemp = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            send(["actmp": String(format: "%.1f", temp)], ki: 2)
            pendingTemp = nil
        }
    }

    func setMode(_ mode: String) {
        state.mode = mode
        send(["acmd": mode], ki: 0)
        if mode == "dry" { setFan("low") } // as the app does: dry runs on low fan
    }

    func setFan(_ fan: String) {
        state.fan = fan
        send(["acfs": fan], ki: 4)
    }

    func setEco(_ on: Bool) {
        state.eco = on
        if on { state.powerful = false }
        send(["acem": on ? "on" : "off"], ki: 10)
        if on { setTemperature(26) } // the app pairs Eco with 26°; the AC restores the old setting when Eco ends
    }

    func setPowerful(_ on: Bool) {
        state.powerful = on
        if on { state.eco = false }
        send(["acpm": on ? "on" : "off"], ki: 3)
    }

    /// Clean dries the indoor unit and is only offered while the AC is off
    /// (turning it off while the AC runs makes the AC switch itself off).
    func setClean(_ on: Bool) {
        state.clean = on
        send(["acec": on ? "on" : "off"], ki: 1)
    }

    func setNanoe(_ on: Bool) {
        state.nanoe = on
        send(["acng": on ? "on" : "off"], ki: 60)
    }

    func setDisplay(_ on: Bool) {
        state.display = on
        send(["acdc": on ? "on" : "off"], ki: 8)
    }

    func setHorizontalSwing(_ value: Int) {
        state.hSwing = value
        send(["achs": value], ki: 6)
    }

    func setVerticalSwing(_ value: Int) {
        state.vSwing = value
        send(["acvs": value], ki: 5)
    }

    func setConverti(_ value: Int) {
        state.converti = value
        send(["cnv": value], ki: 191)
    }

    func setSleepProfile(_ on: Bool) {
        state.profile = on ? "default" : "none"
        send(["acsp": on ? "on" : "off", "pid": "default", "temps": Self.sleepTemps], ki: 12)
    }

    /// The bedtime setting: on, Cool, Low fan, Converti8 at 50%, both
    /// swings on auto. The temperature stays as it is.
    func applySleepSetting() {
        let steps: [() -> Void] = [
            { self.setPower(true) },
            { self.setMode("cool") },
            { self.setFan("low") },
            { self.setConverti(50) },
            { self.setVerticalSwing(0) },
            { self.setHorizontalSwing(0) },
        ]
        Task {
            for (index, step) in steps.enumerated() {
                sleepStep = index + 1
                step()
                // The AC drops commands that arrive on top of each other.
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            // Keep "Applying" up until the AC has confirmed every step, at most 6 s.
            for _ in 0..<12 where !unconfirmed.isEmpty {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            sleepStep = nil
        }
    }

    var sleepSettingActive: Bool {
        let s = state
        return s.power && s.mode == "cool" && s.fan == "low" && s.converti == 50 && s.vSwing == 0 && s.hSwing == 0
    }

    /// Positions in the AC's `actm` pair: it is [switch off, switch on].
    static let switchOff = 0, switchOn = 1

    /// When timer `index` (`switchOff` or `switchOn`) fires, if it is set.
    /// The AC reports each timer as the Unix time it fires, or -1.
    func timerTarget(_ index: Int) -> Date? {
        guard state.timers.count > index, state.timers[index] > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(state.timers[index]))
    }

    /// Sets or cancels (nil) one timer. The AC takes both timers at once, as
    /// seconds from now with -1 for "off", so the other one is resent too.
    func setTimer(_ index: Int, _ time: Date?) {
        let seconds = (0..<2).map { i -> Int in
            guard let date = i == index ? time : timerTarget(i) else { return -1 }
            // A timer about to fire keeps its exact countdown.
            if i != index, date.timeIntervalSinceNow < 60 { return max(1, Int(date.timeIntervalSinceNow)) }
            return max(1, Int(Self.nextOccurrence(of: date).timeIntervalSinceNow))
        }
        if state.timers.count == 2 {
            state.timers[index] = time.map { Int(Self.nextOccurrence(of: $0).timeIntervalSince1970) } ?? -1
        }
        send(["actm": seconds])
    }

    private var pendingTimer: Task<Void, Never>?

    /// For the time pickers: resend once the clicking stops.
    func scheduleTimer(_ index: Int, _ time: Date) {
        pendingTimer?.cancel()
        pendingTimer = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            setTimer(index, time)
            pendingTimer = nil
        }
    }

    /// The next moment the clock shows `time`'s hour and minute, at half past
    /// the minute: the AC's clock drifts a few seconds from the Mac's, and the
    /// middle of the minute keeps both showing (and firing in) the same minute.
    static func nextOccurrence(of time: Date) -> Date {
        var parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        parts.second = 30
        return Calendar.current.nextDate(after: Date(), matching: parts, matchingPolicy: .nextTime) ?? time
    }

    // MARK: - Energy

    func loadEnergy(force: Bool = false) async {
        guard let device else { return }
        if !force, let loaded = energyLoadedAt, Date().timeIntervalSince(loaded) < 600 { return }
        if let bars = try? await api.energy(device.id, energyPeriod) {
            energy = bars
            energyLoadedAt = Date()
        }
    }

    func setEnergyPeriod(_ period: EnergyPeriod) {
        energyPeriod = period
        Task { await loadEnergy(force: true) }
    }
}
