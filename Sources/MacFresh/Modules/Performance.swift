import AppKit
import Foundation
import SwiftUI

struct MaintenanceTask: Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let admin: Bool
    let command: String
    var selected: Bool
    var lastRun: Date? {
        UserDefaults.standard.object(forKey: "maint.\(id)") as? Date
    }
}

enum MaintenanceCatalog {
    static var all: [MaintenanceTask] {
        let uid = getuid()
        var tasks: [MaintenanceTask] = [
            MaintenanceTask(id: "ram", title: L("Liberar RAM"),
                            detail: L("Vacía la memoria inactiva para que las apps que abras dispongan de más RAM libre."),
                            icon: "memorychip", admin: true, command: "/usr/sbin/purge", selected: true),
            MaintenanceTask(id: "dns", title: L("Vaciar caché DNS"),
                            detail: L("Soluciona webs que no cargan o redirigen mal borrando las direcciones guardadas."),
                            icon: "network", admin: true,
                            command: "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder", selected: true),
            MaintenanceTask(id: "purgeable", title: L("Liberar espacio purgable"),
                            detail: L("Elimina instantáneas locales de Time Machine que ocupan espacio en tu disco."),
                            icon: "externaldrive.badge.minus", admin: true,
                            command: "/usr/bin/tmutil thinlocalsnapshots / 999999999999 4", selected: true),
            MaintenanceTask(id: "quicklook", title: L("Restablecer Quick Look"),
                            detail: L("Regenera las miniaturas y previsualizaciones si se ven mal o no aparecen."),
                            icon: "eye", admin: false, command: "/usr/bin/qlmanage -r; /usr/bin/qlmanage -r cache", selected: true),
            MaintenanceTask(id: "spotlight", title: L("Reindexar Spotlight"),
                            detail: L("Reconstruye el índice de búsqueda si Spotlight no encuentra archivos. Puede tardar un rato."),
                            icon: "magnifyingglass", admin: true, command: "/usr/bin/mdutil -E /", selected: false),
            MaintenanceTask(id: "launchservices", title: L("Reconstruir Launch Services"),
                            detail: L("Corrige menús «Abrir con» duplicados y asociaciones de archivos rotas."),
                            icon: "arrow.up.forward.app", admin: false,
                            command: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -r -domain local -domain system -domain user",
                            selected: false),
            MaintenanceTask(id: "mail", title: L("Acelerar Mail"),
                            detail: L("Compacta la base de datos de Mail para que las búsquedas y la carga sean más rápidas. Mail debe estar cerrado."),
                            icon: "envelope", admin: false,
                            command: "for f in \"$HOME\"/Library/Mail/V*/MailData/\"Envelope Index\"; do [ -f \"$f\" ] && /usr/bin/sqlite3 \"$f\" vacuum; done; true",
                            selected: false),
            MaintenanceTask(id: "fonts", title: L("Limpiar caché de fuentes"),
                            detail: L("Arregla fuentes que se ven corruptas. Reinicia tu Mac después."),
                            icon: "textformat", admin: false, command: "/usr/bin/atsutil databases -removeUser", selected: false),
            MaintenanceTask(id: "permissions", title: L("Reparar permisos de usuario"),
                            detail: L("Restablece los permisos de tu carpeta de inicio si ves errores de acceso."),
                            icon: "lock.rotation", admin: true,
                            command: "/usr/sbin/diskutil resetUserPermissions / \(uid)", selected: false),
            MaintenanceTask(id: "verify", title: L("Verificar disco de arranque"),
                            detail: L("Comprueba la integridad del sistema de archivos del disco de arranque."),
                            icon: "checkmark.seal", admin: true, command: "/usr/sbin/diskutil verifyVolume /", selected: false),
        ]
        if FileManager.default.fileExists(atPath: "/usr/sbin/periodic") {
            tasks.append(MaintenanceTask(id: "periodic", title: L("Ejecutar scripts de mantenimiento"),
                                         detail: L("Rota registros y limpia archivos temporales del sistema."),
                                         icon: "terminal", admin: true, command: "/usr/sbin/periodic daily weekly monthly",
                                         selected: false))
        }
        return tasks
    }
}

