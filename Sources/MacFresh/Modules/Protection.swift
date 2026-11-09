import AppKit
import Foundation
import Security
import SwiftUI

// MARK: - Threat model

enum ThreatLevel: Int, Comparable, Sendable {
    case low, medium, high
    static func < (a: ThreatLevel, b: ThreatLevel) -> Bool { a.rawValue < b.rawValue }
    var title: String {
        switch self {
        case .low: L("Bajo")
        case .medium: L("Sospechoso")
        case .high: L("Amenaza")
        }
    }
    var color: Color {
        switch self {
        case .low: .yellow
        case .medium: .orange
        case .high: .red
        }
    }
}

enum LaunchDomain: Sendable {
    case userAgent, globalAgent, daemon, none
}

struct Threat: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let kind: String
    let level: ThreatLevel
    let reason: String
    let files: [URL]
    var label: String? = nil
    var domain: LaunchDomain = .none
    var selected: Bool = true
}

enum MalwareScanner {
    /// Names, bundle IDs and labels of widely reported macOS adware / PUP families.
    static let signatures: [String] = [
        "mackeeper", "zeobit", "genieo", "installmac", "vsearch", "conduit", "trovi", "spigot", "searchmine",
        "searchbaron", "search baron", "chumsearch", "safefinder", "advanced mac cleaner", "advancedmaccleaner",
        "mac auto fixer", "macautofixer", "smart mac booster", "mac cleanup pro", "mactonic", "mac tonic",
        "pcvark", "com.pcv.", "mughthesec", "adload", "bundlore", "shlayer", "pirrit", "crossrider", "weknow",
        "anysearch", "searchpulse", "adsearch", "tapufind", "qsearch", "searchmarquis", "search-marquis",
        "flashmall", "mediadownloader", "mykotlerino", "macsafecleaner", "mac mechanic", "macmechanic",
        "similar photo cleaner", "booster.mac", "spinstall", "esbuild.update", "com.updater.mcy",
        "com.mcy.", "searchmulty", "searchwebway", "searchrange", "chill tab", "chilltab", "mac speedup pro",
        "macspeedup", "smartmacbooster", "elmedia.agent.free", "macupdate.installer", "cloudfront.installer",
    ]

    static let suspiciousDirs = ["/tmp/", "/private/tmp/", "/var/tmp/", "/private/var/tmp/", "/Users/Shared/"]

    static func matchesSignature(_ s: String) -> String? {
        let l = s.lowercased()
        return signatures.first { l.contains($0) }
    }

