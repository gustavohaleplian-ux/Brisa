import SwiftUI
import AppKit

/// The panel opened from the menu bar: the dashboard with the unit and its controls,
/// or the settings for connecting the ThinQ account.
@MainActor
struct ClimatePanel: View {
    @ObservedObject var model: ClimateModel
    @State private var settings = false
    @State private var token = ""
    @State private var confirmRemoval = false
    @State private var draftTemperature = 21.0
    @State private var dragging = false
    @State private var ecoPulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let muted = Color.white.opacity(0.62)

    private var ecoSelected: Bool { model.value("powerSave", "powerSaveEnabled") as? Bool == true }
    private var ecoActive: Bool { ecoSelected && model.isOn && model.ready }
    private var ecoSupported: Bool { model.capability("powerSave", "powerSaveEnabled").writable }
    private var powerDisabled: Bool {
        model.busy || !model.ready || model.power == nil ||
            !model.capability("operation", "airConOperationMode").options.contains(model.isOn ? "POWER_OFF" : "POWER_ON")
    }

    var body: some View {
        VStack(spacing: 0) {
            if settings || (!model.ready && model.profile.isEmpty) { setup }
            else { dashboard }
        }
        .padding(24)
        .frame(width: 420)
        .background {
            RadialGradient(colors: [Color.green.opacity(ecoActive ? 0.14 : 0), .clear],
                           center: .topTrailing, startRadius: 5, endRadius: 360)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: ecoActive)
        .tint(.white)
        .task { await model.reconnect(); syncDraft() }
        .task(id: ecoActive) {
            guard ecoActive, !reduceMotion else { ecoPulse = false; return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { ecoPulse = true }
            do { try await Task.sleep(nanoseconds: 650_000_000) } catch { return }
            withAnimation(.easeOut(duration: 0.3)) { ecoPulse = false }
        }
        .onChange(of: model.target) { if !dragging { syncDraft() } }
    }
    private func syncDraft() {
        let lower = model.tempCapability.min ?? 18
        let upper = max(model.tempCapability.max ?? 30, lower + 1)
        draftTemperature = min(upper, max(lower, (model.target ?? 21).rounded()))
    }
    private func degrees(_ value: Double?) -> String {
        guard let value else { return "—" }
        // Whole degrees everywhere, like the remote control.
        return value.rounded().formatted(.number.precision(.fractionLength(0)))
    }
    private func translated(_ value: String?) -> String {
        guard let value else { return "Indisponível" }
        let labels: [String: String] = ["COOL": "Resfriar", "HEAT": "Aquecer", "DRY": "Desumidificar", "AIR_DRY": "Desumidificar",
                      "FAN": "Ventilar", "AUTO": "Auto", "AI": "Inteligente",
                      "LOW": "Baixa", "MID": "Média", "HIGH": "Alta", "SLOW": "Suave",
                      "POWER": "Turbo", "NATURE": "Natural"]
        return labels[value] ?? value.capitalized.replacingOccurrences(of: "_", with: " ")
    }
    private var dashboard: some View {
        VStack(spacing: 18) {
            HStack {
                Image(systemName: "thermometer.medium").foregroundStyle(muted)
                Text("Ambiente").foregroundStyle(muted)
                Text("\(degrees(model.room))°C").fontWeight(.semibold)
                Spacer()
                Button {
                    Task { await model.send("operation", "airConOperationMode", model.isOn ? "POWER_OFF" : "POWER_ON") }
                } label: {
                    Image(systemName: "power").font(.system(size: 20, weight: .medium))
                        .foregroundStyle(model.isOn ? Color.white : muted)
                        .frame(width: 38, height: 38)
                        .modifier(ControlSurface(accent: model.isOn ? .white : .clear,
                                                 interactive: !powerDisabled, cornerRadius: 19))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(powerDisabled)
                .help(model.isOn ? "Desligar o ar" : "Ligar o ar")
                .accessibilityLabel(model.isOn ? "Desligar ar-condicionado" : "Ligar ar-condicionado")
            }.font(.system(size: 12))

            AirIllustration(
                isOn: model.isOn && model.ready,
                mode: model.value("airConJobMode", "currentJobMode") as? String ?? "COOL",
                fan: model.fanAnimationValue,
                oscillating: model.value("windDirection", "rotateUpDown") as? Bool ?? false,
                eco: ecoActive
            ).frame(height: 140)
                .accessibilityHidden(true)

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name).font(.system(size: 11)).foregroundStyle(muted).lineLimit(1)
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(degrees(dragging ? draftTemperature : model.target))
                            .font(.system(size: 52, weight: .medium, design: .default)).monospacedDigit()
                        Text("°C").font(.system(size: 23)).foregroundStyle(muted)
                    }
                }
                Spacer(minLength: 10)
                ecoControl.padding(.bottom, 8)

            }

