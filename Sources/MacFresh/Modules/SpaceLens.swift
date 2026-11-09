import AppKit
import Foundation
import SwiftUI

final class SpaceNode: Identifiable, @unchecked Sendable {
    let url: URL
    let name: String
    let isDir: Bool
    let synthetic: Bool
    var size: Int64 = 0
    var smallFiles: Int64 = 0
    var children: [SpaceNode] = []
    weak var parent: SpaceNode?

    var id: URL { url }

    init(url: URL, isDir: Bool, size: Int64 = 0, synthetic: Bool = false, name: String? = nil) {
        self.url = url
        self.isDir = isDir
        self.size = size
        self.synthetic = synthetic
        self.name = name ?? (url.path == "/" ? "Macintosh HD" : FileManager.default.displayName(atPath: url.path))
    }
}

enum SpaceScanner {
    static let skipForRoot: Set<String> = ["/System/Volumes", "/Volumes", "/dev", "/net", "/home", "/private/var/vm", "/cores"]
    static let leafThreshold: Int64 = 1_000_000

    static func build(root: URL, token: CancelToken, progress: @escaping @Sendable (Int, String) -> Void) -> SpaceNode {
        let rootNode = SpaceNode(url: root, isDir: true)
        var dirs: [String: SpaceNode] = [root.path: rootNode]
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [],
                                                      errorHandler: { _, _ in true }) else { return rootNode }
        var count = 0
        while let u = en.nextObject() as? URL {
            if token.cancelled { break }
            count += 1
            if count % 2000 == 0 { progress(count, u.path) }
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true else { continue }
            let path = u.path
            guard let parent = dirs[u.deletingLastPathComponent().path] else { continue }
            if v.isDirectory == true {
                if skipForRoot.contains(path) || Preferences.isExcluded(u) { en.skipDescendants(); continue }
                let node = SpaceNode(url: u, isDir: true)
                node.parent = parent
                parent.children.append(node)
                dirs[path] = node
            } else {
                let s = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
                if s >= leafThreshold {
                    let node = SpaceNode(url: u, isDir: false, size: s)
                    node.parent = parent
                    parent.children.append(node)
                } else {
                    parent.smallFiles += s
                }
            }
        }
        finalize(rootNode)
        progress(count, "")
        return rootNode
    }

    @discardableResult
    static func finalize(_ node: SpaceNode) -> Int64 {
        guard node.isDir else { return node.size }
        var total = node.smallFiles
        for c in node.children { total += finalize(c) }
        node.children.removeAll { $0.size == 0 }
        if node.smallFiles > 0 && !node.children.isEmpty {
            let small = SpaceNode(url: node.url.appendingPathComponent(".macfresh-small-files"), isDir: false,
                                  size: node.smallFiles, synthetic: true, name: L("Archivos pequeños"))
            small.parent = node
            node.children.append(small)
        }
        node.children.sort { $0.size > $1.size }
        node.size = total
        return total
    }

    struct Bubble: Identifiable {
        let node: SpaceNode
        var center: CGPoint
        let radius: CGFloat
        var id: URL { node.id }
    }

    /// Greedy circle packing: each circle is placed tangent to an existing one, as close to the center as possible.
    static func pack(_ nodes: [SpaceNode]) -> [Bubble] {
        guard let maxSize = nodes.first?.size, maxSize > 0 else { return [] }
        var placed: [Bubble] = []
        let gap: CGFloat = 0.02
        for n in nodes {
            let r = max(0.06, CGFloat(sqrt(Double(n.size) / Double(maxSize))))
            if placed.isEmpty {
                placed.append(Bubble(node: n, center: .zero, radius: r))
                continue
            }
            var best: CGPoint?
            var bestDist = CGFloat.greatestFiniteMagnitude
            for p in placed {
                for k in 0..<36 {
                    let a = CGFloat(k) * .pi / 18
                    let d = p.radius + r + gap
                    let c = CGPoint(x: p.center.x + cos(a) * d, y: p.center.y + sin(a) * d * 0.8)
                    let dist = hypot(c.x, c.y * 1.25)
                    if dist >= bestDist { continue }
                    if placed.allSatisfy({ hypot($0.center.x - c.x, $0.center.y - c.y) >= $0.radius + r + gap * 0.9 }) {
                        best = c
                        bestDist = dist
                    }
                }
            }
            placed.append(Bubble(node: n, center: best ?? CGPoint(x: CGFloat(placed.count), y: 0), radius: r))
        }
        return placed
    }
}