struct LoginItem: Identifiable, Hashable, Sendable {
    let name: String
    let path: String
    var id: String { name + path }
}

struct LaunchItem: Identifiable, Sendable {
    let plist: URL
    let label: String
    let program: String
    let domain: LaunchDomain
    var enabled: Bool
    var running: Bool
    var id: URL { plist }

    var domainName: String {
        switch domain {
        case .userAgent: L("Usuario")
        case .globalAgent: L("Todos los usuarios")
        case .daemon: L("Sistema")
        case .none: ""
        }
    }

    var appURL: URL? {
        guard let r = program.range(of: ".app/") else { return nil }
        return URL(fileURLWithPath: String(program[..<r.lowerBound]) + ".app")
    }
}

enum StartupManager {
    static func loginItems() -> [LoginItem] {
        let script = """
        tell application "System Events"
            set out to ""
            repeat with li in login items
                set out to out & (name of li) & "|" & (path of li) & linefeed
            end repeat
        end tell
        return out
        """
        let r = Shell.run("/usr/bin/osascript", ["-e", script])
        guard r.ok else { return [] }
        return r.output.split(separator: "\n").compactMap {
            let p = $0.split(separator: "|", maxSplits: 1).map(String.init)
            guard p.count == 2 else { return nil }
            return LoginItem(name: p[0], path: p[1])
        }
    }

    static func removeLoginItem(_ item: LoginItem) -> Bool {
        let name = item.name.replacingOccurrences(of: "\"", with: "\\\"")
        return Shell.run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to delete login item \"\(name)\""]).ok
    }

    static func addLoginItem(_ url: URL) -> Bool {
        let path = url.path.replacingOccurrences(of: "\"", with: "\\\"")
        return Shell.run("/usr/bin/osascript", ["-e",
            "tell application \"System Events\" to make login item at end with properties {path:\"\(path)\", hidden:false}"]).ok
    }

    static func disabledLabels(_ domain: String) -> Set<String> {
        let r = Shell.run("/bin/launchctl", ["print-disabled", domain])
        var set = Set<String>()
        for line in r.output.split(separator: "\n") {
            // "com.foo.bar" => disabled   |  "com.foo.bar" => true
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix("\""), let end = s.dropFirst().firstIndex(of: "\"") else { continue }
            let label = String(s[s.index(after: s.startIndex)..<end])
            if s.hasSuffix("disabled") || s.hasSuffix("true") { set.insert(label) }
        }
        return set
    }

    static func launchItems() -> [LaunchItem] {
        let uid = getuid()
        let userDisabled = disabledLabels("gui/\(uid)")
        let sysDisabled = disabledLabels("system")
        let running = Set(Shell.run("/bin/launchctl", ["list"]).output.split(separator: "\n").compactMap {
            $0.split(separator: "\t").last.map(String.init)
        })
        let dirs: [(URL, LaunchDomain)] = [
            (FS.lib("LaunchAgents"), .userAgent),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), .globalAgent),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), .daemon),
        ]
        var out: [LaunchItem] = []
        for (dir, domain) in dirs {
            for plist in FS.children(dir, hidden: false) where plist.pathExtension == "plist" {
                guard let d = NSDictionary(contentsOf: plist) as? [String: Any] else { continue }
                let label = d["Label"] as? String ?? plist.deletingPathExtension().lastPathComponent
                let program = (d["Program"] as? String) ?? (d["ProgramArguments"] as? [String])?.first ?? ""
                let disabledKey = d["Disabled"] as? Bool ?? false
                let disabled = disabledKey || (domain == .daemon ? sysDisabled.contains(label) : userDisabled.contains(label))
                out.append(LaunchItem(plist: plist, label: label, program: program, domain: domain,
                                      enabled: !disabled, running: running.contains(label)))
            }
        }
        return out.sorted { $0.label.lowercased() < $1.label.lowercased() }
    }

    static func setEnabled(_ item: LaunchItem, _ on: Bool) -> Bool {
        let uid = getuid()
        let plist = Shell.quote(item.plist.path)
        switch item.domain {
        case .userAgent, .globalAgent:
            let target = "gui/\(uid)/\(item.label)"
            if on {
                Shell.run("/bin/launchctl", ["enable", target])
                Shell.run("/bin/launchctl", ["bootstrap", "gui/\(uid)", item.plist.path])
                return true
            } else {
                let r = Shell.run("/bin/launchctl", ["disable", target])
                Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)", item.plist.path])
                return r.ok
            }
        case .daemon:
            let cmd = on
                ? "/bin/launchctl enable system/\(Shell.quote(item.label)); /bin/launchctl bootstrap system \(plist)"
                : "/bin/launchctl disable system/\(Shell.quote(item.label)); /bin/launchctl bootout system \(plist)"
            return Shell.admin(cmd + "; true").ok
        case .none:
            return false
        }
    }

    static func remove(_ item: LaunchItem) -> Bool {
        let uid = getuid()
        if item.domain == .userAgent {
            Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)", item.plist.path])
            return (try? FileManager.default.trashItem(at: item.plist, resultingItemURL: nil)) != nil
        }
        let domain = item.domain == .daemon ? "system" : "gui/\(uid)"
        return Shell.admin("/bin/launchctl bootout \(domain) \(Shell.quote(item.plist.path)) 2>/dev/null; /bin/rm -f \(Shell.quote(item.plist.path))").ok
    }
}

