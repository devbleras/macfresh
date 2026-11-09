import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum Shredder {
    /// Overwrites every regular file with random data, then deletes it.
    static func shred(_ url: URL) -> Bool {
        guard FS.isSafeToRemove(url) else { return false }
        var files: [URL] = []
        if FS.isDir(url) {
            if let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) {
                while let f = en.nextObject() as? URL {
                    if (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { files.append(f) }
                }
            }
        } else {
            files = [url]
        }
        for f in files { overwrite(f) }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    private static func overwrite(_ url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.intValue, size > 0,
              let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        let chunk = 1 << 20
        var written = 0
        var buf = [UInt8](repeating: 0, count: chunk)
        while written < size {
            let n = min(chunk, size - written)
            _ = SecRandomCopyBytes(kSecRandomDefault, n, &buf)
            h.write(Data(buf[0..<n]))
            written += n
        }
        try? h.synchronize()
        try? h.truncate(atOffset: 0)
    }
}

@MainActor
@Observable
final class ShredderModel {
    var items: [FileItem] = []
    var phase: ModulePhase = .idle
    var shredded = 0
    var failed = 0

    func add(_ urls: [URL]) {
        for u in urls where !items.contains(where: { $0.url == u }) {
            items.append(FileItem(url: u, size: FS.size(of: u), modified: FS.modified(u)))
        }
        if !items.isEmpty { phase = .results }
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func shred() async {
        let list = items.filter(\.selected)
        guard Confirm.ask(LF("¿Triturar %@ elementos?", list.count),
                          L("Se sobrescribirán y eliminarán definitivamente. Esta acción no se puede deshacer."),
                          confirm: L("Triturar")) else { return }
        phase = .working
        let result = await Task.detached { () -> (Int, Int) in
            var ok = 0, ko = 0
            for i in list { if Shredder.shred(i.url) { ok += 1 } else { ko += 1 } }
            return (ok, ko)
        }.value
        shredded = result.0
        failed = result.1
        items.removeAll { i in list.contains { $0.url == i.url } }
        phase = .done
    }
}

struct ShredderView: View {
    @Bindable var model: ShredderModel
    @State private var targeted = false

    var body: some View {
        Group {
            switch model.phase {
            case .working:
                WorkingView(module: .shredder, title: L("Triturando…"))
            case .done:
                DoneView(module: .shredder, title: L("Archivos triturados"),
                         subtitle: LF("%@ elementos eliminados de forma segura.", model.shredded), failures: model.failed) {
                    model.phase = model.items.isEmpty ? .idle : .results
                }
            case .results where !model.items.isEmpty:
                VStack(spacing: 0) {
                    ModuleHeader(module: .shredder, title: L("Elementos para triturar"),
                                 subtitle: L("Arrastra más archivos aquí o añádelos con el botón.")) {
                        HStack {
                            Button(L("Añadir…")) { model.choose() }.buttonStyle(PillButtonStyle())
                            Button(L("Vaciar lista")) { model.items = []; model.phase = .idle }.buttonStyle(PillButtonStyle())
                        }
                    }
                    List { ForEach($model.items) { $f in FileRow(item: $f) } }
                        .scrollContentBackground(.hidden)
                    ActionBar(module: .shredder,
                              summary: LF("%@ elementos · %@", model.items.filter(\.selected).count, Fmt.bytes(model.items.filter(\.selected).reduce(0) { $0 + $1.size })),
                              buttonTitle: L("Triturar"), enabled: model.items.contains(where: \.selected)) {
                        Task { await model.shred() }
                    }
                }
            default:
                ModuleHero(module: .shredder, actionTitle: L("Elegir archivos")) {
                    model.choose()
                } extra: {
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                            .foregroundStyle(.white.opacity(targeted ? 0.9 : 0.35))
                            .frame(width: 380, height: 90)
                            .overlay(Text(L("Arrastra aquí archivos o carpetas")).foregroundStyle(.white.opacity(0.8)))
                        Text(L("En discos SSD con APFS la recuperación ya es muy difícil; el triturado añade una capa extra de seguridad."))
                            .font(.caption).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                    }
                    .padding(.top, 8)
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls.filter(\.isFileURL))
            return true
        } isTargeted: { targeted = $0 }
    }
}
