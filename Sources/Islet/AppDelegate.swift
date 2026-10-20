import AppKit
import ActivityCore
import BadgesFeature
import BatteryFeature
import CalendarFeature
import ClockAppFeature
import ClockFeature
import CustomFeature
import DevicesFeature
import DownloadsFeature
import NowPlayingFeature
import ShelfFeature

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController?
    private let settings = SettingsWindowController()
    private var terminationSignal: DispatchSourceSignal?
    private var unlockObserver: NSObjectProtocol?
    /// `islet://` links received before the features were installed (a link that launched the app).
    private var pendingURLs: [URL] = []
    private var isReady = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Registered before launch completes so the link that launched the app is delivered here.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:replyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMainMenu()
        handleTerminationSignal()

        // All services are event-driven: starting them costs nothing while idle. Features start their own
        // event sources lazily (only for enabled sub-features) and never prompt at launch.
        _ = ShelfStore.shared
        NowPlayingService.shared.start()
        BatteryMonitor.shared.start()
        installFeatures()

        attachToScreen()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        // Exact name (observing with a nil name delivers nothing on macOS 26). Deadlines that passed while the
        // screen was locked fire now; wake and clock changes are handled by the scheduler itself.
        unlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { ActivityScheduler.shared.recheck() }
        }

        let preferences = Preferences.shared
        GlobalHotKey.shared.onPress = { [weak self] in self?.controller?.toggleFromHotKey() }
        preferences.onHotKeyChange = { enabled in GlobalHotKey.shared.setEnabled(enabled) }
        GlobalHotKey.shared.setEnabled(preferences.hotKeyEnabled)

        isReady = true
        let urls = pendingURLs
        pendingURLs.removeAll()
        urls.forEach(execute)

        #if DEBUG
        if let link = UserDefaults.standard.string(forKey: "debugURL") { Self.sendURLToSelf(link) }
        if let error = GlobalHotKey.shared.errorMessage { NSLog("Islet debug: hotkey: \(error)") }
        if let path = UserDefaults.standard.string(forKey: "debugSettings") {
            settings.snapshot(UserDefaults.standard.string(forKey: "debugTab") == "general" ? .general : .live, to: path)
        }
        controller?.applyDebugState()
        #endif
    }

    #if DEBUG
    /// `-debugURL "islet://…"`: delivers the link as a GetURL Apple Event to this process, through the same handler
    /// as a link opened by LaunchServices (no Automation consent is involved for events sent to oneself).
    private static func sendURLToSelf(_ link: String) {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL),
            targetDescriptor: .currentProcess(), returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: link), forKeyword: keyDirectObject)
        do {
            _ = try event.sendEvent(options: [.noReply], timeout: 2)
        } catch {
            NSLog("Islet debug: couldn't send \(link): \(error.localizedDescription)")
        }
    }
    #endif

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let shelf = ShelfStore.shared
        guard shelf.isTransferring else { return .terminateNow }
        // Move/Copy jobs still running: quit once the files are where the user asked.
        shelf.whenTransfersFinish { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        ShelfStore.shared.prepareForTermination()
        ClockFeature.prepareForTermination()
        DevicesFeature.prepareForTermination()
        DownloadsFeature.prepareForTermination()
        CalendarFeature.prepareForTermination()
        ClockAppFeature.prepareForTermination()
        CustomFeature.prepareForTermination()
        BadgesFeature.prepareForTermination()
        // Feature state is written off the main thread: make sure it is on disk before exiting.
        ActivityStorage.flush()
    }

    // MARK: - Features

    private func installFeatures() {
        ClockFeature.install()
        DevicesFeature.install()
        DownloadsFeature.install()
        CalendarFeature.install()
        // Before the app's `open` handler below: it answers `open clock` (opens the Clock app).
        ClockAppFeature.install()
        CustomFeature.install()
        BadgesFeature.install()

        ClockFeature.onRing = {
            // "Pause music when a timer ends" (Settings › Live Activities).
            guard UserDefaults.standard.bool(forKey: "clock.pauseMusicOnRing") else { return }
            NowPlayingService.shared.pause()     // explicit pause, never a toggle that could resume a stale player
        }
        DownloadsFeature.onAddToShelf = { urls in
            ShelfStore.shared.add(urls: urls)
        }
        CommandRouter.shared.register { [weak self] command in
            guard case .open(let tab) = command else { return nil }
            return self?.controller?.openFromCommand(tab: tab) ?? .failure("The island isn't ready")
        }
    }

    // MARK: - islet:// links

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else { return }
        if isReady {
            execute(url)
        } else {
            pendingURLs.append(url)
        }
    }

    /// Harmless verbs only (no custom activities over URLs: any web page can open a link). Rejected links are ignored.
    private func execute(_ url: URL) {
        guard let command = URLCommandParser.command(from: url) else {
            NSLog("Islet: ignored link \(url.absoluteString)")
            return
        }
        let result = CommandRouter.shared.execute(command)
        if !result.ok { NSLog("Islet: \(url.absoluteString) failed: \(result.error ?? "")") }
        #if DEBUG
        NSLog("Islet debug: \(url.absoluteString) → ok=\(result.ok) \(result.message ?? result.error ?? "")")
        #endif
    }

    // MARK: - Menus & lifecycle

    /// Never shown (accessory app), but its key equivalents are what make ⌘W and ⌘Q work while Settings is key,
    /// and ⌘C / ⌘V / ⌘A / ⌘Z in the island's command field.
    private static func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Islet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let mainMenu = NSMenu()
        for submenu in [appMenu, editMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        return mainMenu
    }

    /// SIGTERM (`kill`, `pkill`) quits like ⌘Q, so running Move/Copy jobs finish and the shelf cache is tidied.
    private func handleTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        source.resume()
        terminationSignal = source
    }

    @objc private func screensChanged() {
        attachToScreen()
    }

    private func attachToScreen() {
        guard let screen = NotchGeometry.preferredScreen() else { return }
        if let controller {
            controller.update(screen: screen)
        } else {
            controller = NotchController(screen: screen) { [weak self] pane in self?.settings.show(pane) }
        }
    }
}
