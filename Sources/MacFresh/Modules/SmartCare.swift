import AppKit
import Foundation
import SwiftUI

@MainActor
@Observable
final class SmartCareModel {
    enum Step: Int, CaseIterable, Identifiable {
        case cleanup, protection, performance, updates, clutter
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .cleanup: L("Limpieza")
            case .protection: L("Protección")
            case .performance: L("Rendimiento")
            case .updates: L("Aplicaciones")
            case .clutter: L("Desorden")
            }
        }
        var module: Module {
            switch self {
            case .cleanup: .cleanup
            case .protection: .protection
            case .performance: .performance
            case .updates: .applications
            case .clutter: .clutter
            }
        }
    }

    var phase: ModulePhase = .idle
    var currentStep: Step?
    var finished: Set<Step> = []
    var enabled: Set<Step> = [.cleanup, .protection, .performance, .updates]

    var junkSize: Int64 = 0
    var threatCount = 0
    var tasksCount = 0
    var updatesCount = 0
    var clutterItems: [FileItem] = []
    var clutterSize: Int64 { clutterItems.reduce(0) { $0 + $1.size } }

    var summary: [String] = []

    private var app: AppState { AppState.shared }

    func scan() async {
        phase = .scanning
        finished = []

        currentStep = .cleanup
        await app.cleanup.scan()
        junkSize = app.cleanup.selectedSize
        finished.insert(.cleanup)

        currentStep = .protection
        await app.protection.scanMalware()
        threatCount = app.protection.threats.filter { $0.level >= .medium }.count
        // Smart Care only removes confirmed threats; low-risk findings stay for manual review.
        for i in app.protection.threats.indices {
            app.protection.threats[i].selected = app.protection.threats[i].level >= .medium
        }
        finished.insert(.protection)

        currentStep = .performance
        tasksCount = app.performance.tasks.filter(\.selected).count
        finished.insert(.performance)

        currentStep = .updates
        await app.applications.checkUpdates()
        updatesCount = app.applications.updates.count
        finished.insert(.updates)

        currentStep = .clutter
        clutterItems = await Task.detached {
            let cutoff = Date().addingTimeInterval(-60 * 86400)
            return FS.items(in: FS.home.appendingPathComponent("Downloads"), hidden: false, minSize: 50_000_000)
                .filter { ($0.modified ?? .distantPast) < cutoff }
        }.value
        finished.insert(.clutter)
        currentStep = nil

        if threatCount == 0 { enabled.remove(.protection) } else { enabled.insert(.protection) }
        if updatesCount == 0 { enabled.remove(.updates) }
        if junkSize == 0 { enabled.remove(.cleanup) }
        phase = .results
    }

    func run() async {
        phase = .working
        summary = []
        if enabled.contains(.cleanup) {
            currentStep = .cleanup
            await app.cleanup.clean()
            summary.append(LF("Se liberaron %@ de basura.", Fmt.bytes(app.cleanup.result.freed)))
            app.cleanup.reset()
        }
        if enabled.contains(.protection), !app.protection.selectedThreats.isEmpty {
            currentStep = .protection
            await app.protection.removeThreats()
            summary.append(LF("Se eliminaron %@ amenazas.", app.protection.removedCount))
            app.protection.malwarePhase = .idle
        }
        if enabled.contains(.performance) {
            currentStep = .performance
            await app.performance.runSelected()
            let ok = app.performance.taskResults.values.filter { $0 }.count
            summary.append(LF("Se completaron %@ tareas de mantenimiento.", ok))
            app.performance.phase = .idle
        }
        if enabled.contains(.updates) {
            currentStep = .updates
            var store = false
            for u in app.applications.updates {
                if u.storeURL != nil { store = true; continue }
                await app.applications.install(u)
            }
            if store, let url = URL(string: "macappstore://showUpdatesPage") { NSWorkspace.shared.open(url) }
            summary.append(LF("Actualizaciones aplicadas%@.", store ? L("; las de la App Store se abrieron en la tienda") : ""))
        }
        if enabled.contains(.clutter) {
            currentStep = .clutter
            let items = clutterItems.filter(\.selected)
            let r = await Task.detached { FS.remove(items, mode: .trash) }.value
            summary.append(LF("Se movieron %@ descargas antiguas a la Papelera (%@).", r.removed, Fmt.bytes(r.freed)))
        }
        currentStep = nil
        phase = .done
    }

    func valueText(_ s: Step) -> String {
        switch s {
        case .cleanup: Fmt.bytes(junkSize)
        case .protection: threatCount == 0 ? L("Sin amenazas") : LF("%@ amenazas", threatCount)
        case .performance: LF("%@ tareas", tasksCount)
        case .updates: updatesCount == 0 ? L("Todo al día") : LF("%@ actualizaciones", updatesCount)
        case .clutter: clutterItems.isEmpty ? L("Ordenado") : Fmt.bytes(clutterSize)
        }
    }

    func detailText(_ s: Step) -> String {
        switch s {
        case .cleanup: L("Basura del sistema, cachés y registros")
        case .protection: L("Malware y agentes sospechosos")
        case .performance: L("Mantenimiento recomendado (puede pedir contraseña)")
        case .updates: L("Apps de la App Store y con Sparkle")
        case .clutter: L("Descargas grandes sin tocar en 2 meses")
        }
    }

    func isActionable(_ s: Step) -> Bool {
        switch s {
        case .cleanup: junkSize > 0
        case .protection: threatCount > 0
        case .performance: tasksCount > 0
        case .updates: updatesCount > 0
        case .clutter: !clutterItems.isEmpty
        }
    }
}

