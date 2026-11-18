import Foundation

/// A program recipe installed separately from Alchemac, as `<name>.alchemacaddon/addon.json`.
/// It only declares what a program needs; Alchemac implements every behaviour, so an
/// add-on carries no code and cannot reach past the settings listed here.
struct Addon: Codable, Hashable, Identifiable {
    struct Detect: Codable, Hashable {
        /// The EXE file name the user selects.
        let executable: String
        /// Folders or files that must sit next to it.
        let siblings: [String]?
    }
    struct Import: Codable, Hashable {
        /// Names left out of the private copy: `name`, `*.ext` or `.*` for hidden files.
        let exclude: [String]?
    }
    struct Environment: Codable, Hashable {
        enum Mode: String, Codable { case `private`, shared }
        let mode: Mode?
    }
    struct Launch: Codable, Hashable {
        /// Only names in `Addon.allowedEnvironment` are accepted.
        let env: [String: String]?
        /// Select an English keyboard layout before starting the program.
        let englishInput: Bool?
    }

    let schema: Int
    let id: String
    let name: String
    let version: String
    let summary: String?
    let detect: Detect
    let `import`: Import?
    let environment: Environment?
    let launch: Launch?

    var mode: Environment.Mode { environment?.mode ?? .private }
    var exclusions: [String] { `import`?.exclude ?? [] }
    var launchEnvironment: [String: String] { launch?.env ?? [:] }
    var englishInput: Bool { launch?.englishInput ?? false }

    /// Program settings standalone-run passes on to Wine. Paths, prefixes and logging stay Alchemac's.
    static let allowedEnvironment: Set<String> = [
        "WINEDLLOVERRIDES", "DOTNET_BUNDLE_EXTRACT_BASE_DIR", "DXMT_CONFIG", "MTLD3D_CONFIG", "MTL_HUD_ENABLED",
        "HADRON_VSYNC", "HADRON_D3D9", "HADRON_D3D12", "HADRON_HARDWARE_TSO", "HADRON_LARGE_ADDRESS_AWARE",
        "HADRON_MEM_LIMIT_GB", "HADRON_PRECISE_SCROLLING",
    ]

