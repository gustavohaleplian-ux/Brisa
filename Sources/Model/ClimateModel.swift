import Foundation
import Combine
import os

/// An air conditioner found in the ThinQ account.
struct ACDevice: Identifiable {
    let id: String
    let name: String
}

/// A value the device accepts for a control, as it appears in its profile.
enum ControlValue: Equatable {
    case text(String)
    case number(Double)
    case flag(Bool)

    init?(_ raw: Any) {
        if let string = raw as? String {
            self = .text(string)
        } else if let number = raw as? NSNumber {
            self = CFGetTypeID(number) == CFBooleanGetTypeID()
                ? .flag(number.boolValue) : .number(number.doubleValue)
        } else {
            return nil
        }
    }

    var payload: Any {
        switch self {
        case .text(let value): return value
        case .number(let value): return value
        case .flag(let value): return value
        }
    }

    var identifier: String {
        switch self {
        case .text(let value): return "text:" + value
        case .number(let value): return "number:" + String(value)
        case .flag(let value): return "flag:" + String(value)
        }
    }

    var label: String {
        switch self {
        case .text(let value): return value
        case .number(let value): return value.formatted(.number.precision(.fractionLength(0...2)))
        case .flag(let value): return value ? "Sim" : "Não"
        }
    }
}

/// One selectable option of a control, tied to the exact profile property it writes.
struct DeviceChoice: Identifiable {
    let resource: String
    let key: String
    let value: ControlValue
    var id: String { key + ":" + value.identifier }
}

/// What the device profile says about one property: whether it can be written, and
/// which values or range it accepts.
struct Capability {
    var raw: [String: Any] = [:]
    var writable: Bool {
        if let modes = raw["mode"] as? [String] { return modes.contains("w") }
        return (raw["mode"] as? String)?.contains("w") == true
    }
    var values: Any? { (raw["value"] as? [String: Any])?["w"] }
    var options: [String] { writable ? (values as? [String] ?? []) : [] }
    var range: [String: Any] { values as? [String: Any] ?? [:] }
    var min: Double? { (range["min"] as? NSNumber)?.doubleValue }
    var max: Double? { (range["max"] as? NSNumber)?.doubleValue }
    var step: Double { (range["step"] as? NSNumber)?.doubleValue ?? 1 }
    var controlValues: [ControlValue] {
        guard writable else { return [] }
        if let list = values as? [Any] {
            return list.compactMap(ControlValue.init).reduce(into: []) {
                if !$0.contains($1) { $0.append($1) }
            }
        }
        if raw["type"] as? String == "boolean" {
            return [.flag(true), .flag(false)]
        }
        guard raw["type"] as? String == "range",
              let min, let max, min.isFinite, max.isFinite,
              step.isFinite, step > 0, max >= min else { return [] }
        let count = floor((max - min) / step)
        // A malformed profile must not allocate an unbounded list of controls.
        guard count.isFinite, count <= 1000 else { return [] }
        return (0...Int(count)).map { min + Double($0) * step }
            .filter(accepts).map(ControlValue.number)
    }

    func accepts(_ value: ControlValue) -> Bool {
        if case .number(let number) = value, ["range", "number"].contains(raw["type"] as? String) {
            return accepts(number)
        }
        return controlValues.contains(value)
    }

    func accepts(_ number: Double) -> Bool {
        // Some profiles declare a writable plain number without a range (e.g. sleep hours).
        if raw["type"] as? String == "number" { return writable && number.isFinite && number >= 0 }
        guard writable, let min, let max, step > 0, number >= min, number <= max else { return false }
        let units = (number - min) / step
        let excluded = (range["except"] as? [NSNumber] ?? []).map(\.doubleValue)
        return abs(units - units.rounded()) < 0.001 && !excluded.contains(number)
    }
}

