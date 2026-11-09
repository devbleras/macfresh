import AppKit
import SwiftUI

enum Module: String, CaseIterable, Identifiable, Hashable {
    case smartCare, cleanup, protection, performance, applications, clutter, spaceLens, cloud, shredder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smartCare: L("Smart Care")
        case .cleanup: L("Limpieza")
        case .protection: L("Protección")
        case .performance: L("Rendimiento")
        case .applications: L("Aplicaciones")
        case .clutter: L("Mi desorden")
        case .spaceLens: L("Lente de espacio")
        case .cloud: L("Limpieza en la nube")
        case .shredder: L("Triturador")
        }
    }

    var tagline: String {
        switch self {
        case .smartCare: L("Limpieza, protección, rendimiento y actualizaciones en un solo clic.")
        case .cleanup: L("Elimina la basura del sistema, cachés, registros y archivos innecesarios.")
        case .protection: L("Busca malware, adware y elimina tu rastro de privacidad.")
        case .performance: L("Ejecuta tareas de mantenimiento y controla lo que se inicia con tu Mac.")
        case .applications: L("Desinstala apps por completo, elimina restos y mantenlas actualizadas.")
        case .clutter: L("Encuentra duplicados, fotos similares y archivos grandes y antiguos.")
        case .spaceLens: L("Visualiza qué ocupa espacio en tu disco y libéralo al instante.")
        case .cloud: L("Controla cuánto ocupan iCloud, Google Drive, OneDrive y Dropbox en tu Mac.")
        case .shredder: L("Borra archivos de forma segura para que no puedan recuperarse.")
        }
    }

    var icon: String {
        switch self {
        case .smartCare: "sparkles"
        case .cleanup: "trash.circle"
        case .protection: "hand.raised"
        case .performance: "gauge.with.dots.needle.67percent"
        case .applications: "square.grid.2x2"
        case .clutter: "doc.on.doc"
        case .spaceLens: "circle.hexagongrid"
        case .cloud: "icloud"
        case .shredder: "scissors"
        }
    }

    var colors: [Color] {
        switch self {
        case .smartCare: [Color(hex: 0x0B3D3A), Color(hex: 0x0E6E5C), Color(hex: 0x1FB58F)]
        case .cleanup: [Color(hex: 0x0A2F3F), Color(hex: 0x0D5C6E), Color(hex: 0x22A6B3)]
        case .protection: [Color(hex: 0x3A0F2E), Color(hex: 0x7A1E48), Color(hex: 0xD9466F)]
        case .performance: [Color(hex: 0x2D1B4E), Color(hex: 0x5B2C8F), Color(hex: 0xA26BE0)]
        case .applications: [Color(hex: 0x0F2350), Color(hex: 0x1D4A9E), Color(hex: 0x4A8CF0)]
        case .clutter: [Color(hex: 0x3D2408), Color(hex: 0x8A4E12), Color(hex: 0xE59A2F)]
        case .spaceLens: [Color(hex: 0x10274A), Color(hex: 0x1F5C8A), Color(hex: 0x3BB4D8)]
        case .cloud: [Color(hex: 0x14284A), Color(hex: 0x2B5DA8), Color(hex: 0x7DB8F5)]
        case .shredder: [Color(hex: 0x2A2A2E), Color(hex: 0x4A4A55), Color(hex: 0x8C8C9E)]
        }
    }

    var accent: Color { colors[2] }

    var gradient: LinearGradient {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var features: [(String, String)] {
        switch self {
        case .smartCare:
            [("trash", L("Limpia la basura del sistema")), ("shield.lefthalf.filled", L("Busca amenazas")),
             ("bolt", L("Optimiza el rendimiento")), ("arrow.down.app", L("Busca actualizaciones")),
             ("folder", L("Detecta desorden"))]
        case .cleanup:
            [("internaldrive", L("Cachés y registros del sistema")), ("hammer", L("Basura de Xcode y desarrollo")),
             ("envelope", L("Adjuntos de Mail y papeleras")), ("shippingbox", L("Instaladores olvidados"))]
        case .protection:
            [("ladybug", L("Malware y adware conocidos")), ("exclamationmark.shield", L("Agentes de inicio sospechosos")),
             ("eye.slash", L("Historial y cookies de navegadores")), ("lock.shield", L("Permisos de apps"))]
        case .performance:
            [("wrench.and.screwdriver", L("Tareas de mantenimiento")), ("power", L("Elementos de inicio")),
             ("gearshape.2", L("Agentes en segundo plano")), ("flame", L("Apps que consumen mucho"))]
        case .applications:
            [("xmark.bin", L("Desinstalador completo")), ("arrow.triangle.2.circlepath", L("Actualizador")),
             ("puzzlepiece.extension", L("Extensiones")), ("questionmark.folder", L("Restos de apps borradas"))]
        case .clutter:
            [("doc.on.doc", L("Archivos duplicados")), ("photo.on.rectangle", L("Fotos similares")),
             ("archivebox", L("Archivos grandes y antiguos")), ("arrow.down.circle", L("Descargas"))]
        case .spaceLens:
            [("circle.hexagongrid", L("Mapa visual de carpetas")), ("arrow.down.right.and.arrow.up.left", L("Navega por tamaño")),
             ("trash", L("Elimina lo que no necesitas"))]
        case .cloud:
            [("icloud", L("iCloud Drive")), ("externaldrive.connected.to.line.below", L("Google Drive, OneDrive, Dropbox")),
             ("arrow.down.to.line", L("Quita descargas locales")), ("doc.on.doc", L("Copias locales redundantes"))]
        case .shredder:
            [("scissors", L("Sobrescribe antes de borrar")), ("lock", L("Imposible de recuperar con herramientas comunes"))]
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

// MARK: - Background

struct ModuleBackground: View {
    let module: Module
    var body: some View {
        ZStack {
            module.gradient
            RadialGradient(colors: [module.accent.opacity(0.45), .clear], center: .topTrailing,
                           startRadius: 10, endRadius: 600)
            RadialGradient(colors: [Color.black.opacity(0.35), .clear], center: .bottomLeading,
                           startRadius: 10, endRadius: 700)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Glass card

struct GlassCard: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }
}

extension View {
    func glassCard(padding: CGFloat = 16) -> some View { modifier(GlassCard(padding: padding)) }
}

// MARK: - Big round action button

struct RoundActionButton: View {
    let title: String
    var module: Module
    var enabled: Bool = true
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [module.accent, module.colors[1]], startPoint: .top, endPoint: .bottom))
                    .shadow(color: module.accent.opacity(hover ? 0.8 : 0.5), radius: hover ? 24 : 14)
                Circle().strokeBorder(.white.opacity(0.35), lineWidth: 2)
                // Never break a word: one line per word group, and shrink the font until it fits.
                Text(Self.balancedLines(title))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(title.contains(" ") ? 2 : 1)
                    .minimumScaleFactor(0.45)
                    .allowsTightening(true)
                    .padding(12)
            }
            .frame(width: 96, height: 96)
            .scaleEffect(hover ? 1.04 : 1)
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }

    /// Splits a multi-word label into two lines at the space closest to the middle.
    static func balancedLines(_ s: String) -> String {
        let words = s.split(separator: " ")
        guard words.count > 1 else { return s }
        var best = 1
        var bestDiff = Int.max
        for i in 1..<words.count {
            let left = words[..<i].joined(separator: " ").count
            let right = words[i...].joined(separator: " ").count
            if abs(left - right) < bestDiff { bestDiff = abs(left - right); best = i }
        }
        return words[..<best].joined(separator: " ") + "\n" + words[best...].joined(separator: " ")
    }
}