@MainActor
@Observable
final class SpaceLensModel {
    var phase: ModulePhase = .idle
    var root: SpaceNode?
    var current: SpaceNode?
    var scanned = 0
    var scanningPath = ""
    var selected: Set<URL> = []
    var version = 0
    var target: URL = FS.home
    @ObservationIgnored private var token = CancelToken()

    var selectedNodes: [SpaceNode] {
        guard let current else { return [] }
        return current.children.filter { selected.contains($0.url) && !$0.synthetic }
    }

    func scan(_ url: URL) async {
        target = url
        token = CancelToken()
        let token = token
        phase = .scanning
        scanned = 0
        selected = []
        let node = await Task.detached(priority: .userInitiated) {
            SpaceScanner.build(root: url, token: token) { n, p in
                Task { @MainActor in
                    AppState.shared.spaceLens.scanned = n
                    AppState.shared.spaceLens.scanningPath = p
                }
            }
        }.value
        if token.cancelled { return }
        root = node
        current = node
        phase = .results
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { Task { await scan(url) } }
    }

    func cancel() {
        token.cancel()
        phase = .idle
    }

    func open(_ node: SpaceNode) {
        guard node.isDir, !node.children.isEmpty else {
            if !node.synthetic { toggle(node) }
            return
        }
        current = node
        selected = []
    }

    func up() {
        if let p = current?.parent { current = p; selected = [] }
    }

    func toggle(_ node: SpaceNode) {
        if selected.contains(node.url) { selected.remove(node.url) } else { selected.insert(node.url) }
    }

    func trashSelected() async {
        let nodes = selectedNodes
        guard !nodes.isEmpty else { return }
        let total = nodes.reduce(0) { $0 + $1.size }
        guard Confirm.ask(LF("¿Mover %@ elementos a la Papelera?", nodes.count), LF("Ocupan %@.", Fmt.bytes(total)),
                          confirm: L("Mover a la Papelera")) else { return }
        let items = nodes.map { FileItem(url: $0.url, size: $0.size) }
        let r = await Task.detached { FS.remove(items, mode: .trash) }.value
        let failed = Set(r.failed)
        for n in nodes where !failed.contains(n.url) {
            guard let parent = n.parent else { continue }
            parent.children.removeAll { $0 === n }
            var p: SpaceNode? = parent
            while let node = p { node.size -= n.size; p = node.parent }
        }
        selected = []
        version += 1
        if !r.failed.isEmpty {
            Confirm.info(L("Algunos elementos no se pudieron mover"), LF("%@ elementos están protegidos o en uso.", r.failed.count))
        }
    }

    var breadcrumbs: [SpaceNode] {
        var out: [SpaceNode] = []
        var n = current
        while let node = n { out.insert(node, at: 0); n = node.parent }
        return out
    }
}

struct SpaceLensView: View {
    @Bindable var model: SpaceLensModel

    var body: some View {
        switch model.phase {
        case .idle:
            VStack(spacing: 0) {
                FullDiskAccessBanner()
                ModuleHero(module: .spaceLens, actionTitle: L("Analizar")) {
                    Task { await model.scan(FS.home) }
                } extra: {
                    HStack(spacing: 10) {
                        Button(L("Disco completo")) { Task { await model.scan(URL(fileURLWithPath: "/")) } }
                            .buttonStyle(SmallButtonStyle())
                        Button(L("Elegir carpeta…")) { model.chooseFolder() }.buttonStyle(SmallButtonStyle())
                    }
                    .padding(.top, 6)
                }
            }
        case .scanning:
            WorkingView(module: .spaceLens, title: L("Midiendo tu disco…"),
                        detail: LF("%@ elementos · %@", model.scanned, model.scanningPath)) { model.cancel() }
        default:
            if let current = model.current {
                SpaceLensResults(model: model, current: current)
                    .id(model.version)
            }
        }
    }
}