/// The app's state and logic: the ThinQ connection, the device's profile and state,
/// commands (shown at once, then confirmed with the device), the temperature pipeline,
/// automatic refresh and the demonstration mode.
@MainActor
final class ClimateModel: ObservableObject {
    @Published var devices: [ACDevice] = []
    @Published var selectedID = UserDefaults.standard.string(forKey: "deviceID") ?? ""
    @Published var state: [String: Any] = [:] { didSet { onStatusChange?() } }
    @Published var profile: [String: Any] = [:]
    @Published var busy = false
    @Published var ready = false { didSet { onStatusChange?() } }
    @Published var demo = false { didSet { onStatusChange?() } }
    @Published var message = "Conecte sua conta LG ThinQ."
    @Published var error: String?
    @Published var lastUpdated: Date?
    /// Whether a ThinQ key is saved in the Keychain (its value is never kept here).
    @Published private(set) var hasStoredToken = TokenVault.read() != nil
    var onStatusChange: (() -> Void)?
    private var client: ThinQClient?
    private let clientID: String

    init() {
        let defaults = UserDefaults.standard
        // One stable client per install, as LG asks. Lowercase like the SDK's
        // str(uuid.uuid4()); an older uppercase ID keeps its value, only the case changes.
        clientID = (defaults.string(forKey: "clientID") ?? UUID().uuidString).lowercased()
        defaults.set(clientID, forKey: "clientID")
    }
    var name: String { demo ? "Escritório" : devices.first(where: { $0.id == selectedID })?.name ?? "Meu ar-condicionado" }
    /// Values just sent and not yet confirmed by the device, shown right away so the
    /// panel responds instantly. Each is dropped once the device confirms it, or
    /// reverted if it never does.
    @Published private var pending: [String: Any] = [:] { didSet { onStatusChange?() } }
    private var pendingToken: [String: UUID] = [:]
    /// The setpoint shown while an adjustment is in progress. The device's own last
    /// confirmed value is kept apart in `deviceTarget` and never overwritten by this.
    @Published private var pendingTarget: Double? { didSet { onStatusChange?() } }

    // MARK: Temperature adjustments
    enum TemperaturePhase: Equatable { case idle, adjusting, adjusted, failed }
    @Published private(set) var temperaturePhase: TemperaturePhase = .idle
    /// Wait after the last tap or drag before sending, so 23 → 19 sends only 19.
    static let temperatureDebounce: TimeInterval = 0.5
    /// Minimum spacing between temperature commands sent to LG. Tests showed LG only
    /// rejects overlapping commands (2208); sequential ones ~2 s apart all succeed, so
    /// this can be lowered if needed. Start conservative.
    static let temperatureSpacing: TimeInterval = 3
    /// The newest value still waiting to be sent. Only one slot: a newer request
    /// replaces it, so intermediate values are never queued.
    private var requestedTarget: Double?
    private var sendNotBefore = Date.distantPast
    private var lastTemperatureSent = Date.distantPast
    private var temperatureWorker: Task<Void, Never>?
    private var retriedTarget: Double?
    private var phaseReset: Task<Void, Never>?
    private let temperatureLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Brisa", category: "temperature")

