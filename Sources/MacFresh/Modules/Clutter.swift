import AppKit
import CryptoKit
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import Vision

final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
}

enum FileKind: String, CaseIterable, Identifiable, Sendable {
    case all, video, audio, image, disk, archive, document, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: L("Todos")
        case .video: L("Vídeos")
        case .audio: L("Audio")
        case .image: L("Imágenes")
        case .disk: L("Imágenes de disco")
        case .archive: L("Comprimidos")
        case .document: L("Documentos")
        case .other: L("Otros")
        }
    }

    static func of(_ url: URL) -> FileKind {
        guard let t = UTType(filenameExtension: url.pathExtension.lowercased()) else { return .other }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return .video }
        if t.conforms(to: .audio) { return .audio }
        if t.conforms(to: .diskImage) { return .disk }
        if t.conforms(to: .archive) { return .archive }
        if t.conforms(to: .image) { return .image }
        if t.conforms(to: .pdf) || t.conforms(to: .text) || t.conforms(to: .presentation)
            || t.conforms(to: .spreadsheet) || t.conforms(to: .content) { return .document }
        return .other
    }
}

enum AgeFilter: String, CaseIterable, Identifiable {
    case any, month, halfYear, year
    var id: String { rawValue }
    var title: String {
        switch self {
        case .any: L("Cualquier fecha")
        case .month: L("Sin abrir > 1 mes")
        case .halfYear: L("Sin abrir > 6 meses")
        case .year: L("Sin abrir > 1 año")
        }
    }
    var cutoff: Date? {
        switch self {
        case .any: nil
        case .month: Date().addingTimeInterval(-30 * 86400)
        case .halfYear: Date().addingTimeInterval(-182 * 86400)
        case .year: Date().addingTimeInterval(-365 * 86400)
        }
    }
}

struct ScannedFile: Sendable {
    let url: URL
    let logical: Int64
    let allocated: Int64
    let modified: Date?
    let accessed: Date?
    var dataless: Bool { allocated == 0 && logical > 0 }
}

struct DuplicateGroup: Identifiable, Sendable {
    let id = UUID()
    var files: [FileItem]
    var wasted: Int64 { files.filter(\.selected).reduce(0) { $0 + $1.size } }
}

struct SimilarGroup: Identifiable, Sendable {
    let id = UUID()
    var files: [FileItem]
}

