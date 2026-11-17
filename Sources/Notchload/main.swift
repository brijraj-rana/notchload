import AppKit
import NotchloadCore
import ServiceManagement
import SwiftUI

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // AppKit normally pushes windows below the menu bar; this one has to reach the top edge.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class NotchController: NSObject {
    private let metrics = Metrics()
    private let state = PanelState()
    private var panel: NotchPanel!

    private var tabRect = NSRect.zero        // hover target while collapsed (screen coordinates)
    private var bodyRect = NSRect.zero       // hover target while expanded
    private var pointerInside = false
    private var pending: DispatchWorkItem?
    private var pollTimer: Timer?
    private var menuOpen = false

    func start() {
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false

        let host = NSHostingView(rootView: RootView(state: state, metrics: metrics))
        host.safeAreaRegions = []
        panel.contentView = host

        layout()
        panel.orderFrontRegardless()
        metrics.start()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }

        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        NSEvent.addGlobalMonitorForEvents(matching: moves) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
        NSEvent.addLocalMonitorForEvents(matching: moves) { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }
        NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.showMenu(for: event) }
            return nil
        }
    }

    // MARK: Layout

    private func layout() {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        var geo = NotchGeometry()
        var top = screen.frame.maxY

        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            geo.notchHeight = screen.safeAreaInsets.top
            geo.notchWidth = max(120, right.minX - left.maxX)
        } else {
            // No notch (external display, lid closed): hang from the bottom of the menu bar instead.
            geo.notchHeight = 0
            top = screen.visibleFrame.maxY
        }
        state.geo = geo

        let size = geo.windowSize
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
        panel.setFrame(frame, display: true)

        let tabHeight = geo.notchHeight + geo.collapsedHeight
        tabRect = NSRect(x: frame.midX - geo.notchWidth / 2, y: top - tabHeight, width: geo.notchWidth, height: tabHeight + 4)
        bodyRect = NSRect(x: frame.midX - geo.expandedWidth / 2, y: top - geo.notchHeight - geo.expandedHeight,
                          width: geo.expandedWidth, height: geo.expandedHeight)
    }

    // MARK: Hover

    private func pointerMoved() {
        guard !menuOpen else { return }
        let point = NSEvent.mouseLocation
        let inside = tabRect.contains(point) || (state.expanded && bodyRect.contains(point))
        guard inside != pointerInside else { return }
        pointerInside = inside

        // Outside the visible shape the window must not swallow clicks meant for whatever is underneath.
        panel.ignoresMouseEvents = !inside && !state.expanded

        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.setExpanded(inside) }
        }
        pending = work
        // Short dwell before opening so passing over the tab doesn't trigger it; slower to close.
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.12 : 0.3), execute: work)
    }

    private func setExpanded(_ expanded: Bool) {
        guard state.expanded != expanded else { return }
        state.expanded = expanded
        metrics.wantsProcesses = expanded
        panel.ignoresMouseEvents = !expanded

        pollTimer?.invalidate()
        pollTimer = nil
        if expanded {
            // Mouse-moved events aren't guaranteed while the pointer rests over our own panel.
            let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pointerMoved() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        }
    }

    // MARK: Menu

    private func showMenu(for event: NSEvent) {
        guard let view = panel.contentView else { return }
        let menu = NSMenu()

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let monitor = NSMenuItem(title: "Open Activity Monitor", action: #selector(openActivityMonitor), keyEquivalent: "")
        monitor.target = self
        menu.addItem(monitor)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Notchload", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)

        menuOpen = true
        menu.popUp(positioning: nil, at: view.convert(event.locationInWindow, from: nil), in: view)
        menuOpen = false
        pointerMoved()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change the login item"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Snapshot (development aid: renders both states with sample data to PNG and exits)

    func snapshot(to directory: String) {
        var demo = Snapshot()
        demo.cpu = 0.34
        demo.cores = [0.71, 0.58, 0.44, 0.37, 0.22, 0.18, 0.09, 0.05]
        demo.history = (0..<60).map { i in
            let x = Double(i)
            return min(1, max(0.04, 0.26 + 0.14 * sin(x / 5) + 0.09 * sin(x / 1.7) + (i > 44 && i < 52 ? 0.3 : 0)))
        }
        demo.load = [2.41, 2.08, 1.86]
        demo.memTotal = 16 * 1_073_741_824
        demo.memApp = UInt64(6.4 * 1_073_741_824)
        demo.memWired = UInt64(2.1 * 1_073_741_824)
        demo.memCompressed = UInt64(1.3 * 1_073_741_824)
        demo.swapUsed = 512 * 1_048_576
        demo.gpu = 0.18
        demo.netDown = 2.4 * 1_048_576
        demo.netUp = 180 * 1024
        metrics.snap = demo
        metrics.processes = [
            ProcRow(id: 1, name: "Xcode", cpu: 64.2, memBytes: 1_900 * 1_048_576),
            ProcRow(id: 2, name: "WindowServer", cpu: 21.7, memBytes: 310 * 1_048_576),
            ProcRow(id: 3, name: "Safari", cpu: 12.4, memBytes: 640 * 1_048_576),
            ProcRow(id: 4, name: "Figma", cpu: 8.9, memBytes: 1_200 * 1_048_576),
            ProcRow(id: 5, name: "Music", cpu: 2.3, memBytes: 180 * 1_048_576),
        ]

        for expanded in [false, true] {
            let state = PanelState()
            state.expanded = expanded
            let geo = state.geo
            let height = expanded ? geo.windowSize.height : geo.notchHeight + geo.collapsedHeight + 56
            let view = RootView(state: state, metrics: metrics)
                .frame(height: height, alignment: .top)
                .clipped()
                .background(alignment: .top) {
                    ZStack(alignment: .top) {
                        LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.56), Color(red: 0.62, green: 0.56, blue: 0.66)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        Color.white.opacity(0.22).frame(height: geo.notchHeight)
                    }
                }
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let cg = renderer.cgImage,
               let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                let name = expanded ? "expanded.png" : "collapsed.png"
                try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
            }
        }
        exit(0)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = NotchController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            controller.snapshot(to: args[i + 1])
        } else {
            controller.start()
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
