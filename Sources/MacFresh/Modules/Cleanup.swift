import Foundation
import SwiftUI

enum ModulePhase: Equatable {
    case idle, scanning, results, working, done
}

struct CleanupDefinition: Sendable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let mode: DeleteMode
    var defaultSelected: Bool = true
    let collect: @Sendable () -> [FileItem]
}

enum CleanupCatalog {
    static let cacheSafelist: Set<String> = [
        "com.apple.bird", "CloudKit", "com.apple.akd", "FamilyCircle", "com.apple.HomeKit",
        "com.apple.containermanagerd", "com.apple.iCloudHelper", "com.apple.ap.adprivacyd", "com.apple.homed",
        "com.apple.nsurlsessiond", "com.macfresh.app", "GeoServices", "com.apple.findmy.fmipcore",
        "com.apple.Safari.SafeBrowsing", "com.apple.passd", "com.apple.appstoreagent", "com.apple.commerce",
    ]

    static var all: [CleanupDefinition] {
        let fda = Permissions.hasFullDiskAccess
        var defs: [CleanupDefinition] = [
            CleanupDefinition(id: "userCaches", title: L("Cachés de usuario"),
                              detail: L("Archivos temporales que las apps generan para cargar más rápido. Se regeneran cuando hacen falta."),
                              icon: "internaldrive", mode: .permanent) {
                var items = FS.items(in: FS.lib("Caches"), excluding: cacheSafelist, minSize: 64 * 1024, clearContents: true)
                if fda {
                    for container in FS.children(FS.lib("Containers"), hidden: false) {
                        let caches = container.appendingPathComponent("Data/Library/Caches")
                        guard FS.isDir(caches) else { continue }
                        let s = FS.size(of: caches)
                        guard s > 1_000_000 else { continue }
                        items.append(FileItem(url: caches, size: s, modified: FS.modified(caches), clearContentsOnly: true,
                                              note: L("Caché de app (contenedor)"), displayName: container.lastPathComponent))
                    }
                }
                return items.sorted { $0.size > $1.size }
            },
            CleanupDefinition(id: "logs", title: L("Registros de usuario"),
                              detail: L("Historiales de actividad y informes de diagnóstico de las aplicaciones."),
                              icon: "doc.text.magnifyingglass", mode: .permanent) {
                FS.items(in: FS.lib("Logs"), minSize: 4 * 1024, clearContents: true)
            },
            CleanupDefinition(id: "xcode", title: L("Basura de Xcode"),
                              detail: L("Datos derivados, símbolos de dispositivos antiguos y cachés del simulador."),
                              icon: "hammer", mode: .permanent) {
                let dev = FS.lib("Developer")
                var items = FS.items(in: dev.appendingPathComponent("Xcode/DerivedData"), minSize: 1)
                    .map { var i = $0; i.note = L("Datos derivados"); return i }
                for os in ["iOS", "watchOS", "tvOS", "visionOS", "macOS"] {
                    items += FS.items(in: dev.appendingPathComponent("Xcode/\(os) DeviceSupport"))
                        .map { var i = $0; i.note = LF("Símbolos de %@", os); return i }
                }
                let simCaches = dev.appendingPathComponent("CoreSimulator/Caches")
                if FS.isDir(simCaches) {
                    let s = FS.size(of: simCaches)
                    if s > 0 { items.append(FileItem(url: simCaches, size: s, clearContentsOnly: true, note: L("Cachés del simulador"))) }
                }
                return items.sorted { $0.size > $1.size }
            },
            CleanupDefinition(id: "xcodeArchives", title: L("Archivos de Xcode"),
                              detail: L("Builds archivados de tus apps. Revisa antes de borrar: pueden servir para depurar versiones publicadas."),
                              icon: "archivebox", mode: .trash, defaultSelected: false) {
                let archives = FS.lib("Developer/Xcode/Archives")
                return FS.children(archives, hidden: false).flatMap { FS.items(in: $0, hidden: false) }
                    .sorted { $0.size > $1.size }
            },
            CleanupDefinition(id: "devCaches", title: L("Cachés de desarrollo"),
                              detail: L("Cachés de gestores de paquetes (npm, pnpm, Yarn, Gradle, pip, Cargo, Bun…). Se descargan de nuevo al necesitarlas."),
                              icon: "shippingbox", mode: .permanent) {
                let h = FS.home
                let candidates: [(String, String)] = [
                    (".npm/_cacache", L("Caché de npm")), (".yarn/berry/cache", L("Caché de Yarn")),
                    ("Library/pnpm/store", L("Almacén de pnpm")), (".pnpm-store", L("Almacén de pnpm")),
                    (".gradle/caches", L("Caché de Gradle")), (".cache/pip", L("Caché de pip")),
                    (".cargo/registry/cache", L("Caché de Cargo")), (".bun/install/cache", L("Caché de Bun")),
                    ("go/pkg/mod/cache", L("Caché de módulos Go")), (".android/cache", L("Caché de Android")),
                    (".cache/yarn", L("Caché de Yarn")), (".cocoapods/repos", L("Repos de CocoaPods")),
                    (".nuget/packages", L("Paquetes NuGet")), (".dartServer/.analysis-driver", L("Análisis de Dart")),
                ]
                return candidates.compactMap { rel, label in
                    let u = h.appendingPathComponent(rel)
                    guard FS.isDir(u) else { return nil }
                    let s = FS.size(of: u)
                    guard s > 0 else { return nil }
                    return FileItem(url: u, size: s, modified: FS.modified(u), clearContentsOnly: true,
                                    note: label, displayName: label)
                }.sorted { $0.size > $1.size }
            },
            CleanupDefinition(id: "installers", title: L("Instaladores descargados"),
                              detail: L("Imágenes de disco y paquetes de instalación (.dmg, .pkg, .xip) que ya no necesitas tras instalar."),
                              icon: "opticaldiscdrive", mode: .trash) {
                let exts: Set<String> = ["dmg", "pkg", "mpkg", "xip", "iso"]
                return [FS.home.appendingPathComponent("Downloads"), FS.home.appendingPathComponent("Desktop")]
                    .flatMap { FS.items(in: $0, hidden: false) { exts.contains($0.pathExtension.lowercased()) } }
                    .sorted { $0.size > $1.size }
            },
            CleanupDefinition(id: "savedState", title: L("Estados de apps guardados"),
                              detail: L("Ventanas que macOS recuerda para reabrir apps. Seguro de borrar."),
                              icon: "macwindow.on.rectangle", mode: .permanent) {
                FS.items(in: FS.lib("Saved Application State"), minSize: 1)
            },
        ]
        if fda {
            defs.append(CleanupDefinition(id: "mail", title: L("Adjuntos de Mail"),
                                          detail: L("Copias locales de adjuntos que ya abriste. Siguen disponibles en el servidor de correo."),
                                          icon: "envelope", mode: .trash) {
                FS.items(in: FS.lib("Containers/com.apple.mail/Data/Library/Mail Downloads"), minSize: 1)
            })
            defs.append(CleanupDefinition(id: "iosBackups", title: L("Copias de iPhone y iPad"),
                                          detail: L("Copias de seguridad locales de dispositivos iOS. Bórralas solo si tienes otra copia (p. ej. en iCloud)."),
                                          icon: "iphone", mode: .trash, defaultSelected: false) {
                FS.items(in: FS.lib("Application Support/MobileSync/Backup"), minSize: 1).map { item in
                    var i = item
                    if let info = NSDictionary(contentsOf: item.url.appendingPathComponent("Info.plist")) {
                        i.displayName = info["Device Name"] as? String ?? item.name
                        if let d = info["Last Backup Date"] as? Date { i.note = LF("Copia del %@", Fmt.date(d)) }
                    }
                    return i
                }
            })
        }
        defs.append(CleanupDefinition(id: "trash", title: L("Papelera"),
                                      detail: L("Elementos que ya enviaste a la Papelera. Se eliminarán definitivamente."),
                                      icon: "trash", mode: .permanent) {
            FS.items(in: FS.home.appendingPathComponent(".Trash"), minSize: 1)
        })
        return defs
    }
}

