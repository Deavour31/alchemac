import Foundation
import CryptoKit
import Darwin

@main
struct SelfTests {
    @MainActor static func main() throws {
        let fm = FileManager.default
        let temp = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("alchemac-app-unit-" + UUID().uuidString)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        var passed = 0
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw AlchemacError.message("FAIL: " + label) }
            passed += 1; print("PASS: " + label)
        }
        func rejects(_ label: String, _ action: () throws -> Void) throws {
            do { try action() } catch { passed += 1; print("PASS: " + label); return }
            throw AlchemacError.message("FAIL: " + label)
        }
        let store = try LauncherStore(root: temp.appendingPathComponent("library"), logs: temp.appendingPathComponent("logs"))
        try check(store.read().launchers.isEmpty, "empty library does not register or run a launcher")
        try rejects("second app cannot acquire library lock") { _ = try LauncherStore(root: store.root, logs: store.logs) }
        try rejects("path traversal ID rejected") { try Launcher(id: "../outside", name: "Bad", executable: "GameLauncher.exe").validate() }
        try rejects("own prefix only for copied programs") { try Launcher(id: "valid", name: "Bad", executable: "C:\\x.exe", kind: .installed, privatePrefix: true).validate() }
        try rejects("unknown program kind rejected") { _ = try JSONDecoder().decode(Launcher.self, from: Data(#"{"id":"x","name":"x","executable":"x.exe","kind":"script"}"#.utf8)) }
        try rejects("wrong schema rejected") { try Registry(schemaVersion: 2).validate() }
        let source = temp.appendingPathComponent("원본 폴더 with spaces")
        try fm.createDirectory(at: source.appendingPathComponent("Game_Data/Logs"), withIntermediateDirectories: true)
        for (name, text) in [("GameLauncher.exe", "fixture-exe"), ("engine.dll", "fixture-dll"),
                             ("account.txt", "account-secret"), ("player.log", "private-log"),
                             ("Game_Data/Logs/private.txt", "nested-secret"), ("Game_Data/keep.dat", "asset"), (".hidden", "hidden-secret")] {
            try Data(text.utf8).write(to: source.appendingPathComponent(name))
        }
        // A sample add-on bundle, written the way add-on authors ship one.
        let sampleBundle = temp.appendingPathComponent("Sample.alchemacaddon")
        try fm.createDirectory(at: sampleBundle, withIntermediateDirectories: true)
        try Data(#"{"schema":1,"id":"sample","name":"Sample Game","version":"1.0.0","detect":{"executable":"GameLauncher.exe","siblings":["Game_Data"]},"import":{"exclude":["account.txt","logs","*.log",".*"]},"environment":{"mode":"private"},"launch":{"env":{"DOTNET_BUNDLE_EXTRACT_BASE_DIR":"C:\\windows\\temp\\sample-dotnet"},"englishInput":true}}"#.utf8)
            .write(to: sampleBundle.appendingPathComponent("addon.json"))
        try Data("Sample add-on\n".utf8).write(to: sampleBundle.appendingPathComponent("README.md"))
        try Data("not copied".utf8).write(to: sampleBundle.appendingPathComponent("extra.sh"))
        try check(store.matchingAddon(source.appendingPathComponent("GameLauncher.exe")) == nil, "no add-on applies before one is installed")
        let sample = try store.installAddon(from: sampleBundle)
        try check(sample.id == "sample" && store.installedAddons() == [sample] && sample.englishInput && sample.mode == .private,
                  "add-on installs and reads back its recipe")
        try check(Set(try fm.contentsOfDirectory(atPath: store.addonFolder("sample").path)) == ["addon.json", "README.md"], "only the manifest and README are installed")
        var imported = try store.importProgram(from: source.appendingPathComponent("GameLauncher.exe"))
        try check(imported.addon == "sample" && imported.privatePrefix && imported.kind == .copied && imported.name == "Sample Game",
                  "add-on detection imports the program as a copy with its own prefix")
        try check(try store.prefix(imported) == store.directory(imported).appendingPathComponent("prefix", isDirectory: true), "own prefix sits in the program's library folder")
        let game = try store.game(imported)
        try check(try Data(contentsOf: game.appendingPathComponent("engine.dll")) == Data("fixture-dll".utf8), "import preserves binary bytes")
        try check(!fm.fileExists(atPath: game.appendingPathComponent("account.txt").path), "import excludes account config")
        try check(!fm.fileExists(atPath: game.appendingPathComponent("player.log").path), "import excludes logs")
        try check(!fm.fileExists(atPath: game.appendingPathComponent("Game_Data/Logs").path), "import excludes nested log directories")
        try check(!fm.fileExists(atPath: game.appendingPathComponent(".hidden").path), "import excludes hidden files")
        try check(fm.fileExists(atPath: game.appendingPathComponent("Game_Data/keep.dat").path), "file exclusion preserves the next directory's assets")
        try check(try Data(contentsOf: source.appendingPathComponent("account.txt")) == Data("account-secret".utf8), "source account unchanged")
        // The confirmation before a copy counts what the copy takes.
        let copyPlan = store.copyPlan(for: source.appendingPathComponent("GameLauncher.exe"))
        try check(copyPlan?.addon?.id == "sample" && copyPlan?.folder.path == source.standardizedFileURL.path, "an add-on EXE is planned as a folder copy")
        var copiedFiles = 0, copiedBytes: Int64 = 0
        for case let item as URL in fm.enumerator(at: game, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])! {
            let values = try item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true { copiedFiles += 1; copiedBytes += Int64(values.fileSize ?? 0) }
        }
        let surveyed = LauncherStore.survey(source, excluding: copyPlan!.excludes)
        try check(surveyed == LauncherStore.FolderSurvey(files: copiedFiles, bytes: copiedBytes, capped: false), "the survey matches what the import copied")
        try check(LauncherStore.survey(source, excluding: { _ in false }, maxEntries: 1).capped, "a survey over its cap says so")
        try check(store.copyPlan(for: store.sharedPrefix.appendingPathComponent("drive_c/Program Files/App/app.exe")) == nil, "an EXE inside a Wine environment copies nothing")
        let fakeHome = temp.appendingPathComponent("fake-home")
        for name in ["Downloads/Game", "Desktop", "Documents", "Other"] { try fm.createDirectory(at: fakeHome.appendingPathComponent(name), withIntermediateDirectories: true) }
        try check(["", "Downloads", "Desktop", "Documents"].allSatisfy { LauncherStore.broadFolderWarning(fakeHome.appendingPathComponent($0), home: fakeHome)?.contains("전체가 복사됩니다") == true }
                  && ["Downloads/Game", "Other"].allSatisfy { LauncherStore.broadFolderWarning(fakeHome.appendingPathComponent($0), home: fakeHome) == nil }, "Downloads, Desktop, Documents and home warn; a program folder does not")
        imported.name = "Quoted \" launcher 한글"
        try store.write(Registry(selectedID: imported.id, launchers: [imported]))
        try check(try store.read().launchers.first == imported, "registry persists selection and Unicode name")
        try rejects("duplicate IDs rejected") { try Registry(launchers: [imported, imported]).validate() }
        try fm.createSymbolicLink(atPath: source.appendingPathComponent("linked.dll").path, withDestinationPath: "/etc/hosts")
        try rejects("import refuses external links") { _ = try store.importProgram(from: source.appendingPathComponent("GameLauncher.exe")) }
        try fm.removeItem(at: source.appendingPathComponent("linked.dll"))
        let mock = temp.appendingPathComponent("runtime")
        try fm.createDirectory(at: mock.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: mock.appendingPathComponent("scripts/standalone-run"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mock.appendingPathComponent("scripts/standalone-run").path)
        try Data("fixture\n".utf8).write(to: mock.appendingPathComponent("BUILD-ID"))
        let resources = temp.appendingPathComponent("Resources")
        try fm.createDirectory(at: resources.appendingPathComponent("Fonts"), withIntermediateDirectories: true)
        try Data("fixture helper".utf8).write(to: resources.appendingPathComponent("prefix-profile.exe"))
        try Data("fixture font".utf8).write(to: resources.appendingPathComponent("Fonts/NanumGothic-Regular.ttf"))
        let process = Process()
        try AlchemacRuntime.configure(process, launcher: imported, store: store, runtime: mock, resources: resources)
        try check(process.arguments == ["alchemac-" + imported.id, resources.appendingPathComponent("prefix-profile.exe").path, "--launch", AlchemacRuntime.windows(resources.appendingPathComponent("Fonts/NanumGothic-Regular.ttf")), AlchemacRuntime.windows(game.appendingPathComponent("GameLauncher.exe"))], "helper and original launcher argv remain separate, no shell evaluation")
        try check(process.environment?["HADRON_WORKDIR"] == game.path, "helper starts original launcher in game directory")
        try check(process.environment?["HOME"] == fm.homeDirectoryForCurrentUser.path, "real HOME retained")
        try check(process.environment?["WINEPREFIX"] == store.prefix(imported).path, "dedicated prefix selected")
        try check(process.environment?["STEAM_APP_ID"] == nil && process.environment?["DYLD_INSERT_LIBRARIES"] == nil && process.environment?["EXAMPLE_TOOL_HOME"] == nil, "unrelated host environment absent")
        try check(process.environment?["DOTNET_BUNDLE_EXTRACT_BASE_DIR"] == "C:\\windows\\temp\\sample-dotnet", "Windows extraction path retained")
        let plain = try JSONDecoder().decode(Launcher.self, from: Data(#"{"id":"tool","name":"Tool","executable":"tool.exe"}"#.utf8))
        try check(plain.kind == .copied && plain.addon == nil && !plain.privatePrefix && plain.environment == nil && !plain.scaled,
                  "entries without optional fields read as plain copied programs")
        // Add-on manifests are validated before anything is installed.
        func manifest(_ json: String) throws -> URL {
            let folder = temp.appendingPathComponent("bad-" + UUID().uuidString + ".alchemacaddon")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(json.utf8).write(to: folder.appendingPathComponent("addon.json"))
            return folder
        }
        let base = #""schema":1,"id":"demo","name":"Demo","version":"1.0","detect":{"executable":"demo.exe"}"#
        for (label, json) in [("unknown schema", #"{"schema":2,"id":"demo","name":"Demo","version":"1","detect":{"executable":"demo.exe"}}"#),
                              ("bad id", #"{"schema":1,"id":"../x","name":"Demo","version":"1","detect":{"executable":"demo.exe"}}"#),
                              ("environment key outside the allowlist", "{" + base + #","launch":{"env":{"DYLD_INSERT_LIBRARIES":"x"}}}"#),
                              ("prefix override", "{" + base + #","launch":{"env":{"WINEPREFIX":"/tmp/x"}}}"#),
                              ("non-EXE detection", #"{"schema":1,"id":"demo","name":"Demo","version":"1","detect":{"executable":"demo.sh"}}"#),
                              ("path in exclusions", "{" + base + #","import":{"exclude":["../secret"]}}"#)] {
            try rejects("add-on rejected: " + label) { _ = try store.installAddon(from: try manifest(json)) }
        }
        try check(store.installedAddons().map(\.id) == ["sample"], "rejected add-ons leave nothing installed")
        let demo = try store.installAddon(from: try manifest("{" + base + #","environment":{"mode":"shared"},"import":{"exclude":["*.log","cache"]}}"#).appendingPathComponent("addon.json"))
        try check(demo.mode == .shared && demo.excludes(URL(fileURLWithPath: "/x/a.LOG")) && demo.excludes(URL(fileURLWithPath: "/x/Cache"))
                  && !demo.excludes(URL(fileURLWithPath: "/x/data.bin")), "exclusion patterns match names and extensions")
        let upgraded = try store.installAddon(from: try manifest(#"{"schema":1,"id":"demo","name":"Demo","version":"2.0","detect":{"executable":"demo.exe"}}"#))
        try check(upgraded.version == "2.0" && store.addon("demo")?.version == "2.0", "installing again replaces the add-on")
        try check(store.addonExists("demo") && !store.addonExists("nothing-here") && (try store.readAddon(from: try manifest(#"{"schema":1,"id":"nothing-here","name":"N","version":"1","detect":{"executable":"n.exe"}}"#)).addon.id) == "nothing-here"
                  && !store.addonExists("nothing-here"), "reading an add-on installs nothing and tells whether its id exists")
        do { _ = try store.readAddon(from: try manifest("{ not json")); try check(false, "broken JSON is rejected") }
        catch { try check(error.localizedDescription == "애드온 설정 파일을 읽지 못했습니다. 애드온을 다시 받아 설치해 주세요.", "broken add-on JSON gets the plain message") }
        do { _ = try store.readAddon(from: try manifest(#"{"schema":2,"id":"demo","name":"Demo","version":"1","detect":{"executable":"demo.exe"}}"#)); try check(false, "a newer schema is rejected") }
        catch { try check(error.localizedDescription == "이 애드온 형식을 지원하지 않습니다. 최신 Alchemac에서 다시 시도해 주세요.", "an unknown add-on schema gets the plain message") }
        var orphan = imported; orphan.addon = "missing"
        try rejects("program refuses to run without its add-on") { try AlchemacRuntime.configure(Process(), launcher: orphan, store: store, runtime: mock, resources: resources) }
        try check(Launcher.validExecutable("C:\\Program Files\\Origin\\Origin64.exe", kind: .installed), "installed program C: path accepted")
        for bad in ["D:\\x.exe", "C:\\..\\x.exe", "C:\\a\\\"b.exe", "Program Files\\x.exe", "C:\\a/b\\x.exe", "C:\\x.dll"] {
            try rejects("installed program path rejected: " + bad) { try Launcher(id: "valid", name: "Bad", executable: bad, kind: .installed).validate() }
        }
        for bad in ["../x.exe", "a\\b.exe", "/abs.exe", "x.txt"] {
            try rejects("copied program path rejected: " + bad) { try Launcher(id: "valid", name: "Bad", executable: bad, kind: .copied).validate() }
        }
        let portable = temp.appendingPathComponent("휴대용 Tool")
        try fm.createDirectory(at: portable.appendingPathComponent("data"), withIntermediateDirectories: true)
        for (name, text) in [("tool.exe", "tool-exe"), ("data/table.bin", "table"), (".DS_Store", "finder")] {
            try Data(text.utf8).write(to: portable.appendingPathComponent(name))
        }
        let copied = try store.importProgram(from: portable.appendingPathComponent("tool.exe"))
        let copiedGame = try store.game(copied)
        try check(copied.kind == .copied && copied.executable == "tool.exe", "outside EXE registers as a copied program")
        try check(try Data(contentsOf: copiedGame.appendingPathComponent("data/table.bin")) == Data("table".utf8)
                  && !fm.fileExists(atPath: copiedGame.appendingPathComponent(".DS_Store").path), "copied program keeps data and skips hidden files")
        try check(try store.prefix(copied) == store.sharedPrefix, "copied program uses the shared prefix")
        let copiedProcess = Process()
        try AlchemacRuntime.configure(copiedProcess, launcher: copied, store: store, runtime: mock, resources: resources)
        try check(copiedProcess.arguments?.last == AlchemacRuntime.windows(copiedGame.appendingPathComponent("tool.exe"))
                  && copiedProcess.environment?["WINEPREFIX"] == store.sharedPrefix.path
                  && copiedProcess.environment?["DOTNET_BUNDLE_EXTRACT_BASE_DIR"] == nil, "copied program starts from its copy in the shared prefix")
        let installedFolder = store.sharedPrefix.appendingPathComponent("drive_c/Program Files/Tool Co")
        try fm.createDirectory(at: installedFolder, withIntermediateDirectories: true)
        try Data("installed".utf8).write(to: installedFolder.appendingPathComponent("Tool.exe"))
        let installed = try store.importProgram(from: installedFolder.appendingPathComponent("Tool.exe"))
        try check(installed.kind == .installed && installed.executable == "C:\\Program Files\\Tool Co\\Tool.exe", "EXE inside the shared prefix registers by its C: path")
        try check(!fm.fileExists(atPath: store.root.appendingPathComponent("launchers/" + installed.id).path), "installed program is not copied")
        let installedProcess = Process()
        try AlchemacRuntime.configure(installedProcess, launcher: installed, store: store, runtime: mock, resources: resources)
        try check(installedProcess.arguments?.last == "C:\\Program Files\\Tool Co\\Tool.exe"
                  && installedProcess.environment?["HADRON_WORKDIR"] == store.sharedPrefix.appendingPathComponent("drive_c/Program Files/Tool Co").path, "installed program starts in its install folder")
        try rejects("non-EXE program rejected") { _ = try store.importProgram(from: portable.appendingPathComponent("data/table.bin")) }
        let setup = portable.appendingPathComponent("setup.exe")
        try Data("setup".utf8).write(to: setup)
        let setupProcess = Process()
        try AlchemacRuntime.configureInstaller(setupProcess, setup: setup, store: store, runtime: mock, resources: resources)
        try check(setupProcess.arguments == ["alchemac-setup", resources.appendingPathComponent("prefix-profile.exe").path, "--setup",
                                             AlchemacRuntime.windows(resources.appendingPathComponent("Fonts/NanumGothic-Regular.ttf")), AlchemacRuntime.windows(setup.standardizedFileURL)]
                  && setupProcess.environment?["WINEPREFIX"] == store.sharedPrefix.path, "installer runs in the shared prefix with separate argv")
        try rejects("installer must be an EXE") { try AlchemacRuntime.configureInstaller(Process(), setup: portable.appendingPathComponent("data/table.bin"), store: store, runtime: mock, resources: resources) }
        let before = store.installedExecutables()
        try check(before.contains("Program Files/Tool Co/Tool.exe"), "install snapshot lists existing programs")
        let newApp = store.sharedPrefix.appendingPathComponent("drive_c/Program Files/New App")
        try fm.createDirectory(at: newApp.appendingPathComponent("bin"), withIntermediateDirectories: true)
        for name in ["bin/NewApp.exe", "unins000.exe", "bin/Updater.exe", "bin/worker.exe"] { try Data("exe".utf8).write(to: newApp.appendingPathComponent(name)) }
        let menu = store.sharedPrefix.appendingPathComponent("drive_c/ProgramData/Microsoft/Windows/Start Menu/Programs/New App")
        try fm.createDirectory(at: menu, withIntermediateDirectories: true)
        try ("L\0\0\0C:\\Program Files\\New App\\bin\\NEWAPP.EXE".data(using: .utf16LittleEndian)!).write(to: menu.appendingPathComponent("새 앱 New App.lnk"))
        try Data("C:\\Program Files\\New App\\unins000.exe".utf8).write(to: menu.appendingPathComponent("Uninstall New App.lnk"))
        var builtin = Data(count: 0x40); builtin.append(Data("Wine builtin DLL".utf8)); builtin.append(Data(count: 32))
        try fm.createDirectory(at: store.sharedPrefix.appendingPathComponent("drive_c/Program Files/Internet Explorer"), withIntermediateDirectories: true)
        try builtin.write(to: store.sharedPrefix.appendingPathComponent("drive_c/Program Files/Internet Explorer/iexplore.exe"))
        try Data("C:\\Program Files\\Internet Explorer\\iexplore.exe".utf8).write(to: menu.appendingPathComponent("Internet Explorer.lnk"))
        let offered = store.newPrograms(since: before)
        try check(offered.map(\.title) == ["새 앱 New App"] && offered.first?.shortcut == true
                  && offered.first?.exe.lastPathComponent == "NewApp.exe", "installer result offers the shortcut target by its shortcut name only")
        try check(store.installedLocation(of: newApp.appendingPathComponent("bin/NewApp.exe"))?.path == "C:\\Program Files\\New App\\bin\\NewApp.exe"
                  && store.installedLocation(of: newApp.appendingPathComponent("bin/NewApp.exe"))?.environment == nil
                  && store.installedLocation(of: portable.appendingPathComponent("tool.exe")) == nil, "only Wine-environment files map to C: paths")
        try fm.removeItem(at: menu)
        let unlinked = store.newPrograms(since: before)
        try check(Set(unlinked.map(\.title)) == ["NewApp", "worker"] && unlinked.allSatisfy { !$0.shortcut },
                  "without shortcuts the new EXEs are offered unchecked, helpers still excluded")
        // Dedicated Wine environments.
        try check(store.environments().isEmpty && store.newEnvironmentName(for: URL(fileURLWithPath: "/x/Origin 2026b Setup.exe")) == "origin-2026b-setup"
                  && store.newEnvironmentName(for: URL(fileURLWithPath: "/x/설치.exe")) == "env", "environment names derive from the installer name")
        for bad in ["shared", "-x", "Upper", "a/b", "a.b", String(repeating: "a", count: 33)] {
            try check(!Launcher.validEnvironment(bad), "environment name rejected: " + bad)
        }
        try rejects("own-prefix program cannot also name an environment") { try Launcher(id: "valid", name: "D", executable: "GameLauncher.exe", environment: "lab", privatePrefix: true).validate() }
        let lab = store.prefix(environment: "lab")
        try fm.createDirectory(at: lab.appendingPathComponent("drive_c/Program Files/Lab"), withIntermediateDirectories: true)
        try Data("lab".utf8).write(to: lab.appendingPathComponent("drive_c/Program Files/Lab/Lab.exe"))
        try check(store.environments() == ["lab"] && store.newEnvironmentName(for: URL(fileURLWithPath: "/x/lab.exe")) == "lab-2", "existing environments are listed and not reused for new ones")
        let labProgram = try store.importProgram(from: lab.appendingPathComponent("drive_c/Program Files/Lab/Lab.exe"))
        try check(labProgram.kind == .installed && labProgram.environment == "lab" && labProgram.executable == "C:\\Program Files\\Lab\\Lab.exe",
                  "EXE inside a dedicated environment registers in that environment")
        let labProcess = Process()
        try AlchemacRuntime.configure(labProcess, launcher: labProgram, store: store, runtime: mock, resources: resources)
        try check(labProcess.environment?["WINEPREFIX"] == lab.path && labProcess.environment?["HADRON_WORKDIR"] == lab.appendingPathComponent("drive_c/Program Files/Lab").path,
                  "dedicated-environment program runs in its own prefix")
        let isolatedCopy = try store.importProgram(from: portable.appendingPathComponent("tool.exe"), environment: "lab")
        try check(isolatedCopy.kind == .copied && (try store.prefix(isolatedCopy)) == lab, "copied program can run in a chosen dedicated environment")
        let labSetup = Process()
        try AlchemacRuntime.configureInstaller(labSetup, setup: setup, environment: "lab", store: store, runtime: mock, resources: resources)
        try check(labSetup.environment?["WINEPREFIX"] == lab.path, "installer can target a dedicated environment")
        try rejects("installer refuses an invalid environment") { try AlchemacRuntime.configureInstaller(Process(), setup: setup, environment: "../x", store: store, runtime: mock, resources: resources) }
        let labBefore = store.installedExecutables(in: "lab")
        try Data("new".utf8).write(to: lab.appendingPathComponent("drive_c/Program Files/Lab/Plot.exe"))
        try check(store.newPrograms(since: labBefore, in: "lab").map(\.title) == ["Plot"] && store.newPrograms(since: before).allSatisfy { !$0.exe.path.contains("/lab/") },
                  "install detection stays inside the chosen environment")
        // Deleting programs: Windows uninstall entries, uninstaller argv and Trash targets.
        let reg = #"""
        WINE REGISTRY Version 2

        [Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{AAA}] 1792291078
        "DisplayName"="\xc624\xb9ac\xc9c4 Tool"
        "InstallLocation"="C:\\Program Files\\Tool Co\\"
        "UninstallString"="\"C:\\Program Files (x86)\\InstallShield Installation Information\\{AAA}\\setup.exe\" -runfromtemp -removeonly"

        [Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{BBB}] 1792291078
        "DisplayIcon"="C:\\Program Files\\New App\\bin\\NewApp.exe,0"
        "DisplayName"="New App"
        "UninstallString"=str(2):"MsiExec.exe /X{BBB}"

        [Software\\Microsoft\\Windows\\CurrentVersion\\Run] 1792291078
        "UninstallString"="not an uninstall key"
        """#
        try Data(reg.utf8).write(to: store.sharedPrefix.appendingPathComponent("system.reg"))
        try check(LauncherStore.uninstallKeys(reg).count == 2, "only Uninstall keys are read from the registry")
        let toolEntry = store.uninstallEntry(for: installed)
        try check(toolEntry == UninstallEntry(name: "오리진 Tool", command: #""C:\Program Files (x86)\InstallShield Installation Information\{AAA}\setup.exe" -runfromtemp -removeonly"#),
                  "uninstaller found by InstallLocation and unescaped")
        let newAppLauncher = Launcher(id: "newapp", name: "New App", executable: #"C:\Program Files\New App\bin\NewApp.exe"#, kind: .installed)
        try check(store.uninstallEntry(for: newAppLauncher)?.command == "MsiExec.exe /X{BBB}", "uninstaller found by DisplayIcon in the 32-bit view")
        try check(store.uninstallEntry(for: copied) == nil && store.uninstallEntry(for: labProgram) == nil, "no uninstaller guessed without a matching entry")
        let uninstallProcess = Process()
        try AlchemacRuntime.configureUninstall(uninstallProcess, launcher: installed, command: toolEntry!.command, store: store, runtime: mock, resources: resources)
        try check(uninstallProcess.arguments == ["alchemac-" + installed.id, resources.appendingPathComponent("prefix-profile.exe").path, "--command",
                                                 AlchemacRuntime.windows(resources.appendingPathComponent("Fonts/NanumGothic-Regular.ttf")), toolEntry!.command]
                  && uninstallProcess.environment?["WINEPREFIX"] == store.sharedPrefix.path, "uninstaller runs as one command line in the program's environment")
        let patch = portable.appendingPathComponent("patch.exe")
        try Data("patch".utf8).write(to: patch)
        let toolProcess = Process()
        try AlchemacRuntime.configureTool(toolProcess, tool: patch, for: imported, store: store, runtime: mock, resources: resources)
        try check(toolProcess.arguments?[2] == "--setup" && toolProcess.arguments?.last == AlchemacRuntime.windows(patch.standardizedFileURL)
                  && toolProcess.environment?["WINEPREFIX"] == (try store.prefix(imported)).path
                  && toolProcess.environment?["HADRON_WORKDIR"] == patch.standardizedFileURL.deletingLastPathComponent().path, "a tool EXE runs in the chosen program's own prefix from its folder")
        try rejects("attaching needs the session-attach script") { try AlchemacRuntime.configureAttachedTool(Process(), tool: patch, for: imported, store: store, runtime: mock, resources: resources) }
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: resources.appendingPathComponent("session-attach"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: resources.appendingPathComponent("session-attach").path)
        let attachProcess = Process()
        try AlchemacRuntime.configureAttachedTool(attachProcess, tool: patch, for: imported, store: store, runtime: mock, resources: resources)
        try check(attachProcess.executableURL == resources.appendingPathComponent("session-attach") && attachProcess.arguments == toolProcess.arguments
                  && attachProcess.environment?["WINEPREFIX"] == toolProcess.environment?["WINEPREFIX"], "attaching joins the same prefix with the same arguments, without a second supervisor")
        try check(toolProcess.environment?["DOTNET_BUNDLE_EXTRACT_BASE_DIR"] == "C:\\windows\\temp\\sample-dotnet", "a tool runs with the program's add-on settings")
        func pe(_ magic: UInt16, clr: Bool) -> Data {
            var image = Data(count: 1024); image[0] = 0x4d; image[1] = 0x5a; image[0x3c] = 0x80
            image[0x80] = 0x50; image[0x81] = 0x45
            let optional = 0x80 + 24; image[optional] = UInt8(magic & 0xff); image[optional + 1] = UInt8(magic >> 8)
            if clr { image[optional + (magic == 0x20b ? 112 : 96) + 14 * 8] = 0x08 }
            return image
        }
        let dotnet = portable.appendingPathComponent("dotnet.exe"), native = portable.appendingPathComponent("native.exe"), dotnet64 = portable.appendingPathComponent("dotnet64.exe")
        try pe(0x10b, clr: true).write(to: dotnet); try pe(0x20b, clr: false).write(to: native); try pe(0x20b, clr: true).write(to: dotnet64)
        let monoPrefix = temp.appendingPathComponent("mono-prefix")
        try check(store.needsWineMono(dotnet, in: monoPrefix) && store.needsWineMono(dotnet64, in: monoPrefix) && !store.needsWineMono(native, in: monoPrefix) && !store.needsWineMono(patch, in: monoPrefix),
                  "only .NET Framework programs need Wine Mono")
        let monoLibrary = monoPrefix.appendingPathComponent("drive_c/windows/mono/mono-2.0/bin")
        try fm.createDirectory(at: monoLibrary, withIntermediateDirectories: true)
        try Data().write(to: monoLibrary.appendingPathComponent("libmono-2.0-x86_64.dll"))
        try check(!store.needsWineMono(dotnet, in: monoPrefix), "a prefix with Wine Mono needs nothing more")
        try rejects("tool must be an EXE") { try AlchemacRuntime.configureTool(Process(), tool: portable.appendingPathComponent("data/table.bin"), for: imported, store: store, runtime: mock, resources: resources) }
        try rejects("uninstaller only for installed programs") { try AlchemacRuntime.configureUninstall(Process(), launcher: copied, command: "x.exe", store: store, runtime: mock, resources: resources) }
        try rejects("uninstall command with control characters refused") { try AlchemacRuntime.configureUninstall(Process(), launcher: installed, command: "a\nb", store: store, runtime: mock, resources: resources) }
        try check(try store.deletionFolders(for: copied, environmentToo: true) == [store.directory(copied)], "copied program deletes only its private copy")
        try check(try store.deletionFolders(for: installed, environmentToo: true).isEmpty, "shared environment is never moved to the Trash")
        try fm.createDirectory(at: store.root.appendingPathComponent("prefixes/lab.backup.20261018-1"), withIntermediateDirectories: true)
        try check(try store.deletionFolders(for: labProgram, environmentToo: true) == [lab, store.root.appendingPathComponent("prefixes/lab.backup.20261018-1", isDirectory: true)]
                  && (try store.deletionFolders(for: labProgram, environmentToo: false)).isEmpty, "dedicated environment and its snapshots go only when asked")
        try check(try store.deletionFolders(for: imported, environmentToo: false) == [store.directory(imported)], "own-prefix program deletes its library folder with its prefix inside")
        try check(try store.environmentFolders("lab") == [lab, store.root.appendingPathComponent("prefixes/lab.backup.20261018-1", isDirectory: true)],
                  "environment deletion covers the prefix and its snapshots")
        try rejects("shared environment can never be deleted as an environment") { _ = try store.environmentFolders("shared") }
        try check(store.allocatedSize(try store.deletionFolders(for: copied, environmentToo: false)) > 0, "deletion size is measured")
        // Retina mode and per-program DPI scaling.
        try check(!imported.scaled && copiedProcess.arguments?[2] == "--launch", "programs keep their own DPI awareness by default")
        var scaledCopy = copied; scaledCopy.scaled = true
        let scaledProcess = Process()
        try AlchemacRuntime.configure(scaledProcess, launcher: scaledCopy, store: store, runtime: mock, resources: resources)
        try check(scaledProcess.arguments?[2] == "--launch-scaled", "size correction starts the program DPI-scaled")
        try check(!store.retinaEnabled(environment: nil), "Retina mode reads as off without a Mac Driver key")
        try Data("WINE REGISTRY Version 2\n\n[Software\\\\Wine\\\\Mac Driver] 1792291078\n\"RetinaMode\"=\"y\"\n".utf8)
            .write(to: store.sharedPrefix.appendingPathComponent("user.reg"))
        try check(store.retinaEnabled(environment: nil) && !store.retinaEnabled(environment: "lab"), "Retina mode is read per environment")
        let on = LauncherStore.retinaRegistry(on: true), off = LauncherStore.retinaRegistry(on: false)
        try check(on.hasPrefix("REGEDIT4") && on.contains(#""RetinaMode"="y""#) && on.components(separatedBy: "dword:000000c0").count == 4
                  && on.contains(#"@="~ DPIUNAWARE""#), "Retina on sets native resolution, 192 DPI in all three places and default scaling")
        try check(off.contains(#""RetinaMode"="n""#) && off.components(separatedBy: "dword:00000060").count == 4 && off.contains("@=-"),
                  "Retina off restores 96 DPI and removes the default scaling")
        let script = try store.registryScript(on)
        let registryProcess = Process()
        try AlchemacRuntime.configureRegistry(registryProcess, prefix: lab, script: script, store: store, runtime: mock, resources: resources)
        try check(registryProcess.arguments?[2] == "--command" && registryProcess.arguments?.last == "regedit.exe /S \"" + AlchemacRuntime.windows(script) + "\""
                  && registryProcess.environment?["WINEPREFIX"] == lab.path, "registry changes import with regedit in the chosen environment")
        let fresh = store.prefix(environment: "fresh-retina")
        try check(!fm.fileExists(atPath: fresh.path), "the new environment's prefix does not exist yet")
        let freshProcess = Process()
        try AlchemacRuntime.configureRegistry(freshProcess, prefix: fresh, script: script, store: store, runtime: mock, resources: resources)
        try check(freshProcess.environment?["HADRON_WORKDIR"] == fresh.appendingPathComponent("drive_c").path
                  && freshProcess.currentDirectoryURL.map { fm.fileExists(atPath: $0.path) } == true,
                  "a new environment launches from an existing directory while the workdir stays drive_c")
        try check(try String(contentsOf: script, encoding: .utf8) == on, "registry script holds exactly the settings")
        let ownPrefixProcess = Process()
        try AlchemacRuntime.configureRegistry(ownPrefixProcess, prefix: store.prefix(imported), script: script, store: store, runtime: mock, resources: resources)
        try check(ownPrefixProcess.environment?["WINEPREFIX"] == (try store.prefix(imported)).path, "a program's own prefix can switch Retina mode too")
        try rejects("registry changes refused outside the library") { try AlchemacRuntime.configureRegistry(Process(), prefix: URL(fileURLWithPath: "/tmp/elsewhere"), script: script, store: store, runtime: mock, resources: resources) }
        try check(!store.retinaEnabled(prefix: store.prefix(imported)), "Retina state reads from any prefix")
        // Concurrent sessions, one per Wine prefix, against a supervisor stand-in that waits for TERM.
        let bundle = temp.appendingPathComponent("Fixture.app/Contents")
        let slow = bundle.appendingPathComponent("SharedSupport/runtime")
        try fm.createDirectory(at: slow.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\ntrap 'exit 143' TERM\nsleep 30 &\nwait\n".utf8).write(to: slow.appendingPathComponent("scripts/standalone-run"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slow.appendingPathComponent("scripts/standalone-run").path)
        try Data("fixture\n".utf8).write(to: slow.appendingPathComponent("BUILD-ID"))
        try fm.copyItem(at: resources, to: bundle.appendingPathComponent("Resources"))
        try fm.createDirectory(at: store.sharedPrefix, withIntermediateDirectories: true)
        try Data("fixture\n".utf8).write(to: store.sharedPrefix.appendingPathComponent(".hadron-prefix-ready"))
        let sessions = SessionController(runtime: slow)
        var ended = false
        sessions.finished = { ended = true }
        func spin(until condition: () -> Bool) -> Bool {
            let limit = Date().addingTimeInterval(10)
            while !condition() && Date() < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            return condition()
        }
        try sessions.start(copied, store: store)
        try sessions.start(labProgram, store: store)
        try check(sessions.sessions.count == 2 && sessions.isRunning(copied.id) && sessions.isRunning(labProgram.id),
                  "programs in different Wine environments run at the same time")
        try rejects("second program in a busy Wine environment refused") { try sessions.start(installed, store: store) }
        try check(sessions.sessions.count == 2, "refusal leaves running sessions alone")
        sessions.stop(sessions.session(in: store.sharedPrefix)!)
        try check(spin { !sessions.isRunning(copied.id) } && sessions.isRunning(labProgram.id) && !ended,
                  "stopping one environment keeps the other running")
        sessions.stopAll()
        try check(spin { ended } && !sessions.busy, "stopping all ends every session and reports completion")
        // A runtime that refuses to start: the app shows the reason and keeps the run's own logs.
        let refusing = temp.appendingPathComponent("Refusing.app/Contents")
        let refuseRuntime = refusing.appendingPathComponent("SharedSupport/runtime")
        try fm.createDirectory(at: refuseRuntime.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try Data("fixture\n".utf8).write(to: refuseRuntime.appendingPathComponent("BUILD-ID"))
        try fm.copyItem(at: resources, to: refusing.appendingPathComponent("Resources"))
        func installScript(_ body: String) throws {
            let url = refuseRuntime.appendingPathComponent("scripts/standalone-run")
            try? fm.removeItem(at: url)
            try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try installScript("echo 'standalone: existing unmanaged Wine session; stop it first' >&2; exit 75")
        let refused = SessionController(runtime: refuseRuntime)
        try refused.start(copied, store: store)
        try check(spin { !refused.busy } && refused.message.contains("관리하지 않는 Wine 프로세스") && !refused.lastProblemLogs.isEmpty
                  && refused.lastProblemLogs.allSatisfy { fm.fileExists(atPath: $0.path) }, "refused launch shows its reason and keeps this run's log")
        try installScript("echo 'prefix-profile: target exited early, code=0x00000001' > \"$HADRON_LOGS/$1-$$.session.log\"; exit 0")
        try refused.start(copied, store: store)
        try check(spin { !refused.busy } && refused.message.contains("시작 직후 종료됐습니다 (코드 0x00000001)"), "program that ends at once is reported")
        let quiet = SessionController(runtime: refuseRuntime)
        try installScript("exit 0")
        try quiet.start(copied, store: store)
        try check(spin { !quiet.busy } && quiet.message.hasSuffix("세션이 종료됐습니다.") && quiet.lastProblemLogs.isEmpty, "ordinary exit shows no problem")
        let broken = SessionController(runtime: refuseRuntime)
        try installScript("echo 'prefix-profile: refusing an incomplete or foreign prefix' >&2; exit 1")
        try broken.start(copied, store: store)
        try check(spin { !broken.busy } && broken.lastProblemPrefix != nil && !broken.message.contains("폴더를 지우") && broken.message.contains("안전하게 사용할 수 없어"), "an unusable environment offers its folder instead of telling the user to delete it")
        try check(refused.lastProblemPrefix == nil && LaunchDiagnostics.wantsEnvironmentFolder("x staging path already exists y") && !LaunchDiagnostics.wantsEnvironmentFolder("EXE not found"), "only environment problems point at the environment folder")
        let migratingText = "A 실행 준비 중 · 종료하지 마세요."
        try check(LaunchDiagnostics.settledMessage(current: migratingText + "\n추가", migration: migratingText, running: "A 실행 중") == "A 실행 중\n추가"
                  && LaunchDiagnostics.settledMessage(current: "다른 메시지", migration: migratingText, running: "A 실행 중") == nil
                  && LaunchDiagnostics.settledMessage(current: "x", migration: "", running: "y") == nil, "the migration notice is replaced by the running text once it is over")
        var scaledLab = labProgram; scaledLab.scaled = true
        try store.write(Registry(selectedID: labProgram.id, launchers: [imported, scaledLab, isolatedCopy]))
        try check(try store.read().launchers.map(\.scaled) == [false, true, false], "registry persists size correction")
        try check(try store.read().launchers.map(\.environment) == [nil, "lab", "lab"], "registry persists environments")
        try store.write(Registry(selectedID: installed.id, launchers: [imported, copied, installed]))
        try check(try store.read().launchers.map(\.kind) == [.copied, .copied, .installed] && (try store.read().launchers.first?.addon) == "sample",
                  "registry persists every program kind and its add-on")
        try store.write(Registry())
        try check(fm.fileExists(atPath: game.appendingPathComponent("GameLauncher.exe").path), "unregister does not delete game data")
        try fm.createSymbolicLink(atPath: game.appendingPathComponent("redirected").path, withDestinationPath: "/etc")
        try rejects("owned-path link rejected") { try store.requireLocal(game.appendingPathComponent("redirected/hosts")) }
        // Failure reasons from the logs
        try check(LaunchDiagnostics.explain("standalone: runtime path too long for Wine bootstrap; use a shorter HADRON_SUPPORT\n")?.contains("경로가 너무 길어") == true, "known failure gets a Korean reason")
        try check(LaunchDiagnostics.explain("prefix-profile: Wine Mono install exit=0\n")?.hasPrefix("마지막 로그 줄") == true, "successful Wine Mono install is not a failure")
        try check(LaunchDiagnostics.explain("something odd\nstandalone: new thing broke\n") == "마지막 로그 줄: standalone: new thing broke", "unknown failure shows the last meaningful line")
        try check(LaunchDiagnostics.earlyExit(in: "a\nprefix-profile: target exited early, code=0xc0000135\n") == "0xc0000135", "early exit code is parsed")
        // PE icon extraction: a synthetic PE32+ with one group icon entry, then malformed input.
        func le(_ value: Int, _ bytes: Int) -> [UInt8] { (0..<bytes).map { UInt8((value >> (8 * $0)) & 0xFF) } }
        func syntheticPE(rsrcSize: Int = 0x100) -> Data {
            var pe = [UInt8](repeating: 0, count: 0x400)
            func put(_ at: Int, _ bytes: [UInt8]) { pe.replaceSubrange(at..<(at + bytes.count), with: bytes) }
            put(0, [0x4D, 0x5A]); put(0x3C, le(0x40, 4)); put(0x40, [0x50, 0x45, 0, 0])
            put(0x46, le(1, 2)); put(0x54, le(240, 2)); put(0x58, le(0x20B, 2))
            put(0x58 + 108, le(16, 4)); put(0x58 + 112 + 16, le(0x1000, 4) + le(rsrcSize, 4))
            put(0x148, Array("rsrc".utf8) + [0, 0, 0, 0] + le(0x100, 4) + le(0x1000, 4) + le(0x200, 4) + le(0x200, 4))
            let r = 0x200
            func dir(_ at: Int, _ id: Int, _ target: Int, subdirectory: Bool = true) {
                put(r + at + 14, le(1, 2)); put(r + at + 16, le(id, 4) + le(target | (subdirectory ? 0x8000_0000 : 0), 4))
            }
            put(r + 14, le(2, 2)); put(r + 16, le(3, 4) + le(0x8000_0020, 4) + le(14, 4) + le(0x8000_0038, 4))
            dir(0x20, 1, 0x50); dir(0x38, 1, 0x68); dir(0x50, 1033, 0x80, subdirectory: false); dir(0x68, 1033, 0x90, subdirectory: false)
            put(r + 0x80, le(0x10C0, 4) + le(16, 4)); put(r + 0x90, le(0x10A0, 4) + le(20, 4))
            put(r + 0xA0, le(0, 2) + le(1, 2) + le(1, 2) + [16, 16, 0, 0] + le(1, 2) + le(32, 2) + le(16, 4) + le(1, 2))
            put(r + 0xC0, Array("ICONIMAGEDATA123".utf8))
            return Data(pe)
        }
        let ico = ExeIcon.icoData(from: syntheticPE())
        try check(ico?.count == 38 && ico?.prefix(6) == Data([0, 0, 1, 0, 1, 0]) && ico?.suffix(16) == Data("ICONIMAGEDATA123".utf8)
                  && ico.map({ Array($0[18..<22]) }) == le(22, 4), "PE icon extraction builds an .ico from the first group icon")
        try check(ExeIcon.icoData(from: Data()) == nil && ExeIcon.icoData(from: Data("MZ".utf8)) == nil
                  && ExeIcon.icoData(from: Data(repeating: 0xFF, count: 4096)) == nil, "PE icon extraction rejects empty and garbage data")
        try check(ExeIcon.icoData(from: syntheticPE(rsrcSize: 80 << 20)) == nil, "PE icon extraction rejects an oversized resource section")
        let pePng = ExeIcon.png(fromICO: Data("not an icon".utf8))
        try check(pePng == nil, "garbage .ico yields no image")
        for length in stride(from: 0, to: 0x300, by: 7) { _ = ExeIcon.icoData(from: syntheticPE().prefix(length)) }
        var noisy = syntheticPE()
        for i in stride(from: 0x40, to: 0x2D0, by: 3) { noisy[i] = noisy[i] &+ 0x5B; _ = ExeIcon.icoData(from: noisy) }
        try check(true, "truncated and corrupted PE files never crash the extractor")
        let noExe = temp.appendingPathComponent("missing.exe")
        try check(ExeIcon.cachedPNG(exe: noExe, dir: temp) == nil, "icon cache returns nil for a missing program")
        // Add-on setting values: some reach shell arithmetic or config parsers in the runtime.
        try check(!Addon.allowedValue("HADRON_MEM_LIMIT_GB", "a[$(echo x)]") && !Addon.allowedValue("HADRON_MEM_LIMIT_GB", "8\n$(id)")
                  && !Addon.allowedValue("HADRON_MEM_LIMIT_GB", "0") && !Addon.allowedValue("HADRON_MEM_LIMIT_GB", "8 "), "memory limit value cannot carry shell arithmetic")
        try check(Addon.allowedValue("HADRON_MEM_LIMIT_GB", "8") && Addon.allowedValue("HADRON_MEM_LIMIT_GB", "128"), "plain memory limit accepted")
        try check(!Addon.allowedValue("HADRON_VSYNC", "on;debug.x=1") && Addon.allowedValue("HADRON_VSYNC", "on") && !Addon.allowedValue("HADRON_D3D12", "x")
                  && Addon.allowedValue("HADRON_HARDWARE_TSO", "1") && !Addon.allowedValue("MTL_HUD_ENABLED", "2"), "enumerated add-on values are exact")
        try check(!Addon.allowedValue("MTLD3D_CONFIG", "log.dir=/tmp") && !Addon.allowedValue("MTLD3D_CONFIG", "debug.bytecodeDumpDir=x")
                  && !Addon.allowedValue("DXMT_CONFIG", "Log.level=debug") && !Addon.allowedValue("DXMT_CONFIG", "a=b c") && !Addon.allowedValue("DXMT_CONFIG", "a=$(x)")
                  && Addon.allowedValue("MTLD3D_CONFIG", "present.vsync=on") && Addon.allowedValue("DXMT_CONFIG", "a=1;;b.c=x,y:z"), "renderer config values refuse logging, debug and paths")
        let sampleJSON = #"""
        {"schema":1,"id":"sample-app","name":"Sample App","version":"1.0.0",
         "detect":{"executable":"SampleLauncher.exe","siblings":["Sample_Data"]},
         "import":{"exclude":["settings.txt","logs","*.log",".*"]},
         "environment":{"mode":"private"},
         "launch":{"env":{"DOTNET_BUNDLE_EXTRACT_BASE_DIR":"C:\\windows\\temp\\sample-dotnet"},"englishInput":true}}
        """#
        let typical = try JSONDecoder().decode(Addon.self, from: Data(sampleJSON.utf8))
        try typical.validate()
        try check(typical.launchEnvironment["DOTNET_BUNDLE_EXTRACT_BASE_DIR"].map { Addon.allowedValue("DOTNET_BUNDLE_EXTRACT_BASE_DIR", $0) } == true, "a typical add-on's settings are accepted")
        try check(!Addon.allowedValue("DOTNET_BUNDLE_EXTRACT_BASE_DIR", "Z:\\Users\\x") && !Addon.allowedValue("DOTNET_BUNDLE_EXTRACT_BASE_DIR", "C:\\a\\..\\b")
                  && !Addon.allowedValue("DOTNET_BUNDLE_EXTRACT_BASE_DIR", "C:\\a$b") && Addon.allowedValue("DOTNET_BUNDLE_EXTRACT_BASE_DIR", "c:\\windows\\temp\\x y")
                  && !Addon.allowedValue("WINEDLLOVERRIDES", "a=n b") && Addon.allowedValue("WINEDLLOVERRIDES", "d3dcompiler_47=n,b;x=d") && !Addon.allowedValue("HADRON_UNKNOWN", "1"), "path and override values are strict")
        let evil = Addon(schema: 1, id: "evil", name: "Evil", version: "1.0", summary: nil, detect: .init(executable: "a.exe", siblings: nil), import: nil, environment: nil,
                         launch: .init(env: ["HADRON_MEM_LIMIT_GB": "a[$(echo x)]"], englishInput: nil))
        try rejects("add-on with an injection value fails validation") { try evil.validate() }

        // launchers.json recovery.
        var recoveryCount = 0
        func recoveryStore() throws -> LauncherStore {
            recoveryCount += 1
            return try LauncherStore(root: temp.appendingPathComponent("recovery-\(recoveryCount)"), logs: temp.appendingPathComponent("recovery-logs-\(recoveryCount)"))
        }
        func names(_ store: LauncherStore) -> [String] { ((try? fm.contentsOfDirectory(atPath: store.root.path)) ?? []).sorted() }
        func registryJSON(_ ids: [String], selected: String? = nil, extra: String = "") -> Data {
            let items = ids.map { #"{"id":"\#($0)","name":"\#($0)","executable":"a.exe"}"# } + (extra.isEmpty ? [] : [extra])
            return Data((#"{"schemaVersion":1,"#  + (selected.map { #""selectedID":"\#($0)","# } ?? "") + #""launchers":["# + items.joined(separator: ",") + "]}").utf8)
        }
        do {
            let r = try recoveryStore()
            try r.write(Registry(selectedID: "one", launchers: [Launcher(id: "one", name: "One", executable: "a.exe")]))
            try check(!fm.fileExists(atPath: r.backupURL.path), "first save has nothing to back up")
            try r.write(Registry(selectedID: "two", launchers: [Launcher(id: "two", name: "Two", executable: "a.exe")]))
            try check((try? r.read())?.launchers.first?.id == "two" && r.recoveryNotice == nil, "clean registry reads without a notice")
            try check(fm.fileExists(atPath: r.backupURL.path) && (try? Data(contentsOf: r.backupURL)).flatMap { try? JSONDecoder().decode(Registry.self, from: $0) }?.launchers.first?.id == "one"
                      && (((try? fm.attributesOfItem(atPath: r.backupURL.path))?[.posixPermissions] as? Int) ?? 0) == 0o600, "save keeps the previous valid registry as a 0600 backup")
            try Data("{ not json".utf8).write(to: r.registryURL)
            let corrupt = try r.read()
            try check(corrupt.launchers.map(\.id) == ["one"] && names(r).contains { $0.hasPrefix("launchers.corrupt-") && $0.hasSuffix(".json") }
                      && !fm.fileExists(atPath: r.registryURL.path) && r.recoveryNotice?.contains("launchers.corrupt-") == true, "corrupt registry is set aside and the backup is used")
            let keptCorrupt = names(r).first { $0.hasPrefix("launchers.corrupt-") }
            try check((try? String(contentsOf: r.root.appendingPathComponent(keptCorrupt ?? "x"), encoding: .utf8)) == "{ not json", "set-aside file keeps the damaged bytes")
            try r.write(corrupt)
            try check((try? r.read())?.launchers.map(\.id) == ["one"] && r.recoveryNotice == nil, "registry is usable again after recovery")
            try Data("{ not json".utf8).write(to: r.registryURL)
            try fm.removeItem(at: r.backupURL)
            try check(try r.read().launchers.isEmpty && r.recoveryNotice?.contains("빈 목록") == true, "corrupt registry without a backup starts empty and says so")
        }
        do {
            let r = try recoveryStore()
            let bad = String(decoding: registryJSON(["good", "bad", "good", "other"], selected: "bad", extra: #"{"id":"x","name":"x","executable":"a.exe","kind":"script"}"#), as: UTF8.self)
                .replacingOccurrences(of: #""id":"bad""#, with: #""id":"../bad""#)
            try Data(bad.utf8).write(to: r.registryURL)
            let loaded = try r.read()
            try check(loaded.launchers.map(\.id) == ["good", "other"] && loaded.selectedID == "good", "invalid and duplicate launchers are left out and the selection is fixed")
            let invalid = names(r).first { $0.hasPrefix("launchers.invalid-") }
            try check(invalid != nil && (try? Data(contentsOf: r.root.appendingPathComponent(invalid ?? "x"))) == Data(bad.utf8)
                      && r.recoveryNotice?.contains("3개") == true, "the original file is kept and the notice counts the dropped programs")
            try check((try? Data(contentsOf: r.registryURL)) == Data(bad.utf8), "reading does not rewrite launchers.json")
            try r.write(loaded)
            try check(!fm.fileExists(atPath: r.backupURL.path), "a registry that did not validate is never copied to the backup")
        }
        do {
            let r = try recoveryStore()
            let future = Data(#"{"schemaVersion":2,"launchers":[]}"#.utf8)
            try future.write(to: r.registryURL)
            try rejects("registry from a newer app is refused") { _ = try r.read() }
            try check((try? Data(contentsOf: r.registryURL)) == future && names(r).filter { $0.hasPrefix("launchers.") } == ["launchers.json"], "registry from a newer app is left untouched")
            try Data(#"{"schemaVersion":0,"launchers":[]}"#.utf8).write(to: r.registryURL)
            try check(try r.read().launchers.isEmpty && names(r).contains { $0.hasPrefix("launchers.corrupt-") }, "registry with schema 0 is set aside")
        }
        do {
            let r = try recoveryStore()
            try r.write(Registry(selectedID: "one", launchers: [Launcher(id: "one", name: "One", executable: "a.exe")]))
            try r.write(Registry(selectedID: "one", launchers: [Launcher(id: "one", name: "Uno", executable: "a.exe")]))
            try fm.removeItem(at: r.registryURL)
            try check((try? r.read())?.launchers.first?.name == "One" && r.recoveryNotice != nil, "a missing registry comes back from the backup")
        }

        // Watchdog and interrupted-migration diagnostics.
        try check(LaunchDiagnostics.explain("watchdog: only 4000 MB of disk left, stopping the game\n")?.contains("5GB") == true, "disk watchdog stop gets a Korean reason")
        try check(LaunchDiagnostics.explain("watchdog: critical memory pressure, stopping the game\n")?.contains("메모리") == true
                  && LaunchDiagnostics.explain("watchdog: Wine resident memory at 9000 MB, stopping the game")?.contains("메모리") == true, "memory watchdog stop gets a Korean reason")
        try check(LaunchDiagnostics.explain("watchdog: limits 1 MB\nwatchdog: something new\n")?.hasPrefix("마지막 로그 줄: watchdog:") == true, "unknown watchdog line is shown as the last log line")
        try check(LaunchDiagnostics.explain("standalone: prefix migration incomplete; restore its recorded snapshot")?.contains("다시 시도") == true, "interrupted migration explains the recovery choices")
        try check(PrefixMigration.lowDiskError(availableBytes: 4 << 30)?.localizedDescription.contains("약 4.0 GB") == true
                  && PrefixMigration.lowDiskError(availableBytes: 6 << 30) == nil && PrefixMigration.lowDiskError(availableBytes: nil) == nil, "low disk space blocks a launch only when it is known to be low")
        try check((PrefixMigration.availableBytes(near: temp.appendingPathComponent("a/b/c")) ?? 0) > 0, "free space is read from the nearest existing folder")

        // Interrupted runtime migration: marker, snapshot validation, lock.
        do {
            let r = try recoveryStore()
            let parent = r.root.appendingPathComponent("prefixes", isDirectory: true)
            let env = parent.appendingPathComponent("lab", isDirectory: true)
            func makePrefix(_ url: URL, id: String) throws {
                try fm.createDirectory(at: url.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
                try Data((id + "\n").utf8).write(to: url.appendingPathComponent(".hadron-prefix-ready"))
            }
            func record(_ path: String) throws { try Data((path + "\n").utf8).write(to: PrefixMigration.marker(env)) }
            try makePrefix(env, id: "0.3.0-ac5")
            let good = parent.appendingPathComponent("lab.backup.20261117-101010.123", isDirectory: true)
            try makePrefix(good, id: "0.3.0-ac4")
            try check(!PrefixMigration.isInterrupted(env), "no marker, no interrupted migration")
            try record(good.path)
            try check(PrefixMigration.isInterrupted(env) && PrefixMigration.snapshot(for: env, store: r) == good.standardizedFileURL, "a sibling backup recorded by the runtime is accepted")
            for (label, path) in [("parent traversal", parent.path + "/lab.backup.1/../../escape"), ("another folder", r.root.path + "/lab.backup.1"), ("wrong name", parent.path + "/other.backup.1"),
                                  ("relative path", "lab.backup.1"), ("the environment itself", env.path), ("missing folder", parent.path + "/lab.backup.missing"), ("empty record", "")] {
                try record(path)
                try check(PrefixMigration.snapshot(for: env, store: r) == nil, "snapshot refused: \(label)")
            }
            let link = parent.appendingPathComponent("lab.backup.link")
            try fm.createSymbolicLink(at: link, withDestinationURL: good)
            try record(link.path)
            try check(PrefixMigration.snapshot(for: env, store: r) == nil, "snapshot refused: symbolic link")
            let noReady = parent.appendingPathComponent("lab.backup.noready", isDirectory: true)
            try fm.createDirectory(at: noReady.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
            try record(noReady.path)
            try check(PrefixMigration.snapshot(for: env, store: r) == nil, "snapshot refused: no ready marker")
            let noDrive = parent.appendingPathComponent("lab.backup.nodrive", isDirectory: true)
            try fm.createDirectory(at: noDrive, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: noDrive.appendingPathComponent(".hadron-prefix-ready"))
            try record(noDrive.path)
            try check(PrefixMigration.snapshot(for: env, store: r) == nil, "snapshot refused: no drive_c")
            let marked = parent.appendingPathComponent("lab.backup.marked", isDirectory: true)
            try makePrefix(marked, id: "x")
            try Data("x".utf8).write(to: PrefixMigration.marker(marked))
            try record(marked.path)
            try check(PrefixMigration.snapshot(for: env, store: r) == nil, "snapshot refused: it is itself unfinished")
            // Lock: absent is free, held elsewhere refuses, free again afterwards.
            let lock = parent.appendingPathComponent(".lab.hadron-session.lock")
            var ran = false
            try PrefixMigration.withEnvironmentFree(env) { ran = true }
            try check(ran, "environment without a lock file counts as free")
            let holder = Darwin.open(lock.path, O_CREAT | O_RDWR, 0o600)
            try check(holder >= 0 && flock(holder, LOCK_EX | LOCK_NB) == 0, "test holds the session lock")
            ran = false
            try rejects("a held session lock blocks recovery") { try PrefixMigration.withEnvironmentFree(env) { ran = true } }
            try check(!ran, "recovery body does not run while a session holds the environment")
            flock(holder, LOCK_UN); Darwin.close(holder)
            try PrefixMigration.clearMarker(env)
            try check(!PrefixMigration.isInterrupted(env) && fm.fileExists(atPath: env.appendingPathComponent(".hadron-prefix-ready").path), "retry removes only the marker")
            // Migration detection compares the recorded id with the runtime's BUILD-ID.
            let rt = parent.appendingPathComponent("rt", isDirectory: true)
            try fm.createDirectory(at: rt, withIntermediateDirectories: true)
            try Data("0.3.0-ac5\n".utf8).write(to: rt.appendingPathComponent("BUILD-ID"))
            try check(!PrefixMigration.isMigrating(prefix: env, runtime: rt) && PrefixMigration.isMigrating(prefix: good, runtime: rt)
                      && !PrefixMigration.isMigrating(prefix: parent.appendingPathComponent("none"), runtime: rt), "an environment under another build id is about to migrate")
        }

        // Sessions an earlier run left behind: lock test, scope path, process check, real stand-in supervisor.
        do {
            let r = try recoveryStore()
            let parent = r.root.appendingPathComponent("prefixes", isDirectory: true)
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            let env = parent.appendingPathComponent("orph", isDirectory: true)
            try check(!PrefixMigration.isEnvironmentBusy(env), "an environment without a lock file is not busy")
            let lockFile = PrefixMigration.lockURL(env)
            let holder = Darwin.open(lockFile.path, O_CREAT | O_RDWR, 0o600)
            try check(holder >= 0 && flock(holder, LOCK_EX | LOCK_NB) == 0 && PrefixMigration.isEnvironmentBusy(env), "a held session lock makes the environment busy")
            do { try PrefixMigration.withEnvironmentFree(env) {}; throw AlchemacError.message("FAIL: busy environment accepted") }
            catch is OrphanSession { passed += 1; print("PASS: a held lock throws OrphanSession for destructive operations") }
            flock(holder, LOCK_UN); Darwin.close(holder)
            try check(!PrefixMigration.isEnvironmentBusy(env), "the lock test does not keep the lock")
            try check(OrphanSession(prefix: env).localizedDescription.hasPrefix("이전에 시작한 Wine 세션이 아직 이 환경을 쓰고 있습니다."), "orphan refusal explains itself")
            // The scope folder name is md5 of the real path of the prefix, as standalone-run computes it.
            try check(OrphanSessions.md5Hex("") == "d41d8cd98f00b204e9800998ecf8427e" && OrphanSessions.md5Hex("abc") == "900150983cd24fb0d6963f7d28e17f72", "md5 helper matches the known digests")
            try fm.createDirectory(at: r.support, withIntermediateDirectories: true)
            let linkParent = temp.appendingPathComponent("orph-link")
            try fm.createSymbolicLink(at: linkParent, withDestinationURL: parent)
            let real = OrphanSessions.realPrefixPath(linkParent.appendingPathComponent("한글 env"))
            try check(real == (parent.path + "/한글 env"), "prefix path is resolved through its parent's links like pwd -P")
            let sh = Process(), pipe = Pipe()
            sh.executableURL = URL(fileURLWithPath: "/bin/sh"); sh.arguments = ["-c", "printf '%s' \"$1\" | /sbin/md5 -q", "sh", real!]; sh.standardOutput = pipe
            try sh.run(); sh.waitUntilExit()
            let shellKey = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            try check(OrphanSessions.md5Hex(real!) == shellKey && OrphanSessions.scopeDirectory(support: r.support, prefix: linkParent.appendingPathComponent("한글 env"))?.lastPathComponent == shellKey,
                      "scope key equals what /sbin/md5 prints for the same path")
            // KERN_PROCARGS2 parsing.
            func procArgs(_ args: [String]) -> Data {
                var bytes: [UInt8] = [UInt8(args.count), 0, 0, 0] + Array("/bin/sh".utf8) + [0, 0, 0]
                for arg in args { bytes += Array(arg.utf8) + [0] }
                return Data(bytes + Array("HOME=/x".utf8) + [0])
            }
            let good = ["/bin/sh", "/s/runtimes/0.3.0-ac5/scripts/standalone-run", "alchemac-x"]
            try check(OrphanSessions.arguments(fromProcArgs: procArgs(good)) == good && OrphanSessions.isSupervisor(good), "supervisor command line is recognised")
            try check(!OrphanSessions.isSupervisor(["/bin/bash", good[1]]) && !OrphanSessions.isSupervisor(["/bin/sh", "/s/scripts/other"]) && !OrphanSessions.isSupervisor(["/bin/sh"])
                      && OrphanSessions.arguments(fromProcArgs: Data([1, 0])).isEmpty, "other processes are not supervisors")
            try check(OrphanSessions.arguments(ofProcess: getpid())?.isEmpty == false, "this process's own arguments can be read with sysctl")
            // Verification gates, with this process's pid and a stubbed command line (nothing is signalled).
            let support = temp.appendingPathComponent("orph-support", isDirectory: true)
            try fm.createDirectory(at: support, withIntermediateDirectories: true)
            let scopeDir = OrphanSessions.scopeDirectory(support: support, prefix: env)!
            try fm.createDirectory(at: scopeDir, withIntermediateDirectories: true)
            let realEnv = OrphanSessions.realPrefixPath(env)!
            try Data((realEnv + "\n").utf8).write(to: scopeDir.appendingPathComponent("owner-prefix"))
            try Data("\(getpid())\n".utf8).write(to: scopeDir.appendingPathComponent("supervisor-pid"))
            try check(OrphanSessions.verifiedSupervisor(support: support, prefix: env, arguments: { _ in good }) == getpid(), "owner, live pid and command line all match")
            try check(OrphanSessions.verifiedSupervisor(support: support, prefix: env, arguments: { _ in ["/bin/sh", "/x/other"] }) == nil, "a pid whose command line is not a supervisor is refused")
            try Data("999999999\n".utf8).write(to: scopeDir.appendingPathComponent("supervisor-pid"))
            try check(OrphanSessions.verifiedSupervisor(support: support, prefix: env, arguments: { _ in good }) == nil, "a dead pid is refused")
            try Data("\(getpid())\n".utf8).write(to: scopeDir.appendingPathComponent("supervisor-pid"))
            try Data("/somewhere/else\n".utf8).write(to: scopeDir.appendingPathComponent("owner-prefix"))
            try check(OrphanSessions.verifiedSupervisor(support: support, prefix: env, arguments: { _ in good }) == nil, "a scope owned by another prefix is refused")
            try check(!OrphanSessions.terminate(support: support, prefix: env), "nothing is sent while the environment's lock is free")
            // A real stand-in supervisor: holds the session lock like standalone-run (fd 8 via lockf) and stops on TERM.
            let standIn = temp.appendingPathComponent("orph-rt/scripts/standalone-run")
            try fm.createDirectory(at: standIn.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(("#!/bin/sh\nexec 8>>\"$LOCK\" || exit 1\nlockf -s -t 0 8 || exit 75\nprintf '%s\\n' \"$OWNER\" > \"$SCOPE/owner-prefix\"\nprintf '%s\\n' $$ > \"$SCOPE/supervisor-pid\"\n"
                      + "trap 'exit 143' TERM\nsleep 30 8>&- &\nwait\n").utf8).write(to: standIn)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: standIn.path)
            let supervisor = Process()
            supervisor.executableURL = standIn; supervisor.arguments = ["alchemac-test"]
            supervisor.environment = ["LOCK": lockFile.path, "OWNER": realEnv, "SCOPE": scopeDir.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            try Data().write(to: lockFile)
            try supervisor.run()
            try check(spin { PrefixMigration.isEnvironmentBusy(env) && OrphanSessions.verifiedSupervisor(support: support, prefix: env) == supervisor.processIdentifier },
                      "a running stand-in supervisor is found through its lock, scope files and command line")
            try check(OrphanSessions.terminate(support: support, prefix: env) && spin { !PrefixMigration.isEnvironmentBusy(env) } && { supervisor.waitUntilExit(); return supervisor.terminationStatus == 143 }(),
                      "terminate stops the verified supervisor and the lock becomes free")
        }

        // Startup cleanup plan: which paths would go, from a temporary tree.
        do {
            let r = try recoveryStore()
            let root = r.root, support = r.support
            func dir(_ url: URL) throws { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
            func file(_ url: URL, _ text: String = "x") throws { try dir(url.deletingLastPathComponent()); try Data(text.utf8).write(to: url) }
            // Store-level staging: folders and registry scripts of this app only, never links.
            try dir(root.appendingPathComponent(".import-AAA")); try dir(root.appendingPathComponent("launchers/app-1/game"))
            try fm.createSymbolicLink(at: root.appendingPathComponent(".import-link"), withDestinationURL: temp)
            try dir(root.appendingPathComponent("addons/.install-BBB")); try dir(root.appendingPathComponent("addons/sample"))
            try file(root.appendingPathComponent("registry.noindex/one.reg")); try file(root.appendingPathComponent("registry.noindex/notes.txt"))
            // Environment creation leftovers.
            try dir(root.appendingPathComponent("prefixes/lab")); try dir(root.appendingPathComponent("prefixes/lab.hadron-new.123"))
            try dir(root.appendingPathComponent("prefixes/lab.hadron-new.x")); try dir(root.appendingPathComponent("prefixes/lab.backup.20261101-000000.5"))
            try dir(root.appendingPathComponent("launchers/app-1/prefix.hadron-new.9"))
            // Scopes.
            func scope(owner: String?, name: String? = nil) throws -> URL {
                let url = support.appendingPathComponent("prefix-sessions/" + (name ?? OrphanSessions.md5Hex(owner ?? "none")), isDirectory: true)
                try dir(url)
                if let owner { try file(url.appendingPathComponent("owner-prefix"), owner + "\n") }
                return url
            }
            let labPath = root.appendingPathComponent("prefixes/lab").path
            let live = try scope(owner: labPath)
            for id in ["0.3.0-ac5", "0.3.0-ac4"] { try file(live.appendingPathComponent("runtimes/\(id)/BUILD-ID"), id + "\n") }
            try dir(live.appendingPathComponent("runtimes/.new.77")); try dir(live.appendingPathComponent("runtimes/odd-no-build-id"))
            try file(live.appendingPathComponent("runtimes/.launches/0.3.0-ac4.999999999"), labPath); try file(live.appendingPathComponent("runtimes/.launches/0.3.0-ac5.\(getpid())"), labPath)
            try file(live.appendingPathComponent("active-prefix"), ""); try file(live.appendingPathComponent("supervisor-pid"), "1\n")
            try fm.createSymbolicLink(at: live.appendingPathComponent("runtimes/linked"), withDestinationURL: temp)
            let gonePath = root.appendingPathComponent("prefixes/deleted").path
            let gone = try scope(owner: gonePath); try file(gone.appendingPathComponent("runtimes/0.3.0-ac5/BUILD-ID"), "x")
            let blank = try scope(owner: nil, name: String(repeating: "a", count: 32)); try file(blank.appendingPathComponent("owner-prefix"), "")
            let missingOwner = try scope(owner: nil, name: String(repeating: "b", count: 32))
            let foreign = try scope(owner: nil, name: "not-a-hash"); try file(foreign.appendingPathComponent("owner-prefix"), "")
            let mismatch = try scope(owner: labPath, name: String(repeating: "c", count: 32))
            try dir(mismatch.appendingPathComponent("runtimes/old")); try file(mismatch.appendingPathComponent("runtimes/old/BUILD-ID"), "old")
            let busyPath = root.appendingPathComponent("prefixes/busy").path
            try dir(URL(fileURLWithPath: busyPath))
            let inUse = try scope(owner: busyPath); try file(inUse.appendingPathComponent("runtimes/0.3.0-ac4/BUILD-ID"), "0.3.0-ac4")
            let linkScope = support.appendingPathComponent("prefix-sessions/" + String(repeating: "d", count: 32))
            try fm.createSymbolicLink(at: linkScope, withDestinationURL: temp)
            let items = StartupCleanup.plan(root: root, support: support, runtimeID: "0.3.0-ac5", processes: "/x/y\n\(inUse.path)/runtimes/0.3.0-ac4/dist/bin/wineserver\n")
            let removed = Set(items.map(\.url.path))
            func under(_ base: URL, _ rest: String) -> String { base.appendingPathComponent(rest).path }
            let expected: Set<String> = [
                root.appendingPathComponent(".import-AAA").path, root.appendingPathComponent("addons/.install-BBB").path, root.appendingPathComponent("registry.noindex/one.reg").path,
                root.appendingPathComponent("prefixes/lab.hadron-new.123").path, root.appendingPathComponent("launchers/app-1/prefix.hadron-new.9").path,
                under(live, "runtimes/0.3.0-ac4"), under(live, "runtimes/.new.77"), under(live, "runtimes/.launches/0.3.0-ac4.999999999"), under(live, "active-prefix"),
                gone.path, blank.path, missingOwner.path]
            try check(removed == expected, "cleanup plan removes exactly the stale paths" + (removed == expected ? "" : " got \(removed.subtracting(expected)) missing \(expected.subtracting(removed))"))
            try check(!removed.contains(under(live, "runtimes/0.3.0-ac5")) && !removed.contains(under(live, "runtimes/.launches/0.3.0-ac5.\(getpid())")), "the bundled runtime copy and a live launch mark stay")
            try check(!removed.contains(under(live, "runtimes/odd-no-build-id")) && !removed.contains(under(live, "runtimes/linked")) && !removed.contains(linkScope.path), "unknown folders and links are never removed")
            try check(!removed.contains(foreign.path) && !removed.contains(mismatch.path) && !removed.contains(under(inUse, "runtimes/0.3.0-ac4")), "scopes that are not understood or that Wine is using stay")
            try check(items.filter { $0.action == .trash }.allSatisfy { !$0.url.path.contains("prefix-sessions") } && items.filter { $0.url == gone }.first?.prefix?.path == gonePath,
                      "only user-adjacent leftovers go to the Trash, scope caches are removed under the environment's lock")
            try check(StartupCleanup.plan(root: root, support: support, runtimeID: nil, processes: "").allSatisfy { !$0.url.path.contains("/runtimes/0") }, "without a readable bundled BUILD-ID no runtime copy is removed")
            // Applying removals: a busy environment is skipped, a free one is cleaned.
            let lab = URL(fileURLWithPath: labPath, isDirectory: true)
            let holder = Darwin.open(PrefixMigration.lockURL(lab).path, O_CREAT | O_RDWR, 0o600)
            _ = flock(holder, LOCK_EX | LOCK_NB)
            let cache = [StartupCleanup.Item(url: URL(fileURLWithPath: under(live, "runtimes/.new.77")), action: .remove, prefix: lab)]
            let skipped = StartupCleanup.apply(cache, store: r)
            try check(skipped.removed == 0 && skipped.skipped == 1 && fm.fileExists(atPath: under(live, "runtimes/.new.77")), "an environment whose session lock is held is skipped")
            flock(holder, LOCK_UN); Darwin.close(holder)
            let done = StartupCleanup.apply(items.filter { $0.action == .remove && $0.prefix != nil || $0.url == blank || $0.url == missingOwner }, store: r)
            try check(done.skipped == 0 && !fm.fileExists(atPath: under(live, "runtimes/0.3.0-ac4")) && !fm.fileExists(atPath: gone.path) && fm.fileExists(atPath: under(live, "runtimes/0.3.0-ac5/BUILD-ID"))
                      && fm.fileExists(atPath: under(inUse, "runtimes/0.3.0-ac4/BUILD-ID")), "applying the plan removes stale copies and keeps the current one")
            try check(StartupCleanup.runtimeID(support) == nil, "a folder without BUILD-ID has no runtime id")
        }

        // Private runtime copy verification (review 5-#5): a copy must stay equal to the signed bundle.
        do {
            let base = temp.appendingPathComponent("copy-verify", isDirectory: true)
            func write(_ root: URL, _ path: String, _ text: String) throws {
                try fm.createDirectory(at: root.appendingPathComponent(path).deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: root.appendingPathComponent(path))
            }
            func makeBundle(_ name: String) throws -> URL {
                let root = base.appendingPathComponent(name, isDirectory: true)
                try write(root, "BUILD-ID", "0.3.0-test\n"); try write(root, "ADAPTER.json", "{}")
                try write(root, "scripts/play", "#!/bin/sh\necho play\n"); try write(root, "scripts/standalone-run", "#!/bin/sh\necho run\n")
                try write(root, "dist/bin/wine", "binary-wine"); try write(root, "dist/lib/a/b/c.so", "so-bytes")
                try fm.createSymbolicLink(atPath: root.appendingPathComponent("dist/lib/link.so").path, withDestinationPath: "a/b/c.so")
                return root
            }
            /// Made like runtime_copy: copy to a staging name, then rename into place (the rename sets the top's ctime last).
            func makeCopy(of bundle: URL, _ name: String) throws -> URL {
                let staged = base.appendingPathComponent(".new." + name), place = base.appendingPathComponent(name, isDirectory: true)
                try fm.copyItem(at: bundle, to: staged); try fm.moveItem(at: staged, to: place)
                return place
            }
            let bundle = try makeBundle("bundle")
            func fresh(_ name: String) throws -> URL { try makeCopy(of: bundle, name) }
            try check(RuntimeCopy.verify(copy: try fresh("pristine"), bundle: bundle) == nil, "a pristine runtime copy verifies")
            try check(RuntimeCopy.verify(copy: base.appendingPathComponent("absent"), bundle: bundle) == nil, "an absent copy has nothing to verify")
            var copy = try fresh("same-size")
            try Data("#!/bin/sh\necho pl@y\n".utf8).write(to: copy.appendingPathComponent("scripts/play"))
            try check(RuntimeCopy.verify(copy: copy, bundle: bundle, slack: 1000)?.reason.contains("scripts/play") == true, "a script changed to the same size fails by its bytes")
            copy = try fresh("append")
            let handle = try FileHandle(forWritingTo: copy.appendingPathComponent("dist/bin/wine")); try handle.seekToEnd(); handle.write(Data("x".utf8)); try handle.close()
            try check(RuntimeCopy.verify(copy: copy, bundle: bundle, slack: 1000) != nil, "an appended byte fails")
            copy = try fresh("added")
            try write(copy, "dist/extra.so", "evil")
            try check(RuntimeCopy.verify(copy: copy, bundle: bundle, slack: 1000)?.reason.contains("extra.so") == true, "an added file fails")
            copy = try fresh("removed")
            try fm.removeItem(at: copy.appendingPathComponent("dist/lib/a/b/c.so"))
            try check(RuntimeCopy.verify(copy: copy, bundle: bundle, slack: 1000)?.reason.contains("c.so") == true, "a removed file fails")
            copy = try fresh("link")
            try fm.removeItem(at: copy.appendingPathComponent("dist/lib/link.so"))
            try fm.createSymbolicLink(atPath: copy.appendingPathComponent("dist/lib/link.so").path, withDestinationPath: "/tmp/evil.so")
            try check(RuntimeCopy.verify(copy: copy, bundle: bundle, slack: 1000)?.reason.contains("link.so") == true, "a changed symlink destination fails")
            copy = try fresh("kind")
            try fm.removeItem(at: copy.appendingPathComponent("dist/lib/link.so")); try write(copy, "dist/lib/link.so", "so")
            try check(RuntimeCopy.verify(copy: copy, bundle: bundle, slack: 1000) != nil, "a symlink replaced by a file fails")
            let linked = base.appendingPathComponent("top-link")
            try fm.createSymbolicLink(at: linked, withDestinationURL: bundle)
            try check(RuntimeCopy.verify(copy: linked, bundle: bundle) != nil, "a copy that is a symlink to elsewhere fails")
            // ctime: a chmod changes no content, size or name, and only moves the file's ctime past the top's.
            copy = try fresh("chmod")
            try check(RuntimeCopy.verify(copy: copy, bundle: bundle, slack: 1) == nil, "a pristine copy passes with a tight slack")
            Thread.sleep(forTimeInterval: 1.3)
            try fm.setAttributes([.posixPermissions: 0o777], ofItemAtPath: copy.appendingPathComponent("dist/bin/wine").path)
            try check(RuntimeCopy.verify(copy: copy, bundle: bundle, slack: 1)?.reason.contains("dist/bin/wine") == true, "a chmod-only change fails through its ctime")
            try check(RuntimeCopy.verify(copy: copy, bundle: bundle) == nil, "the same chmod is inside the default 2 s slack (the rule is a threshold)")
            // Touching the top afterwards (to hide a change) is caught the other way round.
            copy = try fresh("top-touched")
            Thread.sleep(forTimeInterval: 1.3)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)
            try check(RuntimeCopy.verify(copy: copy, bundle: bundle, slack: 1)?.reason.contains("사본 폴더") == true, "a top directory touched after the entries fails")
            // The removal path deletes the copy folder and nothing around it.
            let support = base.appendingPathComponent("support", isDirectory: true), env = base.appendingPathComponent("envs/lab", isDirectory: true)
            try fm.createDirectory(at: env, withIntermediateDirectories: true)
            try fm.createDirectory(at: support, withIntermediateDirectories: true)
            let scope = OrphanSessions.scopeDirectory(support: support, prefix: env)!
            let runtimes = scope.appendingPathComponent("runtimes", isDirectory: true)
            try fm.createDirectory(at: runtimes, withIntermediateDirectories: true)
            for name in [".new.", "0.3.0-old"] { try fm.createDirectory(at: runtimes.appendingPathComponent(name), withIntermediateDirectories: true) }
            try Data("owner".utf8).write(to: scope.appendingPathComponent("owner-prefix"))
            let kept = try fm.contentsOfDirectory(atPath: runtimes.path)
            let live = runtimes.appendingPathComponent("0.3.0-test", isDirectory: true)
            try fm.copyItem(at: bundle, to: live)
            try write(live, "scripts/watchdog", "extra")
            try fm.createSymbolicLink(at: scope.appendingPathComponent("runtime"), withDestinationURL: live)
            let reason = try RuntimeCopy.verifyAndReset(support: support, prefix: env, runtime: bundle)
            try check(reason != nil && !fm.fileExists(atPath: live.path) && Set(try fm.contentsOfDirectory(atPath: runtimes.path)) == Set(kept)
                      && fm.fileExists(atPath: scope.appendingPathComponent("owner-prefix").path) && fm.fileExists(atPath: bundle.appendingPathComponent("scripts/play").path)
                      && (try? fm.destinationOfSymbolicLink(atPath: scope.appendingPathComponent("runtime").path)) == live.path,
                      "a changed copy is removed alone; other copies, the scope files and the bundle stay (a dangling runtime link is re-pointed by the runtime)")
            try check(try RuntimeCopy.verifyAndReset(support: support, prefix: env, runtime: bundle) == nil, "with the copy gone nothing is reset again")
            try fm.copyItem(at: bundle, to: live)
            try check(try RuntimeCopy.verifyAndReset(support: support, prefix: env, runtime: bundle) == nil && fm.fileExists(atPath: live.path), "an equal copy is left in place")
            let lockFile = PrefixMigration.lockURL(env)
            try Data().write(to: lockFile)
            let holder = Darwin.open(lockFile.path, O_RDWR); flock(holder, LOCK_EX)
            try write(live, "scripts/watchdog", "extra")
            do { _ = try RuntimeCopy.verifyAndReset(support: support, prefix: env, runtime: bundle); throw AlchemacError.message("FAIL: busy environment") }
            catch is OrphanSession { passed += 1; print("PASS: a held session lock stops the verification before anything is removed") }
            flock(holder, LOCK_UN); Darwin.close(holder)
            try check(fm.fileExists(atPath: live.path), "the copy of a busy environment is untouched")
            // Timing with a runtime-sized tree (about 2200 entries).
            let big = base.appendingPathComponent("big", isDirectory: true)
            try write(big, "BUILD-ID", "big\n")
            for i in 0..<2200 { try write(big, "dist/d\(i % 40)/f\(i).bin", String(repeating: "x", count: 64)) }
            for i in 0..<10 { try write(big, "scripts/s\(i)", String(repeating: "#", count: 4000)) }
            let bigCopy = try makeCopy(of: big, "big-copy")
            _ = RuntimeCopy.verify(copy: bigCopy, bundle: big)                    // fills the bundle cache
            let started = Date()
            let timed = RuntimeCopy.verify(copy: bigCopy, bundle: big)
            let ms = Date().timeIntervalSince(started) * 1000
            print(String(format: "INFO: verify of %d entries took %.1f ms", RuntimeCopy.scan(bigCopy.path)?.count ?? 0, ms))
            try check(timed == nil && ms < 100, "verifying a runtime-sized copy takes well under 100 ms")
        }

        // Backups: which snapshots are kept.
        do {
            let r = try recoveryStore()
            let parent = r.root.appendingPathComponent("prefixes", isDirectory: true)
            let env = parent.appendingPathComponent("lab", isDirectory: true)
            for name in ["lab", "lab.backup.20261101-100000.11", "lab.backup.20261117-101010.123", "lab.backup.20260101-000000.7", "lab.backup.odd", "other.backup.20261201-000000.1"] {
                try fm.createDirectory(at: parent.appendingPathComponent(name), withIntermediateDirectories: true)
            }
            try fm.createSymbolicLink(at: parent.appendingPathComponent("lab.backup.link"), withDestinationURL: parent.appendingPathComponent("lab.backup.odd"))
            try Data().write(to: parent.appendingPathComponent("lab.backup.file"))
            let found = Backups.snapshots(of: env)
            try check(Set(found.map(\.url.lastPathComponent)) == ["lab.backup.20261101-100000.11", "lab.backup.20261117-101010.123", "lab.backup.20260101-000000.7", "lab.backup.odd"],
                      "snapshots are the plain backup folders beside the environment")
            try check(Backups.newest(found)?.url.lastPathComponent == "lab.backup.20261117-101010.123" && found.first { $0.url.lastPathComponent == "lab.backup.odd" }?.date == nil, "the newest snapshot is chosen by the date in its name")
            try check(Set(Backups.removable(found, protected: nil).map(\.lastPathComponent)) == ["lab.backup.20261101-100000.11", "lab.backup.20260101-000000.7", "lab.backup.odd"], "all but the newest are removable")
            try Data((parent.path + "/lab.backup.20261101-100000.11\n").utf8).write(to: PrefixMigration.marker(env))
            let kept = Backups.protected(env)
            try check(Set(Backups.removable(found, protected: kept).map(\.lastPathComponent)) == ["lab.backup.20260101-000000.7", "lab.backup.odd"], "the snapshot an unfinished migration points to is never removable")
            try check(Backups.removable([], protected: nil).isEmpty && Backups.removable(Array(found.prefix(1)), protected: nil).isEmpty, "a single snapshot is kept")
        }

        // Updates: signed manifest, tree verification, delta application and the install helper (no network).
        do {
            let signing = Curve25519.Signing.PrivateKey()
            let publicKey = signing.publicKey.rawRepresentation.base64EncodedString()
            func file(_ url: URL, _ text: String, executable: Bool = false) throws {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url)
                try fm.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
            }
            /// A fake app: Info.plist, an executable, a file with spaces/Korean in its path, a link, an empty folder.
            func fakeApp(_ root: URL, version: String, build: Int, binary: String, extra: [String: String] = [:]) throws {
                try fm.createDirectory(at: root.appendingPathComponent("Contents/Resources/빈 폴더"), withIntermediateDirectories: true)
                let plist: [String: Any] = ["CFBundleIdentifier": "io.github.deavour31.alchemac", "CFBundleVersion": String(build), "CFBundleShortVersionString": version]
                try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: root.appendingPathComponent("Contents/Info.plist"))
                try file(root.appendingPathComponent("Contents/MacOS/Alchemac"), binary, executable: true)
                try file(root.appendingPathComponent("Contents/Resources/한글 dir/a b.txt"), "same")
                try fm.createSymbolicLink(atPath: root.appendingPathComponent("Contents/Resources/link").path, withDestinationPath: "한글 dir/a b.txt")
                for (path, text) in extra { try file(root.appendingPathComponent(path), text) }
            }
            func entries(_ app: URL) throws -> [UpdateManifest.Entry] {
                let found = try { () throws -> [String: RuntimeCopy.Entry] in
                    guard let f = RuntimeCopy.scan(app.path) else { throw AlchemacError.message("scan") }; return f }()
                return try found.keys.sorted().map { path in
                    let entry = found[path]!, url = app.appendingPathComponent(path)
                    switch entry.kind {
                    case UInt16(S_IFDIR): return .init(path: path, type: "dir")
                    case UInt16(S_IFLNK): return .init(path: path, type: "link", target: entry.link)
                    default:
                        var info = stat(); _ = lstat(url.path, &info)
                        return .init(path: path, type: "file", size: entry.size, sha256: try Updater.sha256Hex(of: url), executable: info.st_mode & 0o111 != 0)
                    }
                }
            }
            func manifestOf(_ app: URL, version: String = "0.5.13", build: Int = 36, entries given: [UpdateManifest.Entry]? = nil,
                            dmg: String = "Alchemac-0.5.13.dmg", delta: String = "Alchemac-0.5.13-from-35.tar.xz", schema: Int = 1) throws -> UpdateManifest {
                let sha = String(repeating: "ab", count: 32)
                return UpdateManifest(schema: schema, bundleID: "io.github.deavour31.alchemac", version: version, build: build, minimumSystem: "27.0",
                                      releaseURL: "https://github.com/Deavour31/alchemac/releases/tag/v" + version,
                                      dmg: .init(name: dmg, size: 10, sha256: sha), deltas: [.init(fromBuild: 35, name: delta, size: 5, sha256: sha)],
                                      entries: try given ?? entries(app))
            }
            func encode(_ manifest: UpdateManifest) throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(manifest) }
            func sign(_ data: Data, _ key: Curve25519.Signing.PrivateKey = signing) throws -> Data { Data(try key.signature(for: data).base64EncodedString().utf8) }

            let newApp = temp.appendingPathComponent("update new 새 앱.app"), oldApp = temp.appendingPathComponent("update old.app")
            try fakeApp(newApp, version: "0.5.13", build: 36, binary: "binary v36", extra: ["Contents/Resources/new.txt": "added"])
            try fakeApp(oldApp, version: "0.5.12", build: 35, binary: "binary v35", extra: ["Contents/Resources/gone.txt": "only in the old app"])
            let manifest = try manifestOf(newApp)
            let data = try encode(manifest)

            // Signature and validation.
            let ok = try Updater.verifiedManifest(data: data, signature: sign(data), publicKey: publicKey)
            try check(ok == manifest && ok.build == 36, "a manifest with a valid signature is accepted")
            var tampered = data; tampered[tampered.firstIndex(of: UInt8(ascii: "3"))!] = UInt8(ascii: "4")
            try rejects("a tampered manifest byte is rejected") { _ = try Updater.verifiedManifest(data: tampered, signature: sign(data), publicKey: publicKey) }
            try rejects("a signature by another key is rejected") { _ = try Updater.verifiedManifest(data: data, signature: sign(data, Curve25519.Signing.PrivateKey()), publicKey: publicKey) }
            try rejects("the placeholder public key rejects everything") { _ = try Updater.verifiedManifest(data: data, signature: sign(data), publicKey: UpdateFeed.publicKey) }
            try rejects("garbage instead of a signature is rejected") { _ = try Updater.verifiedManifest(data: data, signature: Data("not base64!".utf8), publicKey: publicKey) }
            func signed(_ m: UpdateManifest) throws -> Void { let d = try encode(m); _ = try Updater.verifiedManifest(data: d, signature: sign(d), publicKey: publicKey) }
            let good = manifest.entries
            for bad in ["../x", "/abs", "a/../../b", "", "a//b", "./a", "a/."] {
                try rejects("unsafe path \"\(bad)\" is rejected even when signed") { try signed(manifestOf(newApp, entries: good + [.init(path: bad, type: "dir")])) }
            }
            try rejects("a duplicate path is rejected") { try signed(manifestOf(newApp, entries: good + [good[0]])) }
            try rejects("a link that escapes the bundle is rejected") { try signed(manifestOf(newApp, entries: good + [.init(path: "Contents/bad", type: "link", target: "../../x")])) }
            try rejects("an absolute link target is rejected") { try signed(manifestOf(newApp, entries: good + [.init(path: "Contents/bad", type: "link", target: "/usr/bin")])) }
            try signed(manifestOf(newApp, entries: good + [.init(path: "Contents/a/ok", type: "link", target: "../b/c")]))
            try check(true, "a link that stays inside the bundle is accepted")
            try rejects("a delta name with a slash is rejected") { try signed(manifestOf(newApp, delta: "../evil.tar.xz")) }
            try rejects("a dmg name with a slash is rejected") { try signed(manifestOf(newApp, dmg: "dir/Alchemac.dmg")) }
            try rejects("another schema is rejected") { try signed(manifestOf(newApp, schema: 2)) }
            try rejects("a malformed sha256 is rejected") { try signed(manifestOf(newApp, entries: good + [.init(path: "Contents/z", type: "file", size: 1, sha256: "ABC", executable: false)])) }
            try rejects("a negative size is rejected") { try signed(manifestOf(newApp, entries: good + [.init(path: "Contents/z", type: "file", size: -1, sha256: String(repeating: "0", count: 64), executable: false)])) }
            try rejects("a version that is not numeric is rejected") { try signed(manifestOf(newApp, version: "1.0/../x")) }
            try check(!Updater.isNewer(build: 35, than: 36) && !Updater.isNewer(build: 36, than: 36) && Updater.isNewer(build: 37, than: 36), "only a strictly higher build is an update")
            try check(Updater.systemMeets("27.0", current: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
                      && !Updater.systemMeets("27.1", current: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 5))
                      && Updater.systemMeets("26.4", current: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)), "the minimum system version is compared numerically")
            let now = Date()
            try check(Updater.shouldCheckAutomatically(enabled: true, development: false, last: nil, now: now)
                      && Updater.shouldCheckAutomatically(enabled: true, development: false, last: now.addingTimeInterval(-25 * 3600), now: now)
                      && !Updater.shouldCheckAutomatically(enabled: true, development: false, last: now.addingTimeInterval(-23 * 3600), now: now)
                      && !Updater.shouldCheckAutomatically(enabled: false, development: false, last: nil, now: now)
                      && !Updater.shouldCheckAutomatically(enabled: true, development: true, last: nil, now: now), "the automatic check runs once a day, only when enabled and not in development")
            let suite = UserDefaults(suiteName: "alchemac-selftest-" + UUID().uuidString)!
            suite.set("file:///tmp/feed", forKey: "UpdateFeedURL")
            try check(UpdateFeed.feedBase(development: false, defaults: suite) == UpdateFeed.base
                      && UpdateFeed.feedBase(development: true, defaults: suite).absoluteString == "file:///tmp/feed/"
                      && UpdateFeed.assetURL(version: "0.5.13", name: "a.dmg", development: true, defaults: suite).absoluteString == "file:///tmp/feed/a.dmg"
                      && UpdateFeed.assetURL(version: "0.5.13", name: "a.dmg", development: false, defaults: suite).absoluteString == "https://github.com/Deavour31/alchemac/releases/download/v0.5.13/a.dmg", "the feed override applies to development builds only")
            suite.set("ftp://example.com/", forKey: "UpdateFeedURL")
            try check(UpdateFeed.feedOverride(development: true, defaults: suite) == nil, "a feed override must be http, https or file")

            // Tree verification.
            try Updater.verifyTree(app: newApp, manifest: manifest)
            try check(true, "an exact tree passes verification")
            func mutated(_ label: String, _ change: (URL) throws -> Void) throws {
                let copy = temp.appendingPathComponent("mut-" + UUID().uuidString + ".app")
                try fm.copyItem(at: newApp, to: copy)
                defer { try? fm.removeItem(at: copy) }
                try change(copy)
                try rejects(label) { try Updater.verifyTree(app: copy, manifest: manifest) }
            }
            try mutated("an extra file fails verification") { try file($0.appendingPathComponent("Contents/extra"), "x") }
            try mutated("an extra folder fails verification") { try fm.createDirectory(at: $0.appendingPathComponent("Contents/extra-dir"), withIntermediateDirectories: false) }
            try mutated("a missing file fails verification") { try fm.removeItem(at: $0.appendingPathComponent("Contents/Resources/new.txt")) }
            try mutated("a changed byte fails verification") { try file($0.appendingPathComponent("Contents/Resources/new.txt"), "addeD") }
            try mutated("a wrong executable bit fails verification") { try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: $0.appendingPathComponent("Contents/MacOS/Alchemac").path) }
            try mutated("a changed link target fails verification") {
                let link = $0.appendingPathComponent("Contents/Resources/link")
                try fm.removeItem(at: link); try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "gone.txt")
            }
            try mutated("a file replaced by a link fails verification") {
                let url = $0.appendingPathComponent("Contents/Resources/new.txt")
                try fm.removeItem(at: url); try fm.createSymbolicLink(atPath: url.path, withDestinationPath: "gone.txt")
            }
            try Updater.verifyIdentity(app: newApp, manifest: manifest, codesign: false)
            try check(true, "Info.plist identity matches the manifest")
            try rejects("another build number fails the identity check") { try Updater.verifyIdentity(app: oldApp, manifest: manifest, codesign: false) }
            try rejects("an unsigned fake app fails the codesign check") { try Updater.verifyIdentity(app: newApp, manifest: manifest) }

            // Delta, made the way scripts/make-update-feed.py makes it, applied to a clone of the old app.
            let oldEntries = Dictionary(uniqueKeysWithValues: try entries(oldApp).map { ($0.path, $0) })
            let changed = manifest.entries.filter { $0.type != "dir" && oldEntries[$0.path] != $0 }.map(\.path)
            try check(Set(changed) == ["Contents/Info.plist", "Contents/MacOS/Alchemac", "Contents/Resources/new.txt"], "the delta holds exactly the changed and added files")
            let archive = temp.appendingPathComponent("delta test.tar.xz"), listing = temp.appendingPathComponent("delta.list")
            try Data(changed.sorted().map { $0 + "\n" }.joined().utf8).write(to: listing)
            let made = try Updater.run("/usr/bin/tar", ["--no-mac-metadata", "--no-xattrs", "-cJf", archive.path, "-C", newApp.path, "-T", listing.path])
            try check(made.status == 0, "the delta archive is created with tar")
            let staged = temp.appendingPathComponent("staged.app")
            try fm.copyItem(at: oldApp, to: staged)
            try check(fm.fileExists(atPath: staged.appendingPathComponent("Contents/Resources/gone.txt").path), "the clone starts with a file only the old app has")
            try Updater.applyDelta(archive: archive, to: staged, manifest: manifest)
            try Updater.verifyTree(app: staged, manifest: manifest)
            try check(true, "the old app plus the delta passes the new manifest")
            try check(!fm.fileExists(atPath: staged.appendingPathComponent("Contents/Resources/gone.txt").path)
                      && fm.fileExists(atPath: staged.appendingPathComponent("Contents/Resources/빈 폴더").path), "a file only in the old app is removed and an unchanged folder stays")
            // The same pruning removes a whole folder that is no longer listed, deepest first.
            try file(staged.appendingPathComponent("Contents/old-dir/sub/file"), "x")
            try Updater.conform(app: staged, to: manifest)
            try check(!fm.fileExists(atPath: staged.appendingPathComponent("Contents/old-dir").path), "an unlisted folder with contents is removed")
            let wrongExec = temp.appendingPathComponent("wrong-exec.app")
            try fm.copyItem(at: newApp, to: wrongExec)
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: wrongExec.appendingPathComponent("Contents/MacOS/Alchemac").path)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrongExec.appendingPathComponent("Contents/Resources/new.txt").path)
            try Updater.conform(app: wrongExec, to: manifest)
            try Updater.verifyTree(app: wrongExec, manifest: manifest)
            try check(true, "executable bits are fixed to the manifest")
            try rejects("a delta that does not match the manifest fails verification") {
                let broken = temp.appendingPathComponent("broken.app")
                try fm.copyItem(at: oldApp, to: broken)      // not applied: still the old tree
                try Updater.verifyTree(app: broken, manifest: manifest)
            }

            // Where the app may replace itself.
            try check(!Updater.canReplace(app: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Alchemac.app"), updates: temp), "a translocated app cannot replace itself")
            try check(Updater.canReplace(app: temp.appendingPathComponent("Alchemac.app"), updates: temp.appendingPathComponent("updates")), "an app in a writable folder on the updates volume can")
            try check(!Updater.canReplace(app: URL(fileURLWithPath: "/System/Applications/Alchemac.app"), updates: temp), "an app in a read-only location cannot")
            try check(Updater.stagingURL(app: URL(fileURLWithPath: "/Applications/Alchemac.app"), build: 36).path == "/Applications/.Alchemac-update-36.app", "staging sits next to the app")

            // Install helper (a pid that has already exited, no `open`), paths with spaces.
            let updates = temp.appendingPathComponent("up dates")
            let installed = temp.appendingPathComponent("Installed 앱/Alchemac.app"), stage = temp.appendingPathComponent("Installed 앱/.Alchemac-update-36.app")
            try file(installed.appendingPathComponent("Contents/marker"), "old")
            try file(stage.appendingPathComponent("Contents/marker"), "new")
            let gone = Process(); gone.executableURL = URL(fileURLWithPath: "/usr/bin/true"); try gone.run(); gone.waitUntilExit()
            try Updater.installAndRelaunch(staging: stage, app: installed, oldVersion: "0.5.12", targetBuild: 36, updates: updates, waitFor: gone.processIdentifier, open: false, wait: true)
            let backup = updates.appendingPathComponent("previous/Alchemac-0.5.12.app")
            try check((try? String(contentsOf: installed.appendingPathComponent("Contents/marker"), encoding: .utf8)) == "new"
                      && (try? String(contentsOf: backup.appendingPathComponent("Contents/marker"), encoding: .utf8)) == "old"
                      && !fm.fileExists(atPath: stage.path), "the helper swaps the apps and keeps the old one as a backup")
            let installedResult = Updater.takeInstallResult(updates: updates)
            try check(installedResult?.target == 36 && installedResult?.outcome == "installed", "the helper records a successful install with the target build")
            try check(Updater.takeInstallResult(updates: updates) == nil && !fm.fileExists(atPath: updates.appendingPathComponent("last-install.txt").path), "the result is read once and removed")
            try check(Updater.installReport((36, "installed"), runningBuild: 36) == .installed
                      && Updater.installReport((36, "installed"), runningBuild: 35) == .failed(outcome: "installed")
                      && Updater.installReport((36, "restored"), runningBuild: 35) == .failed(outcome: "restored")
                      && Updater.installReport((36, "not-started"), runningBuild: 36) == .failed(outcome: "not-started"), "only an installed result with the matching build counts as success")
            try check(Updater.backupURL(oldVersion: "0.5.12", updates: updates).lastPathComponent == "Alchemac-0.5.12-2.app", "an existing backup name gets a numeric suffix")
            try check((try? String(contentsOf: updates.appendingPathComponent("install-helper.sh"), encoding: .utf8))?.contains(installed.path) == false, "paths are arguments, never part of the helper script")
            // A missing staging folder changes nothing.
            try rejects("the helper leaves the app alone when the staging folder is missing") {
                try Updater.installAndRelaunch(staging: stage, app: installed, oldVersion: "0.5.13", targetBuild: 37, updates: updates, waitFor: gone.processIdentifier, open: false, wait: true)
            }
            try check((try? String(contentsOf: installed.appendingPathComponent("Contents/marker"), encoding: .utf8)) == "new", "the app is unchanged after a refused swap")
            let failedResult = Updater.takeInstallResult(updates: updates)
            try check(failedResult?.target == 37 && failedResult?.outcome == "not-started", "the helper records a missing staging folder as not-started")
            try check(Updater.takeInstallResult(updates: temp.appendingPathComponent("no-updates")) == nil, "no result file means nothing to report")
            try file(updates.appendingPathComponent("last-install.txt"), "target=abc\noutcome=installed\n")
            try check(Updater.takeInstallResult(updates: updates) == nil, "a malformed result is ignored and removed")

            // The helper's failure paths. The script text is run as is, with only `/bin/mv` swapped for a stub that fails on request
            // (a real mv failure would need a permission trick between the helper's two moves).
            let mvStub = temp.appendingPathComponent("mv-stub")
            try file(mvStub, "#!/bin/sh\nfor a; do last=\"$a\"; done\nfirst=\"\"; for a; do case \"$a\" in -*) ;; *) first=\"$a\"; break;; esac; done\n"
                     + "[ -n \"$FAIL_SRC\" ] && [ \"$first\" = \"$FAIL_SRC\" ] && exit 1\n[ -n \"$FAIL_DEST\" ] && [ \"$last\" = \"$FAIL_DEST\" ] && exit 1\nexec /bin/mv \"$@\"\n")
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mvStub.path)
            let stubbed = Updater.helperScript.replacingOccurrences(of: "/bin/mv", with: mvStub.path)
            try check(stubbed != Updater.helperScript && !stubbed.contains("/bin/mv"), "the test script swaps every mv")
            func swapScenario(_ name: String, failSource: Bool, failDestination: Bool) throws -> (app: URL, stage: URL, backup: URL, result: (target: Int, outcome: String)?) {
                let base = temp.appendingPathComponent("swap-" + name)
                let app = base.appendingPathComponent("Alchemac.app"), stage = base.appendingPathComponent(".Alchemac-update-40.app"), ups = base.appendingPathComponent("updates")
                try file(app.appendingPathComponent("Contents/marker"), "old"); try file(stage.appendingPathComponent("Contents/marker"), "new")
                if failSource { setenv("FAIL_SRC", stage.path, 1) }
                if failDestination { setenv("FAIL_DEST", app.path, 1) }
                defer { unsetenv("FAIL_SRC"); unsetenv("FAIL_DEST") }
                try? Updater.installAndRelaunch(staging: stage, app: app, oldVersion: "1.0", targetBuild: 40, updates: ups, waitFor: gone.processIdentifier, open: false, wait: true, script: stubbed)
                return (app, stage, ups.appendingPathComponent("previous/Alchemac-1.0.app"), Updater.takeInstallResult(updates: ups))
            }
            let restored = try swapScenario("restored", failSource: true, failDestination: false)
            try check(restored.result?.outcome == "restored" && restored.result?.target == 40, "a failed swap-in with a successful move back is recorded as restored")
            try check((try? String(contentsOf: restored.app.appendingPathComponent("Contents/marker"), encoding: .utf8)) == "old"
                      && !fm.fileExists(atPath: restored.backup.path) && fm.fileExists(atPath: restored.stage.path), "restored: the old app is back in place and the staging copy is left")
            let lost = try swapScenario("lost", failSource: false, failDestination: true)
            try check(lost.result?.outcome == "restore-failed" && lost.result?.target == 40, "a failed swap-in with a failed move back is recorded as restore-failed")
            try check(!fm.fileExists(atPath: lost.app.path) && (try? String(contentsOf: lost.backup.appendingPathComponent("Contents/marker"), encoding: .utf8)) == "old",
                      "restore-failed: the old app is still at the backup path, nothing is at the app path")
            try check(Updater.installReport((40, "restore-failed"), runningBuild: 36) == .failed(outcome: "restore-failed"), "a restore-failed result is reported as a failure")
            // After a failed restore the startup cleanup must leave the previous apps alone.
            Updater.cleanup(app: lost.app, currentBuild: 36, updates: lost.backup.deletingLastPathComponent().deletingLastPathComponent(), trashPrevious: false)
            try check(fm.fileExists(atPath: lost.backup.path), "cleanup with trashPrevious false keeps the previous app")

            // Check results: up to date, available, or newer but needing a newer macOS.
            let sys27 = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
            let newer = manifest
            try check(Updater.classify(newer, currentBuild: newer.build, system: sys27) == .upToDate
                      && Updater.classify(newer, currentBuild: newer.build - 1, system: sys27) == .available(newer), "a check tells up to date from available")
            let tooNew = UpdateManifest(schema: newer.schema, bundleID: newer.bundleID, version: newer.version, build: newer.build, minimumSystem: "28.1", releaseURL: newer.releaseURL,
                                        dmg: newer.dmg, deltas: newer.deltas, entries: newer.entries)
            try check(Updater.classify(tooNew, currentBuild: newer.build - 1, system: sys27) == .needsSystem("28.1")
                      && Updater.classify(tooNew, currentBuild: newer.build, system: sys27) == .upToDate, "a newer build that needs a newer macOS is reported as such")

            // Launch cleanup: finished download folders and stale staging go; the Trash is not touched (no previous apps here).
            let cleanUpdates = temp.appendingPathComponent("clean-updates"), cleanParent = temp.appendingPathComponent("clean-parent")
            for name in ["34", "35", "36", "37", "notes"] { try file(cleanUpdates.appendingPathComponent(name + "/part"), "x") }
            try file(cleanParent.appendingPathComponent(".Alchemac-update-35.app/Contents/x"), "x"); try file(cleanParent.appendingPathComponent("Other.app/Contents/x"), "x")
            Updater.cleanup(app: cleanParent.appendingPathComponent("Alchemac.app"), currentBuild: 36, updates: cleanUpdates)
            try check(StartupCleanup.names(cleanUpdates) == ["37", "notes"] && StartupCleanup.names(cleanParent) == ["Other.app"], "launch cleanup removes download folders up to the current build and stale staging")
        }

        // Program availability, row status, results inbox and quit summary (pure rules behind the window).
        do {
            let shared = "/lib/prefixes/shared", other = "/lib/prefixes/env", own = "/lib/launchers/x/prefix"
            func snap(_ prefix: String, _ id: String?, _ title: String, stopping: Bool = false, preparing: Bool = false) -> SessionSnapshot {
                SessionSnapshot(prefix: prefix, launcherID: id, title: title, stopping: stopping, preparing: preparing)
            }
            func make(_ id: String, _ prefix: String?, _ sessions: [SessionSnapshot] = [], task: String? = nil, updating: Bool = false, maintenance: Bool = false) -> ProgramAvailability {
                ProgramAvailability.make(launcherID: id, prefix: prefix, sessions: sessions, task: task, updating: updating, maintenance: maintenance)
            }
            let idle = make("a", shared)
            try check(idle.canRun && idle.canRename && idle.canRemove && idle.canDelete && idle.canToggleRetina && idle.canToggleScaled && idle.canRunTool && !idle.canStopEnvironment && idle.runReason == nil,
                      "an idle program can do everything except stop")
            let blocked = make("b", shared, [snap(shared, "a", "사진 뷰어")])
            try check(!blocked.canRun && blocked.runReason == "같은 Wine 환경에서 ‘사진 뷰어’ 실행 중", "run is blocked by a session in the same Wine environment, with the reason")
            try check(blocked.canStopEnvironment && blocked.environmentSession == "사진 뷰어" && !blocked.ownSession, "the environment can be stopped from another program's row")
            try check(!blocked.canToggleRetina && blocked.retinaReason == ProgramAvailability.retinaBusyReason && ProgramAvailability.retinaBusyReason == "이 환경의 프로그램이 모두 끝나면 바꿀 수 있습니다",
                      "Retina is blocked while the environment is in use")
            try check(blocked.canRename && blocked.canRemove && !blocked.canDelete && blocked.deleteReason?.contains("사진 뷰어") == true, "another program's session blocks delete but not rename or remove")
            try check(blocked.canRunTool && blocked.canToggleScaled, "a tool can join a running environment and the per-program scale stays available")
            try check(make("b", other, [snap(shared, "a", "사진 뷰어")]).canRun, "a session in another Wine environment does not block")
            let running = make("a", shared, [snap(shared, "a", "사진 뷰어")])
            try check(!running.canRun && running.runReason == "이미 실행 중입니다" && running.ownSession && !running.canRename && !running.canRemove && !running.canDelete,
                      "a running program cannot be renamed, removed or deleted")
            try check(!make("a", shared, [snap(shared, "a", "사진 뷰어", stopping: true)]).canStopEnvironment
                      && !make("a", shared, [snap(shared, "a", "사진 뷰어", stopping: true)]).canRunTool, "a stopping environment is not stopped again and takes no tool")
            try check(!make("a", own, [snap(own, nil, "설치.exe")]).canRun && make("a", own, [snap(shared, nil, "설치.exe")]).canRun, "an installer without a row blocks only its own environment")
            for (label, state) in [("a task", make("a", shared, task: "프로그램 삭제")), ("an update", make("a", shared, updating: true))] {
                try check(!state.canRun && !state.canRename && !state.canRemove && !state.canDelete && !state.canToggleRetina && !state.canToggleScaled && !state.canRunTool, "\(label) locks the program")
            }
            try check(make("a", shared, task: "프로그램 삭제").runReason?.contains("프로그램 삭제") == true, "the busy task is named in the reason")
            let cleaning = make("a", shared, maintenance: true)
            try check(!cleaning.canRun && cleaning.canRename && !cleaning.canRunTool, "the startup cleanup stops runs (and a tool that would start a session) only")
            try check(make("a", shared, [snap(shared, "z", "x")], maintenance: true).canRunTool, "joining a running session is fine during the cleanup")
            try check(!make("a", nil).canRun && !make("a", nil).canToggleRetina && !make("a", nil).canRunTool, "a program whose environment cannot be found cannot run")

            // Row status: one badge, or who holds the shared environment.
            try check(RowStatus.make(launcherID: "a", prefix: shared, sessions: [], failed: false) == RowStatus(badge: nil, sharedWith: nil), "an idle row shows nothing")
            try check(RowStatus.make(launcherID: "a", prefix: shared, sessions: [snap(shared, "a", "A")], failed: true).badge == .running, "the program that started the session shows 실행 중 (not the old error)")
            try check(RowStatus.make(launcherID: "a", prefix: shared, sessions: [snap(shared, "a", "A", preparing: true)], failed: false).badge == .preparing
                      && RowStatus.make(launcherID: "a", prefix: shared, sessions: [snap(shared, "a", "A", stopping: true, preparing: true)], failed: false).badge == .stopping, "준비 중 and 종료 중 (stopping wins)")
            let sharing = RowStatus.make(launcherID: "b", prefix: shared, sessions: [snap(shared, "a", "A")], failed: true)
            try check(sharing.badge == nil && sharing.sharedWith == "A" && RowStatus.sharedText("A") == "같은 Wine 환경에서 ‘A’ 실행 중", "a row sharing the environment shows the secondary line, no badge")
            try check(RowStatus.make(launcherID: "b", prefix: shared, sessions: [snap(other, "a", "A")], failed: true).badge == .failed, "a failed row shows 실행 오류")
            try check(RowStatus.badgeText(.failed) == "실행 오류" && !RowStatus.help(.running, time: nil).isEmpty && RowStatus.help(.failed, time: "11:18").contains("11:18"), "plain badge text, precise help text")
            try check(UnregisteredSessions.filter([snap(shared, "a", "A"), snap(other, nil, "설치.exe"), snap(own, "gone", "도구.exe")], registered: ["a"]).map(\.title) == ["도구.exe", "설치.exe"],
                      "sessions without a row (no ID, or an unknown ID) are listed on their own")

            // Results inbox.
            var results: [ResultItem] = []
            let manifest = try JSONDecoder().decode(UpdateManifest.self, from: Data(#"{"schema":1,"bundleID":"x","version":"9.9.9","build":99,"minimumSystem":"27.0","releaseURL":"https://example.invalid/r","dmg":{"name":"a.dmg","size":1,"sha256":"00"},"deltas":[],"entries":[]}"#.utf8))
            let failure = ResultItem(date: Date(), kind: .launchFailure(program: "문서 변환기", launcherID: "a", environment: "공용 Wine 환경", logs: [], detail: "코드 1"))
            let again = ResultItem(date: Date(), kind: .launchFailure(program: "문서 변환기", launcherID: "a", environment: "공용 Wine 환경", logs: [], detail: "코드 2"))
            let candidate = InstalledCandidate(exe: URL(fileURLWithPath: "/nonexistent/app.exe"), title: "앱", shortcut: true)
            let install = ResultItem(date: Date(), kind: .installFinished(installer: "설치.exe", environment: "공용 Wine 환경", environmentName: nil, candidates: [candidate]))
            let update = ResultItem(date: Date(), kind: .updateAvailable(manifest))
            try check(ResultsInbox.add(failure, to: &results) && ResultsInbox.add(install, to: &results) && ResultsInbox.add(update, to: &results) && results.count == 3, "results are added")
            try check(ResultsInbox.add(again, to: &results) && results.count == 3 && results[0].id == again.id, "the same failure replaces the older one in place")
            try check(!ResultsInbox.add(ResultItem(date: Date(), kind: .updateAvailable(manifest)), to: &results) && results.count == 3, "an update already listed for that build is not added twice")
            let notice = ResultItem(date: Date(), kind: .notice(title: "알림", text: "내용"))
            try check(ResultsInbox.add(notice, to: &results) && results.count == 4 && Set(results.map(\.key)).count == 4, "different events have different keys")
            ResultsInbox.remove(install.id, from: &results)
            try check(results.count == 3 && !results.contains { $0.id == install.id }, "a result is removed by its ID")
            var many: [ResultItem] = []
            for n in 0..<(ResultsInbox.limit + 5) { ResultsInbox.add(ResultItem(date: Date(), kind: .notice(title: "n\(n)", text: "")), to: &many) }
            try check(many.count == ResultsInbox.limit && many.first?.key == "notice:n5", "the inbox keeps the newest results only")
            try check(!ResultsInbox.shouldStore(windowVisible: true, appActive: true) && ResultsInbox.shouldStore(windowVisible: false, appActive: true)
                      && ResultsInbox.shouldStore(windowVisible: true, appActive: false), "alerts show only with a visible window in the active app, otherwise results are stored")
            let real = URL(fileURLWithPath: NSTemporaryDirectory())
            try check(ResultsInbox.remainingCandidates([candidate, InstalledCandidate(exe: real, title: "있음", shortcut: false)], exists: { FileManager.default.fileExists(atPath: $0.path) }).map(\.title) == ["있음"],
                      "candidates whose EXE vanished are dropped")

            // Quit summary.
            let quit = QuitSummary.text(sessions: [snap(own, "x", "Sample Game", stopping: true), snap(shared, "a", "사진 뷰어"), snap(other, "c", "회계 도구", preparing: true)],
                                        place: { $0 == shared ? "공용 Wine 환경" : $0 == other ? "전용 Wine 환경 ‘account’" : "‘Sample Game’ 전용 Wine 환경" }, migrating: true)
            try check(quit.contains("공용 Wine 환경 — 사진 뷰어 (실행 중)") && quit.contains("전용 Wine 환경 ‘account’ — 회계 도구 (준비 중)") && quit.contains("‘Sample Game’ 전용 Wine 환경 — Sample Game (종료 중)"), "the quit text lists each environment with its program and state")
            try check(quit.contains("업데이트 전 상태로 복원") && !QuitSummary.text(sessions: [snap(shared, "a", "A")], place: { _ in "공용 Wine 환경" }, migrating: false).contains("복원")
                      && QuitSummary.title == "실행 중인 프로그램을 모두 종료하고 Alchemac을 종료할까요?" && QuitSummary.confirmButton == "모두 종료하고 Alchemac 종료", "the environment-update warning appears only while one is running")
        }

        // UI 2-B: dropped files, update status, environment rows.
        do {
            let none: (URL) -> Bool = { _ in false }
            let exe = URL(fileURLWithPath: "/tmp/Setup.EXE")
            try check(DropInput.classify(urls: [exe], isDirectory: none, busy: nil) == .exe(exe), "one local EXE is accepted (any letter case)")
            func reason(_ input: DropInput) -> String { if case .rejected(let text) = input { return text }; return "" }
            try check(reason(DropInput.classify(urls: [exe, exe], isDirectory: none, busy: nil)) == "파일을 한 번에 하나씩 놓아 주세요.", "several files are refused")
            try check(reason(DropInput.classify(urls: [URL(fileURLWithPath: "/tmp/dir")], isDirectory: { _ in true }, busy: nil)) == "폴더 안에서 등록할 .exe 파일을 놓아 주세요.", "a folder is refused")
            try check(reason(DropInput.classify(urls: [URL(fileURLWithPath: "/tmp/a.lnk")], isDirectory: none, busy: nil)).contains(".lnk"), "a shortcut is refused")
            try check(reason(DropInput.classify(urls: [URL(fileURLWithPath: "/tmp/a.MSI")], isDirectory: none, busy: nil)).contains(".msi"), "an MSI package is refused")
            try check(reason(DropInput.classify(urls: [URL(fileURLWithPath: "/tmp/a.txt")], isDirectory: none, busy: nil)) == "Windows 실행 파일(.exe)만 놓을 수 있습니다.", "other files are refused")
            try check(reason(DropInput.classify(urls: [], isDirectory: none, busy: nil)) == "Windows 실행 파일(.exe)만 놓을 수 있습니다.", "nothing usable is refused")
            try check(reason(DropInput.classify(urls: [URL(string: "https://example.com/a.exe")!], isDirectory: none, busy: nil)) == "Windows 실행 파일(.exe)만 놓을 수 있습니다.", "a non-file URL is refused")
            try check(DropInput.classify(urls: [exe], isDirectory: none, busy: "프로그램 등록") == .rejected("프로그램 등록 중입니다. 끝난 뒤 다시 놓아 주세요."), "the library lock refuses a drop and names the task")
            try check(DropInput.classify(urls: [exe, exe], isDirectory: none, busy: "업데이트") == .rejected("업데이트 중입니다. 끝난 뒤 다시 놓아 주세요."), "the lock is reported before anything else")
            try check(DropInput.choiceTitle("a.exe") == "‘a.exe’를 어떻게 할까요?" && DropInput.overlayTitle("a.exe").contains("설치 또는 등록") && DropInput.overlayNote.contains("바로 실행하지 않습니다"), "drop wording")

            let day = Date()
            try check(UpdateCheckStatus(date: day, outcome: .upToDate).line(when: "오늘 오전 11:00") == "오늘 오전 11:00 확인: 최신 버전입니다.", "status: up to date")
            try check(UpdateCheckStatus(date: day, outcome: .available("0.5.20")).line(when: "오늘") == "오늘 확인: 새 버전 0.5.20이 있습니다.", "status: new version")
            try check(UpdateCheckStatus(date: day, outcome: .failed("네트워크 오류")).line(when: "오늘").hasSuffix("확인하지 못했습니다: 네트워크 오류"), "status: failure reason")
            try check(UpdateCheckStatus(date: day, outcome: .needsSystem("28")).summary.contains("macOS 28") && UpdateCheckStatus(date: day, outcome: .unknown).line(when: "어제") == "마지막 확인: 어제", "status: system requirement and unknown result")

            try check(EnvironmentRow(programs: 0, running: false, shared: true).deleteReason(lock: nil) == "공용 Wine 환경은 삭제할 수 없습니다", "the shared environment cannot be deleted")
            try check(EnvironmentRow(programs: 0, running: false, shared: false).deleteReason(lock: nil) == nil, "an unused dedicated environment can be deleted")
            try check(EnvironmentRow(programs: 2, running: false, shared: false).deleteReason(lock: nil)?.contains("2개") == true, "an environment in use by programs cannot be deleted")
            try check(EnvironmentRow(programs: 0, running: true, shared: false).deleteReason(lock: nil)?.contains("실행 중") == true, "a running environment cannot be deleted")
            try check(EnvironmentRow(programs: 0, running: false, shared: false).deleteReason(lock: "업데이트를 준비하는 중입니다") == "업데이트를 준비하는 중입니다" && EnvironmentRow(programs: 3, running: false, shared: false).programsText == "프로그램 3개", "the library lock disables deleting")
        }
        print("RESULT: \(passed) checks passed")
    }
}
