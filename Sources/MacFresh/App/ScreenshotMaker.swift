import AppKit
import SwiftUI

/// `MacFresh --screenshots <dir>` renders every module off-screen into PNGs (used for the README).
/// Only landing screens and generic lists are captured, so no personal files appear.
@MainActor
enum ScreenshotMaker {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--screenshots"), i + 1 < args.count else { return false }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let state = AppState.shared
        state.performance.loadedStartup = true  // avoid the System Events prompt
        state.applications.tab = .updater

        let size = NSSize(width: 1180, height: 760)
        let host = NSHostingView(rootView: ScreenshotLayout().frame(width: size.width, height: size.height)
            .preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -6000, y: -6000), size: size),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFront(nil)

        Task { @MainActor in
            for w in NSApp.windows where w !== window { w.orderOut(nil) }
            for m in Module.allCases {
                state.selection = m
                try? await Task.sleep(for: .seconds(1.5))
                capture(host, to: dir.appendingPathComponent("\(m.rawValue).png"))
            }
            exit(0)
        }
        return true
    }

    private static func capture(_ view: NSView, to url: URL) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// Same layout as the main window, with a pure-SwiftUI sidebar (native vibrancy can't be captured off-screen).
private struct ScreenshotLayout: View {
    @Bindable private var state = AppState.shared
    private let monitor = SystemMonitor.shared

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 236)
            ModuleDetailView()
        }
        .background(Color(hex: 0x1B1B20))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { Circle().fill(Color(hex: UInt32($0))).frame(width: 12, height: 12) }
            }
            .padding(.bottom, 18)
            HStack(spacing: 8) {
                Image(systemName: "leaf.circle.fill").font(.system(size: 22))
                    .foregroundStyle(LinearGradient(colors: [Color(hex: 0x1FB58F), Color(hex: 0x22A6B3)], startPoint: .top, endPoint: .bottom))
                Text("MacFresh").font(.system(size: 17, weight: .bold))
            }
            .padding(.bottom, 14)
            row(.smartCare)
            header(L("Módulos"))
            ForEach([Module.cleanup, .protection, .performance, .applications, .clutter], id: \.self) { row($0) }
            header(L("Herramientas"))
            ForEach([Module.spaceLens, .cloud, .shredder], id: \.self) { row($0) }
            Spacer()
            let used = monitor.diskTotal - monitor.diskFree
            VStack(alignment: .leading, spacing: 6) {
                Label("Macintosh HD", systemImage: "internaldrive").font(.caption.bold())
                ProgressView(value: monitor.diskTotal > 0 ? Double(used) / Double(monitor.diskTotal) : 0).tint(Color(hex: 0x1FB58F))
                Text(LF("%@ libres de %@", Fmt.bytes(monitor.diskFree), Fmt.bytes(monitor.diskTotal)))
                    .font(.caption2).foregroundStyle(.white.opacity(0.55))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 18)
    }

    private func header(_ t: String) -> some View {
        Text(t).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
            .padding(.top, 14).padding(.bottom, 4).padding(.leading, 8)
    }

    private func row(_ m: Module) -> some View {
        HStack(spacing: 8) {
            Image(systemName: m.icon).foregroundStyle(m.accent).frame(width: 20)
            Text(m.title).font(.system(size: 13))
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(state.selection == m ? Color.white.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
    }
}
