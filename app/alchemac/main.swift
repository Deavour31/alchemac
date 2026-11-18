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
    // 파일: closing the window only closes it (the app keeps running; quit with ⌘Q).
    let fileMenu = NSMenu(title: "파일")
    fileMenu.addItem(withTitle: "창 닫기", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    let fileItem = NSMenuItem(); fileItem.submenu = fileMenu; menu.addItem(fileItem)
    // Text fields and selectable text get ⌘C and friends only through these menu items.
    let editMenu = NSMenu(title: "편집")
    editMenu.addItem(withTitle: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(withTitle: "실행 복귀", action: Selector(("redo:")), keyEquivalent: "Z")
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "오려두기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "복사하기", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "전체 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    let editItem = NSMenuItem(); editItem.submenu = editMenu; menu.addItem(editItem)
    // 윈도우: bring the library window back after closing or minimizing it.
    let windowMenu = NSMenu(title: "윈도우")
    let showLibrary = NSMenuItem(title: "프로그램 보관함 보기", action: #selector(AppDelegate.showLibraryMenu(_:)), keyEquivalent: "0")
    showLibrary.target = delegate
    windowMenu.addItem(showLibrary)
    windowMenu.addItem(withTitle: "최소화", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    let windowItem = NSMenuItem(); windowItem.submenu = windowMenu; menu.addItem(windowItem)
    application.mainMenu = menu
    application.windowsMenu = windowMenu
    withExtendedLifetime(delegate) { application.run() }
}
MainActor.assumeIsolated { runApplication() }