enum ClutterScanner {
    static func enumerate(roots: [URL], minSize: Int64, token: CancelToken,
                          progress: @escaping @Sendable (Int, String) -> Void) -> [ScannedFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey,
                                      .contentModificationDateKey, .contentAccessDateKey, .isDirectoryKey]
        let skip: Set<String> = [FS.lib("").path, FS.home.appendingPathComponent(".Trash").path]
        var out: [ScannedFile] = []
        var count = 0
        for root in roots {
            guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                          errorHandler: { _, _ in true }) else { continue }
            while let u = en.nextObject() as? URL {
                if token.cancelled { return out }
                count += 1
                if count % 400 == 0 { progress(count, u.path) }
                guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
                if v.isDirectory == true {
                    let p = u.standardizedFileURL.path
                    if skip.contains(p) || skip.contains(p + "/") || Preferences.isExcluded(u) { en.skipDescendants() }
                    continue
                }
                guard v.isRegularFile == true, let size = v.fileSize, Int64(size) >= minSize else { continue }
                out.append(ScannedFile(url: u, logical: Int64(size), allocated: Int64(v.totalFileAllocatedSize ?? 0),
                                       modified: v.contentModificationDate, accessed: v.contentAccessDate))
            }
        }
        progress(count, "")
        return out
    }

    static func hash(_ url: URL, limit: Int? = nil) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        var remaining = limit ?? Int.max
        while remaining > 0 {
            guard let chunk = try? h.read(upToCount: min(1 << 20, remaining)), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            remaining -= chunk.count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func duplicates(_ files: [ScannedFile], token: CancelToken,
                           progress: @escaping @Sendable (Double) -> Void) -> [DuplicateGroup] {
        let bySize = Dictionary(grouping: files.filter { !$0.dataless }, by: \.logical).values.filter { $0.count > 1 }
        var groups: [DuplicateGroup] = []
        var done = 0
        let total = max(1, bySize.count)
        for sameSize in bySize {
            if token.cancelled { break }
            done += 1
            if done % 20 == 0 { progress(Double(done) / Double(total)) }
            // Stage 1: first 16 KB. Stage 2: full content.
            let partial = Dictionary(grouping: sameSize) { hash($0.url, limit: 16 * 1024) ?? UUID().uuidString }
            for candidates in partial.values where candidates.count > 1 {
                let full = Dictionary(grouping: candidates) { hash($0.url) ?? UUID().uuidString }
                for same in full.values where same.count > 1 {
                    groups.append(makeGroup(same))
                }
            }
        }
        return groups.sorted { $0.wasted > $1.wasted }
    }

    /// Keeps the "original" (outside Downloads/Desktop, then the oldest) and pre-selects the copies.
    static func makeGroup(_ files: [ScannedFile]) -> DuplicateGroup {
        func score(_ f: ScannedFile) -> (Int, Date) {
            let p = f.url.path
            let transient = p.contains("/Downloads/") || p.contains("/Desktop/") || p.lowercased().contains("copy")
                || p.contains("copia")
            return (transient ? 1 : 0, f.modified ?? .distantFuture)
        }
        let sorted = files.sorted { score($0) < score($1) }
        let items = sorted.enumerated().map { i, f in
            FileItem(url: f.url, size: f.allocated > 0 ? f.allocated : f.logical, modified: f.modified, accessed: f.accessed,
                     selected: i != 0, note: i == 0 ? L("Original (se conserva)") : nil)
        }
        return DuplicateGroup(files: items)
    }

    static let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp", "gif", "bmp"]

    struct Print: @unchecked Sendable {
        let url: URL
        let observation: VNFeaturePrintObservation
        let pixels: Int
        let size: Int64
        let modified: Date?
    }

    static func featurePrints(roots: [URL], token: CancelToken, limit: Int = 4000,
                              progress: @escaping @Sendable (Double, String) -> Void) -> [Print] {
        let images = enumerate(roots: roots, minSize: 20 * 1024, token: token) { _, p in progress(0, p) }
            .filter { imageExts.contains($0.url.pathExtension.lowercased()) && !$0.dataless }
            .prefix(limit)
        let list = Array(images)
        var results = [Print?](repeating: nil, count: list.count)
        let lock = NSLock()
        var done = 0
        DispatchQueue.concurrentPerform(iterations: list.count) { i in
            if token.cancelled { return }
            let f = list[i]
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceThumbnailMaxPixelSize: 360,
                                         kCGImageSourceCreateThumbnailWithTransform: true]
            guard let src = CGImageSourceCreateWithURL(f.url as CFURL, nil),
                  let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return }
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            let w = props?[kCGImagePropertyPixelWidth] as? Int ?? thumb.width
            let h = props?[kCGImagePropertyPixelHeight] as? Int ?? thumb.height
            let req = VNGenerateImageFeaturePrintRequest()
            req.imageCropAndScaleOption = .scaleFill
            let handler = VNImageRequestHandler(cgImage: thumb, options: [:])
            guard (try? handler.perform([req])) != nil, let obs = req.results?.first else { return }
            lock.lock()
            results[i] = Print(url: f.url, observation: obs, pixels: w * h, size: f.allocated, modified: f.modified)
            done += 1
            let d = done
            lock.unlock()
            if d % 10 == 0 { progress(Double(d) / Double(list.count), f.url.path) }
        }
        return results.compactMap { $0 }
    }

    static func cluster(_ prints: [Print], threshold: Float) -> [SimilarGroup] {
        let n = prints.count
        var parent = Array(0..<n)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        for i in 0..<n {
            for j in (i + 1)..<max(i + 1, n) {
                var d: Float = 0
                guard (try? prints[i].observation.computeDistance(&d, to: prints[j].observation)) != nil else { continue }
                if d < threshold {
                    let a = find(i), b = find(j)
                    if a != b { parent[a] = b }
                }
            }
        }
        var buckets: [Int: [Print]] = [:]
        for i in 0..<n { buckets[find(i), default: []].append(prints[i]) }
        return buckets.values.filter { $0.count > 1 }.map { group in
            let sorted = group.sorted { ($0.pixels, $0.size) > ($1.pixels, $1.size) }
            return SimilarGroup(files: sorted.enumerated().map { i, p in
                FileItem(url: p.url, size: p.size, modified: p.modified, selected: i != 0,
                         note: i == 0 ? L("Mejor calidad (se conserva)") : nil)
            })
        }
        .sorted { $0.files.count > $1.files.count }
    }
}

