import AppKit
import Foundation

// MARK: - Formatting

enum Fmt {
    static var locale: Locale { AppLanguage.locale }

    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, b), countStyle: .file)
    }

    static func bytesPerSecond(_ b: Double) -> String {
        bytes(Int64(b)) + "/s"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = locale
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    static func date(_ d: Date?) -> String {
        guard let d else { return "—" }
        return dateFormatter.string(from: d)
    }

    static func relative(_ d: Date?) -> String {
        guard let d else { return L("Nunca") }
        let f = RelativeDateTimeFormatter()
        f.locale = locale
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }

    static func percent(_ v: Double) -> String {
        "\(Int((v * 100).rounded()))%"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d) d \(h) h" }
        if h > 0 { return LF("%@ h %@ min", h, m) }
        return LF("%@ min", m)
    }
}

// MARK: - Models

enum DeleteMode: Sendable {
    /// Moves items to the Trash (recoverable).
    case trash
    /// Deletes items immediately.
    case permanent
}

struct FileItem: Identifiable, Hashable, Sendable {
    let url: URL
    var size: Int64
    var modified: Date? = nil
    var accessed: Date? = nil
    var selected: Bool = true
    /// When true, the folder itself is kept and only its contents are removed (caches).
    var clearContentsOnly: Bool = false
    /// Optional explanatory note shown under the name.
    var note: String? = nil
    /// Optional display name override.
    var displayName: String? = nil

    var id: URL { url }
    var name: String { displayName ?? url.lastPathComponent }
}

struct JunkCategory: Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    var items: [FileItem]
    var mode: DeleteMode
    var defaultSelected: Bool = true

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var selectedSize: Int64 { items.filter(\.selected).reduce(0) { $0 + $1.size } }
    var selectedCount: Int { items.filter(\.selected).count }
    var allSelected: Bool { !items.isEmpty && items.allSatisfy(\.selected) }
    var anySelected: Bool { items.contains(where: \.selected) }

    mutating func setAll(_ on: Bool) {
        for i in items.indices { items[i].selected = on }
    }
}

struct RemovalResult: Sendable {
    var freed: Int64 = 0
    var removed: Int = 0
    var failed: [URL] = []

    mutating func merge(_ o: RemovalResult) {
        freed += o.freed
        removed += o.removed
        failed += o.failed
    }
}

// MARK: - File system helpers