    static func isValidlySigned(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: kSecCSDoNotValidateResources)
        return SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess
    }

    static func scan(progress: @escaping @Sendable (String) -> Void) -> [Threat] {
        var threats: [Threat] = []
        let launchDirs: [(URL, LaunchDomain, String)] = [
            (FS.lib("LaunchAgents"), .userAgent, L("Agente de inicio (usuario)")),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), .globalAgent, L("Agente de inicio (sistema)")),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), .daemon, L("Daemon del sistema")),
        ]
        for (dir, domain, kind) in launchDirs {
            for plist in FS.children(dir, hidden: false) where plist.pathExtension == "plist" {
                progress(plist.path)
                guard let dict = NSDictionary(contentsOf: plist) as? [String: Any] else { continue }
                let label = dict["Label"] as? String ?? plist.deletingPathExtension().lastPathComponent
                let exe = (dict["Program"] as? String) ?? (dict["ProgramArguments"] as? [String])?.first ?? ""
                var files = [plist]
                let exeURL = exe.isEmpty ? nil : URL(fileURLWithPath: exe)
                let exeRemovable = exeURL.map { u in
                    !u.path.hasPrefix("/usr/") && !u.path.hasPrefix("/bin/") && !u.path.hasPrefix("/System/")
                        && !u.path.hasPrefix("/sbin/") && !u.path.contains(".app/")
                } ?? false

                if let sig = matchesSignature(label) ?? matchesSignature(exe) {
                    if let exeURL, exeRemovable, FS.exists(exeURL) { files.append(exeURL) }
                    threats.append(Threat(name: label, kind: kind, level: .high,
                                          reason: LF("Coincide con la firma de adware conocida «%@».", sig),
                                          files: files, label: label, domain: domain))
                    continue
                }
                if let exeURL, suspiciousDirs.contains(where: { exe.hasPrefix($0) }) || exe.contains("/.") {
                    if exeRemovable, FS.exists(exeURL) { files.append(exeURL) }
                    threats.append(Threat(name: label, kind: kind, level: .medium,
                                          reason: LF("Ejecuta un programa desde una ubicación oculta o temporal (%@).", exe),
                                          files: files, label: label, domain: domain))
                    continue
                }
                if label.hasPrefix("com.apple.") {
                    threats.append(Threat(name: label, kind: kind, level: .medium,
                                          reason: L("Se hace pasar por un componente de Apple fuera de la carpeta del sistema."),
                                          files: files, label: label, domain: domain))
                    continue
                }
                if let exeURL, !FS.exists(exeURL) {
                    threats.append(Threat(name: label, kind: kind, level: .low,
                                          reason: L("Elemento roto: el programa que debería abrir ya no existe."),
                                          files: files, label: label, domain: domain, selected: true))
                    continue
                }
                if let exeURL, exe.hasPrefix(FS.home.path), !isValidlySigned(exeURL) {
                    threats.append(Threat(name: label, kind: kind, level: .low,
                                          reason: L("Programa sin firma válida que se inicia automáticamente desde tu carpeta personal."),
                                          files: files, label: label, domain: domain, selected: false))
                }
            }
        }

        // Applications
        for dir in [URL(fileURLWithPath: "/Applications"), FS.home.appendingPathComponent("Applications")] {
            for app in FS.children(dir, hidden: false) where app.pathExtension == "app" {
                progress(app.path)
                let bid = Bundle(url: app)?.bundleIdentifier ?? ""
                if let sig = matchesSignature(app.lastPathComponent) ?? matchesSignature(bid) {
                    threats.append(Threat(name: app.deletingPathExtension().lastPathComponent, kind: L("Aplicación"),
                                          level: .high, reason: LF("Aplicación no deseada conocida («%@»).", sig),
                                          files: [app]))
                }
            }
        }

        // Application Support folders
        for dir in [FS.lib("Application Support"), URL(fileURLWithPath: "/Library/Application Support")] {
            for item in FS.children(dir, hidden: true) {
                if let sig = matchesSignature(item.lastPathComponent) {
                    progress(item.path)
                    threats.append(Threat(name: item.lastPathComponent, kind: L("Datos de soporte"), level: .high,
                                          reason: LF("Carpeta de un software no deseado conocido («%@»).", sig),
                                          files: [item]))
                }
            }
        }

        // Downloads: fake installers
        let fakeNames = ["flashplayer", "flash player", "adobe flash", "video codec", "mediaplayer update"]
        for item in FS.children(FS.home.appendingPathComponent("Downloads"), hidden: false) {
            let n = item.lastPathComponent.lowercased()
            if let f = fakeNames.first(where: { n.contains($0) }) {
                threats.append(Threat(name: item.lastPathComponent, kind: L("Instalador descargado"), level: .medium,
                                      reason: LF("Los instaladores de «%@» son un vector habitual de malware en Mac.", f),
                                      files: [item]))
            } else if let sig = matchesSignature(n) {
                threats.append(Threat(name: item.lastPathComponent, kind: L("Instalador descargado"), level: .high,
                                      reason: LF("Instalador de software no deseado conocido («%@»).", sig), files: [item]))
            }
        }
        return threats.sorted { $0.level > $1.level }
    }

    static func remove(_ threats: [Threat]) -> (removed: Int, failed: Int) {
        var removed = 0, failed = 0
        let uid = getuid()
        var adminCommands: [String] = []
        for t in threats {
            switch t.domain {
            case .userAgent, .globalAgent:
                if let plist = t.files.first {
                    Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)", plist.path])
                }
            default: break
            }
            var ok = true
            for f in t.files {
                do { try FileManager.default.trashItem(at: f, resultingItemURL: nil) } catch {
                    ok = false
                    if t.domain == .daemon {
                        adminCommands.append("/bin/launchctl bootout system \(Shell.quote(f.path)) 2>/dev/null; /bin/rm -rf \(Shell.quote(f.path))")
                    } else {
                        adminCommands.append("/bin/rm -rf \(Shell.quote(f.path))")
                    }
                }
            }
            if ok { removed += 1 }
        }
        if !adminCommands.isEmpty {
            let r = Shell.admin(adminCommands.joined(separator: "; "))
            if r.ok { removed += adminCommands.count } else { failed += adminCommands.count }
        }
        return (removed, failed)
    }
}