// MARK: - Model

@MainActor
@Observable
final class ClutterModel {
    enum Tab: String, CaseIterable, Identifiable {
        case duplicates, similar, large, downloads
        var id: String { rawValue }
        var title: String {
            switch self {
            case .duplicates: L("Duplicados")
            case .similar: L("Fotos similares")
            case .large: L("Grandes y antiguos")
            case .downloads: L("Descargas")
            }
        }
    }

    var tab: Tab = .duplicates
    var roots: [URL] = [FS.home]

    // Files scan (duplicates + large)
    var phase: ModulePhase = .idle
    var scanned = 0
    var currentPath = ""
    var hashProgress = 0.0
    var dupGroups: [DuplicateGroup] = []
    var allLarge: [FileItem] = []
    var largeMinMB: Double = 50
    var ageFilter: AgeFilter = .any
    var kindFilter: FileKind = .all
    @ObservationIgnored private var allFiles: [ScannedFile] = []
    @ObservationIgnored private var token = CancelToken()

    // Similar photos
    var similarPhase: ModulePhase = .idle
    var similarProgress = 0.0
    var similarPath = ""
    var similarGroups: [SimilarGroup] = []
    var sensitivity: Double = 0.45
    @ObservationIgnored private var prints: [ClutterScanner.Print] = []

    // Downloads
    var downloads: [FileItem] = []
    var downloadsLoaded = false

    var lastResult = RemovalResult()
    var showDone = false

    var largeFiles: [FileItem] {
        let min = Int64(largeMinMB * 1_000_000)
        let cutoff = ageFilter.cutoff
        return allLarge.filter { f in
            f.size >= min
                && (cutoff == nil || (f.accessed ?? f.modified ?? .distantPast) < cutoff!)
                && (kindFilter == .all || FileKind.of(f.url) == kindFilter)
        }
    }

    var dupSelectedSize: Int64 { dupGroups.reduce(0) { $0 + $1.wasted } }

