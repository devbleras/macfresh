import AppKit
import Foundation
import Security
import SwiftUI

struct AppInfo: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let bundleID: String
    let version: String
    let build: String
    let isAppStore: Bool
    let sparkleFeed: String?
    var size: Int64 = 0
    var lastUsed: Date?
    var id: URL { url }

    var unused: Bool {
        guard let lastUsed else { return true }
        return lastUsed < Date().addingTimeInterval(-90 * 86400)
    }
}

struct AppUpdate: Identifiable, Sendable {
    let app: AppInfo
    let newVersion: String
    let source: String
    let storeURL: URL?
    let downloadURL: URL?
    var notes: String?
    var id: URL { app.url }
}

// MARK: - Scanning

enum AppScanner {
    static let roots = [URL(fileURLWithPath: "/Applications"), FS.home.appendingPathComponent("Applications")]

    static func listApps() -> [AppInfo] {
        var urls: [URL] = []
        for root in roots {
            for item in FS.children(root, hidden: false) {
                if item.pathExtension == "app" {
                    urls.append(item)
                } else if FS.isDir(item) {
                    urls += FS.children(item, hidden: false).filter { $0.pathExtension == "app" }
                }
            }
        }
        return urls.compactMap(info).sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    static func info(_ url: URL) -> AppInfo? {
        guard let b = Bundle(url: url), let bid = b.bundleIdentifier else { return nil }
        let isStore = FS.exists(url.appendingPathComponent("Contents/_MASReceipt/receipt"))
        // Built-in Apple apps are protected by the system.
        if bid.hasPrefix("com.apple.") && !isStore { return nil }
        let info = b.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let lastUsed = NSMetadataItem(url: url)?.value(forAttribute: "kMDItemLastUsedDate") as? Date
        return AppInfo(url: url, name: url.deletingPathExtension().lastPathComponent.isEmpty ? name : url.deletingPathExtension().lastPathComponent,
                       bundleID: bid,
                       version: info["CFBundleShortVersionString"] as? String ?? "",
                       build: info["CFBundleVersion"] as? String ?? "",
                       isAppStore: isStore,
                       sparkleFeed: info["SUFeedURL"] as? String,
                       lastUsed: lastUsed)
    }

    static let leftoverDirs = [
        "Application Support", "Caches", "Preferences", "Preferences/ByHost", "Containers", "Group Containers",
        "Saved Application State", "Logs", "HTTPStorages", "WebKit", L("Cookies"), "Application Scripts", "LaunchAgents",
    ]
    static let systemLeftoverDirs = [
        "/Library/Application Support", "/Library/Caches", "/Library/Preferences", "/Library/LaunchAgents",
        "/Library/LaunchDaemons", "/Library/PrivilegedHelperTools", "/Library/Logs",
    ]

    static func leftovers(for app: AppInfo) -> [FileItem] {
        let bid = app.bundleID.lowercased()
        let name = app.name.lowercased()
        let compactName = name.replacingOccurrences(of: " ", with: "")
        func matches(_ entry: URL, groupContainer: Bool) -> Bool {
            var n = entry.lastPathComponent.lowercased()
            for ext in [".plist", ".savedstate", ".binarycookies"] where n.hasSuffix(ext) { n = String(n.dropLast(ext.count)) }
            if n == bid || n.hasPrefix(bid + ".") { return true }
            if groupContainer && n.contains(bid) { return true }
            if name.count >= 4 && (n == name || n == compactName) { return true }
            return false
        }
        var out: [FileItem] = []
        var dirs = leftoverDirs.map { FS.lib($0) }
        dirs += systemLeftoverDirs.map { URL(fileURLWithPath: $0) }
        for dir in dirs {
            let isGroup = dir.lastPathComponent == "Group Containers"
            for entry in FS.children(dir, hidden: false) where matches(entry, groupContainer: isGroup) {
                let rel = entry.path.replacingOccurrences(of: FS.home.path, with: "~")
                out.append(FileItem(url: entry, size: FS.size(of: entry), modified: FS.modified(entry),
                                    note: rel))
            }
        }
        return out.sorted { $0.size > $1.size }
    }

    static func installedBundleIDs() -> Set<String> {
        let r = Shell.run("/usr/bin/mdfind", ["kMDItemContentType == 'com.apple.application-bundle'"])
        var ids = Set<String>()
        for line in r.output.split(separator: "\n") {
            if let id = Bundle(path: String(line))?.bundleIdentifier { ids.insert(id.lowercased()) }
        }
        for app in listApps() { ids.insert(app.bundleID.lowercased()) }
        return ids
    }

    static let tlds: Set<String> = ["com", "org", "net", "io", "de", "ru", "co", "me", "app", "us", "uk", "fr", "es",
                                    "jp", "ch", "ai", "dev", "tv", "info", "cc", "at", "nl", "se", "it", "eu", "pl", "ca", "cn", "company"]

    /// Support files from apps that are no longer installed.
    static func orphans() -> [FileItem] {
        let installed = installedBundleIDs()
        let vendors = Set(installed.map { $0.split(separator: ".").prefix(2).joined(separator: ".") })
        var out: [FileItem] = []
        let dirs = ["Containers", "Application Support", "Caches", "Preferences", "Saved Application State",
                    "HTTPStorages", "WebKit", "Application Scripts"]
        for d in dirs {
            for entry in FS.children(FS.lib(d), hidden: false) {
                var n = entry.lastPathComponent.lowercased()
                for ext in [".plist", ".savedstate", ".binarycookies"] where n.hasSuffix(ext) { n = String(n.dropLast(ext.count)) }
                let parts = n.split(separator: ".")
                guard parts.count >= 3, tlds.contains(String(parts[0])), !n.hasPrefix("com.apple"),
                      !n.contains("macfresh") else { continue }
                let vendor = parts.prefix(2).joined(separator: ".")
                if installed.contains(n) || vendors.contains(vendor) { continue }
                if installed.contains(where: { n.hasPrefix($0) }) { continue }
                let size = FS.size(of: entry)
                out.append(FileItem(url: entry, size: size, modified: FS.modified(entry), selected: false,
                                    note: "\(d) · \(Fmt.date(FS.modified(entry)))", displayName: entry.lastPathComponent))
            }
        }
        return out.sorted { $0.size > $1.size }
    }

    static func teamID(_ url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

// MARK: - Updates

enum UpdateChecker {
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let pa = a.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        let pb = b.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    static func check(_ app: AppInfo) async -> AppUpdate? {
        if app.isAppStore { return await checkStore(app) }
        if let feed = app.sparkleFeed, let url = URL(string: feed) { return await checkSparkle(app, url) }
        return nil
    }

    static func checkStore(_ app: AppInfo) async -> AppUpdate? {
        let country = Locale.current.region?.identifier.lowercased() ?? "us"
        guard let url = URL(string: "https://itunes.apple.com/lookup?bundleId=\(app.bundleID)&country=\(country)&entity=macSoftware"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let r = (json["results"] as? [[String: Any]])?.first,
              let v = r["version"] as? String else { return nil }
        guard compare(app.version, v) == .orderedAscending else { return nil }
        let trackID = r["trackId"] as? Int
        return AppUpdate(app: app, newVersion: v, source: L("App Store"),
                         storeURL: trackID.flatMap { URL(string: "macappstore://apps.apple.com/app/id\($0)") },
                         downloadURL: nil, notes: r["releaseNotes"] as? String)
    }

    static func checkSparkle(_ app: AppInfo, _ feed: URL) async -> AppUpdate? {
        var req = URLRequest(url: feed, timeoutInterval: 15)
        req.setValue("MacFresh/1.0 Sparkle", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        let xml = String(decoding: data, as: UTF8.self)
        // Parse each <item> separately so versions and enclosures stay paired.
        var best: (short: String, build: String, url: URL?)?
        for chunk in xml.components(separatedBy: "<item").dropFirst() {
            let item = chunk.components(separatedBy: "</item>").first ?? chunk
            let short = firstMatch(item, #"sparkle:shortVersionString="([^"]+)""#)
                ?? firstMatch(item, #"<sparkle:shortVersionString>([^<]+)<"#)
            let build = firstMatch(item, #"sparkle:version="([^"]+)""#) ?? firstMatch(item, #"<sparkle:version>([^<]+)<"#) ?? short ?? ""
            let enclosure = firstMatch(item, #"<enclosure[^>]*url="([^"]+)""#).flatMap(URL.init(string:))
            let os = firstMatch(item, #"sparkle:os="([^"]+)""#)
            if let os, os != "macos" { continue }
            // Skip beta / pre-release channels.
            if item.contains("<sparkle:channel>") { continue }
            let lower = (short ?? build).lowercased()
            if ["alpha", "beta", "rc", "pre", "dev", "nightly"].contains(where: { lower.contains($0) }) { continue }
            let candidate = (short ?? build, build, enclosure)
            if best == nil || compare(best!.build, build) == .orderedAscending { best = candidate }
        }
        guard let best else { return nil }
        // Prefer the marketing version; fall back to the build number when the feed has no short version.
        let newer = best.short != best.build
            ? compare(app.version, best.short) == .orderedAscending
            : compare(app.build, best.build) == .orderedAscending
        guard newer else { return nil }
        return AppUpdate(app: app, newVersion: best.short, source: L("Web (Sparkle)"), storeURL: nil, downloadURL: best.url)
    }

    private static func firstMatch(_ s: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum InstallError: LocalizedError {
        case download, noApp, signature, replace(String), unsupported
        var errorDescription: String? {
            switch self {
            case .download: L("No se pudo descargar la actualización.")
            case .noApp: L("El archivo descargado no contiene la aplicación.")
            case .signature: L("La firma del desarrollador no coincide con la app instalada. Actualización cancelada por seguridad.")
            case .replace(let s): LF("No se pudo reemplazar la app: %@", s)
            case .unsupported: L("Formato de actualización no compatible; se abrió la descarga en el navegador.")
            }
        }
    }

    /// Downloads a Sparkle update (zip / dmg), verifies the developer signature matches and replaces the app.
    static func install(_ update: AppUpdate) async throws {
        guard let remote = update.downloadURL else { throw InstallError.download }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("MacFresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        guard let (tmp, _) = try? await URLSession.shared.download(from: remote) else { throw InstallError.download }
        let file = work.appendingPathComponent(remote.lastPathComponent.isEmpty ? "update" : remote.lastPathComponent)
        try FileManager.default.moveItem(at: tmp, to: file)
        let ext = file.pathExtension.lowercased()
        let extracted = work.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        var mount: String?
        switch ext {
        case "zip":
            guard Shell.run("/usr/bin/ditto", ["-x", "-k", file.path, extracted.path]).ok else { throw InstallError.noApp }
        case "dmg":
            let mp = work.appendingPathComponent("mnt").path
            guard Shell.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-noverify", "-noautoopen", "-mountpoint", mp, file.path]).ok
            else { throw InstallError.noApp }
            mount = mp
            for app in FS.children(URL(fileURLWithPath: mp), hidden: false) where app.pathExtension == "app" {
                Shell.run("/usr/bin/ditto", [app.path, extracted.appendingPathComponent(app.lastPathComponent).path])
            }
        case "tar", "gz", "tgz", "bz2", "xz":
            Shell.run("/usr/bin/tar", ["-xf", file.path, "-C", extracted.path])
        default:
            NSWorkspace.shared.open(remote)
            throw InstallError.unsupported
        }
        defer { if let mount { Shell.run("/usr/bin/hdiutil", ["detach", "-force", mount]) } }
        guard let newApp = findApp(in: extracted, bundleID: update.app.bundleID) else { throw InstallError.noApp }
        let oldTeam = AppScanner.teamID(update.app.url)
        let newTeam = AppScanner.teamID(newApp)
        guard let newTeam, oldTeam == nil || oldTeam == newTeam, MalwareScanner.isValidlySigned(newApp) else {
            throw InstallError.signature
        }
        for running in NSWorkspace.shared.runningApplications where running.bundleIdentifier == update.app.bundleID {
            running.terminate()
        }
        try? await Task.sleep(for: .seconds(1.5))
        do {
            try FileManager.default.trashItem(at: update.app.url, resultingItemURL: nil)
            try FileManager.default.copyItem(at: newApp, to: update.app.url)
        } catch {
            let r = Shell.admin("/bin/rm -rf \(Shell.quote(update.app.url.path)) && /usr/bin/ditto \(Shell.quote(newApp.path)) \(Shell.quote(update.app.url.path))")
            if !r.ok { throw InstallError.replace(r.output) }
        }
        Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", update.app.url.path])
    }

    private static func findApp(in dir: URL, bundleID: String) -> URL? {
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil,
                                                      options: [.skipsPackageDescendants]) else { return nil }
        while let u = en.nextObject() as? URL {
            if u.pathExtension == "app", Bundle(url: u)?.bundleIdentifier == bundleID { return u }
        }
        return nil
    }
}

// MARK: - Extensions

struct ExtensionItem: Identifiable, Sendable {
    let url: URL?
    let identifier: String
    let name: String
    let kind: String
    var enabled: Bool
    let toggleable: Bool
    var id: String { (url?.path ?? "") + identifier }
}

enum ExtensionScanner {
    static func scan() -> [ExtensionItem] {
        var out: [ExtensionItem] = []
        let kinds: [(String, String, String)] = [
            ("PreferencePanes", "prefPane", L("Panel de ajustes")),
            ("Internet Plug-Ins", "plugin", L("Plug-in de internet")),
            ("QuickLook", "qlgenerator", L("Plug-in de Quick Look")),
            ("Spotlight", "mdimporter", L("Importador de Spotlight")),
            ("Screen Savers", "saver", L("Salvapantallas")),
            ("Audio/Plug-Ins/Components", "component", L("Plug-in de audio (AU)")),
            ("Audio/Plug-Ins/VST", "vst", L("Plug-in de audio (VST)")),
            ("Audio/Plug-Ins/VST3", "vst3", L("Plug-in de audio (VST3)")),
            ("Audio/Plug-Ins/HAL", "driver", L("Controlador de audio")),
        ]
        for (dir, ext, kind) in kinds {
            for base in [FS.lib(dir), URL(fileURLWithPath: "/Library/\(dir)")] {
                for item in FS.children(base, hidden: false) where item.pathExtension.lowercased() == ext.lowercased() {
                    out.append(ExtensionItem(url: item, identifier: Bundle(url: item)?.bundleIdentifier ?? "",
                                             name: item.deletingPathExtension().lastPathComponent, kind: kind,
                                             enabled: true, toggleable: false))
                }
            }
        }
        // Safari and Finder/Share app extensions via pluginkit
        let points = [("com.apple.Safari.web-extension", L("Extensión de Safari")),
                      ("com.apple.Safari.extension", L("Extensión de Safari")),
                      ("com.apple.FinderSync", L("Extensión del Finder")),
                      ("com.apple.share-services", L("Extensión de compartir"))]
        for (point, kind) in points {
            let r = Shell.run("/usr/bin/pluginkit", ["-mAv", "-p", point])
            for line in r.output.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let first = trimmed.first else { continue }
                let state = first
                let body = "+-!=?".contains(state) ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces) : trimmed
                let fields = body.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
                guard let idField = fields.first else { continue }
                let ident = idField.components(separatedBy: "(").first ?? idField
                let path = fields.last.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
                if ident.hasPrefix("com.apple.") { continue }
                let name = path.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".appex", with: "") } ?? ident
                out.append(ExtensionItem(url: path, identifier: ident, name: name, kind: kind,
                                         enabled: state != "-", toggleable: true))
            }
        }
        return out.sorted { ($0.kind, $0.name) < ($1.kind, $1.name) }
    }

    static func setEnabled(_ item: ExtensionItem, _ on: Bool) -> Bool {
        Shell.run("/usr/bin/pluginkit", ["-e", on ? "use" : "ignore", "-i", item.identifier]).ok
    }
}

// MARK: - Model

@MainActor
@Observable
final class ApplicationsModel {
    enum Tab: String, CaseIterable, Identifiable {
        case uninstaller, updater, extensions, leftovers
        var id: String { rawValue }
        var title: String {
            switch self {
            case .uninstaller: L("Desinstalador")
            case .updater: L("Actualizador")
            case .extensions: L("Extensiones")
            case .leftovers: L("Restos")
            }
        }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all, unused, store, other
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: L("Todas")
            case .unused: L("Sin usar (90 días)")
            case .store: L("App Store")
            case .other: L("Otras")
            }
        }
    }

    var tab: Tab = .uninstaller
    var filter: Filter = .all
    var search = ""
    var apps: [AppInfo] = []
    var loaded = false
    var loading = false
    var selectedApp: AppInfo?
    var appFiles: [FileItem] = []
    var loadingFiles = false
    var busy = false

    var updates: [AppUpdate] = []
    var checkingUpdates = false
    var updatesChecked = false
    var installing: Set<URL> = []
    var updateMessage: String?

    var extensions: [ExtensionItem] = []
    var extensionsLoaded = false

    var orphanCats: [JunkCategory] = []
    var orphanPhase: ModulePhase = .idle
    var orphanResult = RemovalResult()

    var filteredApps: [AppInfo] {
        apps.filter { a in
            let f: Bool = switch filter {
            case .all: true
            case .unused: a.unused
            case .store: a.isAppStore
            case .other: !a.isAppStore
            }
            return f && (search.isEmpty || a.name.localizedCaseInsensitiveContains(search))
        }
    }

    func load() async {
        guard !loading else { return }
        loading = true
        apps = await Task.detached { AppScanner.listApps() }.value
        loaded = true
        loading = false
        // Compute sizes progressively.
        let list = apps
        await withTaskGroup(of: (URL, Int64).self) { group in
            var it = list.makeIterator()
            for _ in 0..<4 {
                if let a = it.next() { group.addTask { (a.url, FS.size(of: a.url)) } }
            }
            while let (url, size) = await group.next() {
                if let i = apps.firstIndex(where: { $0.url == url }) { apps[i].size = size }
                if let a = it.next() { group.addTask { (a.url, FS.size(of: a.url)) } }
            }
        }
    }

    func select(_ app: AppInfo) async {
        selectedApp = app
        loadingFiles = true
        appFiles = []
        let files = await Task.detached { AppScanner.leftovers(for: app) }.value
        guard selectedApp?.id == app.id else { return }
        var bundle = FileItem(url: app.url, size: app.size > 0 ? app.size : FS.size(of: app.url), modified: FS.modified(app.url))
        bundle.note = L("Aplicación")
        appFiles = [bundle] + files
        loadingFiles = false
    }

    var selectedFilesSize: Int64 { appFiles.filter(\.selected).reduce(0) { $0 + $1.size } }

    func uninstall(resetOnly: Bool = false) async {
        guard let app = selectedApp else { return }
        var items = appFiles.filter(\.selected)
        if resetOnly { items.removeAll { $0.url == app.url } }
        guard !items.isEmpty else { return }
        guard Confirm.ask(resetOnly ? LF("¿Restablecer %@?", app.name) : LF("¿Desinstalar %@?", app.name),
                          LF("%@ elementos (%@) se moverán a la Papelera.", items.count, Fmt.bytes(items.reduce(0) { $0 + $1.size })),
                          confirm: resetOnly ? L("Restablecer") : L("Desinstalar")) else { return }
        for r in NSWorkspace.shared.runningApplications where r.bundleIdentifier == app.bundleID { r.terminate() }
        busy = true
        let result = await Task.detached { () -> RemovalResult in
            var r = FS.remove(items, mode: .trash)
            // Root-owned leftovers (/Library) need admin rights.
            let rootOwned = r.failed.filter { FS.isSafeToRemove($0) && !$0.path.hasPrefix(FS.home.path) || $0 == app.url }
            if !rootOwned.isEmpty {
                let cmd = rootOwned.map { "/bin/rm -rf \(Shell.quote($0.path))" }.joined(separator: "; ")
                if Shell.admin(cmd).ok {
                    r.removed += rootOwned.count
                    r.failed.removeAll { rootOwned.contains($0) }
                }
            }
            return r
        }.value
        busy = false
        if !resetOnly && !FS.exists(app.url) {
            apps.removeAll { $0.id == app.id }
            selectedApp = nil
            appFiles = []
        } else {
            await select(app)
        }
        Confirm.info(resetOnly ? L("App restablecida") : L("App desinstalada"),
                     LF("Se liberaron %@.%@", Fmt.bytes(result.freed), result.failed.isEmpty ? "" : LF(" %@ elementos no se pudieron eliminar.", result.failed.count)))
    }

    func checkUpdates() async {
        if !loaded { await load() }
        checkingUpdates = true
        updates = []
        let candidates = apps.filter { $0.isAppStore || $0.sparkleFeed != nil }
        await withTaskGroup(of: AppUpdate?.self) { group in
            var it = candidates.makeIterator()
            for _ in 0..<6 { if let a = it.next() { group.addTask { await UpdateChecker.check(a) } } }
            while let r = await group.next() {
                if let r { updates.append(r) }
                if let a = it.next() { group.addTask { await UpdateChecker.check(a) } }
            }
        }
        updates.sort { $0.app.name < $1.app.name }
        checkingUpdates = false
        updatesChecked = true
    }

    func install(_ u: AppUpdate) async {
        if let store = u.storeURL {
            NSWorkspace.shared.open(store)
            return
        }
        installing.insert(u.id)
        do {
            try await UpdateChecker.install(u)
            updates.removeAll { $0.id == u.id }
            updateMessage = LF("%@ se actualizó a la versión %@.", u.app.name, u.newVersion)
            if let fresh = AppScanner.info(u.app.url), let i = apps.firstIndex(where: { $0.id == u.id }) { apps[i] = fresh }
        } catch {
            updateMessage = "\(u.app.name): \(error.localizedDescription)"
        }
        installing.remove(u.id)
    }

    func loadExtensions() async {
        extensions = await Task.detached { ExtensionScanner.scan() }.value
        extensionsLoaded = true
    }

    func toggle(_ e: ExtensionItem) async {
        let target = !e.enabled
        if await Task.detached(operation: { ExtensionScanner.setEnabled(e, target) }).value,
           let i = extensions.firstIndex(where: { $0.id == e.id }) {
            extensions[i].enabled = target
        }
    }

    func removeExtension(_ e: ExtensionItem) async {
        guard let url = e.url, Confirm.ask(LF("¿Eliminar %@?", e.name), L("Se moverá a la Papelera.")) else { return }
        let item = FileItem(url: url, size: 0)
        var r = await Task.detached { FS.remove([item], mode: .trash) }.value
        if !r.failed.isEmpty, Shell.admin("/bin/rm -rf \(Shell.quote(url.path))").ok { r.failed = [] }
        if r.failed.isEmpty { extensions.removeAll { $0.id == e.id } }
    }

    func scanOrphans() async {
        orphanPhase = .scanning
        let items = await Task.detached { AppScanner.orphans() }.value
        orphanCats = items.isEmpty ? [] : [JunkCategory(id: "orphans", title: L("Restos de apps eliminadas"),
                                                        detail: L("Archivos de soporte de apps que ya no están instaladas. Revisa antes de borrar."),
                                                        icon: "questionmark.folder", items: items, mode: .trash, defaultSelected: false)]
        orphanPhase = .results
    }

    func removeOrphans() async {
        orphanPhase = .working
        let items = orphanCats.flatMap { $0.items.filter(\.selected) }
        orphanResult = await Task.detached { FS.remove(items, mode: .trash) }.value
        orphanPhase = .done
    }
}

// MARK: - Views

struct ApplicationsView: View {
    @Bindable var model: ApplicationsModel

    var body: some View {
        VStack(spacing: 0) {
            TabPicker(items: ApplicationsModel.Tab.allCases, selection: $model.tab) { $0.title }
                .padding(.top, 16)
            switch model.tab {
            case .uninstaller: UninstallerSection(model: model)
            case .updater: UpdaterSection(model: model)
            case .extensions: ExtensionsSection(model: model)
            case .leftovers: OrphansSection(model: model)
            }
        }
        .task { if !model.loaded { await model.load() } }
    }
}

private struct UninstallerSection: View {
    @Bindable var model: ApplicationsModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.6))
                    TextField(L("Buscar apps"), text: $model.search).textFieldStyle(.plain)
                }
                .padding(8)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                Picker("", selection: $model.filter) {
                    ForEach(ApplicationsModel.Filter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                if model.loading {
                    ProgressView().padding()
                }
                List(model.filteredApps, selection: Binding(get: { model.selectedApp?.id }, set: { id in
                    if let id, let app = model.apps.first(where: { $0.id == id }) { Task { await model.select(app) } }
                })) { app in
                    HStack(spacing: 8) {
                        FileIconView(url: app.url, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.name).lineLimit(1)
                            Text(app.lastUsed.map { LF("Usada %@", Fmt.relative($0)) } ?? L("Sin uso registrado"))
                                .font(.caption2).foregroundStyle(.white.opacity(0.5))
                        }
                        Spacer()
                        Text(app.size > 0 ? Fmt.bytes(app.size) : "…").font(.caption).monospacedDigit()
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .tag(app.id)
                }
                .scrollContentBackground(.hidden)
                Text(LF("%@ apps · %@", model.filteredApps.count, Fmt.bytes(model.filteredApps.reduce(0) { $0 + $1.size })))
                    .font(.caption).foregroundStyle(.white.opacity(0.6)).padding(.bottom, 8)
            }
            .padding(12)
            .frame(width: 330)
            .background(.black.opacity(0.12))

            if let app = model.selectedApp {
                VStack(spacing: 0) {
                    HStack(spacing: 14) {
                        FileIconView(url: app.url, size: 64)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.name).font(.title.bold())
                            Text(LF("Versión %@ · %@ · %@", app.version, app.isAppStore ? L("App Store") : L("Otra fuente"), app.bundleID))
                                .font(.caption).foregroundStyle(.white.opacity(0.65))
                            Text(LF("Último uso: %@", Fmt.relative(app.lastUsed))).font(.caption).foregroundStyle(.white.opacity(0.65))
                        }
                        Spacer()
                    }
                    .padding(20)
                    if model.loadingFiles {
                        ProgressView(L("Buscando archivos relacionados…")).padding()
                        Spacer()
                    } else {
                        List {
                            ForEach($model.appFiles) { $f in FileRow(item: $f) }
                        }
                        .scrollContentBackground(.hidden)
                    }
                    ActionBar(module: .applications, summary: LF("%@ seleccionados", Fmt.bytes(model.selectedFilesSize)),
                              buttonTitle: model.busy ? "…" : L("Desinstalar"),
                              enabled: !model.busy && model.appFiles.contains(where: \.selected),
                              secondaryTitle: L("Restablecer app"),
                              secondary: { Task { await model.uninstall(resetOnly: true) } }) {
                        Task { await model.uninstall() }
                    }
                }
            } else {
                VStack(spacing: 14) {
                    Spacer()
                    ModuleGlyph(module: .applications, size: 120)
                    Text(L("Desinstalador")).font(.title.bold())
                    Text(L("Selecciona una app para ver todos sus archivos y eliminarla por completo,\nsin dejar restos en la Biblioteca."))
                        .multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.75))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct UpdaterSection: View {
    @Bindable var model: ApplicationsModel

    var body: some View {
        VStack(spacing: 0) {
            if model.checkingUpdates {
                WorkingView(module: .applications, title: L("Buscando actualizaciones…"),
                            detail: L("Consultando App Store y canales de los desarrolladores"))
            } else if !model.updatesChecked {
                ModuleHero(module: .applications, actionTitle: L("Buscar")) { Task { await model.checkUpdates() } }
            } else {
                ModuleHeader(module: .applications,
                             title: model.updates.isEmpty ? L("Todas tus apps están al día") : LF("%@ actualizaciones disponibles", model.updates.count),
                             subtitle: L("Comprobamos apps de la App Store y apps con actualizaciones Sparkle.")) {
                    Button(L("Comprobar de nuevo")) { Task { await model.checkUpdates() } }.buttonStyle(PillButtonStyle())
                }
                if let msg = model.updateMessage {
                    Text(msg).font(.callout).padding(10)
                        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 20)
                }
                List(model.updates) { u in
                    HStack(spacing: 12) {
                        FileIconView(url: u.app.url, size: 40)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(u.app.name).font(.headline)
                            Text("\(u.app.version) → \(u.newVersion) · \(u.source)").font(.callout).foregroundStyle(.white.opacity(0.7))
                            if let notes = u.notes {
                                Text(notes).font(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
                            }
                        }
                        Spacer()
                        if model.installing.contains(u.id) {
                            ProgressView().controlSize(.small)
                        } else {
                            Button(u.storeURL != nil ? L("Abrir en App Store") : L("Actualizar")) {
                                Task { await model.install(u) }
                            }
                            .buttonStyle(SmallButtonStyle())
                        }
                    }
                    .padding(.vertical, 6)
                }
                .scrollContentBackground(.hidden)
            }
        }
    }
}

private struct ExtensionsSection: View {
    @Bindable var model: ApplicationsModel