@MainActor
@Observable
final class PerformanceModel {
    enum Tab: String, CaseIterable, Identifiable {
        case maintenance, login, background, heavy
        var id: String { rawValue }
        var title: String {
            switch self {
            case .maintenance: L("Mantenimiento")
            case .login: L("Ítems de inicio")
            case .background: L("Agentes en segundo plano")
            case .heavy: L("Consumo elevado")
            }
        }
    }

    var tab: Tab = .maintenance
    var tasks: [MaintenanceTask] = MaintenanceCatalog.all
    var phase: ModulePhase = .idle
    var currentTask = ""
    var taskResults: [String: Bool] = [:]
    var loginItems: [LoginItem] = []
    var launchItems: [LaunchItem] = []
    var heavyCPU: [ProcessUsage] = []
    var heavyMemory: [ProcessUsage] = []
    var loadedStartup = false

    var selectedTasks: [MaintenanceTask] { tasks.filter(\.selected) }

    func runSelected() async {
        await run(selectedTasks)
    }

    func run(_ list: [MaintenanceTask]) async {
        guard !list.isEmpty else { return }
        phase = .working
        taskResults = [:]
        let adminTasks = list.filter(\.admin)
        let userTasks = list.filter { !$0.admin }
        for t in userTasks {
            currentTask = t.title
            let ok = await Task.detached { Shell.sh(t.command).ok }.value
            taskResults[t.id] = ok
            if ok { UserDefaults.standard.set(Date(), forKey: "maint.\(t.id)") }
        }
        if !adminTasks.isEmpty {
            currentTask = adminTasks.map(\.title).joined(separator: ", ")
            // One password prompt for every admin task; each one reports its own status.
            let script = adminTasks.map { "(\($0.command)) >/dev/null 2>&1 && echo OK:\($0.id) || echo KO:\($0.id)" }
                .joined(separator: "; ")
            let r = await Task.detached { Shell.admin(script) }.value
            for t in adminTasks {
                let ok = r.output.contains("OK:\(t.id)")
                taskResults[t.id] = ok
                if ok { UserDefaults.standard.set(Date(), forKey: "maint.\(t.id)") }
            }
        }
        tasks = tasks.map { var t = $0; t.selected = $0.selected; return t }
        phase = .done
    }

    func loadStartup() async {
        async let li = Task.detached { StartupManager.loginItems() }.value
        async let la = Task.detached { StartupManager.launchItems() }.value
        loginItems = await li
        launchItems = await la
        loadedStartup = true
    }

    func refreshHeavy() async {
        async let cpu = Task.detached { SystemMonitor.readTopProcesses(limit: 12) }.value
        async let mem = Task.detached { SystemMonitor.readTopMemoryProcesses(limit: 12) }.value
        heavyCPU = await cpu
        heavyMemory = await mem
    }