@MainActor
@Observable
final class CleanupModel {
    var phase: ModulePhase = .idle
    var categories: [JunkCategory] = []
    var currentStep = ""
    var progress = 0.0
    var result = RemovalResult()
    @ObservationIgnored private var task: Task<Void, Never>?

    var totalFound: Int64 { categories.reduce(0) { $0 + $1.totalSize } }
    var selectedSize: Int64 { categories.reduce(0) { $0 + $1.selectedSize } }

    func startScan() {
        task = Task { await scan() }
    }

    func cancel() {
        task?.cancel()
        phase = .idle
    }

    func scan() async {
        phase = .scanning
        progress = 0
        categories = []
        let defs = CleanupCatalog.all
        var found: [JunkCategory] = []
        for (i, def) in defs.enumerated() {
            if Task.isCancelled { return }
            currentStep = def.title
            let items = await Task.detached(priority: .userInitiated) { def.collect() }.value
            if !items.isEmpty {
                var cat = JunkCategory(id: def.id, title: def.title, detail: def.detail, icon: def.icon,
                                       items: items, mode: def.mode, defaultSelected: def.defaultSelected)
                cat.setAll(def.defaultSelected)
                found.append(cat)
            }
            progress = Double(i + 1) / Double(defs.count)
        }
        if Task.isCancelled { return }
        categories = found
        phase = .results
    }