    func value(_ resource: String, _ key: String) -> Any? {
        pending[resource + "." + key] ?? deviceValue(resource, key)
    }
    /// What the device last reported, ignoring anything still pending.
    private func deviceValue(_ resource: String, _ key: String) -> Any? {
        if resource == "temperatureInUnits" {
            return temperatureState[key]
        }
        return (state[resource] as? [String: Any])?[key]
    }
    var temperatureState: [String: Any] {
        if let list = state["temperatureInUnits"] as? [[String: Any]] {
            return list.first(where: { $0["unit"] as? String == "C" }) ?? [:]
        }
        let item = state["temperatureInUnits"] as? [String: Any] ?? [:]
        return item["unit"] as? String == "C" ? item : [:]
    }
    /// Values LG rejected with "not provided feature", keyed by device ID. The error
    /// is value-specific (e.g. a sleep timer of 8 h fails while 1–7 h work), so only
    /// that value is withheld, never the whole property.
    @Published private var rejected: [String: [String]] =
        UserDefaults.standard.dictionary(forKey: "rejectedValues") as? [String: [String]] ?? [:]
    private func rejectionKey(_ resource: String, _ key: String, _ value: Any) -> String? {
        ControlValue(value).map { resource + "." + key + "=" + $0.identifier }
    }
    /// Only properties without declared limits (a plain "number", like sleep hours)
    /// learn rejected values. Where the profile declares the valid values or range
    /// (temperature, mode, fan, direction), a 2201 is a momentary refusal: the value
    /// stays available, so one bad response can never lock a control.
    private func learnsRejections(_ resource: String, _ key: String) -> Bool {
        let cap = capability(resource, key)
        return cap.raw["type"] as? String == "number" && cap.min == nil && cap.max == nil
    }
    func isRejected(_ resource: String, _ key: String, _ value: Any) -> Bool {
        guard !demo, learnsRejections(resource, key),
              let entry = rejectionKey(resource, key, value) else { return false }
        return rejected[selectedID]?.contains(entry) == true
    }
    private func markRejected(_ resource: String, _ key: String, _ value: Any) {
        guard !demo, !selectedID.isEmpty, learnsRejections(resource, key),
              let entry = rejectionKey(resource, key, value) else { return }
        var list = rejected[selectedID] ?? []
        if !list.contains(entry) { list.append(entry) }
        rejected[selectedID] = list
        UserDefaults.standard.set(rejected, forKey: "rejectedValues")
    }
    func capability(_ resource: String, _ key: String) -> Capability {
        let properties = profile["property"] as? [String: Any] ?? [:]
        if let list = properties[resource] as? [[String: Any]] {
            let resourceValue = list.first(where: { $0["unit"] as? String == "C" }) ?? [:]
            return Capability(raw: resourceValue[key] as? [String: Any] ?? [:])
        }
        return Capability(raw: (properties[resource] as? [String: Any])?[key] as? [String: Any] ?? [:])
    }
    var target: Double? { pendingTarget ?? deviceTarget }
    private var deviceTarget: Double? { (temperatureState["targetTemperature"] as? NSNumber)?.doubleValue }
    var room: Double? { (temperatureState["currentTemperature"] as? NSNumber)?.doubleValue }
    var power: String? { value("operation", "airConOperationMode") as? String }
    var isOn: Bool { power == "POWER_ON" }
    /// Where this unit accepts a new setpoint. Profiles differ: some expose a writable
    /// temperatureInUnits target, others only the `temperature` resource or a
    /// mode-specific cool/heat target. The current value is always read from
    /// temperatureInUnits (°C).
    private var temperatureTarget: (resource: String, key: String, capability: Capability)? {
        var candidates = [("temperatureInUnits", "targetTemperature"), ("temperature", "targetTemperature")]
        switch value("airConJobMode", "currentJobMode") as? String {
        case "COOL": candidates.append(("temperatureInUnits", "coolTargetTemperature"))
        case "HEAT": candidates.append(("temperatureInUnits", "heatTargetTemperature"))
        default: break
        }
        for (resource, key) in candidates {
            let cap = capability(resource, key)
            if cap.writable, cap.min != nil, cap.max != nil { return (resource, key, cap) }
        }
        return nil
    }
    /// The setpoint range in whole degrees only, even when the unit accepts half steps.
    var tempCapability: Capability {
        guard var cap = temperatureTarget?.capability, let min = cap.min, let max = cap.max else { return Capability() }
        cap.raw["value"] = ["w": ["min": min.rounded(.up), "max": max.rounded(.down),
                                  "step": Swift.max(1, cap.step.rounded(.up))]]
        return cap
    }
    var canTemperature: Bool {
        // Not blocked while another command is in flight: taps queue up and are sent
        // together once the previous request finishes.
        ready && isOn && target != nil && tempCapability.writable &&
        (tempCapability.min ?? 1) < (tempCapability.max ?? 0) && tempCapability.step > 0
    }
    var menuTemperature: String {
        // Off: the room temperature. On (or unknown): the selected setpoint.
        guard ready, let shown = power == "POWER_OFF" ? room : target else { return "— °C" }
        return shown.rounded().formatted(.number.precision(.fractionLength(0))) + " °C"
    }

