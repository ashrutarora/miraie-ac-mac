import Foundation
import Security

/// MirAIe's cloud API: sign-in, homes and devices, status and energy.
/// Uses the same sign-in the `ac` command saved: the phone number in
/// ~/.config/miraie-ac/config.json and the password in the Keychain.

enum MirAIeError: LocalizedError {
    case notSignedIn, badLogin, server(Int), noDevices

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Not signed in. Run `ac login` in Terminal."
        case .badLogin: "MirAIe refused the saved password. Run `ac login` in Terminal."
        case .server(let code): "MirAIe's server answered \(code). Retrying…"
        case .noDevices: "No ACs on this MirAIe account."
        }
    }
}

struct Config {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/miraie-ac/config.json")

    static func read() -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    static func set(_ key: String, _ value: Any) {
        var config = read()
        config[key] = value
        if let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }
}

struct Credentials {
    let phone: String
    let password: String

    static func load() throws -> Credentials {
        guard let phone = Config.read()["phone"] as? String else { throw MirAIeError.notSignedIn }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "miraie-ac",
            kSecAttrAccount as String: phone,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8)
        else { throw MirAIeError.notSignedIn }
        return Credentials(phone: phone, password: password)
    }
}

struct Device: Identifiable, Hashable {
    let id: String
    let name: String
    let room: String
    let topic: String // base; "/control", "/status", "/connectionStatus" hang off it
}

struct EnergyBar: Identifiable {
    let id: String   // the API's date key
    let label: String
    let kwh: Double
}

enum EnergyPeriod: String, CaseIterable, Identifiable {
    case daily = "Daily", weekly = "Weekly", monthly = "Monthly"
    var id: String { rawValue }
}

final class MirAIeAPI {
    private static let clientId = "PBcMcfG19njNCL8AOgvRzIC8AjQa"
    private static let app = "https://app.miraie.in/simplifi/v1"

    private(set) var token = ""
    private(set) var homeId = ""

    func login(_ credentials: Credentials) async throws {
        var body: [String: Any] = [
            "clientId": Self.clientId,
            "password": credentials.password,
            "scope": "an_14214235325",
        ]
        body[credentials.phone.contains("@") ? "email" : "mobile"] = credentials.phone
        var request = URLRequest(url: URL(string: "https://auth.miraie.in/simplifi/v1/userManagement/login")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (400..<500).contains(code) { throw MirAIeError.badLogin }
        guard code == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["accessToken"] as? String
        else { throw MirAIeError.server(code) }
        self.token = token
    }

    private func get(_ path: String) async throws -> Any {
        var request = URLRequest(url: URL(string: Self.app + path)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw MirAIeError.server(code) }
        return try JSONSerialization.jsonObject(with: data)
    }

    func devices() async throws -> [Device] {
        guard let homes = try await get("/homeManagement/homes") as? [[String: Any]],
              let home = homes.first
        else { throw MirAIeError.noDevices }
        homeId = home["homeId"] as? String ?? ""
        var devices: [Device] = []
        for space in home["spaces"] as? [[String: Any]] ?? [] {
            for device in space["devices"] as? [[String: Any]] ?? [] {
                guard let id = device["deviceId"] as? String,
                      let topic = (device["topic"] as? [String])?.first
                else { continue }
                devices.append(Device(
                    id: id,
                    name: device["deviceName"] as? String ?? "AC",
                    room: space["spaceName"] as? String ?? "",
                    topic: topic
                ))
            }
        }
        if devices.isEmpty { throw MirAIeError.noDevices }
        return devices
    }

    func status(_ deviceId: String) async throws -> [String: Any] {
        try await get("/deviceManagement/devices/\(deviceId)/mobile/status") as? [String: Any] ?? [:]
    }

    func details(_ deviceId: String) async throws -> [String: Any] {
        (try await get("/deviceManagement/devices/deviceId/\(deviceId)") as? [[String: Any]])?.first ?? [:]
    }

    func energy(_ deviceId: String, _ period: EnergyPeriod) async throws -> [EnergyBar] {
        let calendar = Calendar.current
        let today = Date()
        // Weeks are keyed by their Sunday.
        let lastSunday = calendar.date(byAdding: .day, value: 1 - calendar.component(.weekday, from: today), to: today)!
        let (key, format, from, to): (String, String, Date, Date) = switch period {
        case .daily: ("day", "ddMMyyyy", calendar.date(byAdding: .day, value: -6, to: today)!, today)
        case .weekly: ("week", "ddMMyyyy", calendar.date(byAdding: .day, value: -35, to: lastSunday)!, lastSunday)
        case .monthly: ("month", "MMyyyy", calendar.date(byAdding: .month, value: -5, to: today)!, today)
        }
        let api = DateFormatter()
        api.dateFormat = format
        let path = "/powerConsumption/devices/\(deviceId)?grain=\(period.rawValue)"
            + "&startDate=\(api.string(from: from))&endDate=\(api.string(from: to))"
        guard let rows = try await get(path) as? [[String: Any]] else { return [] }

        let label = DateFormatter()
        label.dateFormat = period == .monthly ? "MMM" : "d MMM"
        return rows.compactMap { row in
            guard let date = row[key] as? String, let kwh = row["power"] as? Double else { return nil }
            let parsed = api.date(from: date)
            return EnergyBar(id: date, label: parsed.map(label.string) ?? date, kwh: kwh)
        }
    }
}

/// One AC's state, read from the status the AC publishes (all fields at once).
struct ACState: Equatable {
    var online = false
    var power = false
    var setTemp = 24.0
    var roomTemp: Double?
    var mode = "cool"
    var fan = "auto"
    var hSwing = 0
    var vSwing = 0
    var display = true
    var eco = false
    var powerful = false
    var clean = false
    var nanoe = false
    var converti = 0
    var profile = "none"
    var timers = [-1, -1]
    var filterDirty = false
    var rssi = 0