    func toggle(_ item: LaunchItem) async {
        let ok = await Task.detached { StartupManager.setEnabled(item, !item.enabled) }.value
        if ok, let i = launchItems.firstIndex(where: { $0.id == item.id }) {
            launchItems[i].enabled.toggle()
        }
    }

    func remove(_ item: LaunchItem) async {
        guard Confirm.ask(LF("Eliminar «%@»", item.label), L("El archivo de configuración se moverá a la Papelera y el agente dejará de ejecutarse.")) else { return }
        if await Task.detached(operation: { StartupManager.remove(item) }).value {
            launchItems.removeAll { $0.id == item.id }
        }
    }

    func removeLogin(_ item: LoginItem) async {
        if await Task.detached(operation: { StartupManager.removeLoginItem(item) }).value {
            loginItems.removeAll { $0.id == item.id }
        }
    }

    func addLogin() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = await Task.detached { StartupManager.addLoginItem(url) }.value
        await loadStartup()
    }
}

// MARK: - Views

struct PerformanceView: View {
    @Bindable var model: PerformanceModel

    var body: some View {
        VStack(spacing: 0) {
            TabPicker(items: PerformanceModel.Tab.allCases, selection: $model.tab) { $0.title }
                .padding(.top, 16)
            switch model.tab {
            case .maintenance: MaintenanceSection(model: model)
            case .login: LoginItemsSection(model: model)
            case .background: LaunchItemsSection(model: model)
            case .heavy: HeavySection(model: model)
            }
        }
        .task { if !model.loadedStartup { await model.loadStartup() } }
    }
}

private struct MaintenanceSection: View {
    @Bindable var model: PerformanceModel