// MARK: - Privacy

enum PrivacyCatalog {
    struct Browser {
        let name: String
        let bundleID: String
        let support: String   // relative to Application Support
        let caches: String    // relative to Caches
        let chromium: Bool
        let singleProfile: Bool
    }

    static let browsers: [Browser] = [
        Browser(name: L("Google Chrome"), bundleID: "com.google.Chrome", support: "Google/Chrome", caches: "Google/Chrome", chromium: true, singleProfile: false),
        Browser(name: L("Brave"), bundleID: "com.brave.Browser", support: "BraveSoftware/Brave-Browser", caches: "BraveSoftware/Brave-Browser", chromium: true, singleProfile: false),
        Browser(name: L("Microsoft Edge"), bundleID: "com.microsoft.edgemac", support: L("Microsoft Edge"), caches: L("Microsoft Edge"), chromium: true, singleProfile: false),
        Browser(name: L("Arc"), bundleID: "company.thebrowser.Browser", support: "Arc/User Data", caches: "Arc/User Data", chromium: true, singleProfile: false),
        Browser(name: L("Vivaldi"), bundleID: "com.vivaldi.Vivaldi", support: L("Vivaldi"), caches: L("Vivaldi"), chromium: true, singleProfile: false),
        Browser(name: L("Opera"), bundleID: "com.operasoftware.Opera", support: "com.operasoftware.Opera", caches: "com.operasoftware.Opera", chromium: true, singleProfile: true),
        Browser(name: L("Firefox"), bundleID: "org.mozilla.firefox", support: "Firefox/Profiles", caches: "Firefox/Profiles", chromium: false, singleProfile: false),
    ]

    static func fileItem(_ url: URL, _ label: String, selected: Bool = true) -> FileItem? {
        guard FS.exists(url) else { return nil }
        return FileItem(url: url, size: max(FS.size(of: url), 1), modified: FS.modified(url), selected: selected,
                        clearContentsOnly: FS.isDir(url), note: url.path.replacingOccurrences(of: FS.home.path, with: "~"),
                        displayName: label)
    }