private struct SpaceLensResults: View {
    @Bindable var model: SpaceLensModel
    let current: SpaceNode
    @State private var hovered: URL?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { model.up() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(SmallButtonStyle())
                    .disabled(current.parent == nil)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(model.breadcrumbs) { n in
                            Button(n.name) { model.open(n) }.buttonStyle(.plain)
                                .font(n === current ? .headline : .body)
                            if n !== current { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.white.opacity(0.5)) }
                        }
                    }
                }
                Spacer()
                Text(Fmt.bytes(current.size)).font(.title3.bold())
                Button(L("Nuevo análisis")) { model.phase = .idle }.buttonStyle(PillButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            HStack(spacing: 0) {
                List {
                    ForEach(current.children) { n in
                        HStack(spacing: 8) {
                            if n.synthetic {
                                Image(systemName: "circle.grid.3x3").frame(width: 17)
                            } else {
                                CheckCircle(isOn: Binding(get: { model.selected.contains(n.url) }, set: { _ in model.toggle(n) }))
                            }
                            if n.synthetic { Image(systemName: "doc.on.doc").frame(width: 22) } else { FileIconView(url: n.url, size: 22) }
                            Text(n.name).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(Fmt.bytes(n.size)).font(.callout).monospacedDigit().foregroundStyle(.white.opacity(0.8))
                            if n.isDir && !n.children.isEmpty {
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.white.opacity(0.5))
                            }
                        }
                        .padding(.vertical, 2)
                        .background(hovered == n.url ? Color.white.opacity(0.1) : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { model.open(n) }
                        .onHover { hovered = $0 ? n.url : nil }
                        .contextMenu {
                            if !n.synthetic { Button(L("Mostrar en Finder")) { FS.reveal(n.url) } }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .frame(width: 340)
                .background(.black.opacity(0.12))

                BubbleChart(model: model, nodes: Array(current.children.prefix(30)), total: current.size, hovered: $hovered)
                    .padding(20)
            }

            ActionBar(module: .spaceLens,
                      summary: LF("%@ seleccionados · %@", model.selectedNodes.count, Fmt.bytes(model.selectedNodes.reduce(0) { $0 + $1.size })),
                      buttonTitle: L("Eliminar"), enabled: !model.selectedNodes.isEmpty) {
                Task { await model.trashSelected() }
            }
        }
    }
}

private struct BubbleChart: View {
    let model: SpaceLensModel
    let nodes: [SpaceNode]
    let total: Int64
    @Binding var hovered: URL?

    var body: some View {
        GeometryReader { geo in
            let bubbles = SpaceScanner.pack(nodes)
            let minX = bubbles.map { $0.center.x - $0.radius }.min() ?? -1
            let maxX = bubbles.map { $0.center.x + $0.radius }.max() ?? 1
            let minY = bubbles.map { $0.center.y - $0.radius }.min() ?? -1
            let maxY = bubbles.map { $0.center.y + $0.radius }.max() ?? 1
            let scale = min(geo.size.width / max(0.01, maxX - minX), geo.size.height / max(0.01, maxY - minY)) * 0.95
            let ox = geo.size.width / 2 - (minX + maxX) / 2 * scale
            let oy = geo.size.height / 2 - (minY + maxY) / 2 * scale
            ZStack {
                ForEach(Array(bubbles.enumerated()), id: \.element.id) { i, b in
                    let r = b.radius * scale
                    let isSel = model.selected.contains(b.node.url)
                    let isHover = hovered == b.node.url
                    ZStack {
                        Circle()
                            .fill(RadialGradient(colors: [Module.spaceLens.accent.opacity(isHover ? 0.75 : 0.55),
                                                          Module.spaceLens.colors[1].opacity(0.35)],
                                                 center: .topLeading, startRadius: 0, endRadius: r * 2))
                        Circle().strokeBorder(isSel ? Color.red : .white.opacity(isHover ? 0.8 : 0.35), lineWidth: isSel ? 3 : 1)
                        if r > 34 {
                            VStack(spacing: 2) {
                                if r > 60 {
                                    Image(systemName: b.node.synthetic ? "doc.on.doc" : (b.node.isDir ? "folder.fill" : "doc.fill"))
                                        .font(.system(size: min(28, r * 0.25)))
                                }
                                Text(b.node.name).font(.system(size: min(15, max(10, r * 0.13)), weight: .semibold))
                                    .lineLimit(2).multilineTextAlignment(.center)
                                Text(Fmt.bytes(b.node.size)).font(.system(size: min(13, max(9, r * 0.11))))
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                            .padding(6)
                            .frame(width: r * 1.6)
                        }
                    }
                    .frame(width: r * 2, height: r * 2)
                    .position(x: ox + b.center.x * scale, y: oy + b.center.y * scale)
                    .onHover { hovered = $0 ? b.node.url : nil }
                    .onTapGesture { model.open(b.node) }
                    .help("\(b.node.name) — \(Fmt.bytes(b.node.size)) (\(Fmt.percent(total > 0 ? Double(b.node.size) / Double(total) : 0)))")
                    .transition(.scale.combined(with: .opacity))
                    .animation(.spring(duration: 0.4).delay(Double(i) * 0.01), value: model.current?.id)
                }
            }
        }
    }
}
