import Foundation

/// Read-only diagnostics: `MacFresh --selftest` runs every scanner and prints a summary. Nothing is deleted.
enum SelfTest {
    static func run() -> Never {
        func line(_ s: String) { print(s); fflush(stdout) }
        let t0 = Date()
        line("== MacFresh self-test (solo lectura) ==")
        line("Acceso total al disco: \(Permissions.hasFullDiskAccess)")
        let disk = FS.diskSpace()
        line("Disco: \(Fmt.bytes(disk.free)) libres de \(Fmt.bytes(disk.total))")

        line("\n-- Limpieza --")
        var junk: Int64 = 0
        for def in CleanupCatalog.all {
            let items = def.collect()
            let size = items.reduce(0) { $0 + $1.size }
            junk += size
            line("  \(def.title): \(items.count) elementos, \(Fmt.bytes(size))")
        }
        line("  TOTAL: \(Fmt.bytes(junk))")

        line("\n-- Protección --")
        let threats = MalwareScanner.scan { _ in }
        line("  Hallazgos: \(threats.count)")
        for t in threats.prefix(8) { line("   [\(t.level.title)] \(t.name) — \(t.reason)") }
        let privacy = PrivacyCatalog.scan()
        line("  Privacidad: " + privacy.map { "\($0.title) (\($0.items.count))" }.joined(separator: ", "))
        line("  Permisos TCC leídos: \(PermissionsCatalog.read().count)")

        line("\n-- Rendimiento --")
        let launch = StartupManager.launchItems()
        line("  Agentes/daemons: \(launch.count) (\(launch.filter(\.enabled).count) activos)")
        line("  Tareas de mantenimiento: \(MaintenanceCatalog.all.count)")
        line("  Top CPU: " + SystemMonitor.readTopProcesses(limit: 3).map { "\($0.name) \($0.cpu)%" }.joined(separator: ", "))

        line("\n-- Aplicaciones --")
        let apps = AppScanner.listApps()
        line("  Apps: \(apps.count) (App Store: \(apps.filter(\.isAppStore).count), Sparkle: \(apps.filter { $0.sparkleFeed != nil }.count), sin usar: \(apps.filter(\.unused).count))")
        if let sample = apps.first(where: { !$0.isAppStore }) ?? apps.first {
            let left = AppScanner.leftovers(for: sample)
            line("  Restos de \(sample.name): \(left.count) → " + left.prefix(4).map(\.name).joined(separator: ", "))
        }
        let orphans = AppScanner.orphans()
        line("  Restos huérfanos: \(orphans.count), \(Fmt.bytes(orphans.reduce(0) { $0 + $1.size }))")
        line("  Extensiones: \(ExtensionScanner.scan().count)")

        let sem = DispatchSemaphore(value: 0)
        let candidates = apps.filter { $0.isAppStore || $0.sparkleFeed != nil }.prefix(10)
        let box = UpdatesBox()
        Task.detached {
            for a in candidates { if let u = await UpdateChecker.check(a) { box.add("\(u.app.name) \(u.app.version) → \(u.newVersion)") } }
            sem.signal()
        }
        sem.wait()
        line("  Actualizaciones (muestra de \(candidates.count)): " + (box.items.isEmpty ? "ninguna" : box.items.joined(separator: ", ")))

        line("\n-- Mi desorden / Nube --")
        let token = CancelToken()
        let docs = ClutterScanner.enumerate(roots: [FS.home.appendingPathComponent("Downloads")], minSize: 100 * 1024, token: token) { _, _ in }
        let dups = ClutterScanner.duplicates(docs, token: token) { _ in }
        line("  Descargas: \(docs.count) archivos ≥100 KB, \(dups.count) grupos de duplicados")
        for p in CloudScanner.providers() {
            let (m, _) = CloudScanner.measure(p, token: token)
            line("  \(m.name): \(Fmt.bytes(m.localAllocated)) locales de \(Fmt.bytes(m.totalLogical))")
        }
        line("\nCompletado en \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        exit(0)
    }
}

final class UpdatesBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
}