    static func scan() -> [JunkCategory] {
        var cats: [JunkCategory] = []
        let support = FS.lib("Application Support")
        let caches = FS.lib("Caches")

        // Safari (requires Full Disk Access)
        if Permissions.hasFullDiskAccess {
            let safari = FS.lib("Safari")
            let container = FS.lib("Containers/com.apple.Safari/Data/Library")
            let items: [FileItem?] = [
                fileItem(safari.appendingPathComponent("History.db"), L("Historial de navegación")),
                fileItem(safari.appendingPathComponent("History.db-wal"), L("Historial (diario)")),
                fileItem(safari.appendingPathComponent("History.db-shm"), L("Historial (memoria)")),
                fileItem(safari.appendingPathComponent("Downloads.plist"), L("Historial de descargas")),
                fileItem(safari.appendingPathComponent("LastSession.plist"), L("Última sesión"), selected: false),
                fileItem(container.appendingPathComponent("Cookies/Cookies.binarycookies"), L("Cookies")),
                fileItem(FS.lib("Cookies/Cookies.binarycookies"), L("Cookies (heredadas)")),
                fileItem(container.appendingPathComponent("Caches"), L("Caché")),
                fileItem(caches.appendingPathComponent("com.apple.Safari"), L("Caché web")),
            ]
            let list = items.compactMap { $0 }
            if !list.isEmpty {
                cats.append(JunkCategory(id: "safari", title: L("Safari"), detail: L("Historial, cookies y caché de Safari. Cierra Safari antes de limpiar."),
                                         icon: "safari", items: list, mode: .permanent))
            }
        }

        for b in browsers {
            let base = support.appendingPathComponent(b.support)
            guard FS.isDir(base) else { continue }
            var list: [FileItem] = []
            let profiles: [URL]
            if b.singleProfile {
                profiles = [base]
            } else if b.chromium {
                profiles = FS.children(base, hidden: false).filter {
                    let n = $0.lastPathComponent
                    return n == "Default" || n.hasPrefix("Profile ")
                }
            } else {
                profiles = FS.children(base, hidden: false).filter(FS.isDir)
            }
            for p in profiles {
                let suffix = profiles.count > 1 ? " — \(p.lastPathComponent)" : ""
                if b.chromium {
                    let hist = ["History", "History-journal", "Visited Links", "Top Sites", "Top Sites-journal", "Shortcuts", "Shortcuts-journal"]
                    for f in hist {
                        if let i = fileItem(p.appendingPathComponent(f), LF("Historial (%@)", f) + suffix) { list.append(i) }
                    }
                    for f in [L("Cookies"), "Cookies-journal", "Network/Cookies", "Network/Cookies-journal"] {
                        if let i = fileItem(p.appendingPathComponent(f), L("Cookies") + suffix) { list.append(i) }
                    }
                    for f in ["Code Cache", "GPUCache", "Service Worker/CacheStorage"] {
                        if let i = fileItem(p.appendingPathComponent(f), LF("Caché (%@)", f) + suffix) { list.append(i) }
                    }
                    if let i = fileItem(p.appendingPathComponent("Web Data"), L("Datos de autocompletar") + suffix, selected: false) { list.append(i) }
                    let cacheDir = b.singleProfile ? caches.appendingPathComponent(b.caches) : caches.appendingPathComponent(b.caches).appendingPathComponent(p.lastPathComponent)
                    if let i = fileItem(cacheDir, L("Caché web") + suffix) { list.append(i) }
                } else {
                    for f in ["cookies.sqlite", "cookies.sqlite-wal"] {
                        if let i = fileItem(p.appendingPathComponent(f), L("Cookies") + suffix) { list.append(i) }
                    }
                    if let i = fileItem(p.appendingPathComponent("formhistory.sqlite"), L("Historial de formularios") + suffix) { list.append(i) }
                    if let i = fileItem(caches.appendingPathComponent(b.caches).appendingPathComponent(p.lastPathComponent).appendingPathComponent("cache2"), L("Caché web") + suffix) { list.append(i) }
                }
            }
            if !list.isEmpty {
                cats.append(JunkCategory(id: b.bundleID, title: b.name,
                                         detail: LF("Historial, cookies y caché de %@. Cerrar sesión en webs puede ser necesario después.", b.name),
                                         icon: "globe", items: list, mode: .permanent))
            }
        }

        // System traces
        var traces: [FileItem] = []
        let sfl = support.appendingPathComponent("com.apple.sharedfilelist")
        for f in FS.children(sfl, hidden: false) where f.lastPathComponent.contains("Recent") {
            if let i = fileItem(f, LF("Elementos recientes (%@)", f.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "com.apple.LSSharedFileList.", with: ""))) {
                traces.append(i)
            }
        }
        if let i = fileItem(FS.lib("Preferences/com.apple.LaunchServices.QuarantineEventsV2"), L("Registro de archivos descargados")) { traces.append(i) }
        if let i = fileItem(FS.home.appendingPathComponent(".zsh_history"), L("Historial de Terminal (zsh)"), selected: false) { traces.append(i) }
        if let i = fileItem(FS.home.appendingPathComponent(".bash_history"), L("Historial de Terminal (bash)"), selected: false) { traces.append(i) }
        if let i = fileItem(FS.home.appendingPathComponent(".zsh_sessions"), L("Sesiones de Terminal"), selected: false) { traces.append(i) }
        if !traces.isEmpty {
            cats.append(JunkCategory(id: "traces", title: L("Rastros del sistema"),
                                     detail: L("Listas de documentos y apps recientes, registro de descargas e historial de Terminal."),
                                     icon: "clock.arrow.circlepath", items: traces, mode: .permanent))
        }
        return cats
    }

    static func runningBrowsers(in cats: [JunkCategory]) -> [NSRunningApplication] {
        let ids = Set(cats.filter(\.anySelected).map(\.id) + (cats.contains { $0.id == "safari" && $0.anySelected } ? ["com.apple.Safari"] : []))
        return NSWorkspace.shared.runningApplications.filter { ids.contains($0.bundleIdentifier ?? "") }
    }
}