// MARK: - Hero (module landing)

struct ModuleHero<Extra: View>: View {
    let module: Module
    var actionTitle: String = L("Analizar")
    var actionEnabled: Bool = true
    let action: () -> Void
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 10)
            ModuleGlyph(module: module, size: 150)
            VStack(spacing: 10) {
                Text(module.title).font(.system(size: 34, weight: .bold))
                Text(module.tagline)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(module.features, id: \.1) { f in
                    Label(f.1, systemImage: f.0)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            extra()
            Spacer(minLength: 10)
            RoundActionButton(title: actionTitle, module: module, enabled: actionEnabled, action: action)
                .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 30)
    }
}

extension ModuleHero where Extra == EmptyView {
    init(module: Module, actionTitle: String = L("Analizar"), actionEnabled: Bool = true, action: @escaping () -> Void) {
        self.module = module
        self.actionTitle = actionTitle
        self.actionEnabled = actionEnabled
        self.action = action
        self.extra = { EmptyView() }
    }
}

struct ModuleGlyph: View {
    let module: Module
    var size: CGFloat = 120
    var spinning = false
    @State private var angle: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [module.accent.opacity(0.9), module.colors[1].opacity(0.6), .clear],
                                     center: .center, startRadius: 2, endRadius: size * 0.6))
                .blur(radius: 6)
            Circle()
                .strokeBorder(AngularGradient(colors: [.white.opacity(0.9), module.accent, .white.opacity(0.1), module.accent],
                                              center: .center), lineWidth: 3)
                .rotationEffect(.degrees(angle))
            Image(systemName: module.icon)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
        }
        .frame(width: size, height: size)
        .onAppear {
            if spinning {
                withAnimation(.linear(duration: 2.2).repeatForever(autoreverses: false)) { angle = 360 }
            }
        }
    }
}