    private static func plainName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 120 && name != "." && name != ".."
            && !name.contains(where: { "/\\\"".contains($0) }) && !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression)?.lowerBound == value.startIndex
            && value.range(of: pattern, options: .regularExpression)?.upperBound == value.endIndex
    }

    /// Whether a setting value is safe to hand to the runtime. Some values reach shell arithmetic (`$(( ... ))`
    /// in the watchdog, where bash evaluates `a[$(cmd)]`) or config parsers, so each key has a strict shape.
    static func allowedValue(_ key: String, _ value: String) -> Bool {
        switch key {
        case "HADRON_MEM_LIMIT_GB": return matches(value, "[1-9][0-9]{0,2}")
        case "HADRON_VSYNC": return ["game", "on", "off"].contains(value)
        case "HADRON_D3D9": return ["mtld3d", "wined3d"].contains(value)
        case "HADRON_D3D12": return ["auto", "vkd3d", "wine"].contains(value)
        case "HADRON_HARDWARE_TSO", "HADRON_LARGE_ADDRESS_AWARE", "HADRON_PRECISE_SCROLLING", "MTL_HUD_ENABLED": return value == "0" || value == "1"
        case "WINEDLLOVERRIDES": return matches(value, "[A-Za-z0-9_.,;=*+-]{1,512}")
        case "DXMT_CONFIG", "MTLD3D_CONFIG":
            // key=value pairs; logging and debug dump options would write to paths the add-on chooses.
            return value.split(separator: ";", omittingEmptySubsequences: true).allSatisfy { entry in
                let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 2, matches(parts[0], "[A-Za-z0-9_.]+"), matches(parts[1], "[A-Za-z0-9_.,:+-]*") else { return false }
                let lower = parts[0].lowercased()
                return !lower.hasPrefix("debug.") && !lower.hasPrefix("log.")
            }
        case "DOTNET_BUNDLE_EXTRACT_BASE_DIR":
            guard value.count <= 200, value.lowercased().hasPrefix("c:\\"), matches(String(value.dropFirst(3)), "[A-Za-z0-9_ .\\\\-]*") else { return false }
            return !value.dropFirst(3).split(separator: "\\", omittingEmptySubsequences: false).contains("..")
        default: return false
        }
    }

    func validate() throws {
        func fail(_ reason: String) -> AlchemacError { .message("사용할 수 없는 애드온입니다(‘\(name)’): \(reason)") }
        guard schema == 1 else { throw AlchemacError.message("이 애드온 형식을 지원하지 않습니다. 최신 Alchemac에서 다시 시도해 주세요.") }
        guard id.range(of: "^[a-z0-9][a-z0-9-]{0,31}$", options: .regularExpression) != nil else { throw fail("ID가 올바르지 않습니다.") }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, name.count <= 80, (summary?.count ?? 0) <= 400 else { throw fail("이름이나 설명이 올바르지 않습니다.") }
        guard version.range(of: #"^[0-9]+(\.[0-9]+){0,3}$"#, options: .regularExpression) != nil else { throw fail("버전이 올바르지 않습니다.") }
        guard Self.plainName(detect.executable), detect.executable.lowercased().hasSuffix(".exe"),
              (detect.siblings ?? []).allSatisfy(Self.plainName), (detect.siblings ?? []).count <= 16 else { throw fail("감지 규칙이 올바르지 않습니다.") }
        guard exclusions.count <= 64, exclusions.allSatisfy({ $0 == ".*" || Self.plainName($0) }) else { throw fail("제외 목록이 올바르지 않습니다.") }
        for (key, value) in launchEnvironment {
            guard Self.allowedEnvironment.contains(key) else { throw fail("허용되지 않는 환경 변수 \(key)입니다.") }
            guard Self.allowedValue(key, value), value.count <= 512, !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { throw fail("\(key) 값이 올바르지 않습니다.") }
        }
    }

    /// Whether the selected EXE is the program this add-on describes.
    func matches(_ exe: URL) -> Bool {
        guard exe.lastPathComponent.lowercased() == detect.executable.lowercased() else { return false }
        let folder = exe.deletingLastPathComponent()
        return (detect.siblings ?? []).allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    /// Whether a file or folder stays out of the private copy.
    func excludes(_ item: URL) -> Bool {
        let name = item.lastPathComponent.lowercased()
        return exclusions.contains { pattern in
            let rule = pattern.lowercased()
            if rule == ".*" { return name.hasPrefix(".") }
            if rule.hasPrefix("*.") { return item.pathExtension.lowercased() == String(rule.dropFirst(2)) }
            return name == rule
        }
    }
}

extension LauncherStore {
    var addonsFolder: URL { root.appendingPathComponent("addons", isDirectory: true) }

    /// Installed add-ons that still validate, by name.
    func installedAddons() -> [Addon] {
        let names = (try? fm.contentsOfDirectory(atPath: addonsFolder.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.compactMap { name in
            let file = addonsFolder.appendingPathComponent(name).appendingPathComponent("addon.json")
            guard (try? requireLocal(file)) != nil, let data = try? Data(contentsOf: file),
                  let addon = try? JSONDecoder().decode(Addon.self, from: data), addon.id == name, (try? addon.validate()) != nil else { return nil }
            return addon
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func addon(_ id: String) -> Addon? { installedAddons().first { $0.id == id } }
    func matchingAddon(_ exe: URL) -> Addon? { installedAddons().first { $0.matches(exe) } }

    /// Reads and validates an add-on from a `.alchemacaddon` folder or its `addon.json`, without installing it.
    func readAddon(from source: URL) throws -> (addon: Addon, bundle: URL) {
        let bundle = source.lastPathComponent.lowercased() == "addon.json" ? source.deletingLastPathComponent() : source
        let manifest = bundle.appendingPathComponent("addon.json")
        guard let values = try? manifest.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else {
            throw AlchemacError.message("애드온 폴더(.alchemacaddon) 안에 addon.json이 없습니다.")
        }
        let addon: Addon
        do { addon = try JSONDecoder().decode(Addon.self, from: Data(contentsOf: manifest)) }
        catch { throw AlchemacError.message("애드온 설정 파일을 읽지 못했습니다. 애드온을 다시 받아 설치해 주세요.") }
        try addon.validate()
        return (addon, bundle)
    }

    /// Whether an add-on with this id is already installed (valid or not).
    func addonExists(_ id: String) -> Bool { fm.fileExists(atPath: addonsFolder.appendingPathComponent(id).path) }

    /// Installs or replaces an add-on from a `.alchemacaddon` folder or its `addon.json`.
    /// Only the manifest and a README or LICENSE are kept; nothing else in the bundle is copied.
    @discardableResult
    func installAddon(from source: URL) throws -> Addon {
        let (addon, bundle) = try readAddon(from: source)
        try fm.createDirectory(at: addonsFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try requireLocal(addonsFolder)
        let stage = addonsFolder.appendingPathComponent(".install-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        do {
            for name in ["addon.json", "README.md", "LICENSE"] {
                let file = bundle.appendingPathComponent(name)
                guard let kind = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      kind.isRegularFile == true, kind.isSymbolicLink != true else { continue }
                try fm.copyItem(at: file, to: stage.appendingPathComponent(name))
            }
            let destination = addonsFolder.appendingPathComponent(addon.id, isDirectory: true)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: stage)
            } else {
                try fm.moveItem(at: stage, to: destination)
            }
        } catch {
            try? fm.removeItem(at: stage) // Only this invocation's staging folder.
            throw error
        }
        return addon
    }

    /// The installed add-on folder, for moving it to the Trash.
    func addonFolder(_ id: String) throws -> URL {
        guard id.range(of: "^[a-z0-9][a-z0-9-]{0,31}$", options: .regularExpression) != nil else { throw AlchemacError.message("애드온 ID가 올바르지 않습니다.") }
        let folder = addonsFolder.appendingPathComponent(id, isDirectory: true)
        try requireLocal(folder)
        return folder
    }
}
