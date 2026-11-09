import AppKit
import ServiceManagement
import SwiftUI

@main
struct MacFreshApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage("showMenuBar") private var showMenuBar = true

    init() {
        if CommandLine.arguments.contains("--selftest") { SelfTest.run() }
    }

    var body: some Scene {
        Window("MacFresh", id: "main") {
            ContentView()
                .frame(minWidth: 1060, minHeight: 700)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarView()
                .preferredColorScheme(.dark)
        } label: {
            Image(systemName: "leaf.circle.fill")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .frame(width: 560, height: 420)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        _ = SystemMonitor.shared
        if ScreenshotMaker.runIfRequested() { return }
        // Notifications require a real app bundle (not available under `swift run`).
        if Bundle.main.bundleIdentifier != nil {
            Task { @MainActor in DiskAlerts.start() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: "showMenuBar") && UserDefaults.standard.object(forKey: "showMenuBar") != nil
    }
}

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    var selection: Module = .smartCare

    let smartCare = SmartCareModel()
    let cleanup = CleanupModel()
    let protection = ProtectionModel()
    let performance = PerformanceModel()
    let applications = ApplicationsModel()
    let clutter = ClutterModel()
    let spaceLens = SpaceLensModel()
    let cloud = CloudModel()
    let shredder = ShredderModel()
}

// MARK: - Main window

struct ContentView: View {
    @Bindable private var state = AppState.shared

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $state.selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 230, max: 260)
        } detail: {
            ModuleDetailView()
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
    }
}

/// The colored module area to the right of the sidebar.
struct ModuleDetailView: View {
    @Bindable private var state = AppState.shared

    var body: some View {
        ZStack {
            ModuleBackground(module: state.selection)
            detail
                .foregroundStyle(.white)
                .tint(.white)
        }
        .animation(.easeInOut(duration: 0.35), value: state.selection)
    }

    @ViewBuilder private var detail: some View {
        switch state.selection {
        case .smartCare: SmartCareView(model: state.smartCare)
        case .cleanup: CleanupView(model: state.cleanup)
        case .protection: ProtectionView(model: state.protection)
        case .performance: PerformanceView(model: state.performance)
        case .applications: ApplicationsView(model: state.applications)
        case .clutter: ClutterView(model: state.clutter)
        case .spaceLens: SpaceLensView(model: state.spaceLens)
        case .cloud: CloudView(model: state.cloud)
        case .shredder: ShredderView(model: state.shredder)
        }
    }
}

struct Sidebar: View {
    @Binding var selection: Module
    private let monitor = SystemMonitor.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "leaf.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(LinearGradient(colors: [Color(hex: 0x1FB58F), Color(hex: 0x22A6B3)],
                                                    startPoint: .top, endPoint: .bottom))
                Text("MacFresh").font(.system(size: 17, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 34)
            .padding(.bottom, 10)

            List(selection: Binding(get: { selection }, set: { if let v = $0 { selection = v } })) {
                row(.smartCare)
                Section(L("Módulos")) {
                    ForEach([Module.cleanup, .protection, .performance, .applications, .clutter], id: \.self) { row($0) }
                }
                Section(L("Herramientas")) {
                    ForEach([Module.spaceLens, .cloud, .shredder], id: \.self) { row($0) }
                }
            }
            .listStyle(.sidebar)

            diskSummary
        }
    }

    private func row(_ m: Module) -> some View {
        Label {
            Text(m.title)
        } icon: {
            Image(systemName: m.icon)
                .foregroundStyle(m.accent)
        }
        .tag(m)
        .padding(.vertical, 3)
    }

    private var diskSummary: some View {
        let used = monitor.diskTotal - monitor.diskFree
        let frac = monitor.diskTotal > 0 ? Double(used) / Double(monitor.diskTotal) : 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "internaldrive")
                Text("Macintosh HD").font(.caption.bold())
                Spacer()
            }
            ProgressView(value: frac).tint(frac > 0.9 ? .red : Color(hex: 0x1FB58F))
            Text(LF("%@ libres de %@", Fmt.bytes(monitor.diskFree), Fmt.bytes(monitor.diskTotal)))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
    }
}

// MARK: - Settings

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label(L("General"), systemImage: "gearshape") }
            ExclusionSettings().tabItem { Label(L("Exclusiones"), systemImage: "nosign") }
        }
        .padding(20)
    }
}

struct GeneralSettings: View {
    @AppStorage("showMenuBar") private var showMenuBar = true
    @AppStorage("lowDiskAlert") private var lowDiskAlert = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var fda = Permissions.hasFullDiskAccess

    var body: some View {
        Form {
            Toggle(L("Mostrar MacFresh en la barra de menús"), isOn: $showMenuBar)
            Toggle(L("Abrir MacFresh al iniciar sesión"), isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Toggle(L("Avisar cuando quede poco espacio en disco"), isOn: $lowDiskAlert)
            LabeledContent(L("Acceso total al disco")) {
                HStack {
                    Text(fda ? L("Concedido") : L("No concedido")).foregroundStyle(fda ? .green : .orange)
                    Button(L("Abrir Ajustes")) { Permissions.openFullDiskAccessSettings() }
                    Button(L("Comprobar")) { fda = Permissions.hasFullDiskAccess }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ExclusionSettings: View {
    @State private var items: [String] = Preferences.exclusions
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading) {
            Text(L("MacFresh nunca analizará ni eliminará estas carpetas o archivos."))
                .foregroundStyle(.secondary)
            List(items, id: \.self, selection: $selection) { Text($0).lineLimit(1).truncationMode(.middle) }
                .frame(minHeight: 220)
            HStack {
                Button(L("Añadir…")) {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = true
                    panel.allowsMultipleSelection = true
                    if panel.runModal() == .OK {
                        items += panel.urls.map(\.path).filter { !items.contains($0) }
                        Preferences.exclusions = items
                    }
                }
                Button(L("Quitar")) {
                    items.removeAll { $0 == selection }
                    Preferences.exclusions = items
                }
                .disabled(selection == nil)
            }
        }
    }
}
