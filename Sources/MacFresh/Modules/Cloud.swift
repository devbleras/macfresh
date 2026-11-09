import AppKit
import Foundation
import SwiftUI

struct CloudProvider: Identifiable, Sendable {
    let name: String
    let icon: String
    let root: URL
    var totalLogical: Int64 = 0
    var localAllocated: Int64 = 0
    var fileCount = 0
    var localCount = 0
    var largeLocal: [FileItem] = []
    var id: URL { root }
    var isICloud: Bool { root.path.contains("Mobile Documents") }
}

enum CloudScanner {
    static func providers() -> [CloudProvider] {
        var out: [CloudProvider] = []
        let icloud = FS.lib("Mobile Documents")
        if FS.isDir(icloud) {
            out.append(CloudProvider(name: L("iCloud Drive"), icon: "icloud", root: icloud))
        }
        for dir in FS.children(FS.lib("CloudStorage"), hidden: false) where FS.isDir(dir) {
            let raw = dir.lastPathComponent
            let base = raw.components(separatedBy: "-").first ?? raw
            let (name, icon): (String, String) = switch base.lowercased() {
            case "googledrive": (L("Google Drive"), "externaldrive.connected.to.line.below")
            case "onedrive": ("OneDrive", "cloud")
            case "dropbox": ("Dropbox", "shippingbox")
            case "box": (L("Box"), "archivebox")
            case "iclouddrive": (L("iCloud Drive"), "icloud")
            default: (base, "cloud")
            }
            var account = raw.dropFirst(base.count).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if account.hasPrefix(base) { account = String(account.dropFirst(base.count)) }
            account = account.trimmingCharacters(in: CharacterSet(charactersIn: "() ").union(.whitespaces))
            out.append(CloudProvider(name: account.isEmpty ? name : "\(name) (\(account))", icon: icon, root: dir))
        }
        let legacyDropbox = FS.home.appendingPathComponent("Dropbox")
        if FS.isDir(legacyDropbox), !out.contains(where: { $0.name.hasPrefix("Dropbox") }) {
            out.append(CloudProvider(name: "Dropbox", icon: "shippingbox", root: legacyDropbox))
        }
        return out
    }

    static func measure(_ p: CloudProvider, token: CancelToken) -> (CloudProvider, [ScannedFile]) {
        var p = p
        var files: [ScannedFile] = []
        let all = ClutterScanner.enumerate(roots: [p.root], minSize: 1, token: token) { _, _ in }
        for f in all {
            p.totalLogical += f.logical
            p.localAllocated += f.allocated
            p.fileCount += 1
            if f.allocated > 0 { p.localCount += 1 }
            if f.logical >= 1_000_000 { files.append(f) }
        }
        p.largeLocal = all.filter { $0.allocated >= 5_000_000 }
            .sorted { $0.allocated > $1.allocated }
            .prefix(400)
            .map { FileItem(url: $0.url, size: $0.allocated, modified: $0.modified, accessed: $0.accessed, selected: false) }
        return (p, files)
    }

    /// Files in Desktop / Documents / Downloads that already exist (same name and size) in a cloud folder.
    static func redundant(cloudFiles: [ScannedFile], token: CancelToken) -> [FileItem] {
        let keys = Set(cloudFiles.map { "\($0.url.lastPathComponent.lowercased())|\($0.logical)" })
        guard !keys.isEmpty else { return [] }
        let roots = ["Desktop", "Documents", "Downloads"].map { FS.home.appendingPathComponent($0) }
            .filter { !$0.resolvingSymlinksInPath().path.contains("Mobile Documents") }
        return ClutterScanner.enumerate(roots: roots, minSize: 1_000_000, token: token) { _, _ in }
            .filter { keys.contains("\($0.url.lastPathComponent.lowercased())|\($0.logical)") }
            .map { FileItem(url: $0.url, size: $0.allocated, modified: $0.modified, selected: true,
                            note: L("Ya existe en la nube · ") + $0.url.deletingLastPathComponent().path.replacingOccurrences(of: FS.home.path, with: "~")) }
            .sorted { $0.size > $1.size }
    }

