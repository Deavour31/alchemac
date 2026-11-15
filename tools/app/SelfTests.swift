import Foundation
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
        // d3d9.dll refresh of an existing prefix
        let d3dRuntime = temp.appendingPathComponent("d3d-runtime")
        for arch in ["aarch64", "i386"] {
            try fm.createDirectory(at: d3dRuntime.appendingPathComponent("dist/lib/hadron/d3d9/" + arch), withIntermediateDirectories: true)
            try Data("MZ mtld3d new \(arch)".utf8).write(to: d3dRuntime.appendingPathComponent("dist/lib/hadron/d3d9/\(arch)/d3d9.dll"))
        }
        func d3dPrefix(_ name: String, ready: Bool = true, incomplete: Bool = false, system32: String?, syswow64: String? = nil) throws -> URL {
            let prefix = temp.appendingPathComponent(name)
            for (folder, text) in [("system32", system32), ("syswow64", syswow64)] {
                let dir = prefix.appendingPathComponent("drive_c/windows/" + folder)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                if let text { try Data(text.utf8).write(to: dir.appendingPathComponent("d3d9.dll")) }
            }
            if ready { try Data("id\n".utf8).write(to: prefix.appendingPathComponent(".hadron-prefix-ready")) }
            if incomplete { try Data().write(to: prefix.appendingPathComponent(".hadron-migration-incomplete")) }
            return prefix
        }
        func d3dFile(_ prefix: URL, _ folder: String) -> String? {
            (try? String(contentsOf: prefix.appendingPathComponent("drive_c/windows/" + folder + "/d3d9.dll"), encoding: .utf8))
        }
        let d3dOld = try d3dPrefix("d3d-old", system32: "MZ mtld3d old", syswow64: "MZ mtld3d old32")
        AlchemacRuntime.refreshD3D9(prefix: d3dOld, runtime: d3dRuntime)
        try check(d3dFile(d3dOld, "system32") == "MZ mtld3d new aarch64" && d3dFile(d3dOld, "syswow64") == "MZ mtld3d new i386",
                  "d3d9 refresh replaces a differing mtld3d file")
        try check(try fm.contentsOfDirectory(atPath: d3dOld.appendingPathComponent("drive_c/windows/system32").path) == ["d3d9.dll"],
                  "d3d9 refresh leaves no temporary file")
        let d3dForeign = try d3dPrefix("d3d-foreign", system32: "MZ wine builtin", syswow64: "MZ user file")
        AlchemacRuntime.refreshD3D9(prefix: d3dForeign, runtime: d3dRuntime)
        try check(d3dFile(d3dForeign, "system32") == "MZ wine builtin" && d3dFile(d3dForeign, "syswow64") == "MZ user file",
                  "d3d9 refresh leaves a file without the mtld3d marker alone")
        let d3dEmpty = try d3dPrefix("d3d-empty", system32: nil)
        AlchemacRuntime.refreshD3D9(prefix: d3dEmpty, runtime: d3dRuntime)
        try check(d3dFile(d3dEmpty, "system32") == nil && d3dFile(d3dEmpty, "syswow64") == nil, "d3d9 refresh does not create a missing file")
        let d3dSame = try d3dPrefix("d3d-same", system32: "MZ mtld3d new aarch64")
        let d3dSameFile = d3dSame.appendingPathComponent("drive_c/windows/system32/d3d9.dll")
        let inodeBefore = try fm.attributesOfItem(atPath: d3dSameFile.path)[.systemFileNumber] as? Int
        AlchemacRuntime.refreshD3D9(prefix: d3dSame, runtime: d3dRuntime)
        try check(inodeBefore != nil && (try fm.attributesOfItem(atPath: d3dSameFile.path)[.systemFileNumber] as? Int) == inodeBefore,
                  "d3d9 refresh leaves an identical file untouched")
        let d3dBusy = try d3dPrefix("d3d-incomplete", incomplete: true, system32: "MZ mtld3d old")
        let d3dFresh = try d3dPrefix("d3d-notready", ready: false, system32: "MZ mtld3d old")
        AlchemacRuntime.refreshD3D9(prefix: d3dBusy, runtime: d3dRuntime)
        AlchemacRuntime.refreshD3D9(prefix: d3dFresh, runtime: d3dRuntime)
        try check(d3dFile(d3dBusy, "system32") == "MZ mtld3d old" && d3dFile(d3dFresh, "system32") == "MZ mtld3d old",
                  "d3d9 refresh skips an incomplete or unprepared prefix")
        print("RESULT: \(passed) checks passed")
    }
}
