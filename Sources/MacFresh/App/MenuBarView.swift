import AppKit
import SwiftUI
import UserNotifications

struct MenuBarView: View {
    private let m = SystemMonitor.shared
    @Environment(\.openWindow) private var openWindow
    @State private var freeingRAM = false
    @State private var ramMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "leaf.circle.fill").font(.title2).foregroundStyle(Module.smartCare.accent)
                VStack(alignment: .leading, spacing: 0) {
                    Text("MacFresh").font(.headline)
                    Text("\(m.machineName) · \(m.osVersion)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(LF("Activo %@", Fmt.duration(m.uptime))).font(.caption2).foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                card(icon: "internaldrive", title: L("Disco"),
                     value: LF("%@ libres", Fmt.bytes(m.diskFree)),
                     frac: m.diskTotal > 0 ? 1 - Double(m.diskFree) / Double(m.diskTotal) : 0,
                     action: (L("Limpiar"), { open(.cleanup) }))
                card(icon: "memorychip", title: L("Memoria"),
                     value: "\(Fmt.bytes(m.memoryUsed)) de \(Fmt.bytes(m.memoryTotal))",
                     frac: m.memoryPressure,
                     action: (freeingRAM ? "…" : L("Liberar"), { freeRAM() }))
                card(icon: "cpu", title: "CPU", value: Fmt.percent(m.cpu), frac: m.cpu,
                     subtitle: m.topProcesses.first.map { LF("Mayor: %@", $0.name) })
                if let b = m.battery {
                    card(icon: b.charging ? "battery.100.bolt" : "battery.75percent", title: L("Batería"),
                         value: Fmt.percent(b.percent), frac: b.percent,
                         subtitle: [b.health.map { LF("Salud %@", Fmt.percent($0)) }, b.cycleCount.map { LF("%@ ciclos", $0) }]
                            .compactMap { $0 }.joined(separator: " · "))
                } else {
                    card(icon: "network", title: L("Red"), value: "↓ \(Fmt.bytesPerSecond(m.netIn))", frac: 0,
                         subtitle: "↑ \(Fmt.bytesPerSecond(m.netOut))")
                }
            }

            if m.battery != nil {
                HStack {
                    Image(systemName: "network")
                    Text("↓ \(Fmt.bytesPerSecond(m.netIn))").monospacedDigit()
                    Text("↑ \(Fmt.bytesPerSecond(m.netOut))").monospacedDigit()
                    Spacer()
                }
                .font(.callout)
                .padding(10)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }

            if let ramMessage {
                Text(ramMessage).font(.caption).foregroundStyle(.secondary)
            }

            Divider()
            HStack {
                Button { open(.smartCare) } label: { Label(L("Smart Care"), systemImage: "sparkles") }
                Spacer()
                Button { emptyTrash() } label: { Label(L("Vaciar Papelera"), systemImage: "trash") }
            }
            HStack {
                Button(L("Abrir MacFresh")) { open(nil) }
                Spacer()
                SettingsLink { Text(L("Ajustes…")) }
                Button(L("Salir")) { NSApp.terminate(nil) }
            }
        }
        .buttonStyle(.borderless)
        .padding(14)
        .frame(width: 340)
    }

    private func card(icon: String, title: String, value: String, frac: Double, subtitle: String? = nil,
                      action: (String, () -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ZStack {
                    MeterRing(value: frac, color: frac > 0.85 ? .orange : Module.smartCare.accent, lineWidth: 4)
                    Image(systemName: icon).font(.caption)
                }
                .frame(width: 32, height: 32)
                Spacer()
                if let action {
                    Button(action.0, action: action.1).buttonStyle(SmallButtonStyle())
                }
            }
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.bold()).lineLimit(1).minimumScaleFactor(0.8)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private func open(_ module: Module?) {
        if let module { AppState.shared.selection = module }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func freeRAM() {
        guard !freeingRAM else { return }
        freeingRAM = true
        let before = m.memoryUsed
        Task {
            let ok = await Task.detached { Shell.admin("/usr/sbin/purge").ok }.value
            try? await Task.sleep(for: .seconds(2.5))
            m.refresh()
            let freed = max(0, before - m.memoryUsed)
            ramMessage = ok ? LF("Memoria liberada: %@", Fmt.bytes(freed)) : L("No se pudo liberar la memoria.")
            freeingRAM = false
        }
    }

    private func emptyTrash() {
        Task.detached {
            Shell.run("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty trash"])
        }
    }
}

/// Posts a notification when the startup disk runs low on space (at most once a day).
@MainActor
enum DiskAlerts {
    static func start() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            Task { @MainActor in check() }
        }
        check()
    }

    static func check() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "lowDiskAlert") as? Bool ?? true else { return }
        let space = FS.diskSpace()
        guard space.free > 0, space.free < 10_000_000_000 else { return }
        if let last = defaults.object(forKey: "lastDiskAlert") as? Date, Date().timeIntervalSince(last) < 86400 { return }
        defaults.set(Date(), forKey: "lastDiskAlert")
        let content = UNMutableNotificationContent()
        content.title = L("Queda poco espacio en disco")
        content.body = LF("Solo quedan %@ libres. Abre MacFresh para liberar espacio.", Fmt.bytes(space.free))
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "lowdisk", content: content, trigger: nil))
    }
}
