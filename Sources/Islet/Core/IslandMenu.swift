import AppKit
import ActivityCore
import CalendarFeature

/// The right-click quick menu: start an activity from any launcher, then control each running one (its
/// actions, pin, hide for 10 min). Built on demand, released when it closes.
@MainActor
enum IslandMenu {
    struct Handlers {
        /// Runs a launcher command.
        var run: (IsletCommand) -> Void
        /// Opens the launcher with this text in the command field ("" for a custom timer, "at " for alarms).
        var openLauncher: (String) -> Void
        var openSettings: () -> Void
    }

    static func make(items: [any LiveActivity], handlers: Handlers) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let center = ActivityCenter.shared

        for launcher in center.launchers {
            let item = ClosureMenuItem(title: launcher.title)
            item.image = symbol(launcher.symbol)
            if let primary = launcher.primary {
                item.handler = { handlers.run(primary) }
            } else if !launcher.options.isEmpty {
                let submenu = NSMenu()
                for option in launcher.options {
                    let command = option.command
                    submenu.addItem(ClosureMenuItem(title: option.title) { handlers.run(command) })
                }
                if launcher.prefill == nil, case .timerStart = launcher.options.first?.command {
                    submenu.addItem(.separator())
                    submenu.addItem(ClosureMenuItem(title: "Custom…") { handlers.openLauncher("") })
                }
                item.submenu = submenu
            } else if let prefill = launcher.prefill {
                item.title += "…"
                item.handler = { handlers.openLauncher(prefill) }
            } else if launcher.id == CalendarFeature.launcherID {
                item.handler = { CalendarFeature.openFromLauncher() }
            } else {
                continue
            }
            menu.addItem(item)
        }

        for activity in items {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem.sectionHeader(title: activity.title))
            for action in activity.actions {
                let item = ClosureMenuItem(title: action.title) { action.perform() }
                item.image = symbol(action.symbol)
                item.isEnabled = action.isEnabled
                menu.addItem(item)
            }
            // Only registered activities can be pinned or hidden (a paused track isn't running).
            guard center.activity(id: activity.id) != nil else { continue }
            let id = activity.id
            let pinned = center.pinnedID == id
            menu.addItem(ClosureMenuItem(title: pinned ? "Unpin from Island" : "Pin to Island") {
                center.pinnedID = pinned ? nil : id
            })
            let hidden = center.isHidden(id: id)
            menu.addItem(ClosureMenuItem(title: hidden ? "Show in Island" : "Hide for 10 Minutes") {
                hidden ? center.unhide(id: id) : center.hide(id: id)
            })
        }

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Settings…", handler: handlers.openSettings))
        return menu
    }

    private static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        return image?.withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
    }
}

/// Menu item running a closure (it is its own target).
final class ClosureMenuItem: NSMenuItem {
    var handler: (@MainActor () -> Void)?

    init(title: String, handler: (@MainActor () -> Void)? = nil) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func invoke() {
        MainActor.assumeIsolated { handler?() }
    }
}