// MARK: - Scanning / working state

struct WorkingView: View {
    let module: Module
    let title: String
    var detail: String = ""
    var progress: Double? = nil
    var onCancel: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            ModuleGlyph(module: module, size: 170, spinning: true)
            Text(title).font(.system(size: 26, weight: .bold))
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.white)
                    .frame(width: 320)
            }
            Text(detail)
                .font(.callout.monospaced())
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 520)
            Spacer()
            if let onCancel {
                Button(L("Detener"), action: onCancel)
                    .buttonStyle(PillButtonStyle())
                    .padding(.bottom, 30)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Done state

struct DoneView: View {
    let module: Module
    let title: String
    let subtitle: String
    var failures: Int = 0
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                Circle().fill(.white.opacity(0.12)).frame(width: 150, height: 150)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 84))
                    .foregroundStyle(.white, module.accent)
            }
            Text(title).font(.system(size: 30, weight: .bold))
            Text(subtitle).font(.title3).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
            if failures > 0 {
                Label(LF("%@ elementos no se pudieron eliminar (en uso o protegidos).", failures),
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.yellow.opacity(0.9))
                    .font(.callout)
            }
            Spacer()
            Button(L("Listo"), action: onDone)
                .buttonStyle(PillButtonStyle(prominent: true))
                .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Buttons

struct PillButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .foregroundStyle(prominent ? .black : .white)
            .background(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.15)), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(prominent ? 0 : 0.2)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct SmallButtonStyle: ButtonStyle {
    var tint: Color = .white
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(tint)
            .background(.white.opacity(configuration.isPressed ? 0.25 : 0.12), in: Capsule())
    }
}

// MARK: - Bottom action bar

struct ActionBar: View {
    let module: Module
    let summary: String
    let buttonTitle: String
    var enabled: Bool = true
    var secondaryTitle: String? = nil
    var secondary: (() -> Void)? = nil
    let action: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            if let secondaryTitle, let secondary {
                Button(secondaryTitle, action: secondary).buttonStyle(PillButtonStyle())
            }
            Spacer()
            Text(summary).font(.headline).foregroundStyle(.white.opacity(0.85))
            RoundActionButton(title: buttonTitle, module: module, enabled: enabled, action: action)
                .scaleEffect(0.78)
                .frame(width: 80, height: 80)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
        .background(.black.opacity(0.18))
    }
}

// MARK: - Checkbox

