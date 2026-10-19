import AppKit

@MainActor
func runApplication() {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let delegate = AppDelegate()
    application.delegate = delegate
    let menu = NSMenu()
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Alchemac 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    let item = NSMenuItem(); item.submenu = appMenu; menu.addItem(item)
    application.mainMenu = menu
    withExtendedLifetime(delegate) { application.run() }
}
MainActor.assumeIsolated { runApplication() }