// MARK: - App permissions (TCC)

struct AppPermission: Identifiable, Hashable, Sendable {
    let service: String
    let client: String
    let allowed: Bool
    let systemDB: Bool
    var id: String { service + "|" + client }

    var serviceName: String { PermissionsCatalog.names[service] ?? service.replacingOccurrences(of: "kTCCService", with: "") }
    var serviceIcon: String { PermissionsCatalog.icons[service] ?? "lock" }
    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: client) }
    var appName: String {
        appURL.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? client
    }
}

enum PermissionsCatalog {
    static let names: [String: String] = [
        "kTCCServiceCamera": L("Cámara"), "kTCCServiceMicrophone": L("Micrófono"),
        "kTCCServiceScreenCapture": L("Grabación de pantalla"), "kTCCServiceAccessibility": L("Accesibilidad"),
        "kTCCServiceSystemPolicyAllFiles": L("Acceso total al disco"), "kTCCServiceListenEvent": L("Monitorización de entrada"),
        "kTCCServicePostEvent": L("Control del ordenador"), "kTCCServiceAddressBook": L("Contactos"),
        "kTCCServiceCalendar": L("Calendarios"), "kTCCServiceReminders": L("Recordatorios"), "kTCCServicePhotos": L("Fotos"),
        "kTCCServiceSystemPolicyDesktopFolder": L("Carpeta Escritorio"), "kTCCServiceSystemPolicyDocumentsFolder": L("Carpeta Documentos"),
        "kTCCServiceSystemPolicyDownloadsFolder": L("Carpeta Descargas"), "kTCCServiceAppleEvents": L("Automatización"),
        "kTCCServiceBluetoothAlways": L("Bluetooth"), "kTCCServiceSpeechRecognition": L("Reconocimiento de voz"),
        "kTCCServiceMediaLibrary": L("Música y multimedia"), "kTCCServiceSystemPolicyNetworkVolumes": L("Volúmenes de red"),
        "kTCCServiceSystemPolicyRemovableVolumes": L("Volúmenes extraíbles"), "kTCCServiceFileProviderDomain": L("Proveedores de archivos"),
        "kTCCServiceDeveloperTool": L("Herramientas de desarrollo"), "kTCCServiceLocation": L("Localización"),
    ]
    static let icons: [String: String] = [
        "kTCCServiceCamera": "camera", "kTCCServiceMicrophone": "mic", "kTCCServiceScreenCapture": "rectangle.dashed.badge.record",
        "kTCCServiceAccessibility": "accessibility", "kTCCServiceSystemPolicyAllFiles": "internaldrive",
        "kTCCServiceListenEvent": "keyboard", "kTCCServiceAddressBook": "person.crop.circle", "kTCCServiceCalendar": "calendar",
        "kTCCServiceReminders": "checklist", "kTCCServicePhotos": "photo", "kTCCServiceAppleEvents": "gearshape.2",
        "kTCCServiceBluetoothAlways": "dot.radiowaves.left.and.right", "kTCCServiceSystemPolicyDesktopFolder": "menubar.dock.rectangle",
        "kTCCServiceSystemPolicyDocumentsFolder": "doc", "kTCCServiceSystemPolicyDownloadsFolder": "arrow.down.circle",
    ]