    func chooseRoots() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = FS.home
        if panel.runModal() == .OK, !panel.urls.isEmpty { roots = panel.urls }
    }

    func scanFiles() async {
        token = CancelToken()
        let token = token
        phase = .scanning
        scanned = 0
        hashProgress = 0
        let roots = roots
        allFiles = await Task.detached(priority: .userInitiated) {
            ClutterScanner.enumerate(roots: roots, minSize: 100 * 1024, token: token) { n, p in
                Task { @MainActor in
                    let m = AppState.shared.clutter
                    m.scanned = n
                    m.currentPath = p
                }
            }
        }.value
        if token.cancelled { return }
        let files = allFiles
        currentPath = L("Comparando contenido de archivos…")
        dupGroups = await Task.detached(priority: .userInitiated) {
            ClutterScanner.duplicates(files, token: token) { p in
                Task { @MainActor in AppState.shared.clutter.hashProgress = p }
            }
        }.value
        allLarge = files.filter { $0.logical >= 10_000_000 }
            .map { FileItem(url: $0.url, size: $0.allocated > 0 ? $0.allocated : $0.logical, modified: $0.modified,
                            accessed: $0.accessed, selected: false) }
            .sorted { $0.size > $1.size }
        if token.cancelled { return }
        phase = .results
    }

    func cancel() {
        token.cancel()
        phase = .idle
        similarPhase = .idle
    }

    func scanSimilar() async {
        token = CancelToken()
        let token = token
        similarPhase = .scanning
        similarProgress = 0
        let roots = [FS.home.appendingPathComponent("Pictures"), FS.home.appendingPathComponent("Desktop"),
                     FS.home.appendingPathComponent("Downloads"), FS.home.appendingPathComponent("Documents")]
            .filter(FS.isDir)
        prints = await Task.detached(priority: .userInitiated) {
            ClutterScanner.featurePrints(roots: roots, token: token) { p, path in
                Task { @MainActor in
                    let m = AppState.shared.clutter
                    m.similarProgress = p
                    m.similarPath = path
                }
            }
        }.value
        if token.cancelled { return }
        await regroupSimilar()
        similarPhase = .results
    }

    func regroupSimilar() async {
        let prints = prints
        let threshold = Float(sensitivity)
        similarGroups = await Task.detached { ClutterScanner.cluster(prints, threshold: threshold) }.value
    }

    func loadDownloads() async {
        let dir = FS.home.appendingPathComponent("Downloads")
        downloads = await Task.detached {
            FS.items(in: dir, hidden: false).map { item in
                var i = item
                i.selected = false
                let added = (try? item.url.resourceValues(forKeys: [.addedToDirectoryDateKey]))?.addedToDirectoryDate
                i.accessed = added
                i.note = LF("Descargado %@", Fmt.relative(added ?? item.modified))
                return i
            }
        }.value
        downloadsLoaded = true
    }

    func trash(_ items: [FileItem]) async {
        guard !items.isEmpty else { return }
        guard Confirm.ask(LF("¿Mover %@ elementos a la Papelera?", items.count),
                          LF("Se liberarán %@ cuando vacíes la Papelera.", Fmt.bytes(items.reduce(0) { $0 + $1.size })),
                          confirm: L("Mover a la Papelera")) else { return }
        lastResult = await Task.detached { FS.remove(items, mode: .trash) }.value
        let removed = Set(items.map(\.url)).subtracting(lastResult.failed)
        dupGroups = dupGroups.compactMap { g in
            var g = g
            g.files.removeAll { removed.contains($0.url) }
            return g.files.count > 1 ? g : nil
        }
        similarGroups = similarGroups.compactMap { g in
            var g = g
            g.files.removeAll { removed.contains($0.url) }
            return g.files.count > 1 ? g : nil
        }
        allLarge.removeAll { removed.contains($0.url) }
        downloads.removeAll { removed.contains($0.url) }
        showDone = true
    }
}

// MARK: - Views

struct ClutterView: View {
    @Bindable var model: ClutterModel

    var body: some View {
        VStack(spacing: 0) {
            TabPicker(items: ClutterModel.Tab.allCases, selection: $model.tab) { $0.title }
                .padding(.top, 16)
            switch model.tab {
            case .duplicates, .large: FilesSection(model: model)
            case .similar: SimilarSection(model: model)
            case .downloads: DownloadsSection(model: model)
            }
        }
        .alert(L("Listo"), isPresented: $model.showDone) {
            Button("OK") {}
        } message: {
            Text(LF("%@ elementos movidos a la Papelera (%@).", model.lastResult.removed, Fmt.bytes(model.lastResult.freed)))
        }
    }
}

private struct FilesSection: View {
    @Bindable var model: ClutterModel

    var body: some View {
        switch model.phase {
        case .idle:
            ModuleHero(module: .clutter, actionTitle: L("Analizar")) {
                Task { await model.scanFiles() }
            } extra: {
                HStack {
                    Text(L("Carpetas: ") + model.roots.map { $0.path.replacingOccurrences(of: FS.home.path, with: "~") }.joined(separator: ", "))
                        .font(.callout).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                    Button(L("Cambiar…")) { model.chooseRoots() }.buttonStyle(SmallButtonStyle())
                }
            }
        case .scanning:
            WorkingView(module: .clutter, title: L("Buscando desorden…"),
                        detail: LF("%@ archivos · %@", model.scanned, model.currentPath),
                        progress: model.hashProgress > 0 ? model.hashProgress : nil) { model.cancel() }
        default:
            if model.tab == .duplicates { DuplicatesResults(model: model) } else { LargeResults(model: model) }
        }
    }
}