enum FS {
    static var fm: FileManager { .default }
    static var home: URL { URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) }

    static func lib(_ sub: String) -> URL {
        home.appendingPathComponent("Library", isDirectory: true).appendingPathComponent(sub)
    }

    static func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    static func isDir(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }

    static let sizeKeys: [URLResourceKey] = [
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey,
        .isDirectoryKey, .isSymbolicLinkKey,
    ]

    /// Allocated (on-disk) size of a file or a whole directory tree.
    static func size(of url: URL, cancelled: (() -> Bool)? = nil) -> Int64 {
        guard let rv = try? url.resourceValues(forKeys: Set(sizeKeys)) else { return 0 }
        if rv.isSymbolicLink == true { return 0 }
        if rv.isDirectory != true {
            return Int64(rv.totalFileAllocatedSize ?? rv.fileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: sizeKeys, options: [],
                                     errorHandler: { _, _ in true }) else { return 0 }
        var n = 0
        while let f = en.nextObject() as? URL {
            n += 1
            if n % 512 == 0, let c = cancelled, c() { break }
            guard let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]),
                  v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return total
    }

    static func children(_ url: URL, hidden: Bool = true) -> [URL] {
        let opts: FileManager.DirectoryEnumerationOptions = hidden ? [] : [.skipsHiddenFiles]
        return (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: opts)) ?? []
    }

    static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    static func accessed(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate
    }

    private static let ignoredNames: Set<String> = [".DS_Store", ".localized", ".com.apple.timemachine.supported"]

    /// Lists the direct children of a directory as sized items.
    static func items(in dir: URL, hidden: Bool = true, excluding: Set<String> = [],
                      minSize: Int64 = 1, clearContents: Bool = false,
                      filter: ((URL) -> Bool)? = nil) -> [FileItem] {
        children(dir, hidden: hidden).compactMap { u in
            let name = u.lastPathComponent
            if ignoredNames.contains(name) || excluding.contains(name) { return nil }
            if let filter, !filter(u) { return nil }
            if Preferences.isExcluded(u) { return nil }
            let s = size(of: u)
            guard s >= minSize else { return nil }
            return FileItem(url: u, size: s, modified: modified(u),
                            clearContentsOnly: clearContents && isDir(u))
        }
        .sorted { $0.size > $1.size }
    }

    // MARK: Safety

    static var protectedPaths: Set<String> {
        let h = home.path
        var set: Set<String> = ["/", "/System", "/Library", "/Applications", "/Users", "/usr", "/bin",
                                "/sbin", "/private", "/etc", "/var", "/opt", "/Volumes", "/cores"]
        let homeSubs = ["", "/Library", "/Documents", "/Desktop", "/Downloads", "/Pictures", "/Movies",
                        "/Music", "/Public", "/Applications", "/.Trash", "/Library/Caches",
                        "/Library/Application Support", "/Library/Preferences", "/Library/Containers",
                        "/Library/Group Containers", "/Library/Logs", "/Library/Mobile Documents",
                        "/Library/CloudStorage", "/Library/Mail", "/Library/Keychains",
                        "/Library/Developer", "/Library/LaunchAgents"]
        for s in homeSubs { set.insert(h + s) }
        return set
    }

    static func isSafeToRemove(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        if protectedPaths.contains(p) { return false }
        for prefix in ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Keychains/"] where p.hasPrefix(prefix) {
            if !p.hasPrefix("/usr/local/") { return false }
        }
        if p.hasPrefix(home.path + "/Library/Keychains") { return false }
        if p.contains("/MacFresh.app") { return false }
        if Preferences.isExcluded(url) { return false }
        return true
    }

    static func remove(_ items: [FileItem], mode: DeleteMode) -> RemovalResult {
        var r = RemovalResult()
        for item in items {
            let u = item.url
            guard isSafeToRemove(u) else { r.failed.append(u); continue }
            if item.clearContentsOnly {
                var freedHere: Int64 = 0
                var anyFail = false
                for c in children(u) {
                    let s = size(of: c)
                    do {
                        if mode == .trash { try fm.trashItem(at: c, resultingItemURL: nil) } else { try fm.removeItem(at: c) }
                        freedHere += s
                    } catch { anyFail = true }
                }
                r.freed += freedHere
                if anyFail && freedHere == 0 { r.failed.append(u) } else { r.removed += 1 }
                continue
            }
            do {
                switch mode {
                case .trash: try fm.trashItem(at: u, resultingItemURL: nil)
                case .permanent: try fm.removeItem(at: u)
                }
                r.freed += item.size
                r.removed += 1
            } catch {
                r.failed.append(u)
            }
        }
        return r
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func icon(for url: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Volume capacity info for the startup disk.
    static func diskSpace(for url: URL = URL(fileURLWithPath: "/")) -> (total: Int64, free: Int64) {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                         .volumeAvailableCapacityKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return (0, 0) }
        let total = Int64(v.volumeTotalCapacity ?? 0)
        let free = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
        return (total, free)
    }
}

// MARK: - Shell

enum Shell {
    struct Result: Sendable {
        let status: Int32
        let output: String
        var ok: Bool { status == 0 }
    }

    @discardableResult
    static func run(_ path: String, _ args: [String] = []) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch {
            return Result(status: -1, output: error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    @discardableResult
    static func sh(_ command: String) -> Result {
        run("/bin/sh", ["-c", command])
    }

    /// Runs a shell command with administrator privileges (shows the system password prompt).
    @discardableResult
    static func admin(_ command: String) -> Result {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let prompt = L("MacFresh necesita permisos de administrador para completar esta tarea.")
            .replacingOccurrences(of: "\"", with: "'")
        let script = "do shell script \"\(escaped)\" with administrator privileges with prompt \"\(prompt)\""
        return run("/usr/bin/osascript", ["-e", script])
    }

    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Permissions

enum Permissions {
    static var hasFullDiskAccess: Bool {
        let path = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        let fd = open(path, O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return false
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Preferences

enum Preferences {
    static let exclusionsKey = "exclusions"

    static var exclusions: [String] {
        get { UserDefaults.standard.stringArray(forKey: exclusionsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: exclusionsKey) }
    }

    static func isExcluded(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        return exclusions.contains { p == $0 || p.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }
}