    static func evict(_ items: [FileItem]) -> (ok: Int, freed: Int64, failed: Int) {
        var ok = 0, failed = 0
        var freed: Int64 = 0
        for i in items {
            do {
                try FileManager.default.evictUbiquitousItem(at: i.url)
                ok += 1
                freed += i.size
            } catch {
                failed += 1
            }
        }
        return (ok, freed, failed)
    }
}

@MainActor
@Observable
final class CloudModel {
    var phase: ModulePhase = .idle
    var providers: [CloudProvider] = []
    var selectedProvider: URL?
    var redundant: [FileItem] = []
    var showingRedundant = false
    var message: String?
    @ObservationIgnored private var token = CancelToken()

    var current: CloudProvider? { providers.first { $0.id == selectedProvider } }

    func scan() async {
        token = CancelToken()
        let token = token
        phase = .scanning
        let found = await Task.detached { CloudScanner.providers() }.value
        var measured: [CloudProvider] = []
        var cloudFiles: [ScannedFile] = []
        for p in found {
            let (m, files) = await Task.detached(priority: .userInitiated) { CloudScanner.measure(p, token: token) }.value
            measured.append(m)
            cloudFiles += files
        }
        let cf = cloudFiles
        redundant = await Task.detached(priority: .userInitiated) { CloudScanner.redundant(cloudFiles: cf, token: token) }.value
        if token.cancelled { return }
        providers = measured
        selectedProvider = measured.first?.id
        phase = .results
    }

    func cancel() {
        token.cancel()
        phase = .idle
    }

    func bindingForLarge(_ idx: Int) -> Binding<[FileItem]> {
        Binding(get: { self.providers[idx].largeLocal }, set: { self.providers[idx].largeLocal = $0 })
    }

    func evictSelected() async {
        guard let idx = providers.firstIndex(where: { $0.id == selectedProvider }) else { return }
        let items = providers[idx].largeLocal.filter(\.selected)
        let r = await Task.detached { CloudScanner.evict(items) }.value
        message = LF("Se quitaron %@ descargas locales (%@). Siguen disponibles en la nube.", r.ok, Fmt.bytes(r.freed))
            + (r.failed > 0 ? LF(" %@ no se pudieron quitar: usa «Quitar descarga» en el Finder.", r.failed) : "")
        let evicted = Set(items.map(\.url))
        providers[idx].localAllocated -= r.freed
        providers[idx].largeLocal.removeAll { evicted.contains($0.url) && r.failed == 0 }
    }

    func deleteSelected() async {
        guard let idx = providers.firstIndex(where: { $0.id == selectedProvider }) else { return }
        let items = providers[idx].largeLocal.filter(\.selected)
        guard Confirm.ask(LF("¿Eliminar %@ archivos de la nube?", items.count),
                          LF("Se borrarán de %@ y de todos tus dispositivos (irán a la Papelera).", providers[idx].name),
                          confirm: L("Eliminar")) else { return }
        let r = await Task.detached { FS.remove(items, mode: .trash) }.value
        let failed = Set(r.failed)
        providers[idx].largeLocal.removeAll { items.map(\.url).contains($0.url) && !failed.contains($0.url) }
        providers[idx].localAllocated -= r.freed
        message = LF("%@ archivos movidos a la Papelera.", r.removed)
    }

    func removeRedundant() async {
        let items = redundant.filter(\.selected)
        guard Confirm.ask(LF("¿Mover %@ copias locales a la Papelera?", items.count),
                          L("Los originales seguirán en tu almacenamiento en la nube."), confirm: L("Mover a la Papelera")) else { return }
        let r = await Task.detached { FS.remove(items, mode: .trash) }.value
        let failed = Set(r.failed)
        redundant.removeAll { item in items.contains { $0.url == item.url } && !failed.contains(item.url) }
        message = LF("Se liberaron %@ de copias redundantes.", Fmt.bytes(r.freed))
    }
}

struct CloudView: View {
    @Bindable var model: CloudModel