    var grouped: [(String, [ExtensionItem])] {
        Dictionary(grouping: model.extensions, by: \.kind).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .applications, title: L("Extensiones"),
                         subtitle: L("Paneles de ajustes, plug-ins, extensiones de Safari y del Finder.")) {
                Button(L("Actualizar")) { Task { await model.loadExtensions() } }.buttonStyle(PillButtonStyle())
            }
            if !model.extensionsLoaded {
                ProgressView().padding(40)
                Spacer()
            } else if model.extensions.isEmpty {
                Text(L("No se encontraron extensiones de terceros.")).padding(40)
                Spacer()
            } else {
                List {
                    ForEach(grouped, id: \.0) { kind, items in
                        Section {
                            ForEach(items) { e in
                                HStack(spacing: 10) {
                                    if let u = e.url { FileIconView(url: u, size: 26) } else { Image(systemName: "puzzlepiece.extension") }
                                    VStack(alignment: .leading) {
                                        Text(e.name)
                                        Text(e.identifier.isEmpty ? (e.url?.path ?? "") : e.identifier)
                                            .font(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                                    }
                                    Spacer()
                                    if e.toggleable {
                                        Toggle("", isOn: Binding(get: { e.enabled }, set: { _ in Task { await model.toggle(e) } }))
                                            .toggleStyle(.switch).labelsHidden()
                                    } else {
                                        Button(L("Eliminar")) { Task { await model.removeExtension(e) } }.buttonStyle(SmallButtonStyle())
                                    }
                                }
                            }
                        } header: {
                            Text(kind).font(.headline).foregroundStyle(.white)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .task { if !model.extensionsLoaded { await model.loadExtensions() } }
    }
}

private struct OrphansSection: View {
    @Bindable var model: ApplicationsModel

    var body: some View {
        switch model.orphanPhase {
        case .idle:
            VStack(spacing: 18) {
                Spacer()
                ModuleGlyph(module: .applications, size: 120)
                Text(L("Restos de apps")).font(.largeTitle.bold())
                Text(L("Encuentra preferencias, cachés y contenedores de apps que ya borraste."))
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
                RoundActionButton(title: L("Analizar"), module: .applications) { Task { await model.scanOrphans() } }
                    .padding(.bottom, 30)
            }
        case .scanning:
            WorkingView(module: .applications, title: L("Buscando restos…"))
        case .results:
            if model.orphanCats.isEmpty {
                DoneView(module: .applications, title: L("Sin restos"), subtitle: L("No se encontraron archivos de apps eliminadas.")) {
                    model.orphanPhase = .idle
                }
            } else {
                VStack(spacing: 0) {
                    CategoryResultsView(categories: $model.orphanCats, showDates: true)
                    ActionBar(module: .applications,
                              summary: LF("%@ seleccionados", Fmt.bytes(model.orphanCats.reduce(0) { $0 + $1.selectedSize })),
                              buttonTitle: L("Eliminar"), enabled: model.orphanCats.contains(where: \.anySelected)) {
                        Task { await model.removeOrphans() }
                    }
                }
            }
        case .working:
            WorkingView(module: .applications, title: L("Eliminando restos…"))
        case .done:
            DoneView(module: .applications, title: LF("%@ liberados", Fmt.bytes(model.orphanResult.freed)),
                     subtitle: L("Los restos se movieron a la Papelera."), failures: model.orphanResult.failed.count) {
                model.orphanPhase = .idle
            }
        }
    }
}