    // Keep each option attached to its original property; never send a detail
    // value to windStrength or infer a sixth speed from the physical remote.
    var fanChoices: [DeviceChoice] {
        // windStrengthDetail already covers every speed (Natural plus five levels),
        // so the overlapping windStrength and windStep lists are only a fallback.
        let detail = choices("airFlow", keys: ["windStrengthDetail"])
        return detail.isEmpty ? choices("airFlow", keys: ["windStrength", "windStep"]) : detail
    }

    var verticalChoices: [DeviceChoice] {
        // stepUpDown is offered only if the device profile explicitly exposes it.
        // No horizontal properties or inferred vane angles are sent.
        choices("windDirection", keys: ["rotateUpDown", "stepUpDown"])
    }

    var hasVerticalPositions: Bool {
        verticalChoices.contains { $0.key == "stepUpDown" }
    }

    var verticalExplanation: String {
        if hasVerticalPositions {
            return "Posições conforme o perfil do aparelho. Os códigos não indicam um ângulo conhecido; parar a oscilação não significa apontar para cima."
        }
        return "Este perfil não oferece posições verticais selecionáveis. Parar a oscilação mantém a posição atual; não posiciona para cima."
    }

    private func choices(_ resource: String, keys: [String]) -> [DeviceChoice] {
        keys.flatMap { key in
            capability(resource, key).controlValues
                .filter { !isRejected(resource, key, $0.payload) }
                .map { DeviceChoice(resource: resource, key: key, value: $0) }
        }
    }

    func isSelected(_ choice: DeviceChoice) -> Bool {
        guard let current = value(choice.resource, choice.key),
              let decoded = ControlValue(current) else { return false }
        return decoded == choice.value
    }

    var fanAnimationValue: String {
        value("airFlow", "windStrengthDetail") as? String ??
        value("airFlow", "windStrength") as? String ?? ""
    }
    func connect(token: String) async {
        guard !busy else { return }
        busy = true; ready = false; demo = false; error = nil
        defer { busy = false }
        do {
            let cleaned = ThinQClient.normalizedToken(token)
            guard !cleaned.isEmpty else { throw BrisaError(message: "Insira sua chave de acesso ThinQ.") }
            let newClient = ThinQClient(token: cleaned, clientID: clientID)
            let response = try await newClient.request("devices")
            guard let list = response as? [[String: Any]] else {
                throw BrisaError(message: "A lista de aparelhos veio em formato não reconhecido.")
            }
            let found: [ACDevice] = list.compactMap { item in
                let info = item["deviceInfo"] as? [String: Any] ?? item
                guard info["deviceType"] as? String == "DEVICE_AIR_CONDITIONER",
                      let id = item["deviceId"] as? String,
                      !id.isEmpty else { return nil }
                return ACDevice(id: id, name: info["alias"] as? String ?? "Ar-condicionado LG")
            }
            guard !found.isEmpty else {
                throw BrisaError(message: "Nenhum ar disponível pela API. Confira a conta e as permissões da chave. Estar no ThinQ não garante suporte pela API.")
            }
            try TokenVault.save(cleaned)
            hasStoredToken = true
            client = newClient; devices = found
            if !found.contains(where: { $0.id == selectedID }) { selectedID = found[0].id }
            try await loadSelected()
        } catch { self.error = error.localizedDescription; message = "Conexão não concluída." }
    }
    func reconnect() async {
        guard client == nil, !demo, let token = TokenVault.read() else { return }
        await connect(token: token)
    }
    private var path: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return "devices/" + (selectedID.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
    }
    private func loadSelected() async throws {
        guard let client else { return }
        // A pending adjustment belongs to the previous device; drop it.
        requestedTarget = nil; pendingTarget = nil; temperaturePhase = .idle
        state = [:]; profile = [:]; ready = false; lastUpdated = nil
        guard let p = try await client.request(path + "/profile") as? [String: Any] else {
            throw BrisaError(message: "Perfil do aparelho não reconhecido.")
        }
        profile = p
        try await readState()
        UserDefaults.standard.set(selectedID, forKey: "deviceID")
    }
    private func readState() async throws {
        guard let client else { return }
        guard let s = try await client.request(path + "/state") as? [String: Any],
              s["operation"] != nil || s["temperatureInUnits"] != nil else {
            throw BrisaError(message: "Não foi possível ler o estado do ar. Confira o ThinQ.")
        }
        state = s; ready = true; lastUpdated = Date(); message = ""
    }
    // MARK: Automatic refresh
    /// How often the state is read in the background. Room temperature changes
    /// slowly, but the same read also catches the unit being switched on, off or
    /// adjusted by its remote, so 5 minutes keeps the menu bar honest at ~12 reads/h.
    static let autoRefreshInterval: TimeInterval = 5 * 60
    private var autoRefreshTask: Task<Void, Never>?