struct SmartCareView: View {
    @Bindable var model: SmartCareModel
    private let monitor = SystemMonitor.shared

    var body: some View {
        switch model.phase {
        case .idle:
            ModuleHero(module: .smartCare, actionTitle: L("Analizar")) {
                Task { await model.scan() }
            } extra: {
                HStack(spacing: 12) {
                    statCard("internaldrive", L("Disco"), LF("%@ libres", Fmt.bytes(monitor.diskFree)),
                             monitor.diskTotal > 0 ? 1 - Double(monitor.diskFree) / Double(monitor.diskTotal) : 0)
                    statCard("memorychip", L("Memoria"), LF("%@ en uso", Fmt.bytes(monitor.memoryUsed)), monitor.memoryPressure)
                    statCard("cpu", "CPU", Fmt.percent(monitor.cpu), monitor.cpu)
                    if let b = monitor.battery {
                        statCard("battery.75percent", L("Batería"),
                                 b.health.map { LF("Salud %@", Fmt.percent($0)) } ?? Fmt.percent(b.percent), b.percent)
                    }
                }
                .padding(.top, 8)
            }
        case .scanning:
            VStack(spacing: 26) {
                Spacer()
                ModuleGlyph(module: .smartCare, size: 160, spinning: true)
                Text(L("Analizando tu Mac…")).font(.system(size: 26, weight: .bold))
                HStack(spacing: 18) {
                    ForEach(SmartCareModel.Step.allCases) { s in
                        VStack(spacing: 8) {
                            ZStack {
                                Circle().fill(.white.opacity(0.1)).frame(width: 54, height: 54)
                                if model.finished.contains(s) {
                                    Image(systemName: "checkmark").font(.title2.bold()).foregroundStyle(.green)
                                } else if model.currentStep == s {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: s.module.icon).foregroundStyle(.white.opacity(0.5))
                                }
                            }
                            Text(s.title).font(.caption)
                        }
                    }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .results:
            VStack(spacing: 0) {
                ModuleHeader(module: .smartCare, title: L("Esto es lo que encontramos"),
                             subtitle: L("Marca lo que quieres que MacFresh haga por ti.")) {
                    Button(L("Volver a analizar")) { Task { await model.scan() } }.buttonStyle(PillButtonStyle())
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                        ForEach(SmartCareModel.Step.allCases) { s in resultCard(s) }
                    }
                    .padding(20)
                }
                ActionBar(module: .smartCare, summary: LF("%@ acciones seleccionadas", model.enabled.count),
                          buttonTitle: L("Ejecutar"), enabled: !model.enabled.isEmpty) {
                    Task { await model.run() }
                }
            }
        case .working:
            WorkingView(module: .smartCare, title: L("Cuidando tu Mac…"), detail: model.currentStep?.title ?? "")
        case .done:
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "checkmark.seal.fill").font(.system(size: 90)).foregroundStyle(.white, Module.smartCare.accent)
                Text(L("Tu Mac está en forma")).font(.system(size: 30, weight: .bold))
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.summary, id: \.self) { Label($0, systemImage: "checkmark.circle") }
                }
                .glassCard()
                Spacer()
                Button(L("Listo")) { model.phase = .idle }.buttonStyle(PillButtonStyle(prominent: true)).padding(.bottom, 30)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func statCard(_ icon: String, _ title: String, _ value: String, _ frac: Double) -> some View {
        HStack(spacing: 10) {
            ZStack {
                MeterRing(value: frac, color: frac > 0.85 ? .orange : .white, lineWidth: 4)
                Image(systemName: icon).font(.caption)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).foregroundStyle(.white.opacity(0.7))
                Text(value).font(.callout.bold())
            }
        }
        .glassCard(padding: 10)
    }

    private func resultCard(_ s: SmartCareModel.Step) -> some View {
        let on = Binding(get: { model.enabled.contains(s) }, set: { v in
            if v { model.enabled.insert(s) } else { model.enabled.remove(s) }
        })
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: s.module.icon)
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .background(s.module.gradient, in: RoundedRectangle(cornerRadius: 12))
                Spacer()
                if model.isActionable(s) {
                    Toggle("", isOn: on).toggleStyle(.switch).labelsHidden()
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title2)
                }
            }
            Text(s.title).font(.headline)
            Text(model.valueText(s)).font(.title2.bold())
            Text(model.detailText(s)).font(.caption).foregroundStyle(.white.opacity(0.7))
            Button(L("Revisar detalles")) { AppState.shared.selection = s.module }
                .buttonStyle(SmallButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}