    static func read() -> [AppPermission] {
        var out: [AppPermission] = []
        let dbs = [(FS.lib("Application Support/com.apple.TCC/TCC.db").path, false),
                   ("/Library/Application Support/com.apple.TCC/TCC.db", true)]
        for (db, system) in dbs {
            let r = Shell.run("/usr/bin/sqlite3", ["-readonly", "-separator", "|", db,
                                                   "SELECT service, client, auth_value FROM access WHERE client_type = 0;"])
            guard r.ok else { continue }
            for line in r.output.split(separator: "\n") {
                let p = line.split(separator: "|").map(String.init)
                guard p.count == 3, names[p[0]] != nil else { continue }
                out.append(AppPermission(service: p[0], client: p[1], allowed: p[2] == "2", systemDB: system))
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }
    }

    static func revoke(_ p: AppPermission) -> Bool {
        let service = p.service.replacingOccurrences(of: "kTCCService", with: "")
        if Shell.run("/usr/bin/tccutil", ["reset", service, p.client]).ok { return true }
        return Shell.admin("/usr/bin/tccutil reset \(service) \(Shell.quote(p.client))").ok
    }
}

// MARK: - Model

@MainActor
@Observable
final class ProtectionModel {
    enum Tab: String, CaseIterable, Identifiable {
        case malware, privacy, permissions
        var id: String { rawValue }
        var title: String {
            switch self {
            case .malware: L("Eliminación de malware")
            case .privacy: L("Privacidad")
            case .permissions: L("Permisos de apps")
            }
        }
    }

    var tab: Tab = .malware

    // Malware
    var malwarePhase: ModulePhase = .idle
    var threats: [Threat] = []
    var scanningPath = ""
    var lastScan: Date?
    var removedCount = 0
    var failedCount = 0

    // Privacy
    var privacyPhase: ModulePhase = .idle
    var privacy: [JunkCategory] = []
    var privacyResult = RemovalResult()

    // Permissions
    var permissions: [AppPermission] = []
    var permissionsLoaded = false

    var selectedThreats: [Threat] { threats.filter(\.selected) }

    func scanMalware() async {
        malwarePhase = .scanning
        let found = await Task.detached(priority: .userInitiated) {
            MalwareScanner.scan { path in
                Task { @MainActor in AppState.shared.protection.scanningPath = path }
            }
        }.value
        threats = found
        lastScan = Date()
        malwarePhase = .results
    }

    func removeThreats() async {
        let sel = selectedThreats
        malwarePhase = .working
        let r = await Task.detached { MalwareScanner.remove(sel) }.value
        removedCount = r.removed
        failedCount = r.failed
        threats.removeAll { t in sel.contains { $0.id == t.id } }
        malwarePhase = .done
    }

    func scanPrivacy() async {
        privacyPhase = .scanning
        privacy = await Task.detached(priority: .userInitiated) { PrivacyCatalog.scan() }.value
        privacyPhase = .results
    }