    var body: some View {
        switch model.phase {
        case .idle:
            ModuleHero(module: .cloud, actionTitle: L("Analizar")) { Task { await model.scan() } }
        case .scanning:
            WorkingView(module: .cloud, title: L("Analizando tu almacenamiento en la nube…")) { model.cancel() }
        default:
            if model.providers.isEmpty {
                DoneView(module: .cloud, title: L("Sin almacenamiento en la nube"),
                         subtitle: L("No encontramos iCloud Drive, Google Drive, OneDrive ni Dropbox en este Mac.")) {
                    model.phase = .idle
                }
            } else {
                CloudResults(model: model)
            }
        }
    }
}

private struct CloudResults: View {
    @Bindable var model: CloudModel

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .cloud, title: L("Tu almacenamiento en la nube"),
                         subtitle: L("Lo que ocupa cada servicio en este Mac frente a lo que guarda en la nube.")) {
                Button(L("Volver a analizar")) { Task { await model.scan() } }.buttonStyle(PillButtonStyle())
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(model.providers) { p in
                        let sel = model.selectedProvider == p.id && !model.showingRedundant
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: p.icon).font(.title2)
                                Text(p.name).font(.headline).lineLimit(1)
                            }
                            Text(LF("%@ en este Mac", Fmt.bytes(p.localAllocated))).font(.title3.bold())
                            ProgressView(value: p.totalLogical > 0 ? Double(p.localAllocated) / Double(p.totalLogical) : 0)
                                .tint(.white)
                            Text(LF("%@ en total · %@/%@ descargados", Fmt.bytes(p.totalLogical), p.localCount, p.fileCount))
                                .font(.caption).foregroundStyle(.white.opacity(0.7))
                        }
                        .frame(width: 240, alignment: .leading)
                        .glassCard(padding: 14)
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(sel ? .white : .clear, lineWidth: 2))
                        .onTapGesture { model.selectedProvider = p.id; model.showingRedundant = false }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "doc.on.doc").font(.title2)
                            Text(L("Copias redundantes")).font(.headline)
                        }
                        Text(Fmt.bytes(model.redundant.reduce(0) { $0 + $1.size })).font(.title3.bold())
                        Text(LF("%@ archivos locales que ya están en la nube", model.redundant.count))
                            .font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                    .frame(width: 240, alignment: .leading)
                    .glassCard(padding: 14)
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(model.showingRedundant ? .white : .clear, lineWidth: 2))
                    .onTapGesture { model.showingRedundant = true }
                }
                .padding(.horizontal, 20)
            }
            if let msg = model.message {
                Text(msg).font(.callout).padding(10)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.top, 10)
            }
            if model.showingRedundant {
                List { ForEach($model.redundant) { $f in FileRow(item: $f, showDate: true) } }
                    .scrollContentBackground(.hidden)
                let sel = model.redundant.filter(\.selected)
                ActionBar(module: .cloud, summary: LF("%@ seleccionados", Fmt.bytes(sel.reduce(0) { $0 + $1.size })),
                          buttonTitle: L("Eliminar"), enabled: !sel.isEmpty) { Task { await model.removeRedundant() } }
            } else if let idx = model.providers.firstIndex(where: { $0.id == model.selectedProvider }) {
                let binding = model.bindingForLarge(idx)
                Text(L("Archivos grandes descargados en este Mac")).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.top, 12)
                List { ForEach(binding) { $f in FileRow(item: $f, showDate: true) } }
                    .scrollContentBackground(.hidden)
                let sel = model.providers[idx].largeLocal.filter(\.selected)
                ActionBar(module: .cloud, summary: LF("%@ seleccionados", Fmt.bytes(sel.reduce(0) { $0 + $1.size })),
                          buttonTitle: L("Quitar descarga"), enabled: !sel.isEmpty,
                          secondaryTitle: L("Eliminar de la nube"),
                          secondary: { Task { await model.deleteSelected() } }) {
                    Task { await model.evictSelected() }
                }
            }
        }
    }
}