    var body: some View {
        switch model.phase {
        case .working:
            WorkingView(module: .performance, title: L("Ejecutando mantenimiento…"), detail: model.currentTask)
        case .done:
            VStack(spacing: 0) {
                ModuleHeader(module: .performance, title: L("Mantenimiento completado"),
                             subtitle: L("Resultados de las tareas ejecutadas.")) {
                    Button(L("Listo")) { model.phase = .idle }.buttonStyle(PillButtonStyle(prominent: true))
                }
                List(model.tasks.filter { model.taskResults[$0.id] != nil }) { t in
                    HStack {
                        Image(systemName: t.icon).frame(width: 24)
                        Text(t.title)
                        Spacer()
                        if model.taskResults[t.id] == true {
                            Label(L("Hecho"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Label(L("No completado"), systemImage: "xmark.circle.fill").foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .scrollContentBackground(.hidden)
            }
        default:
            VStack(spacing: 0) {
                ModuleHeader(module: .performance, title: L("Tareas de mantenimiento"),
                             subtitle: L("Selecciona las tareas que quieres ejecutar. Las marcadas con candado piden tu contraseña."))
                List {
                    ForEach($model.tasks) { $t in
                        HStack(alignment: .top, spacing: 12) {
                            CheckCircle(isOn: $t.selected)
                            Image(systemName: t.icon).font(.title3).frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(t.title).font(.headline)
                                    if t.admin { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.white.opacity(0.6)) }
                                }
                                Text(t.detail).font(.callout).foregroundStyle(.white.opacity(0.75))
                                Text(LF("Última ejecución: %@", Fmt.relative(t.lastRun)))
                                    .font(.caption).foregroundStyle(.white.opacity(0.5))
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
                .scrollContentBackground(.hidden)
                ActionBar(module: .performance, summary: LF("%@ tareas seleccionadas", model.selectedTasks.count),
                          buttonTitle: L("Ejecutar"), enabled: !model.selectedTasks.isEmpty) {
                    Task { await model.runSelected() }
                }
            }
        }
    }
}

private struct LoginItemsSection: View {
    @Bindable var model: PerformanceModel

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .performance, title: L("Ítems de inicio de sesión"),
                         subtitle: L("Apps que se abren automáticamente al iniciar sesión. Menos ítems = arranque más rápido.")) {
                HStack {
                    Button(L("Añadir…")) { Task { await model.addLogin() } }.buttonStyle(PillButtonStyle())
                    Button(L("Actualizar")) { Task { await model.loadStartup() } }.buttonStyle(PillButtonStyle())
                }
            }
            if model.loginItems.isEmpty {
                VStack(spacing: 8) {
                    Text(model.loadedStartup ? L("No hay ítems de inicio, o MacFresh no tiene permiso para leerlos.") : L("Cargando…"))
                    Text(L("Si se te pidió permiso para controlar «System Events», acéptalo en Ajustes > Privacidad > Automatización."))
                        .font(.caption).foregroundStyle(.white.opacity(0.6))
                }
                .padding(30)
                Spacer()
            } else {
                List(model.loginItems) { item in
                    HStack(spacing: 10) {
                        FileIconView(url: URL(fileURLWithPath: item.path))
                        VStack(alignment: .leading) {
                            Text(item.name).font(.headline)
                            Text(item.path).font(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button(L("Quitar")) { Task { await model.removeLogin(item) } }.buttonStyle(SmallButtonStyle())
                    }
                    .padding(.vertical, 4)
                }
                .scrollContentBackground(.hidden)
            }
        }
    }
}

private struct LaunchItemsSection: View {
    @Bindable var model: PerformanceModel
    @State private var showApple = false

    var visible: [LaunchItem] {
        model.launchItems.filter { showApple || !$0.label.hasPrefix("com.apple.") }
    }

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .performance, title: L("Agentes en segundo plano"),
                         subtitle: L("Procesos auxiliares que se inician solos. Desactiva los que no reconozcas o no necesites.")) {
                Button(L("Actualizar")) { Task { await model.loadStartup() } }.buttonStyle(PillButtonStyle())
            }
            List(visible) { item in
                HStack(spacing: 10) {
                    if let app = item.appURL, FS.exists(app) {
                        FileIconView(url: app)
                    } else {
                        Image(systemName: "gearshape.2").frame(width: 28)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.label).font(.headline).lineLimit(1)
                            if item.running {
                                Circle().fill(.green).frame(width: 7, height: 7).help(L("En ejecución"))
                            }
                        }
                        Text("\(item.domainName) · \(item.program)")
                            .font(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if item.domain == .daemon {
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.white.opacity(0.5))
                    }
                    Toggle("", isOn: Binding(get: { item.enabled }, set: { _ in Task { await model.toggle(item) } }))
                        .toggleStyle(.switch).labelsHidden()
                    Button { Task { await model.remove(item) } } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
                    Button { FS.reveal(item.plist) } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
                }
                .padding(.vertical, 4)
            }
            .scrollContentBackground(.hidden)
            HStack {
                Toggle(L("Mostrar agentes de Apple"), isOn: $showApple).toggleStyle(.checkbox)
                Spacer()
                Text(LF("%@ activos de %@", visible.filter(\.enabled).count, visible.count)).foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
            .background(.black.opacity(0.18))
        }
    }
}

private struct HeavySection: View {
    @Bindable var model: PerformanceModel
    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .performance, title: L("Consumo elevado"),
                         subtitle: L("Procesos que más CPU y memoria usan ahora mismo."))
            HStack(alignment: .top, spacing: 16) {
                processList("CPU", icon: "cpu", items: model.heavyCPU) { String(format: "%.1f%%", $0.cpu) }
                processList(L("Memoria"), icon: "memorychip", items: model.heavyMemory) { Fmt.bytes($0.memory) }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .task { await model.refreshHeavy() }
        .onReceive(timer) { _ in Task { await model.refreshHeavy() } }
    }

    private func processList(_ title: String, icon: String, items: [ProcessUsage], value: @escaping (ProcessUsage) -> String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.headline)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(items) { p in
                        let app = NSRunningApplication(processIdentifier: p.pid)
                        HStack(spacing: 8) {
                            if let icon = app?.icon {
                                Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                            } else {
                                Image(systemName: "terminal").frame(width: 22)
                            }
                            Text(app?.localizedName ?? p.name).lineLimit(1)
                            Spacer()
                            Text(value(p)).monospacedDigit().foregroundStyle(.white.opacity(0.8))
                            if let app, app.activationPolicy == .regular {
                                Button(L("Salir")) { app.terminate() }.buttonStyle(SmallButtonStyle())
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .glassCard()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