    func cleanPrivacy() async {
        let running = PrivacyCatalog.runningBrowsers(in: privacy)
        if !running.isEmpty {
            let names = running.compactMap(\.localizedName).joined(separator: ", ")
            guard Confirm.ask(L("Cerrar navegadores"), LF("Para limpiar sus datos hay que cerrar: %@.", names), confirm: L("Cerrar y limpiar")) else { return }
            running.forEach { $0.terminate() }
            try? await Task.sleep(for: .seconds(2))
        }
        privacyPhase = .working
        let items = privacy.flatMap { $0.items.filter(\.selected) }
        privacyResult = await Task.detached { FS.remove(items, mode: .permanent) }.value
        Shell.run("/usr/bin/killall", ["sharedfilelistd"])
        privacyPhase = .done
    }

    func loadPermissions() async {
        permissions = await Task.detached { PermissionsCatalog.read() }.value
            .sorted { ($0.serviceName, $0.appName) < ($1.serviceName, $1.appName) }
        permissionsLoaded = true
    }

    func revoke(_ p: AppPermission) async {
        let ok = await Task.detached { PermissionsCatalog.revoke(p) }.value
        if ok { permissions.removeAll { $0.id == p.id } }
    }
}

// MARK: - Views

struct ProtectionView: View {
    @Bindable var model: ProtectionModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TabPicker(items: ProtectionModel.Tab.allCases, selection: $model.tab) { $0.title }
            }
            .padding(.top, 16)
            FullDiskAccessBanner()
            switch model.tab {
            case .malware: MalwareSection(model: model)
            case .privacy: PrivacySection(model: model)
            case .permissions: PermissionsSection(model: model)
            }
        }
    }
}

private struct MalwareSection: View {
    @Bindable var model: ProtectionModel