struct CheckCircle: View {
    @Binding var isOn: Bool
    var mixed: Bool = false
    var body: some View {
        Button { isOn.toggle() } label: {
            Image(systemName: isOn ? "checkmark.circle.fill" : (mixed ? "minus.circle.fill" : "circle"))
                .font(.system(size: 17))
                .foregroundStyle(isOn || mixed ? Color.white : Color.white.opacity(0.45))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - File row

struct FileIconView: View {
    let url: URL
    var size: CGFloat = 28
    var body: some View {
        Image(nsImage: FS.icon(for: url))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

struct FileRow: View {
    @Binding var item: FileItem
    var showDate = false

    var body: some View {
        HStack(spacing: 10) {
            CheckCircle(isOn: $item.selected)
            FileIconView(url: item.url)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                Text(item.note ?? item.url.deletingLastPathComponent().path.replacingOccurrences(of: FS.home.path, with: "~"))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if showDate {
                Text(Fmt.date(item.accessed ?? item.modified))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            }
            Text(Fmt.bytes(item.size)).monospacedDigit().foregroundStyle(.white.opacity(0.85))
            Button { FS.reveal(item.url) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.6))
                .help(L("Mostrar en Finder"))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Category results (two-pane review)

struct CategoryResultsView: View {
    @Binding var categories: [JunkCategory]
    @State private var selectedID: String?
    var showDates = false

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach($categories) { $cat in
                        let isSel = (selectedID ?? categories.first?.id) == cat.id
                        HStack(spacing: 10) {
                            CheckCircle(isOn: Binding(get: { cat.allSelected },
                                                      set: { cat.setAll($0) }),
                                        mixed: cat.anySelected && !cat.allSelected)
                            Image(systemName: cat.icon).frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cat.title).font(.system(size: 13, weight: .semibold))
                                Text(LF("%@ elementos", cat.items.count)).font(.caption).foregroundStyle(.white.opacity(0.55))
                            }
                            Spacer()
                            Text(Fmt.bytes(cat.selectedSize)).font(.callout).monospacedDigit()
                        }
                        .padding(10)
                        .background(isSel ? .white.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                        .onTapGesture { selectedID = cat.id }
                    }
                }
                .padding(12)
            }
            .frame(width: 300)
            .background(.black.opacity(0.12))

            if let idx = categories.firstIndex(where: { $0.id == (selectedID ?? categories.first?.id) }) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(categories[idx].title).font(.title2.bold())
                        Text(categories[idx].detail).foregroundStyle(.white.opacity(0.7))
                        if categories[idx].mode == .trash {
                            Label(L("Se moverán a la Papelera"), systemImage: "trash").font(.caption).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .padding(16)
                    List {
                        ForEach($categories[idx].items) { $item in
                            FileRow(item: $item, showDate: showDates)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .listStyle(.plain)
                }
            } else {
                Spacer()
            }
        }
    }
}

// MARK: - Section header

struct ModuleHeader<Trailing: View>: View {
    let module: Module
    let title: String
    var subtitle: String = ""
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: module.icon)
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.bold())
                if !subtitle.isEmpty {
                    Text(subtitle).foregroundStyle(.white.opacity(0.7))
                }
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }
}

extension ModuleHeader where Trailing == EmptyView {
    init(module: Module, title: String, subtitle: String = "") {
        self.module = module
        self.title = title
        self.subtitle = subtitle
        self.trailing = { EmptyView() }
    }
}

// MARK: - Segmented tabs

struct TabPicker<T: Hashable & Identifiable>: View {
    let items: [T]
    @Binding var selection: T
    let label: (T) -> String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items) { item in
                Button { selection = item } label: {
                    Text(label(item))
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .foregroundStyle(selection == item ? .black : .white)
                        .background(selection == item ? AnyShapeStyle(.white) : AnyShapeStyle(.clear), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(.white.opacity(0.12), in: Capsule())
    }
}

// MARK: - Permission banner

struct FullDiskAccessBanner: View {
    @State private var granted = Permissions.hasFullDiskAccess
    var body: some View {
        if !granted {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield").font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Concede Acceso total al disco")).font(.headline)
                    Text(L("Sin él, MacFresh no puede analizar Mail, Safari, la Papelera ni algunas carpetas del sistema."))
                        .font(.caption).foregroundStyle(.white.opacity(0.75))
                }
                Spacer()
                Button(L("Abrir Ajustes")) { Permissions.openFullDiskAccessSettings() }
                    .buttonStyle(SmallButtonStyle())
                Button { granted = Permissions.hasFullDiskAccess } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(SmallButtonStyle())
                    .help(L("Comprobar de nuevo"))
            }
            .padding(12)
            .background(.orange.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 20)
            .padding(.top, 10)
        }
    }
}

// MARK: - Meter ring

struct MeterRing: View {
    let value: Double
    var color: Color = .white
    var lineWidth: CGFloat = 6
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, value)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.5), value: value)
        }
    }
}

// MARK: - Confirmation helper

@MainActor
enum Confirm {
    static func ask(_ title: String, _ message: String, confirm: String = L("Continuar"), destructive: Bool = true) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = destructive ? .warning : .informational
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: L("Cancelar"))
        if destructive, #available(macOS 11.0, *) { alert.buttons.first?.hasDestructiveAction = true }
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func info(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
