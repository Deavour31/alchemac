import Foundation

enum AlchemacRuntime {
    static var root: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/SharedSupport/runtime", isDirectory: true) }
    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
    /// Builds made for this Mac only; release builds leave the key out.
    static var isDevelopment: Bool { Bundle.main.object(forInfoDictionaryKey: "AlchemacDevelopmentBuild") as? Bool ?? false }
    /// Alchemac's own license and every bundled component's license and notice.
    static var licenses: URL { Bundle.main.resourceURL!.appendingPathComponent("Licenses", isDirectory: true) }
    static var buildID: String {
        (try? String(contentsOf: root.appendingPathComponent("BUILD-ID"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "알 수 없음"
    }

    static func configure(_ process: Process, launcher: Launcher, store: LauncherStore, runtime: URL = root, resources: URL? = nil) throws {
        let exe = try store.executable(launcher)
        guard FileManager.default.fileExists(atPath: exe.path) else {
            throw AlchemacError.message("등록된 실행 파일을 찾을 수 없습니다. 프로그램 폴더를 확인해 주세요.")
        }
        // A program imported with an add-on runs only with that recipe's settings.
        var settings: [String: String] = [:]
        if let id = launcher.addon {
            guard let addon = store.addon(id) else {
                throw AlchemacError.message("‘\(launcher.name)’은(는) ‘\(id)’ 애드온 설정으로 실행해야 합니다. 애드온 메뉴에서 애드온을 설치해 주세요.")
            }
            settings = addon.launchEnvironment
        }
        try prepare(process, session: "alchemac-" + launcher.id, target: try store.windowsExecutable(launcher),
                    workdir: try store.game(launcher), prefix: try store.prefix(launcher), logs: launcher.id,
                    settings: settings, mode: launcher.scaled ? "--launch-scaled" : "--launch",
                    store: store, runtime: runtime, resources: resources)
    }

    /// Imports a .reg file into a Wine prefix of this library with Wine's regedit.
    static func configureRegistry(_ process: Process, prefix: URL, script: URL, store: LauncherStore, runtime: URL = root, resources: URL? = nil) throws {
        guard store.contains(prefix), !script.path.contains("\"") else { throw AlchemacError.message("설정 파일을 적용할 수 없습니다.") }
        try prepare(process, session: "alchemac-registry", target: "regedit.exe /S \"" + windows(script) + "\"",
                    workdir: prefix.appendingPathComponent("drive_c", isDirectory: true), prefix: prefix, logs: "registry",
                    settings: [:], mode: "--command", store: store, runtime: runtime, resources: resources)
    }

    /// Runs an installer from wherever it was downloaded; `environment` (nil: shared) receives the install.
    static func configureInstaller(_ process: Process, setup: URL, environment: String? = nil, store: LauncherStore, runtime: URL = root, resources: URL? = nil) throws {
        let file = setup.standardizedFileURL
        guard file.pathExtension.lowercased() == "exe", !file.path.contains("\""),
              FileManager.default.fileExists(atPath: file.path) else {
            throw AlchemacError.message("설치 파일(.exe)을 선택해 주세요.")
        }
        guard environment.map(Launcher.validEnvironment) ?? true else { throw AlchemacError.message("Wine 환경 이름이 올바르지 않습니다.") }
        try prepare(process, session: "alchemac-setup", target: windows(file), workdir: file.deletingLastPathComponent(),
                    prefix: store.prefix(environment: environment), logs: "setup", settings: [:], mode: "--setup",
                    store: store, runtime: runtime, resources: resources)
    }

    /// Runs another EXE, such as a patch or a tool for the program, in that program's Wine environment.
    static func configureTool(_ process: Process, tool: URL, for launcher: Launcher, store: LauncherStore, runtime: URL = root, resources: URL? = nil) throws {
        let file = tool.standardizedFileURL
        guard file.pathExtension.lowercased() == "exe", !file.path.contains("\""),
              FileManager.default.fileExists(atPath: file.path) else {
            throw AlchemacError.message("실행할 Windows 프로그램(.exe)을 선택해 주세요.")
        }
        try prepare(process, session: "alchemac-" + launcher.id, target: windows(file), workdir: file.deletingLastPathComponent(),
                    prefix: try store.prefix(launcher), logs: launcher.id,
                    settings: launcher.addon.flatMap(store.addon)?.launchEnvironment ?? [:], mode: "--setup",
                    store: store, runtime: runtime, resources: resources)
    }

    /// Runs another EXE inside the program's running session, which `session-attach` joins.
    static func configureAttachedTool(_ process: Process, tool: URL, for launcher: Launcher, store: LauncherStore, runtime: URL = root, resources: URL? = nil) throws {
        try configureTool(process, tool: tool, for: launcher, store: store, runtime: runtime, resources: resources)
        let assets = resources ?? runtime.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        let script = assets.appendingPathComponent("session-attach")
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            throw AlchemacError.message("앱의 실행 환경이 누락됐습니다. 앱을 다시 설치해 주세요.")
        }
        process.executableURL = script
    }

    /// Runs a program's registered Windows uninstaller in the program's own environment.
    static func configureUninstall(_ process: Process, launcher: Launcher, command: String, store: LauncherStore, runtime: URL = root, resources: URL? = nil) throws {
        guard launcher.kind == .installed, !command.isEmpty, command.count <= 2048,
              !command.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw AlchemacError.message("제거 명령을 실행할 수 없습니다.")
        }
        let prefix = try store.prefix(launcher)
        try prepare(process, session: "alchemac-" + launcher.id, target: command, workdir: prefix.appendingPathComponent("drive_c", isDirectory: true),
                    prefix: prefix, logs: launcher.id, settings: [:], mode: "--command", store: store, runtime: runtime, resources: resources)
    }

    private static func prepare(_ process: Process, session: String, target: String, workdir: URL, prefix: URL, logs name: String,
                                settings: [String: String], mode: String = "--launch", store: LauncherStore, runtime: URL, resources: URL?) throws {
        let fm = FileManager.default
        let script = runtime.appendingPathComponent("scripts/standalone-run")
        let assets = resources ?? runtime.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        let profile = assets.appendingPathComponent("prefix-profile.exe")
        let font = assets.appendingPathComponent("Fonts/NanumGothic-Regular.ttf")
        try store.requireLocal(store.support)
        try store.requireLocal(prefix)
        guard fm.isExecutableFile(atPath: script.path), fm.fileExists(atPath: runtime.appendingPathComponent("BUILD-ID").path) else {
            throw AlchemacError.message("앱의 실행 환경이 누락됐습니다. 앱을 다시 설치해 주세요.")
        }
        guard fm.fileExists(atPath: profile.path), fm.fileExists(atPath: font.path) else {
            throw AlchemacError.message("한글 글꼴 준비 파일이 누락됐습니다. 앱을 다시 설치해 주세요.")
        }
        refreshD3D9(prefix: prefix, runtime: runtime)
        // standalone-run creates an absent prefix next to itself, so its parent must exist.
        try fm.createDirectory(at: prefix.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let logs = store.logs.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: logs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        process.executableURL = script
        // Prepare this locked prefix, then start the program as a child.
        // standalone-run waits for the whole Wine session, not just this helper.
        process.arguments = [session, profile.path, mode, windows(font), target]
        // A new environment has no drive_c yet; the launch directory must exist, HADRON_WORKDIR may still name it.
        process.currentDirectoryURL = fm.fileExists(atPath: workdir.path) ? workdir : prefix.deletingLastPathComponent()
        // No inherited host tokens, Wine/CrossOver state, DYLD injection or shell evaluation.
        var environment = [
            "HOME": fm.homeDirectoryForCurrentUser.path, "USER": NSUserName(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": NSTemporaryDirectory(),
            "LANG": "ko_KR.UTF-8", "LC_ALL": "ko_KR.UTF-8", "WINEDEBUG": "-all",
            "WINEPREFIX": prefix.path, "HADRON_SUPPORT": store.support.path,
            "HADRON_LOGS": logs.path, "HADRON_WORKDIR": workdir.path, "HADRON_APP_NAME": "Alchemac Runtime"
        ]
        // Add-on settings are limited to Addon.allowedEnvironment and never replace Alchemac's own keys.
        for (key, value) in settings where Addon.allowedEnvironment.contains(key) && environment[key] == nil { environment[key] = value }
        process.environment = environment
    }

    /// A prefix receives mtld3d's native d3d9.dll only when it is created. For an existing, complete prefix this
    /// replaces that file with the runtime's when they differ. A file without the "mtld3d" marker (Wine's builtin
    /// or one a user put there) and an absent file are left alone. Failures are logged and never stop the launch.
    static func refreshD3D9(prefix: URL, runtime: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: prefix.appendingPathComponent(".hadron-prefix-ready").path),
              !fm.fileExists(atPath: prefix.appendingPathComponent(".hadron-migration-incomplete").path) else { return }
        let source = runtime.appendingPathComponent("dist/lib/hadron/d3d9", isDirectory: true)
        for (arch, folder) in [("aarch64", "system32"), ("i386", "syswow64")] {
            let new = source.appendingPathComponent(arch + "/d3d9.dll")
            let old = prefix.appendingPathComponent("drive_c/windows/" + folder + "/d3d9.dll")
            guard let current = try? Data(contentsOf: old), current.range(of: Data("mtld3d".utf8)) != nil,
                  let latest = try? Data(contentsOf: new), latest != current else { continue }
            let temp = old.deletingLastPathComponent().appendingPathComponent(".d3d9.dll.alchemac-\(UUID().uuidString)")
            do {
                try latest.write(to: temp)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.path)
                guard rename(temp.path, old.path) == 0 else { throw AlchemacError.message(String(cString: strerror(errno))) }
            } catch {
                try? fm.removeItem(at: temp)
                fputs("Alchemac: d3d9.dll refresh failed (\(folder)): \(error)\n", stderr)
            }
        }
    }

    static func windows(_ path: URL) -> String { "Z:" + path.path.replacingOccurrences(of: "/", with: "\\") }
}