private struct DuplicatesResults: View {
    @Bindable var model: ClutterModel

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .clutter,
                         title: model.dupGroups.isEmpty ? L("No hay duplicados") : LF("%@ grupos de duplicados", model.dupGroups.count),
                         subtitle: L("Se conserva automáticamente el original de cada grupo.")) {
                Button(L("Volver a analizar")) { Task { await model.scanFiles() } }.buttonStyle(PillButtonStyle())
            }
            List {
                ForEach($model.dupGroups) { $group in
                    Section {
                        ForEach($group.files) { $f in FileRow(item: $f, showDate: true) }
                    } header: {
                        HStack {
                            Text(group.files.first?.url.lastPathComponent ?? "").font(.headline).foregroundStyle(.white)
                            Spacer()
                            Text(LF("%@ copias · %@ cada una", group.files.count, Fmt.bytes(group.files.first?.size ?? 0)))
                                .font(.caption).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            ActionBar(module: .clutter, summary: LF("%@ seleccionados", Fmt.bytes(model.dupSelectedSize)),
                      buttonTitle: L("Eliminar"), enabled: model.dupSelectedSize > 0) {
                Task { await model.trash(model.dupGroups.flatMap { $0.files.filter(\.selected) }) }
            }
        }
    }
}

private struct LargeResults: View {
    @Bindable var model: ClutterModel

    var body: some View {
        let files = model.largeFiles
        let selected = files.filter(\.selected)
        VStack(spacing: 0) {
            ModuleHeader(module: .clutter, title: L("Archivos grandes y antiguos"),
                         subtitle: LF("%@ archivos · %@", files.count, Fmt.bytes(files.reduce(0) { $0 + $1.size }))) {
                Button(L("Volver a analizar")) { Task { await model.scanFiles() } }.buttonStyle(PillButtonStyle())
            }
            HStack(spacing: 16) {
                Picker(L("Tipo"), selection: $model.kindFilter) {
                    ForEach(FileKind.allCases) { Text($0.title).tag($0) }
                }.frame(width: 200)
                Picker(L("Antigüedad"), selection: $model.ageFilter) {
                    ForEach(AgeFilter.allCases) { Text($0.title).tag($0) }
                }.frame(width: 260)
                HStack {
                    Text(L("Mín."))
                    Slider(value: $model.largeMinMB, in: 10...2000, step: 10).frame(width: 140)
                    Text("\(Int(model.largeMinMB)) MB").monospacedDigit().frame(width: 70, alignment: .leading)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
            List {
                ForEach(files) { f in
                    if let idx = model.allLarge.firstIndex(where: { $0.id == f.id }) {
                        FileRow(item: $model.allLarge[idx], showDate: true)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            ActionBar(module: .clutter, summary: LF("%@ seleccionados", Fmt.bytes(selected.reduce(0) { $0 + $1.size })),
                      buttonTitle: L("Eliminar"), enabled: !selected.isEmpty) {
                Task { await model.trash(selected) }
            }
        }
    }
}

private struct SimilarSection: View {
    @Bindable var model: ClutterModel

    var body: some View {
        switch model.similarPhase {
        case .idle:
            VStack(spacing: 18) {
                Spacer()
                ModuleGlyph(module: .clutter, size: 120)
                Text(L("Fotos similares")).font(.largeTitle.bold())
                Text(L("Analiza tus imágenes con visión artificial en el propio Mac para encontrar ráfagas,\ncapturas repetidas y fotos casi idénticas. Se conserva la de mayor calidad."))
                    .multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.75))
                Text(L("Carpetas: Imágenes, Escritorio, Descargas y Documentos")).font(.caption).foregroundStyle(.white.opacity(0.6))
                Spacer()
                RoundActionButton(title: L("Analizar"), module: .clutter) { Task { await model.scanSimilar() } }
                    .padding(.bottom, 30)
            }
        case .scanning:
            WorkingView(module: .clutter, title: L("Comparando fotos…"), detail: model.similarPath,
                        progress: model.similarProgress) { model.cancel() }
        default:
            let selected = model.similarGroups.flatMap { $0.files.filter(\.selected) }
            VStack(spacing: 0) {
                ModuleHeader(module: .clutter,
                             title: model.similarGroups.isEmpty ? L("No hay fotos similares") : LF("%@ grupos de fotos similares", model.similarGroups.count),
                             subtitle: L("Pulsa una foto para marcarla o desmarcarla.")) {
                    HStack {
                        Text(L("Sensibilidad")).font(.caption)
                        Slider(value: $model.sensitivity, in: 0.2...0.8).frame(width: 120)
                            .onChange(of: model.sensitivity) { _, _ in Task { await model.regroupSimilar() } }
                        Button(L("Volver a analizar")) { Task { await model.scanSimilar() } }.buttonStyle(PillButtonStyle())
                    }
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach($model.similarGroups) { $group in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(LF("%@ fotos", group.files.count)).font(.headline)
                                ScrollView(.horizontal) {
                                    HStack(spacing: 10) {
                                        ForEach($group.files) { $f in PhotoTile(item: $f) }
                                    }
                                }
                            }
                            .glassCard(padding: 12)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                ActionBar(module: .clutter, summary: LF("%@ fotos · %@", selected.count, Fmt.bytes(selected.reduce(0) { $0 + $1.size })),
                          buttonTitle: L("Eliminar"), enabled: !selected.isEmpty) {
                    Task { await model.trash(selected) }
                }
            }
        }
    }
}

struct PhotoTile: View {
    @Binding var item: FileItem
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(.white.opacity(0.1))
                    }
                }
                .frame(width: 150, height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(item.selected ? Color.red : .white.opacity(0.2),
                                                                         lineWidth: item.selected ? 3 : 1))
                Image(systemName: item.selected ? "trash.circle.fill" : "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white, item.selected ? .red : .green)
                    .padding(5)
            }
            Text(item.url.lastPathComponent).font(.caption2).lineLimit(1).frame(width: 150)
            Text(Fmt.bytes(item.size)).font(.caption2).foregroundStyle(.white.opacity(0.6))
        }
        .onTapGesture { item.selected.toggle() }
        .contextMenu { Button(L("Mostrar en Finder")) { FS.reveal(item.url) } }
        .task(id: item.url) {
            let url = item.url
            image = await Task.detached {
                let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                             kCGImageSourceThumbnailMaxPixelSize: 300,
                                             kCGImageSourceCreateThumbnailWithTransform: true]
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil as NSImage? }
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }.value
        }
    }
}

