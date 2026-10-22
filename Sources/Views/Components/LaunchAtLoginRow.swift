import SwiftUI
import ServiceManagement

/// Registers Brisa as a login item. The switch always reflects the system's real
/// status, so changes made in System Settings show up here too.
struct LaunchAtLoginRow: View {
    @State private var status = SMAppService.mainApp.status
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Iniciar com o Mac").font(.system(size: 13, weight: .semibold))
                    Text("Abrir automaticamente ao iniciar sessão")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.62))
                }
                Spacer()
                Toggle("Iniciar com o Mac", isOn: Binding(get: { status == .enabled }, set: update))
                    .labelsHidden().toggleStyle(.switch).tint(.green)
            }
            if status == .requiresApproval {
                HStack(spacing: 6) {
                    Text("Permita o Brisa em Itens de Início.").foregroundStyle(.orange)
                    Button("Abrir Ajustes") { SMAppService.openSystemSettingsLoginItems() }
                        .buttonStyle(.link)
                }.font(.system(size: 11))
            }
            if let failure {
                Text(failure).font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { status = SMAppService.mainApp.status }
    }

    private func update(_ enabled: Bool) {
        failure = nil
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            failure = "Não foi possível alterar o início automático: \(error.localizedDescription)"
        }
        status = SMAppService.mainApp.status
    }
}
