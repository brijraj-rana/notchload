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

/// An invisible panel that takes the keyboard while the pinned panel has the pointer over it, so Escape can
/// reach the app. The notch panel itself never becomes key. Ordering this one out hands the keys straight back
/// to whichever window had them, and being a non-activating panel it never brings Notchload to the front.
final class KeyPanel: NSPanel {
    var onEscape: () -> Void = {}
    var onOtherKey: () -> Void = {}

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape() } else { onOtherKey() }
    }

    override func cancelOperation(_ sender: Any?) { onEscape() }
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
    private var yielding = false             // another notch app (Notchshelf) is using the space under the notch
    private var keyPanel: KeyPanel!
    private var keyYielded = false           // the user typed something else; leave the keyboard alone until the pointer returns
    private var menuProcess: ProcRow?        // the row the open menu was asked about

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

        keyPanel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        keyPanel.level = panel.level
        keyPanel.collectionBehavior = panel.collectionBehavior
        keyPanel.alphaValue = 0
        keyPanel.isOpaque = false
        keyPanel.backgroundColor = .clear
        keyPanel.hasShadow = false
        keyPanel.hidesOnDeactivate = false
        keyPanel.ignoresMouseEvents = true
        keyPanel.isReleasedWhenClosed = false
        keyPanel.onEscape = { [weak self] in
            MainActor.assumeIsolated { self?.unpinAndClose() }
        }
        keyPanel.onOtherKey = { [weak self] in
            MainActor.assumeIsolated {
                self?.keyYielded = true
                self?.updateKeyFocus()
            }
        }

        layout()
        panel.orderFrontRegardless()
        metrics.start()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }

        // Notchshelf announces when its shelf drops out of the notch; stay closed until it is done.
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: Notification.Name("com.brijraj.notchshelf.covering"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setYielding(true) }
        }
        distributed.addObserver(forName: Notification.Name("com.brijraj.notchshelf.clear"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setYielding(false) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == "com.brijraj.notchshelf" else { return }
            MainActor.assumeIsolated { self?.setYielding(false) }
        }

        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        NSEvent.addGlobalMonitorForEvents(matching: moves) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
        NSEvent.addLocalMonitorForEvents(matching: moves) { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            // Alerts and anything else of ours keep their clicks; only the notch panel pins.
            let ours = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.window === self.panel else { return false }
                self.togglePin()
                return true
            }
            return ours ? nil : event
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

    private func setYielding(_ yielding: Bool) {
        self.yielding = yielding
        if yielding {
            pending?.cancel()
            pointerInside = false
            state.pinned = false
            setExpanded(false)
            updateKeyFocus()
        } else {
            pointerMoved()
        }
    }

    private func pointerMoved() {
        guard !menuOpen, !yielding else { return }
        let point = NSEvent.mouseLocation
        let inside = tabRect.contains(point) || (state.expanded && bodyRect.contains(point))
        guard inside != pointerInside else { return }
        pointerInside = inside

        // Outside the visible shape the window must not swallow clicks meant for whatever is underneath.
        // A pinned panel stays open with the pointer elsewhere, so it has to step aside as soon as the pointer leaves.
        panel.ignoresMouseEvents = state.pinned ? !inside : (!inside && !state.expanded)
        if !inside { keyYielded = false }
        updateKeyFocus()

        pending?.cancel()
        guard !state.pinned else { return }
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
        metrics.panelOpen = expanded
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

    // MARK: Pin

    /// A click on the tab or the open panel pins it open; another click hands it back to the pointer.
    private func togglePin() {
        guard !yielding, !menuOpen else { return }
        let point = NSEvent.mouseLocation
        guard tabRect.contains(point) || (state.expanded && bodyRect.contains(point)) else { return }

        pending?.cancel()
        if state.pinned {
            state.pinned = false
            // Back to plain hover: it stays open under the pointer and closes once the pointer leaves.
            pointerInside = false
            pointerMoved()
        } else {
            state.pinned = true
            pointerInside = true
            setExpanded(true)
        }
        updateKeyFocus()
    }

    private func unpinAndClose() {
        guard state.pinned else { return }
        pending?.cancel()
        state.pinned = false
        setExpanded(false)
        // The pointer may still be on the tab; it has to leave and come back to open the panel by hover again.
        panel.ignoresMouseEvents = !tabRect.contains(NSEvent.mouseLocation)
        updateKeyFocus()
    }

    /// Holds the keyboard only while the panel is pinned and the pointer is over it, and returns it otherwise.
    private func updateKeyFocus() {
        let want = state.pinned && pointerInside && !keyYielded && !menuOpen
        if want {
            guard !keyPanel.isKeyWindow else { return }
            keyPanel.setFrameOrigin(NSPoint(x: panel.frame.midX, y: panel.frame.maxY - 1))
            keyPanel.orderFrontRegardless()
            keyPanel.makeKey()
        } else if keyPanel.isVisible {
            keyPanel.orderOut(nil)
        }
    }

    // MARK: Menu

    private func showMenu(for event: NSEvent) {
        guard let view = panel.contentView else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false

        menuProcess = process(at: event.locationInWindow)
        if let proc = menuProcess {
            if ProcessGuard.canQuit(pid: proc.id, name: proc.name) {
                let quit = NSMenuItem(title: "Quit \(proc.name)", action: #selector(quitProcess), keyEquivalent: "")
                quit.target = self
                menu.addItem(quit)
                let force = NSMenuItem(title: "Force Quit \(proc.name)", action: #selector(forceQuitProcess), keyEquivalent: "")
                force.target = self
                menu.addItem(force)
            } else {
                let blocked = NSMenuItem(title: "\(proc.name) can't be quit from here", action: nil, keyEquivalent: "")
                blocked.isEnabled = false
                menu.addItem(blocked)
            }
            menu.addItem(.separator())
        }

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
        updateKeyFocus()
        menu.popUp(positioning: nil, at: view.convert(event.locationInWindow, from: nil), in: view)
        menuOpen = false
        pointerMoved()
        updateKeyFocus()
    }

    /// The process row under a point given in window coordinates, if there is one.
    private func process(at windowPoint: NSPoint) -> ProcRow? {
        guard state.expanded else { return nil }
        let point = CGPoint(x: windowPoint.x, y: panel.frame.height - windowPoint.y)
        // Rows sit 5 points apart; split the gap so there is no dead strip between them.
        guard let hit = state.rowFrames.first(where: { $0.value.insetBy(dx: 0, dy: -2.5).contains(point) }) else { return nil }
        return metrics.processes.first { $0.id == hit.key }
    }

    @objc private func quitProcess() {
        guard let proc = menuProcess, ProcessGuard.canQuit(pid: proc.id, name: proc.name) else { return }
        // A regular app gets the same polite request as Cmd-Q, so it can ask about unsaved work.
        if ProcessGuard.stillMatches(pid: proc.id, name: proc.name, currentName: ProcessGuard.currentName(of: proc.id)),
           let app = NSRunningApplication(processIdentifier: pid_t(proc.id)), app.activationPolicy == .regular {
            if app.terminate() { return }
        }
        report(ProcessGuard.signal(pid: proc.id, name: proc.name, force: false), for: proc)
    }

    @objc private func forceQuitProcess() {
        guard let proc = menuProcess, ProcessGuard.canQuit(pid: proc.id, name: proc.name) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Force quit \(proc.name)?"
        alert.informativeText = "Anything it has not saved will be lost."
        alert.addButton(withTitle: "Force Quit")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        report(ProcessGuard.signal(pid: proc.id, name: proc.name, force: true), for: proc)
    }

    private func report(_ outcome: ProcessGuard.Outcome, for proc: ProcRow) {
        let reason: String
        switch outcome {
        case .sent, .protected: return
        case .changed: reason = "It has already quit."
        case .failed(let code): reason = code == EPERM ? "It belongs to the system or another user." : String(cString: strerror(code))
        }
        let alert = NSAlert()
        alert.messageText = "Couldn't quit \(proc.name)"
        alert.informativeText = reason
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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

    // MARK: Snapshot (development aid: renders each state with sample data to PNG and exits)

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

        demo.battery = Battery(level: 0.82, source: .battery, minutesRemaining: 281)
        demo.disk = Disk(free: 212_400_000_000, total: 494_380_000_000)

        // The tab after a long build: CPU pinned high, the trace replaced by the process responsible.
        var busy = demo
        busy.cpu = 0.93
        busy.history = (0..<60).map { i in
            let x = Double(i)
            return min(1, max(0.04, i < 18 ? 0.3 + 0.1 * sin(x / 3) : 0.9 + 0.06 * sin(x / 2.3)))
        }

        var desktop = demo
        desktop.battery = nil

        render("collapsed.png", snap: demo, to: directory)
        render("expanded.png", snap: demo, expanded: true, to: directory)
        render("culprit.png", snap: busy, culprit: "Xcode", to: directory)
        if CommandLine.arguments.contains("--extras") {
            // States the README does not show, for checking layout by eye.
            render("expanded-pinned-desktop.png", snap: desktop, expanded: true, pinned: true, to: directory)
            var low = demo
            low.battery = Battery(level: 0.08, source: .battery, minutesRemaining: nil)
            low.disk = Disk(free: 9_200_000_000, total: 494_380_000_000)
            render("expanded-low.png", snap: low, expanded: true, to: directory)
            var charging = demo
            charging.battery = Battery(level: 0.46, source: .charging, minutesRemaining: 72)
            render("expanded-charging.png", snap: charging, expanded: true, to: directory)
            render("culprit-long.png", snap: busy, culprit: "Google Chrome Helper (Renderer)", to: directory)
        }
        exit(0)
    }

    private func render(_ name: String, snap: Snapshot, expanded: Bool = false, pinned: Bool = false,
                        culprit: String? = nil, to directory: String) {
        metrics.snap = snap
        metrics.culprit = culprit
        let state = PanelState()
        state.expanded = expanded
        state.pinned = pinned
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
            try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
        }
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