    /// Starts the background refresh loop once; it lives as long as the app.
    func startAutoRefresh() {
        guard autoRefreshTask == nil else { return }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.autoRefreshInterval * 1_000_000_000))
                await self?.refreshQuietly()
            }
        }
    }

    /// A background read that never shows a spinner, locks controls or replaces good
    /// data with an error: if it fails, the last known state stays on screen.
    /// `ifOlderThan` skips the read when the data is already fresh.
    func refreshQuietly(ifOlderThan age: TimeInterval = 0) async {
        guard !busy, !demo, client != nil, temperatureWorker == nil else { return }
        if let lastUpdated, Date().timeIntervalSince(lastUpdated) < age { return }
        try? await readState()
    }

    func refresh() async {
        guard !busy, !demo, client != nil else { return }
        busy = true; error = nil
        defer { busy = false }
        do { try await readState() }
        catch { ready = false; self.error = error.localizedDescription; message = "Dados desatualizados" }
    }
    /// Shows the chosen setpoint at once and schedules it. Every tap or drag only
    /// replaces the single requested value; one worker sends it when allowed.
    func setTemperature(_ value: Double) {
        let celsius = value.rounded()
        guard temperatureTarget != nil, tempCapability.accepts(celsius) else { return }
        pendingTarget = celsius
        requestedTarget = celsius
        retriedTarget = nil
        sendNotBefore = Date().addingTimeInterval(Self.temperatureDebounce)
        setPhase(.adjusting)
        if temperatureWorker == nil {
            temperatureWorker = Task { [weak self] in await self?.runTemperatureWorker() }
        }
    }

    /// Sends requested setpoints one at a time. It is never cancelled, so a request
    /// that already left is always allowed to finish, and two temperature commands
    /// are never in flight together (LG fails overlapping ones with 2208).
    private func runTemperatureWorker() async {
        defer { temperatureWorker = nil }
        while let desired = requestedTarget {
            // Wait for the debounce, the spacing since the last command, and any other
            // control's command, re-checking each time since a new tap may move them.
            let earliest = max(sendNotBefore, lastTemperatureSent.addingTimeInterval(Self.temperatureSpacing))
            let wait = earliest.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)); continue }
            if busy { try? await Task.sleep(nanoseconds: 100_000_000); continue }
            requestedTarget = nil
            if desired == deviceTarget { finishTemperature(desired, applied: true); continue }
            await performTemperature(desired)
        }
    }

    private func performTemperature(_ celsius: Double) async {
        guard let target = temperatureTarget, let client, !demo else {
            if demo {
                var t = temperatureState; t["targetTemperature"] = celsius; state["temperatureInUnits"] = [t]
                DemoSounds.play(.adjust)
                finishTemperature(celsius, applied: true)
            } else {
                finishTemperature(celsius, applied: false)
            }
            return
        }
        busy = true
        lastTemperatureSent = Date()
        var failure: BrisaError?
        do {
            _ = try await client.request(path + "/control",
                                         body: [target.resource: [target.key: celsius, "unit": "C"]])
        } catch let error as BrisaError {
            failure = error
        } catch {
            failure = BrisaError(message: error.localizedDescription)
        }
        busy = false

        if let failure {
            temperatureLog.error("Ajuste para \(celsius, privacy: .public) °C recusado: \(failure.message, privacy: .public)")
            // Never trust the error alone: the device may have applied it anyway.
            try? await readState()
            if deviceTarget == celsius { finishTemperature(celsius, applied: true); return }
            // A newer request supersedes this one; it will be sent next.
            if requestedTarget != nil { return }
            // Momentary refusals get exactly one more try, after the normal spacing.
            if isMomentary(failure), retriedTarget != celsius {
                retriedTarget = celsius
                requestedTarget = celsius
                return
            }
            finishTemperature(celsius, applied: false)
            return
        }

        // Accepted. If the person already chose a newer value, skip confirming this one.
        if requestedTarget != nil { return }
        for delay in [0.5, 1.0, 1.5, 2.5] {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if requestedTarget != nil { return }
            try? await readState()
            if deviceTarget == celsius { finishTemperature(celsius, applied: true); return }
        }
        temperatureLog.notice("Ajuste para \(celsius, privacy: .public) °C aceito, mas não confirmado pelo aparelho")
        finishTemperature(celsius, applied: false)
    }

    /// Transient refusals: LG's "not provided" seen once and not reproducible,
    /// overlapping-command and device-delay errors, and network failures.
    private func isMomentary(_ failure: BrisaError) -> Bool {
        guard let code = failure.code else { return true }
        return ["2201", "2208", "2209", "2210", "2212", "2214", "2000"].contains(code)
    }

    private func finishTemperature(_ celsius: Double, applied: Bool) {
        // Only settle if nothing newer was requested in the meantime.
        guard requestedTarget == nil else { return }
        retriedTarget = nil
        pendingTarget = nil
        if !applied { temperatureLog.notice("Ajuste para \(celsius, privacy: .public) °C não aplicado") }
        setPhase(applied ? .adjusted : .failed)
    }

    private func setPhase(_ phase: TemperaturePhase) {
        temperaturePhase = phase
        phaseReset?.cancel()
        // "Temperatura ajustada" fades out by itself; a failure stays a little longer.
        guard phase == .adjusted || phase == .failed else { return }
        phaseReset = Task { [weak self] in
            try? await Task.sleep(nanoseconds: phase == .adjusted ? 2_500_000_000 : 6_000_000_000)
            guard !Task.isCancelled, self?.temperaturePhase == phase else { return }
            self?.temperaturePhase = .idle
        }
    }
    func setSleepTimer(hours: Int) async {
        if hours == 0, capability("sleepTimer", "relativeStopTimer").options.contains("UNSET") {
            await send("sleepTimer", "relativeStopTimer", "UNSET")
        } else {
            // Same pair the official SDK sends for the sleep timer.
            await send("sleepTimer", "relativeHourToStop", hours, extra: ["relativeMinuteToStop": 0],
                       shows: ["sleepTimer.relativeStopTimer": "SET"])
        }
    }
    /// Sends one control command (everything except temperature, which has its own
    /// pipeline above). The new value shows at once and is confirmed in the background.
    /// `extra` adds companion fields to the same resource (e.g. unit or minutes).
    /// `shows` adds related values to display while pending (e.g. a timer as SET).
    func send(_ resource: String, _ key: String, _ newValue: Any,
              extra: [String: Any] = [:], shows: [String: Any] = [:]) async {
        // Commands go out one at a time: a new one waits (up to 6 s) for the
        // request before it instead of being dropped.
        var waited = 0
        while busy && waited < 60 { try? await Task.sleep(nanoseconds: 100_000_000); waited += 1 }
        let cap = capability(resource, key)
        guard ready, !busy, cap.writable, let command = ControlValue(newValue), cap.accepts(command),
              !isRejected(resource, key, newValue) else { return }
        var fields: [String: Any] = extra
        fields[key] = newValue
        if demo {
            // Apply the whole command as a unit would: the value, its companion fields
            // (e.g. minutes) and the related state it implies (e.g. a timer as SET).
            if resource == "temperatureInUnits" {
                var t = temperatureState; t[key] = newValue; state[resource] = [t]
            } else {
                var r = state[resource] as? [String: Any] ?? [:]
                for (field, value) in fields { r[field] = value }
                state[resource] = r
            }
            for (entry, value) in shows {
                let parts = entry.split(separator: ".", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                var r = state[parts[0]] as? [String: Any] ?? [:]; r[parts[1]] = value; state[parts[0]] = r
            }
            // The unit's beep: its own tune for on and off, a short beep for anything else.
            if resource == "operation", key == "airConOperationMode" {
                DemoSounds.play(newValue as? String == "POWER_OFF" ? .powerOff : .powerOn)
            } else {
                DemoSounds.play(.adjust)
            }
            message = "Demonstração · nenhum comando enviado"
            return
        }
        guard let client else { return }

        // Show the new value immediately; it is only a display until confirmed.
        let slot = resource + "." + key
        let token = UUID()
        var shown = shows
        shown[slot] = newValue
        for (entry, value) in shown { pending[entry] = value; pendingToken[entry] = token }
        let clear = { [weak self] in
            guard let self else { return }
            for entry in shown.keys where self.pendingToken[entry] == token {
                self.pending[entry] = nil; self.pendingToken[entry] = nil
            }
        }

        busy = true; error = nil; message = ""
        do {
            do {
                _ = try await client.request(path + "/control", body: [resource: fields])
            } catch let failure as BrisaError where failure.isUnsupported && !learnsRejections(resource, key) {
                // LG occasionally refuses a declared, valid value with 2201 for a moment;
                // the same command is accepted right after, so retry once before failing.
                try await Task.sleep(nanoseconds: 800_000_000)
                _ = try await client.request(path + "/control", body: [resource: fields])
            }
        } catch let failure as BrisaError where failure.code != nil {
            // A rejected command affects only this control: revert it, keep the panel
            // usable and re-read the real state so the other controls stay current.
            busy = false; clear()
            if failure.isUnsupported && !learnsRejections(resource, key) {
                // The profile declares this value as valid, so it is not a missing feature.
                self.error = "A LG recusou o comando no momento. Tente novamente em instantes."
                    + " (código \(failure.code ?? "?"))"
            } else {
                if failure.isUnsupported { markRejected(resource, key, newValue) }
                self.error = failure.message
            }
            try? await readState()
            return
        } catch is CancellationError {
            busy = false; clear(); return
        } catch let failure as URLError where failure.code == .cancelled {
            busy = false; clear(); return
        } catch {
            // A failed command only affects this control. The panel stays usable and
            // the real state is re-read, so nothing else is locked waiting for it.
            busy = false; clear()
            self.error = "O comando não chegou ao aparelho. Tente novamente. (\(error.localizedDescription))"
            try? await readState()
            return
        }
        busy = false

        // Confirm in the background, checking early and then backing off. An accepted
        // request is never treated as the device's state until a read confirms it.
        let matches: () -> Bool = { [weak self] in
            guard let current = self?.deviceValue(resource, key) as? NSObject,
                  let expected = newValue as? NSObject else { return false }
            return current.isEqual(expected)
        }
        Task { [weak self] in
            for delay in [0.4, 0.8, 1.2, 2.0] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self else { return }
                // A newer command for the same control takes over the confirmation.
                if self.pendingToken[slot] != token { return }
                try? await self.readState()
                if matches() { clear(); return }
            }
            clear()
            self?.message = "Enviado; o aparelho ainda não confirmou. Atualize em instantes."
        }
    }
    func disconnect() {
        guard !busy else { return }
        do { try TokenVault.delete() } catch { self.error = error.localizedDescription; return }
        hasStoredToken = false
        requestedTarget = nil; pendingTarget = nil; temperaturePhase = .idle
        client = nil; ready = false; demo = false; devices = []; state = [:]; profile = [:]
        selectedID = ""; lastUpdated = nil; error = nil
        UserDefaults.standard.removeObject(forKey: "deviceID")
        message = "Conecte sua conta LG ThinQ."
    }
    /// A demonstration with the same profile shape a real LG unit returns (modelled on
    /// an actual ThinQ air conditioner), so every menu offers exactly the options a
    /// connected unit would. Nothing is sent to LG.
    func startDemo() {
        guard !busy else { return }
        demo = true; ready = true; error = nil
        let rw = ["r", "w"]
        func enumeration(_ values: [String], mode: [String] = ["r", "w"]) -> [String: Any] {
            ["type": "enum", "mode": mode, "value": ["w": values]]
        }
        func range(_ min: Double, _ max: Double, _ step: Double) -> [String: Any] {
            ["type": "range", "mode": rw, "value": ["w": ["min": min, "max": max, "step": step]]]
        }
        let readOnly: [String: Any] = ["type": "number", "mode": ["r"]]
        profile = ["property": [
            "operation": ["airConOperationMode": enumeration(["POWER_ON", "POWER_OFF"])],
            "airConJobMode": ["currentJobMode": enumeration(["COOL", "FAN", "AIR_DRY"])],
            // As on real units: the °C entry is read-only and the setpoint is written
            // through the `temperature` resource.
            "temperatureInUnits": [["unit": "C", "currentTemperature": readOnly, "targetTemperature": readOnly]],
            "temperature": ["targetTemperature": range(18, 30, 0.5)],
            "airFlow": [
                "windStrength": enumeration(["LOW", "MID", "HIGH", "AUTO"]),
                "windStrengthDetail": enumeration(["NATURE", "LOW", "LOW_MID", "MID", "MID_HIGH", "HIGH"]),
                "windStep": range(1, 5, 1)
            ],
            "windDirection": ["rotateUpDown": ["type": "boolean", "mode": rw]],
            // Eco is offered in the demo so the whole panel can be tried, even though
            // some real units don't expose it through the API.
            "powerSave": ["powerSaveEnabled": ["type": "boolean", "mode": rw]],
            "sleepTimer": [
                "relativeHourToStop": ["type": "number", "mode": rw],
                "relativeMinuteToStop": ["type": "number", "mode": rw],
                "relativeStopTimer": enumeration(["UNSET"])
            ]
        ]]
        // Starts switched off, as a real unit usually is, so the demo begins by turning it on.
        state = ["operation": ["airConOperationMode": "POWER_OFF"],
                 "airConJobMode": ["currentJobMode": "COOL"],
                 // A warm room, so the demo starts with a reason to cool it down.
                 "temperatureInUnits": [["unit": "C", "currentTemperature": 28, "targetTemperature": 24]],
                 "temperature": ["unit": "C", "currentTemperature": 28, "targetTemperature": 24],
                 "powerSave": ["powerSaveEnabled": false],
                 "airFlow": ["windStrength": "MID", "windStrengthDetail": "LOW_MID", "windStep": 2],
                 "windDirection": ["rotateUpDown": true],
                 "sleepTimer": ["relativeStopTimer": "UNSET"]]
        message = "Demonstração · nenhum comando enviado"
    }
}