    mutating func apply(_ s: [String: Any]) {
        if let v = s["onlineStatus"] as? String { online = v == "true" }
        if let v = s["ps"] as? String { power = v == "on" }
        if let v = double(s["actmp"]) { setTemp = v }
        if let v = s["rmtmp"] as? String { roomTemp = Self.decodeRoomTemp(v, previous: roomTemp) ?? roomTemp }
        if let v = s["acmd"] as? String { mode = v }
        if let v = s["acfs"] as? String { fan = v }
        if let v = int(s["achs"]) { hSwing = v }
        if let v = int(s["acvs"]) { vSwing = v }
        if let v = s["acdc"] as? String { display = v == "on" }
        if let v = s["acem"] as? String { eco = v == "on" }
        if let v = s["acpm"] as? String { powerful = v == "on" }
        if let v = s["acec"] as? String { clean = v == "on" }
        if let v = (s["acngs"] ?? s["acng"]) as? String { nanoe = v == "on" }
        if let v = int(s["cnv"]) { converti = v }
        if let v = s["acsp"] as? String { profile = v }
        if let v = s["actm"] as? [Any] { timers = v.compactMap(int) }
        if let v = s["acfc"] as? String { filterDirty = v == "on" }
        if let v = int(s["rssi"]) { rssi = v }
    }

    /// `rmtmp` comes in two formats: a plain reading ("23.12") or
    /// "<fraction byte>.<whole degrees>" ("62.22" = 22.24°). Many strings fit
    /// both ("23.12": 23.12° or 12.09°), so readings outside 15-40° are dropped
    /// as impossible for a room; if both survive, the one closest to the last
    /// reading wins, else the plain one.
    static func decodeRoomTemp(_ value: String, previous: Double? = nil) -> Double? {
        var candidates: [Double] = []
        if let plain = Double(value) { candidates.append(plain) }
        let parts = value.split(separator: ".")
        if parts.count == 2, let byte = Double(parts[0]), let whole = Double(parts[1]),
           byte <= 255, whole > 0 {
            candidates.append(((whole + byte / 256) * 10).rounded() / 10)
        }
        let plausible = candidates.filter { (15...40).contains($0) }
        guard let first = plausible.first else { return nil }
        guard let previous else { return first }
        return plausible.min { abs($0 - previous) < abs($1 - previous) } ?? first
    }

    private func int(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let s = any as? String { return Int(s) }
        if let d = any as? Double { return Int(d) }
        return nil
    }

    private func double(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let s = any as? String { return Double(s) }
        if let i = any as? Int { return Double(i) }
        return nil
    }
}