    func startClean() {
        task = Task { await clean() }
    }

    func clean() async {
        phase = .working
        let work = categories.map { ($0.items.filter(\.selected), $0.mode) }
        result = await Task.detached(priority: .userInitiated) {
            var r = RemovalResult()
            for (items, mode) in work where !items.isEmpty { r.merge(FS.remove(items, mode: mode)) }
            return r
        }.value
        phase = .done
    }

    func reset() {
        categories = []
        phase = .idle
    }
}

struct CleanupView: View {
    @Bindable var model: CleanupModel

    var body: some View {
        switch model.phase {
        case .idle:
            VStack(spacing: 0) {
                FullDiskAccessBanner()
                ModuleHero(module: .cleanup) { model.startScan() }
            }
        case .scanning:
            WorkingView(module: .cleanup, title: L("Buscando basura…"), detail: model.currentStep,
                        progress: model.progress) { model.cancel() }
        case .results:
            if model.categories.isEmpty {
                DoneView(module: .cleanup, title: L("Tu Mac está limpio"), subtitle: L("No se encontró basura que eliminar.")) {
                    model.reset()
                }
            } else {
                VStack(spacing: 0) {
                    ModuleHeader(module: .cleanup, title: LF("%@ de basura encontrados", Fmt.bytes(model.totalFound)),
                                 subtitle: L("Revisa los elementos y pulsa Limpiar.")) {
                        Button(L("Volver a empezar")) { model.reset() }.buttonStyle(PillButtonStyle())
                    }
                    CategoryResultsView(categories: $model.categories)
                    ActionBar(module: .cleanup, summary: LF("%@ seleccionados", Fmt.bytes(model.selectedSize)),
                              buttonTitle: L("Limpiar"), enabled: model.selectedSize > 0) { model.startClean() }
                }
            }
        case .working:
            WorkingView(module: .cleanup, title: L("Limpiando…"), detail: L("Eliminando archivos seleccionados"))
        case .done:
            DoneView(module: .cleanup, title: LF("%@ liberados", Fmt.bytes(model.result.freed)),
                     subtitle: LF("Se eliminaron %@ elementos.", model.result.removed),
                     failures: model.result.failed.count) { model.reset() }
        }
    }
}