    var body: some View {
        switch model.malwarePhase {
        case .idle:
            ModuleHero(module: .protection, actionTitle: L("Analizar")) { Task { await model.scanMalware() } }
        case .scanning:
            WorkingView(module: .protection, title: L("Buscando amenazas…"), detail: model.scanningPath)
        case .results:
            if model.threats.isEmpty {
                DoneView(module: .protection, title: L("No se encontraron amenazas"),
                         subtitle: L("Revisamos agentes de inicio, aplicaciones y descargas.")) { model.malwarePhase = .idle }
            } else {
                VStack(spacing: 0) {
                    ModuleHeader(module: .protection, title: LF("%@ elementos requieren tu atención", model.threats.count),
                                 subtitle: L("Revisa cada hallazgo antes de eliminarlo.")) {
                        Button(L("Volver a analizar")) { Task { await model.scanMalware() } }.buttonStyle(PillButtonStyle())
                    }
                    List {
                        ForEach($model.threats) { $t in
                            HStack(alignment: .top, spacing: 12) {
                                CheckCircle(isOn: $t.selected)
                                Image(systemName: t.level == .high ? "ladybug.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(t.level.color)
                                    .font(.title3)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(t.name).font(.headline)
                                        Text(t.level.title)
                                            .font(.caption.bold())
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(t.level.color.opacity(0.3), in: Capsule())
                                        Text(t.kind).font(.caption).foregroundStyle(.white.opacity(0.6))
                                    }
                                    Text(t.reason).font(.callout).foregroundStyle(.white.opacity(0.8))
                                    ForEach(t.files, id: \.self) { f in
                                        Text(f.path).font(.caption.monospaced()).foregroundStyle(.white.opacity(0.5))
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                }
                                Spacer()
                                if let f = t.files.first {
                                    Button { FS.reveal(f) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 6)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    ActionBar(module: .protection, summary: LF("%@ seleccionados", model.selectedThreats.count),
                              buttonTitle: L("Eliminar"), enabled: !model.selectedThreats.isEmpty) {
                        Task { await model.removeThreats() }
                    }
                }
            }
        case .working:
            WorkingView(module: .protection, title: L("Eliminando amenazas…"))
        case .done:
            DoneView(module: .protection, title: L("Amenazas eliminadas"),
                     subtitle: LF("%@ elementos movidos a la Papelera o eliminados.", model.removedCount),
                     failures: model.failedCount) { model.malwarePhase = .idle }
        }
    }
}

private struct PrivacySection: View {
    @Bindable var model: ProtectionModel

    var body: some View {
        switch model.privacyPhase {
        case .idle:
            VStack(spacing: 20) {
                Spacer()
                ModuleGlyph(module: .protection, size: 130)
                Text(L("Privacidad")).font(.largeTitle.bold())
                Text(L("Borra historial de navegación, cookies, cachés, la lista de elementos recientes\ny el registro de descargas del sistema."))
                    .multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.75))
                Spacer()
                RoundActionButton(title: L("Analizar"), module: .protection) { Task { await model.scanPrivacy() } }
                    .padding(.bottom, 30)
            }
        case .scanning:
            WorkingView(module: .protection, title: L("Buscando rastros de privacidad…"))
        case .results:
            VStack(spacing: 0) {
                ModuleHeader(module: .protection, title: L("Datos de privacidad"),
                             subtitle: L("Selecciona qué rastros quieres borrar.")) {
                    Button(L("Volver a analizar")) { Task { await model.scanPrivacy() } }.buttonStyle(PillButtonStyle())
                }
                CategoryResultsView(categories: $model.privacy)
                ActionBar(module: .protection,
                          summary: LF("%@ elementos seleccionados", model.privacy.reduce(0) { $0 + $1.selectedCount }),
                          buttonTitle: L("Borrar"), enabled: model.privacy.contains(where: \.anySelected)) {
                    Task { await model.cleanPrivacy() }
                }
            }
        case .working:
            WorkingView(module: .protection, title: L("Borrando rastros…"))
        case .done:
            DoneView(module: .protection, title: L("Rastros eliminados"),
                     subtitle: LF("%@ elementos borrados.", model.privacyResult.removed),
                     failures: model.privacyResult.failed.count) { model.privacyPhase = .idle }
        }
    }
}

private struct PermissionsSection: View {
    @Bindable var model: ProtectionModel

    var grouped: [(String, [AppPermission])] {
        Dictionary(grouping: model.permissions, by: \.serviceName).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .protection, title: L("Permisos de apps"),
                         subtitle: L("Apps con acceso a cámara, micrófono, pantalla, archivos y más.")) {
                Button(L("Actualizar")) { Task { await model.loadPermissions() } }.buttonStyle(PillButtonStyle())
            }
            if !Permissions.hasFullDiskAccess {
                Text(L("Se necesita Acceso total al disco para leer los permisos concedidos."))
                    .foregroundStyle(.white.opacity(0.7)).padding()
                Spacer()
            } else if model.permissions.isEmpty && model.permissionsLoaded {
                Text(L("No se encontraron permisos concedidos.")).foregroundStyle(.white.opacity(0.7)).padding()
                Spacer()
            } else {
                List {
                    ForEach(grouped, id: \.0) { service, perms in
                        Section {
                            ForEach(perms) { p in
                                HStack(spacing: 10) {
                                    if let u = p.appURL { FileIconView(url: u, size: 24) } else { Image(systemName: "app").frame(width: 24) }
                                    Text(p.appName)
                                    Spacer()
                                    Text(p.allowed ? L("Permitido") : L("Denegado"))
                                        .font(.caption).foregroundStyle(p.allowed ? .green : .white.opacity(0.5))
                                    Button(L("Revocar")) { Task { await model.revoke(p) } }
                                        .buttonStyle(SmallButtonStyle())
                                }
                            }
                        } header: {
                            Label(service, systemImage: perms.first?.serviceIcon ?? "lock")
                                .font(.headline).foregroundStyle(.white)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .task { if !model.permissionsLoaded { await model.loadPermissions() } }
    }
}