            VStack(spacing: 4) {
                HStack(spacing: 12) {
                    temperatureButton("minus", delta: -model.tempCapability.step)
                    TemperatureTrack(value: $draftTemperature,
                           bounds: (model.tempCapability.min ?? 18)...max(model.tempCapability.max ?? 30, (model.tempCapability.min ?? 18) + 1),
                           step: max(model.tempCapability.step, 0.5),
                           onEditingChanged: { editing in
                        dragging = editing
                        if !editing { model.setTemperature(draftTemperature); syncDraft() }
                    })
                    .disabled(!model.canTemperature)
                    .accessibilityLabel("Temperatura desejada")
                    temperatureButton("plus", delta: model.tempCapability.step)
                }
                // The range labels give way to a quiet status while adjusting, in the
                // same row so the layout never jumps.
                ZStack {
                    HStack {
                        Text("❄ \(degrees(model.tempCapability.min))°").foregroundStyle(Color.cyan.opacity(0.75))
                        Spacer()
                        Text("\(degrees(model.tempCapability.max))° ☀").foregroundStyle(Color.orange.opacity(0.8))
                    }
                    .opacity(model.temperaturePhase == .idle ? 1 : 0)
                    temperatureStatus
                        .opacity(model.temperaturePhase == .idle ? 0 : 1)
                }
                .font(.system(size: 9)).foregroundStyle(muted).padding(.horizontal, 46)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.temperaturePhase)
            }

            HStack(spacing: 7) {
                enumCard("Modo", icon: modeIcon, resource: "airConJobMode", key: "currentJobMode")
                fanCard
                sleepCard
                directionCard
            }

            if model.error != nil || !model.message.isEmpty {
                status
            }
            HStack(spacing: 8) {
                if model.busy { ProgressView().controlSize(.mini) }
                else { Circle().fill(model.demo ? Color.orange : (model.ready ? Color.green : Color.gray)).frame(width: 5, height: 5) }
                Text((model.demo ? "Demo · " : "") + (model.isOn ? "Ligado" : model.power == "POWER_OFF" ? "Desligado" : "Sem estado"))
                    .font(.system(size: 10)).foregroundStyle(muted)
                if let date = model.lastUpdated, !model.demo {
                    Text(date, style: .time).font(.system(size: 10)).foregroundStyle(muted)
                }
                Spacer()
                Button { Task { await model.refresh(); syncDraft() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.busy || model.demo).help("Atualizar estado")
                Button { settings = true } label: { Image(systemName: "slider.horizontal.3") }.help("Configurações")
            }.buttonStyle(.plain).foregroundStyle(muted)
        }
    }
    /// Subtle adjustment feedback. It never blocks the controls, and failures use plain
    /// language; LG's codes stay in the diagnostics log only.
    @ViewBuilder private var temperatureStatus: some View {
        switch model.temperaturePhase {
        case .idle:
            Text(" ")
        case .adjusting:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini).scaleEffect(0.7)
                Text("Ajustando…")
            }
        case .adjusted:
            Label("Temperatura ajustada", systemImage: "checkmark")
                .foregroundStyle(Color.white.opacity(0.75))
        case .failed:
            Text("Não foi possível ajustar a temperatura. Tente novamente.")
                .foregroundStyle(Color.orange.opacity(0.85))
                .lineLimit(1).minimumScaleFactor(0.8)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
    private func temperatureButton(_ icon: String, delta: Double) -> some View {
        // Step to the next whole degree, so a half-degree setpoint (e.g. 21,5) becomes 22 or 21.
        let current = model.target ?? 21
        let next = delta > 0 ? current.rounded(.down) + delta : current.rounded(.up) + delta
        let enabled = model.canTemperature && model.tempCapability.accepts(next)
        return Button {
            // Shown at once; rapid taps are merged and only the last value is sent.
            model.setTemperature(next); syncDraft()
        } label: {
            Image(systemName: icon).font(.system(size: 15, weight: .medium))
                .frame(width: 32, height: 32)
                .modifier(ControlSurface(accent: .clear, interactive: enabled, cornerRadius: 16))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(delta > 0 ? "Aumentar temperatura" : "Diminuir temperatura")
    }
    private var modeIcon: String {
        switch model.value("airConJobMode", "currentJobMode") as? String {
        case "HEAT": return "sun.max"
        case "DRY", "AIR_DRY": return "drop"
        case "FAN": return "fan"
        case "AUTO", "AI": return "sparkles"
        default: return "snowflake"
        }
    }
    /// The small status line under a card's value: missing feature vs. missing data.
    private func cardStatus(available: Bool, known: Bool) -> String {
        if !available { return "Indisponível" }
        if !known || !model.ready { return "Sem dados" }
        return ""
    }
    private func enumCard(_ title: String, icon: String, resource: String, key: String) -> some View {
        let current = model.value(resource, key) as? String
        let options = model.capability(resource, key).options
        let available = !options.isEmpty
        return ControlCard(title: title, value: current.map { translated($0) } ?? "—", icon: icon,
                           status: cardStatus(available: available, known: current != nil),
                           active: model.ready && model.isOn && current != nil && available,
                           enabled: model.ready && model.isOn && !model.busy && available,
                           options: options.map { CardOption(id: $0, label: translated($0)) }, selected: current) { option in
            Task { await model.send(resource, key, option) }
        }
    }
    private var sleepCard: some View {
        // An unset timer reports only relativeStopTimer: UNSET, without hours.
        let stopTimer = model.value("sleepTimer", "relativeStopTimer") as? String
        let hours = stopTimer == "UNSET" ? 0 : (model.value("sleepTimer", "relativeHourToStop") as? NSNumber)?.intValue
        let cap = model.capability("sleepTimer", "relativeHourToStop")
        // With a declared range, the profile decides. A plain number has no range, and
        // LG accepts 1–7 h there (8 h or more returns 2201), the same as the remote.
        let maxHours = cap.max.map { Int($0) } ?? 7
        var options = (1...max(1, min(12, maxHours))).filter {
            cap.accepts(Double($0)) && !model.isRejected("sleepTimer", "relativeHourToStop", Double($0))
        }.map {
            CardOption(id: String($0), label: "Desligar em \($0) h")
        }
        // Cancelling is a separate command: offer it whenever setting hours works, or
        // when a timer set elsewhere (remote, ThinQ) is running and UNSET is accepted.
        let canCancel = model.capability("sleepTimer", "relativeStopTimer").options.contains("UNSET") || cap.accepts(0)
        if canCancel && (!options.isEmpty || stopTimer == "SET") {
            options.insert(CardOption(id: "0", label: "Desativar temporizador"), at: 0)
        }
        // "Desligado" only when the device reports it; SET without hours is still a confirmed timer.
        let display = hours.map { $0 == 0 ? "Desligado" : "\($0) h" } ?? (stopTimer == "SET" ? "Ativo" : "—")
        return ControlCard(title: "Sono", value: display, icon: "moon",
                           status: cardStatus(available: !options.isEmpty, known: hours != nil || stopTimer != nil),
                           active: model.ready && model.isOn && (hours ?? 0) > 0,
                           enabled: model.ready && model.isOn && !model.busy && !options.isEmpty,
                           options: options, selected: hours.map { String($0) }) { option in
            if let hour = Int(option) { Task { await model.setSleepTimer(hours: hour) } }
        }
    }
    private func fanLabel(_ choice: DeviceChoice) -> String {
        let known: [String: String] = ["LOW": "Baixa", "MID": "Média", "HIGH": "Alta", "AUTO": "Automática"]
        // Detailed speeds map one-to-one onto the remote: Natural, then levels 1 to 5.
        let detail: [String: String] = ["NATURE": "Natural", "LOW": "1", "LOW_MID": "2",
                                        "MID": "3", "MID_HIGH": "4", "HIGH": "5"]
        if case .text(let raw) = choice.value, choice.key == "windStrengthDetail", let label = detail[raw] {
            return label
        }
        if case .text(let raw) = choice.value {
            // Keep unrecognized API codes verbatim.
            return known[raw] ?? raw
        }
        return choice.value.label
    }

    private var fanCard: some View {
        let choices = model.fanChoices
        let current = choices.filter { model.isSelected($0) }
        let labels = current.map(fanLabel).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        let groups: [String: String] = ["windStrengthDetail": "Velocidades detalhadas",
                      "windStrength": "Velocidades e modos", "windStep": "Níveis"]
        let singleGroup = Set(choices.map(\.key)).count == 1
        let options = choices.enumerated().map { index, choice in
            CardOption(id: choice.id, label: fanLabel(choice),
                       groupTitle: !singleGroup && (index == 0 || choices[index - 1].key != choice.key) ? groups[choice.key] : nil)
        }
        return ControlCard(title: "Ventilação", value: labels.isEmpty ? "—" : labels.joined(separator: " / "),
                           icon: "fan",
                           status: cardStatus(available: !choices.isEmpty, known: !current.isEmpty),
                           active: model.ready && model.isOn && !current.isEmpty,
                           enabled: model.ready && model.isOn && !model.busy && !choices.isEmpty,
                           options: options, selected: nil,
                           selectedIDs: Set(current.map(\.id)),
                           explanation: singleGroup ? nil : "Opções informadas pelo aparelho. Códigos sem tradução são mantidos como recebidos, sem presumir vento automático ou variável.") { id in
            guard let choice = choices.first(where: { $0.id == id }) else { return }
            Task { await model.send(choice.resource, choice.key, choice.value.payload) }
        }
    }

    private func directionLabel(_ choice: DeviceChoice) -> String {
        if choice.key == "rotateUpDown" {
            if case .flag(let oscillating) = choice.value {
                return oscillating ? "Oscilar" : "Parar oscilação"
            }
            return "Oscilação: " + choice.value.label
        }
        return "Posição " + choice.value.label
    }

    private var directionCard: some View {
        let choices = model.verticalChoices
        let oscillating = model.value("windDirection", "rotateUpDown") as? Bool
        let current = choices.filter { model.isSelected($0) }
        let position = current.first { $0.key == "stepUpDown" }
        let display = oscillating == true ? "Oscilando" :
            position.map(directionLabel) ?? (oscillating == false ? "Parada" :
                current.first(where: { $0.key == "rotateUpDown" }).map(directionLabel) ?? "—")
        let options = choices.enumerated().map { index, choice in
            CardOption(id: choice.id, label: directionLabel(choice),
                       groupTitle: index == 0 || choices[index - 1].key != choice.key
                           ? (choice.key == "rotateUpDown" ? "Oscilação vertical" : "Posições verticais") : nil)
        }
        return ControlCard(title: "Direção", value: display, icon: "wind",
                           status: cardStatus(available: !choices.isEmpty, known: !current.isEmpty),
                           active: model.ready && model.isOn && !current.isEmpty,
                           enabled: model.ready && model.isOn && !model.busy && !choices.isEmpty,
                           options: options, selected: nil,
                           selectedIDs: Set(current.filter { oscillating != true || $0.key == "rotateUpDown" }.map(\.id)),
                           explanation: model.verticalExplanation) { id in
            guard let choice = choices.first(where: { $0.id == id }) else { return }
            Task { await model.send(choice.resource, choice.key, choice.value.payload) }
        }
    }

    private var ecoControl: some View {
        HStack(spacing: 8) {
            Image(systemName: ecoActive ? "leaf.fill" : "leaf")
                .foregroundStyle(ecoActive ? Color.green : Color.white.opacity(0.65))
                .scaleEffect(ecoPulse ? 1.28 : 1)
                .rotationEffect(.degrees(ecoPulse ? -12 : 0))
            Text("Eco").font(.system(size: 12, weight: .semibold))
            // The binding reads device state only. A command never changes it optimistically.
            // While the unit is off the switch reads as off, since saving has no effect.
            Toggle("Eco", isOn: Binding(get: { ecoActive }, set: { desired in
                Task { await model.send("powerSave", "powerSaveEnabled", desired) }
            }))
            .labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(.green)
            .disabled(!model.ready || model.busy || !model.isOn || !ecoSupported)
            .accessibilityLabel("Modo econômico")
        }
        .padding(12)
        .modifier(ControlSurface(accent: ecoActive ? .green : .clear,
                                 interactive: model.ready && !model.busy && model.isOn && ecoSupported))
        .help(ecoSupported ? "Economia de energia" : "Modo econômico indisponível neste aparelho")
    }
    private var status: some View {
        Text(model.error ?? model.message)
            .font(.system(size: 11)).foregroundStyle(model.error == nil ? muted : Color.orange)
            .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(model.error ?? model.message)
    }
    private var keyEntry: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Conecte a mesma conta usada no LG ThinQ. Gere uma chave pessoal com acesso à lista, ao estado, ao perfil e ao controle dos aparelhos.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Link("Gerar chave no portal da LG ↗", destination: URL(string: "https://connect-pat.lgthinq.com")!)
                .font(.system(size: 12, weight: .medium))
            SecureField("Cole sua chave de acesso ThinQ", text: $token)
                .textFieldStyle(.roundedBorder).disabled(model.busy)
            Text("A chave fica no Chaves deste Mac. Conta e região: Brasil.")
                .font(.system(size: 10)).foregroundStyle(muted)
            Button {
                Task {
                    await model.connect(token: token)
                    if model.ready { token = ""; settings = false; syncDraft() }
                }
            } label: {
                HStack {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.busy ? "Conectando…" : "Conectar ao meu ar")
                        .font(.system(size: 13, weight: .semibold))
                }.frame(maxWidth: .infinity).padding(.vertical, 8)
            }.buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black).disabled(model.busy)
        }
    }
    // Shown once a key is saved: the key itself is never displayed, only removable.
    private var connectedAccount: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: model.ready ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 22)).foregroundStyle(model.ready ? Color.green : Color.orange)
                // One sentence per line, so a line never breaks in the middle of a sentence.
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.ready ? "Conta LG ThinQ conectada" : "Chave salva, sem conexão")
                        .font(.system(size: 13, weight: .semibold))
                    Group {
                        Text("A chave fica no Chaves deste Mac.")
                        Text("Conta e região: Brasil.")
                    }
                    .font(.system(size: 11)).foregroundStyle(muted)
                    .lineLimit(1).minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .modifier(ControlSurface(accent: model.ready ? .green : .orange, interactive: false))
            HStack(spacing: 10) {
                if !model.ready {
                    Button {
                        Task {
                            await model.reconnect()
                            if !model.ready { await model.refresh() }
                            if model.ready { settings = false; syncDraft() }
                        }
                    } label: {
                        Text(model.busy ? "Conectando…" : "Tentar novamente")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
                }
                Button(role: .destructive) { confirmRemoval = true } label: {
                    Text("Remover chave").font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.bordered).tint(.red)
            }
            .disabled(model.busy)
            .confirmationDialog("Remover a chave ThinQ deste Mac?", isPresented: $confirmRemoval) {
                Button("Remover chave", role: .destructive) { token = ""; model.disconnect() }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("O Brisa deixa de controlar o ar até você colar uma nova chave.")
            }
        }
    }
    private var setup: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Brisa").font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text("Seu clima, a um clique.").font(.system(size: 12)).foregroundStyle(muted)
                }
                Spacer()
                // The three gusts from the app icon, drawn as a template so they take
                // the same muted tone as the text around them.
                Image("BrisaMark")
                    .resizable().scaledToFit()
                    .frame(width: 38)
                    .foregroundStyle(muted)
                    .accessibilityHidden(true)
            }
            if model.hasStoredToken { connectedAccount } else { keyEntry }
            if model.error != nil || !model.message.isEmpty { status }
            Divider().opacity(0.4)
            LaunchAtLoginRow()
            Divider().opacity(0.4)
            HStack {
                if model.ready {
                    Button("Voltar") { settings = false; syncDraft() }
                } else {
                    Button("Experimentar demonstração") { model.startDemo(); settings = false; syncDraft() }
                }
                Spacer()
                PopupMenuButton(items: [
                    .init(title: "Reiniciar Brisa") { AppLifecycle.relaunch() },
                    .init(title: "Encerrar Brisa") { NSApplication.shared.terminate(nil) }
                ]) {
                    HStack(spacing: 3) {
                        Image(systemName: "ellipsis.circle")
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    }
                }
                .help("Mais opções")
                .accessibilityLabel("Mais opções")
            }.font(.system(size: 11)).disabled(model.busy)
        }
    }
}