private struct DownloadsSection: View {
    @Bindable var model: ClutterModel

    var body: some View {
        let selected = model.downloads.filter(\.selected)
        VStack(spacing: 0) {
            ModuleHeader(module: .clutter, title: L("Descargas"),
                         subtitle: LF("%@ elementos · %@", model.downloads.count, Fmt.bytes(model.downloads.reduce(0) { $0 + $1.size }))) {
                HStack {
                    Button(L("Seleccionar > 3 meses")) {
                        let cutoff = Date().addingTimeInterval(-90 * 86400)
                        for i in model.downloads.indices {
                            model.downloads[i].selected = (model.downloads[i].accessed ?? model.downloads[i].modified ?? .distantPast) < cutoff
                        }
                    }
                    .buttonStyle(PillButtonStyle())
                    Button(L("Actualizar")) { Task { await model.loadDownloads() } }.buttonStyle(PillButtonStyle())
                }
            }
            List {
                ForEach($model.downloads) { $f in FileRow(item: $f) }
            }
            .scrollContentBackground(.hidden)
            ActionBar(module: .clutter, summary: LF("%@ seleccionados", Fmt.bytes(selected.reduce(0) { $0 + $1.size })),
                      buttonTitle: L("Eliminar"), enabled: !selected.isEmpty) {
                Task { await model.trash(selected) }
            }
        }
        .task { if !model.downloadsLoaded { await model.loadDownloads() } }
    }
}
