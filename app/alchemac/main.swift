import AppKit

@MainActor
func runApplication() {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let delegate = AppDelegate()
    application.delegate = delegate

    /// An item whose action is handled (and validated) by the app delegate.
    func command(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = delegate
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        return item
    }
    func topMenu(_ menu: NSMenu, into main: NSMenu) { let item = NSMenuItem(); item.submenu = menu; main.addItem(item) }

    let menu = NSMenu()
    // Alchemac
    let appMenu = NSMenu()
    appMenu.addItem(command("Alchemac에 관하여", #selector(AppDelegate.menuAbout(_:))))
    appMenu.addItem(.separator())
    appMenu.addItem(command("설정…", #selector(AppDelegate.menuSettings(_:)), ","))
    appMenu.addItem(command("업데이트 확인…", #selector(AppDelegate.menuCheckUpdate(_:))))
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Alchemac 가리기", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    let hideOthers = appMenu.addItem(withTitle: "기타 가리기", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    appMenu.addItem(withTitle: "모두 보기", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Alchemac 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    topMenu(appMenu, into: menu)

    // 파일: closing the window only closes it (the app keeps running; quit with ⌘Q).
    let fileMenu = NSMenu(title: "파일")
    fileMenu.addItem(command("프로그램 등록…", #selector(AppDelegate.menuRegister(_:)), "o"))
    fileMenu.addItem(command("설치 파일 실행…", #selector(AppDelegate.menuInstall(_:)), "o", [.command, .shift]))
    fileMenu.addItem(.separator())
    fileMenu.addItem(withTitle: "창 닫기", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    topMenu(fileMenu, into: menu)

    // Text fields and selectable text get ⌘C and friends only through these menu items.
    let editMenu = NSMenu(title: "편집")
    editMenu.addItem(withTitle: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(withTitle: "실행 복귀", action: Selector(("redo:")), keyEquivalent: "Z")
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "오려두기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "복사하기", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "전체 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    topMenu(editMenu, into: menu)

    // 프로그램: acts on the selected row, only while the library window is the key window (see AppDelegate.validateMenuItem).
    let programMenu = NSMenu(title: "프로그램")
    programMenu.addItem(command("실행", #selector(AppDelegate.menuRun(_:)), "r"))
    programMenu.addItem(command("같은 Wine 환경에서 다른 EXE 실행…", #selector(AppDelegate.menuRunTool(_:))))
    programMenu.addItem(command("이 Wine 환경의 프로그램 모두 종료…", #selector(AppDelegate.menuStopEnvironment(_:))))
    programMenu.addItem(.separator())
    programMenu.addItem(command("프로그램 폴더 보기", #selector(AppDelegate.menuReveal(_:)), "r", [.command, .shift]))
    programMenu.addItem(command("이름 변경…", #selector(AppDelegate.menuRename(_:))))
    let screen = NSMenu(title: "화면 설정")
    screen.addItem(command("크기 보정 켜기 (작게 보일 때)", #selector(AppDelegate.menuToggleScaled(_:))))
    screen.addItem(command("선명한 화면(Retina)", #selector(AppDelegate.menuToggleRetina(_:))))
    let metalFXItem = command("성능 우선(MetalFX 업스케일)", #selector(AppDelegate.menuToggleMetalFX(_:)))
    metalFXItem.toolTip = "낮은 해상도로 그린 뒤 Apple MetalFX로 Retina 크기로 키웁니다. 프레임은 오르고 글자는 Retina보다 조금 부드럽습니다. Direct3D 11 게임에만 적용됩니다."
    screen.addItem(metalFXItem)
    let screenItem = NSMenuItem(title: "화면 설정", action: nil, keyEquivalent: ""); screenItem.submenu = screen
    programMenu.addItem(screenItem)
    programMenu.addItem(.separator())
    programMenu.addItem(command("목록에서 제거…", #selector(AppDelegate.menuRemove(_:)), "\u{8}"))
    programMenu.addItem(command("프로그램 삭제…", #selector(AppDelegate.menuDelete(_:))))
    topMenu(programMenu, into: menu)

    let wineMenu = NSMenu(title: "Wine 환경")
    wineMenu.addItem(command("Wine 환경 및 애드온 관리…", #selector(AppDelegate.menuManagement(_:))))
    wineMenu.addItem(.separator())
    wineMenu.addItem(command("이전 실행에서 남은 프로그램 확인…", #selector(AppDelegate.menuOrphans(_:))))
    wineMenu.addItem(command("환경 백업 정리…", #selector(AppDelegate.menuBackups(_:))))
    topMenu(wineMenu, into: menu)

    let addonMenu = NSMenu(title: "애드온")
    addonMenu.addItem(command("애드온 설치…", #selector(AppDelegate.menuInstallAddon(_:))))
    addonMenu.addItem(command("애드온 관리…", #selector(AppDelegate.menuManageAddons(_:))))
    topMenu(addonMenu, into: menu)

    // 윈도우: bring the library window back after closing or minimizing it.
    let windowMenu = NSMenu(title: "윈도우")
    windowMenu.addItem(command("프로그램 보관함 보기", #selector(AppDelegate.showLibraryMenu(_:)), "0"))
    windowMenu.addItem(withTitle: "최소화", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    topMenu(windowMenu, into: menu)

    let helpMenu = NSMenu(title: "도움말")
    helpMenu.addItem(command("최근 오류 로그 보기", #selector(AppDelegate.menuRecentLog(_:))))
    helpMenu.addItem(command("진단 로그 폴더 열기", #selector(AppDelegate.menuLogsFolder(_:))))
    helpMenu.addItem(command("버전 정보 복사", #selector(AppDelegate.menuCopyVersion(_:))))
    helpMenu.addItem(.separator())
    helpMenu.addItem(command("오픈소스 라이선스", #selector(AppDelegate.menuLicenses(_:))))
    topMenu(helpMenu, into: menu)

    application.mainMenu = menu
    application.windowsMenu = windowMenu
    application.helpMenu = helpMenu
    withExtendedLifetime(delegate) { application.run() }
}
MainActor.assumeIsolated { runApplication() }
