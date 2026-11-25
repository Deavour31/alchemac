import Foundation
import Darwin

enum AlchemacError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum ProgramKind: String, Codable {
    /// A program installed into its Wine environment; `executable` is its C:\ path.
    case installed
    /// A copied program folder run in its Wine environment; `executable` is relative to it.
    case copied
}

struct Launcher: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    let executable: String
    var kind: ProgramKind = .copied
    /// A dedicated Wine environment under prefixes/; nil is the shared one.
    var environment: String?
    /// Have Wine scale this program as DPI-unaware, for programs that draw too small in Retina mode.
    var scaled = false
    /// "WxH" (see DisplayModeSpec): the desktop size the program sees for this session, set by editing launchers.json.
    var displayMode: String?
    /// The add-on whose recipe this program was imported and runs with.
    var addon: String?
    /// A copied program with a Wine environment of its own, inside its library folder.
    var privatePrefix = false

    func validate() throws {
        guard id.range(of: "^[a-z0-9-]{1,48}$", options: .regularExpression) != nil,
              Self.validExecutable(executable, kind: kind), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 80, environment.map(Self.validEnvironment) ?? true,
              displayMode.map({ DisplayModeSpec.parse($0) != nil }) ?? true,
              !privatePrefix || (kind == .copied && environment == nil),
              addon.map({ $0.range(of: "^[a-z0-9][a-z0-9-]{0,31}$", options: .regularExpression) != nil }) ?? true else {
            throw AlchemacError.message("프로그램 등록 정보를 읽을 수 없습니다. 보관함을 확인해 주세요.")
        }
    }

    static func validEnvironment(_ name: String) -> Bool {
        name != "shared" && name.range(of: "^[a-z0-9][a-z0-9-]{0,31}$", options: .regularExpression) != nil
    }

    static func validExecutable(_ path: String, kind: ProgramKind) -> Bool {
        guard path.count <= 240, path.lowercased().hasSuffix(".exe"),
              !path.contains("\""), !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return false }
        switch kind {
        case .installed:
            let parts = path.split(separator: "\\", omittingEmptySubsequences: false)
            return parts.count > 1 && parts[0].uppercased() == "C:" && !parts.dropFirst().contains { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("/") }
        case .copied:
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            return !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("\\") }
        }
    }
}

extension LauncherStore {
    /// Whether this EXE is a .NET Framework program and the prefix does not have Wine Mono yet,
    /// so its first start takes extra time. prefix-profile makes the same check and installs it.
    func needsWineMono(_ exe: URL, in prefix: URL) -> Bool {
        guard !fm.fileExists(atPath: prefix.appendingPathComponent("drive_c/windows/mono/mono-2.0/bin/libmono-2.0-x86_64.dll").path),
              let file = try? FileHandle(forReadingFrom: exe), let head = try? file.read(upToCount: 4096), head.count >= 0x40 else { return false }
        defer { try? file.close() }
        func u16(_ at: Int) -> Int { at + 2 <= head.count ? Int(head[at]) | Int(head[at + 1]) << 8 : 0 }
        func u32(_ at: Int) -> Int { at + 4 <= head.count ? u16(at) | u16(at + 2) << 16 : 0 }
        let pe = u32(0x3c)
        guard u16(0) == 0x5a4d, u32(pe) == 0x4550 else { return false }
        let optional = pe + 24, magic = u16(optional)
        guard magic == 0x10b || magic == 0x20b else { return false }
        return u32(optional + (magic == 0x20b ? 112 : 96) + 14 * 8) != 0
    }
}

extension Launcher {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        executable = try values.decode(String.self, forKey: .executable)
        environment = try values.decodeIfPresent(String.self, forKey: .environment)
        scaled = try values.decodeIfPresent(Bool.self, forKey: .scaled) ?? false
        let raw = try values.decodeIfPresent(String.self, forKey: .kind) ?? ProgramKind.copied.rawValue
        guard let parsed = ProgramKind(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: values, debugDescription: "unknown program kind")
        }
        kind = parsed
        displayMode = try values.decodeIfPresent(String.self, forKey: .displayMode)
        addon = try values.decodeIfPresent(String.self, forKey: .addon)
        privatePrefix = try values.decodeIfPresent(Bool.self, forKey: .privatePrefix) ?? false
    }
}

struct Registry: Codable {
    var schemaVersion = 1
    var selectedID: String?
    var launchers: [Launcher] = []

    func validate() throws {
        guard schemaVersion == 1, Set(launchers.map(\.id)).count == launchers.count,
              selectedID == nil || launchers.contains(where: { $0.id == selectedID }) else {
            throw AlchemacError.message("지원하지 않거나 손상된 보관함입니다. 기존 데이터는 보존됩니다.")
        }
        try launchers.forEach { try $0.validate() }
    }
}

// Root/FileManager are immutable; lockFD changes only in init/deinit. Registry
// commits run on the main actor; the import worker only creates a unique stage.
final class LauncherStore: @unchecked Sendable {
    let root: URL
    private var lockFD: Int32 = -1
    var registryURL: URL { root.appendingPathComponent("launchers.json") }
    var support: URL { root.appendingPathComponent("runtime.noindex", isDirectory: true) }
    let fm = FileManager.default

    /// Session logs, one folder per program.
    let logs: URL

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Alchemac"),
         logs: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Alchemac")) throws {
        self.root = root.standardizedFileURL
        self.logs = logs.standardizedFileURL
        try fm.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try requireLocal(self.root)
        lockFD = Darwin.open(self.root.appendingPathComponent(".app.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if lockFD >= 0 { Darwin.close(lockFD); lockFD = -1 }
            throw AlchemacError.message("Alchemac이 이미 열려 있습니다. Dock에서 기존 창을 열어 주세요.")
        }
    }

    deinit { if lockFD >= 0 { flock(lockFD, LOCK_UN); Darwin.close(lockFD) } }

    func requireLocal(_ url: URL) throws {
        let normalized = url.standardizedFileURL
        guard normalized.path == normalized.resolvingSymlinksInPath().path else {
            throw AlchemacError.message("보관함에 외부 폴더로 연결된 링크가 있습니다. 이 경로에서는 실행하지 않습니다.")
        }
    }

    /// Whether a path, existing or not yet created, lies inside the library. Links are resolved
    /// on the part that exists, since /tmp and /private/tmp name the same folder.
    func contains(_ url: URL) -> Bool {
        func resolved(_ url: URL) -> [String] {
            var existing = url.standardizedFileURL, rest: [String] = []
            while !fm.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
                rest.insert(existing.lastPathComponent, at: 0); existing.deleteLastPathComponent()
            }
            return existing.resolvingSymlinksInPath().pathComponents + rest
        }
        let target = resolved(url), base = resolved(root)
        return target.starts(with: base) && target.count > base.count && !target.contains("..")
    }

    func directory(_ launcher: Launcher) throws -> URL {
        try launcher.validate()
        let url = root.appendingPathComponent("launchers/\(launcher.id)", isDirectory: true)
        try requireLocal(url)
        return url
    }

    /// One Wine prefix for every generic program, as most Wine front ends do by default.
    var sharedPrefix: URL { root.appendingPathComponent("prefixes/shared", isDirectory: true) }

    /// The shared prefix, or a dedicated one beside it.
    func prefix(environment: String?) -> URL {
        environment.map { root.appendingPathComponent("prefixes/" + $0, isDirectory: true) } ?? sharedPrefix
    }

    /// Dedicated environments that exist, by name.
    func environments() -> [String] {
        let names = (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent("prefixes").path)) ?? []
        return names.filter { name in
            var directory: ObjCBool = false
            return Launcher.validEnvironment(name) && fm.fileExists(atPath: prefix(environment: name).path, isDirectory: &directory) && directory.boolValue
        }.sorted()
    }

    /// An unused environment name derived from a file name, e.g. "Origin Setup.exe" -> "origin-setup".
    func newEnvironmentName(for file: URL) -> String {
        let words = file.deletingPathExtension().lastPathComponent.lowercased()
            .split { !("a"..."z").contains(String($0)) && !("0"..."9").contains(String($0)) }
        var base = String(words.joined(separator: "-").prefix(24))
        if base.isEmpty || base == "shared" || !Launcher.validEnvironment(base) { base = "env" }
        let taken = Set(environments())
        var name = base, number = 2
        while taken.contains(name) || fm.fileExists(atPath: prefix(environment: name).path) { name = "\(base)-\(number)"; number += 1 }
        return name
    }

    /// The folder the program starts in: the private copy, or its install folder.
    func game(_ launcher: Launcher) throws -> URL {
        let url = launcher.kind == .installed
            ? try executable(launcher).deletingLastPathComponent()
            : try directory(launcher).appendingPathComponent("game", isDirectory: true)
        try requireLocal(url)
        return url
    }

    func prefix(_ launcher: Launcher) throws -> URL {
        let url = launcher.privatePrefix
            ? try directory(launcher).appendingPathComponent("prefix", isDirectory: true)
            : prefix(environment: launcher.environment)
        try requireLocal(url)
        return url
    }

    func executable(_ launcher: Launcher) throws -> URL {
        try launcher.validate()
        let url: URL
        switch launcher.kind {
        case .copied:
            url = try directory(launcher).appendingPathComponent("game/" + launcher.executable)
        case .installed:
            let relative = launcher.executable.split(separator: "\\").dropFirst().joined(separator: "/")
            url = try prefix(launcher).appendingPathComponent("drive_c/" + relative)
        }
        try requireLocal(url)
        return url
    }

    /// The Windows path the program is started with inside its prefix.
    func windowsExecutable(_ launcher: Launcher) throws -> String {
        launcher.kind == .installed ? launcher.executable : AlchemacRuntime.windows(try executable(launcher))
    }

    var backupURL: URL { root.appendingPathComponent("launchers.json.bak") }
    /// What `read()` did to keep the app usable (a backup used, a broken file set aside), for the user to be told once.
    private(set) var recoveryNotice: String?

    /// A launchers.json entry that may not decode or validate; one bad entry must not hide the others.
    private struct Lossy: Decodable {
        let launcher: Launcher?
        init(from decoder: Decoder) throws { launcher = try? Launcher(from: decoder) }
    }
    private struct RawRegistry: Decodable {
        let schemaVersion: Int
        let selectedID: String?
        let launchers: [Lossy]
    }

    /// A registry file that decodes and fully validates, else nil. Never throws.
    private func validRegistry(at url: URL) -> (Registry, Data)? {
        guard (try? requireLocal(url)) != nil, let data = try? Data(contentsOf: url),
              let registry = try? JSONDecoder().decode(Registry.self, from: data), (try? registry.validate()) != nil else { return nil }
        return (registry, data)
    }

    /// A new name beside launchers.json for a file that is set aside, never an existing one.
    private func preservedURL(_ kind: String) -> URL {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        var url = root.appendingPathComponent("launchers.\(kind)-\(stamp).json"), number = 2
        while fm.fileExists(atPath: url.path) { url = root.appendingPathComponent("launchers.\(kind)-\(stamp)-\(number).json"); number += 1 }
        return url
    }

    /// Reads the registry. A damaged file is set aside rather than overwritten and the last good backup is used;
    /// launchers that no longer validate are left out of the list and the original file is kept. A file from a
    /// newer Alchemac is the one case that throws, so that nothing is changed.
    func read() throws -> Registry {
        recoveryNotice = nil
        guard fm.fileExists(atPath: registryURL.path) else {
            if let (backup, _) = validRegistry(at: backupURL) {
                recoveryNotice = "프로그램 목록 파일(launchers.json)이 없어 마지막 백업(launchers.json.bak)으로 복구했습니다."
                return backup
            }
            return Registry()
        }
        try requireLocal(registryURL)
        let data = try Data(contentsOf: registryURL)
        guard let raw = try? JSONDecoder().decode(RawRegistry.self, from: data), raw.schemaVersion >= 1 else {
            let kept = preservedURL("corrupt")
            try fm.moveItem(at: registryURL, to: kept)
            let note = "프로그램 목록 파일을 읽을 수 없어 ‘\(kept.lastPathComponent)’으로 따로 보관했습니다."
            if let (backup, _) = validRegistry(at: backupURL) {
                recoveryNotice = note + " 마지막 백업(launchers.json.bak)으로 목록을 복구했습니다."
                return backup
            }
            recoveryNotice = note + " 백업이 없어 빈 목록으로 시작합니다."
            return Registry()
        }
        guard raw.schemaVersion == 1 else {
            throw AlchemacError.message("프로그램 목록이 더 새로운 버전의 Alchemac에서 만들어졌습니다. 최신 Alchemac을 설치해 주세요. 기존 데이터는 그대로 보존됩니다.")
        }
        var launchers: [Launcher] = [], seen = Set<String>(), dropped = 0
        for entry in raw.launchers {
            guard let launcher = entry.launcher, (try? launcher.validate()) != nil, seen.insert(launcher.id).inserted else { dropped += 1; continue }
            launchers.append(launcher)
        }
        var value = Registry(schemaVersion: 1, selectedID: raw.selectedID, launchers: launchers)
        if let selected = value.selectedID, !seen.contains(selected) { value.selectedID = launchers.first?.id }
        if dropped > 0 {
            // The file is only rewritten by a later save, but keep the original before anything can replace it.
            let kept = preservedURL("invalid")
            try data.write(to: kept, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: kept.path)
            recoveryNotice = "읽을 수 없는 프로그램 \(dropped)개를 목록에서 뺐습니다. 원래 파일은 ‘\(kept.lastPathComponent)’에 보관했습니다."
        }
        try value.validate()
        return value
    }

    func write(_ registry: Registry) throws {
        try registry.validate()
        try requireLocal(registryURL)
        // Keep the last file that was fully valid; a file that does not validate never replaces the backup.
        if let (_, current) = validRegistry(at: registryURL), (try? Data(contentsOf: backupURL)) != current, (try? requireLocal(backupURL)) != nil {
            try? current.write(to: backupURL, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(registry).write(to: registryURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: registryURL.path)
    }

    /// Registers any Windows program. An EXE an installed add-on describes is copied and
    /// set up by its recipe; an EXE already inside a Wine environment is run where it was
    /// installed; any other EXE's folder is copied, read-only, and runs in `environment`.
    func importProgram(from exe: URL, environment: String? = nil) throws -> Launcher {
        let file = exe.standardizedFileURL
        guard file.pathExtension.lowercased() == "exe" else { throw AlchemacError.message("Windows 실행 파일(.exe)을 선택해 주세요.") }
        let id = "app-" + UUID().uuidString.prefix(8).lowercased()
        if let addon = matchingAddon(file) {
            let launcher = Launcher(id: id, name: addon.name, executable: file.lastPathComponent, kind: .copied,
                                    environment: nil, addon: addon.id, privatePrefix: addon.mode == .private)
            try launcher.validate()
            try copyFolder(file.deletingLastPathComponent(), into: launcher, excluding: addon.excludes)
            return launcher
        }
        let name = String(file.deletingPathExtension().lastPathComponent.prefix(80))
        if let location = installedLocation(of: file) {
            let launcher = Launcher(id: id, name: name, executable: location.path, kind: .installed, environment: location.environment)
            try launcher.validate()
            guard fm.fileExists(atPath: try executable(launcher).path) else {
                throw AlchemacError.message("Wine 환경 안의 실행 파일을 열 수 없습니다. 링크된 폴더가 아닌 Program Files 아래에서 선택해 주세요.")
            }
            return launcher
        }
        let launcher = Launcher(id: id, name: name, executable: file.lastPathComponent, kind: .copied, environment: environment)
        try launcher.validate()
        try copyFolder(file.deletingLastPathComponent(), into: launcher) { $0.lastPathComponent.hasPrefix(".") }
        return launcher
    }

    /// What `importProgram` would copy for this EXE: the folder and the rule for names left out, or nil when the EXE
    /// already lives inside a Wine environment and nothing is copied.
    struct CopyPlan {
        let folder: URL
        let addon: Addon?
        func excludes(_ item: URL) -> Bool { addon.map { $0.excludes(item) } ?? item.lastPathComponent.hasPrefix(".") }
    }
    func copyPlan(for exe: URL) -> CopyPlan? {
        let file = exe.standardizedFileURL
        if let addon = matchingAddon(file) { return CopyPlan(folder: file.deletingLastPathComponent(), addon: addon) }
        if installedLocation(of: file) != nil { return nil }
        return CopyPlan(folder: file.deletingLastPathComponent(), addon: nil)
    }

    struct FolderSurvey: Equatable {
        var files = 0
        var bytes: Int64 = 0
        /// The walk stopped early, so both numbers are lower bounds.
        var capped = false
    }
    /// Counts what a copy would take. Stops after `maxEntries` items or `maxSeconds`; meant for a background queue.
    static func survey(_ folder: URL, excluding: (URL) -> Bool, maxEntries: Int = 100_000, maxSeconds: TimeInterval = 4) -> FolderSurvey {
        var result = FolderSurvey()
        let start = Date(), keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return result }
        var seen = 0
        for case let item as URL in items {
            seen += 1
            if seen > maxEntries || (seen % 256 == 0 && Date().timeIntervalSince(start) > maxSeconds) { result.capped = true; break }
            guard let properties = try? item.resourceValues(forKeys: Set(keys)) else { continue }
            if excluding(item) {
                if properties.isDirectory == true { items.skipDescendants() }
                continue
            }
            if properties.isDirectory == true || properties.isSymbolicLink == true { continue }
            result.files += 1; result.bytes += Int64(properties.fileSize ?? 0)
        }
        return result
    }

    /// A warning when the folder to copy is the user's Downloads, Desktop, Documents or home folder itself.
    static func broadFolderWarning(_ folder: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path, base = home.standardizedFileURL.resolvingSymlinksInPath().path
        let names = [base: "홈", base + "/Downloads": "다운로드", base + "/Desktop": "데스크탑", base + "/Documents": "문서"]
        guard let name = names[path] else { return nil }
        return "주의: 선택한 파일이 ‘\(name)’ 폴더 바로 아래에 있어 그 폴더 전체가 복사됩니다. 관련 없는 파일이 많다면 취소하고, 프로그램 전용 폴더로 옮긴 뒤 다시 선택해 주세요."
    }

    /// The Wine environment and C:\ path of a file inside one of their C drives, or nil for any other file.
    func installedLocation(of file: URL) -> (environment: String?, path: String)? {
        let resolved = file.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        for environment in [nil] + environments().map(Optional.some) {
            let driveC = prefix(environment: environment).appendingPathComponent("drive_c", isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath().pathComponents
            if resolved.starts(with: driveC), resolved.count > driveC.count {
                return (environment, (["C:"] + resolved.dropFirst(driveC.count)).joined(separator: "\\"))
            }
        }
        return nil
    }

    private func copyFolder(_ folder: URL, into launcher: Launcher, excluding: (URL) -> Bool) throws {
        let source = folder.standardizedFileURL
        try requireLocal(source)
        let destination = try directory(launcher)
        guard !fm.fileExists(atPath: destination.path) else { throw AlchemacError.message("동일한 보관 경로가 이미 있습니다. 다시 시도해 주세요.") }
        let stage = root.appendingPathComponent(".import-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage.appendingPathComponent("game"), withIntermediateDirectories: true)
        do {
            var enumerationError: Error?
            guard let items = fm.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [], errorHandler: { _, error in enumerationError = error; return false }) else {
                throw AlchemacError.message("프로그램 폴더를 읽을 수 없습니다.")
            }
            for case let item as URL in items {
                let properties = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if excluding(item) {
                    if properties.isDirectory == true { items.skipDescendants() }
                    continue
                }
                guard properties.isSymbolicLink != true else { throw AlchemacError.message("프로그램 폴더 안의 링크는 가져오지 않습니다. 압축을 해제한 원본 폴더를 선택해 주세요.") }
                // APFS may return decomposed Unicode. Component counts remain
                // stable when source and enumerated strings normalize differently.
                // Standardize both sides: the enumerator can return /private/tmp
                // while Foundation has shortened the base URL to /tmp.
                let components = item.standardizedFileURL.pathComponents
                let base = source.standardizedFileURL.pathComponents
                guard components.starts(with: base), components.count > base.count else {
                    throw AlchemacError.message("프로그램 폴더 바깥의 경로를 발견했습니다.")
                }
                let relative = components.dropFirst(base.count).joined(separator: "/")
                let target = stage.appendingPathComponent("game/" + relative)
                if properties.isDirectory == true {
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                } else {
                    try fm.copyItem(at: item, to: target)
                }
            }
            if let enumerationError { throw enumerationError }
            guard fm.fileExists(atPath: stage.appendingPathComponent("game/" + launcher.executable).path) else {
                throw AlchemacError.message("실행 파일을 복사하지 못했습니다.")
            }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: stage, to: destination)
        } catch {
            try? fm.removeItem(at: stage) // Only this invocation's disposable import stage.
            throw error
        }
    }
}

/// A program an installer left in a Wine environment, offered for registration.
struct InstalledCandidate: Hashable {
    let exe: URL
    let title: String
    let shortcut: Bool
}

extension LauncherStore {
    private func driveC(_ environment: String?) -> URL { prefix(environment: environment).appendingPathComponent("drive_c", isDirectory: true) }

    private func folders(_ relative: [String], in environment: String?) -> [URL] {
        let driveC = driveC(environment)
        return relative.flatMap { pattern -> [URL] in
            guard pattern.contains("*") else { return [driveC.appendingPathComponent(pattern, isDirectory: true)] }
            // Only the users/* level is a wildcard.
            let parts = pattern.components(separatedBy: "/*/")
            let users = driveC.appendingPathComponent(parts[0], isDirectory: true)
            let names = (try? fm.contentsOfDirectory(atPath: users.path)) ?? []
            return names.map { users.appendingPathComponent($0).appendingPathComponent(parts[1], isDirectory: true) }
        }
    }

    /// Files with one of `extensions` below `roots`, keyed by their path under drive_c.
    /// The enumerator does not descend into linked folders, so host folders are not scanned.
    private func files(_ extensions: Set<String>, under roots: [URL], in environment: String?) -> [String: URL] {
        let base = driveC(environment).standardizedFileURL.resolvingSymlinksInPath().pathComponents
        var found: [String: URL] = [:]
        for root in roots where fm.fileExists(atPath: root.path) {
            guard let items = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let item as URL in items where extensions.contains(item.pathExtension.lowercased()) {
                let parts = item.standardizedFileURL.resolvingSymlinksInPath().pathComponents
                guard parts.starts(with: base), parts.count > base.count else { continue }
                found[parts.dropFirst(base.count).joined(separator: "/")] = item
            }
        }
        return found
    }

    private func programFolders(_ environment: String?) -> [URL] {
        folders(["Program Files", "Program Files (x86)", "users/*/AppData/Local/Programs"], in: environment)
    }

    /// Snapshot taken before an installer runs.
    func installedExecutables(in environment: String? = nil) -> Set<String> {
        Set(files(["exe"], under: programFolders(environment), in: environment).keys)
    }

    /// New EXEs since `before`. Ones a Start Menu or public desktop shortcut points to
    /// come first and are named after it; uninstallers and updaters are left out.
    func newPrograms(since before: Set<String>, in environment: String? = nil) -> [InstalledCandidate] {
        let added = files(["exe"], under: programFolders(environment), in: environment).filter { !before.contains($0.key) }
        let shortcuts = files(["lnk"], under: folders(["ProgramData/Microsoft/Windows/Start Menu/Programs", "users/Public/Desktop",
                                                        "users/*/AppData/Roaming/Microsoft/Windows/Start Menu/Programs"], in: environment), in: environment)
            .sorted { $0.key < $1.key }
            .compactMap { _, url in (try? Data(contentsOf: url)).map { (url.deletingPathExtension().lastPathComponent, Self.foldASCII($0)) } }
        let helper = try! NSRegularExpression(pattern: "^(unins|uninst|setup|install|update|crash|report|repair|vc_?redist|dotnet)|uninstall|updater")
        func isHelper(_ name: String) -> Bool {
            let lower = name.lowercased()
            return helper.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil
        }
        var linked: [InstalledCandidate] = [], plain: [InstalledCandidate] = []
        for (_, exe) in added.sorted(by: { $0.key < $1.key }) {
            let name = exe.lastPathComponent
            guard !isHelper(name), !Self.isWineBuiltin(exe) else { continue }
            // .lnk files store the target path as ANSI and/or UTF-16LE; match the file name in either.
            let ascii = Data(name.lowercased().utf8), wide = name.lowercased().data(using: .utf16LittleEndian) ?? Data()
            if let title = shortcuts.first(where: { $0.1.range(of: ascii) != nil || $0.1.range(of: wide) != nil })?.0, !isHelper(title) {
                linked.append(InstalledCandidate(exe: exe, title: String(title.prefix(80)), shortcut: true))
            } else {
                plain.append(InstalledCandidate(exe: exe, title: String(exe.deletingPathExtension().lastPathComponent.prefix(80)), shortcut: false))
            }
        }
        if !linked.isEmpty { return linked }
        return Array(plain.sorted { $0.exe.pathComponents.count < $1.exe.pathComponents.count }.prefix(8))
    }

    /// Wine's own programs (iexplore, wordpad, ...) that every new prefix receives carry this
    /// marker after the DOS header; they are not something an installer added.
    static func isWineBuiltin(_ exe: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: exe) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 0x80)) ?? Data()
        return head.range(of: Data("Wine builtin DLL".utf8)) != nil || head.range(of: Data("Wine placeholder DLL".utf8)) != nil
    }

    private static func foldASCII(_ data: Data) -> Data {
        Data(data.map { (0x41...0x5a).contains($0) ? $0 + 0x20 : $0 })
    }
}

/// A Windows "Programs and Features" entry from a prefix's registry.
struct UninstallEntry: Hashable {
    let name: String
    let command: String
}

extension LauncherStore {
    /// The uninstaller Windows registered for an installed program: the entry whose
    /// InstallLocation holds its EXE, else whose DisplayIcon is the EXE itself.
    func uninstallEntry(for launcher: Launcher) -> UninstallEntry? {
        guard launcher.kind == .installed, let prefix = try? prefix(launcher),
              let text = try? String(contentsOf: prefix.appendingPathComponent("system.reg"), encoding: .utf8) else { return nil }
        let exe = launcher.executable.lowercased()
        var best: (score: Int, entry: UninstallEntry)?
        for values in Self.uninstallKeys(text) {
            guard let command = values["uninstallstring"], !command.isEmpty else { continue }
            var location = (values["installlocation"] ?? "").lowercased()
            if !location.isEmpty, !location.hasSuffix("\\") { location += "\\" }
            let icon = (values["displayicon"] ?? "").lowercased().split(separator: ",").first.map(String.init) ?? ""
            let score = !location.isEmpty && exe.hasPrefix(location) ? 2 : icon.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) == exe ? 1 : 0
            guard score > 0, score > (best?.score ?? 0) else { continue }
            best = (score, UninstallEntry(name: values["displayname"] ?? launcher.name, command: command))
        }
        return best?.entry
    }

    /// Values of every HKLM ...\CurrentVersion\Uninstall\* key in a Wine system.reg, names lowercased.
    static func uninstallKeys(_ text: String) -> [[String: String]] {
        var keys: [[String: String]] = [], current: [String: String]?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("[") {
                if let current { keys.append(current) }
                let name = line.lowercased()
                current = name.hasPrefix(#"[software\\microsoft\\windows\\currentversion\\uninstall\\"#)
                    || name.hasPrefix(#"[software\\wow6432node\\microsoft\\windows\\currentversion\\uninstall\\"#) ? [:] : nil
            } else if current != nil, line.hasPrefix("\""), let (name, value) = registryValue(line) {
                current?[name.lowercased()] = value
            }
        }
        if let current { keys.append(current) }
        return keys
    }

    /// `"Name"="value"` or `"Name"=str(2):"value"`, unescaping Wine's \\ \" \n \t \0 and \xHHHH.
    static func registryValue(_ line: Substring) -> (String, String)? {
        var rest = line[...]
        guard let name = quoted(&rest), rest.hasPrefix("=") else { return nil }
        rest = rest.dropFirst()
        if rest.hasPrefix("str(") { guard let colon = rest.firstIndex(of: ":") else { return nil }; rest = rest[rest.index(after: colon)...] }
        guard rest.hasPrefix("\""), let value = quoted(&rest) else { return nil }
        return (name, value)
    }

    private static func quoted(_ rest: inout Substring) -> String? {
        guard rest.first == "\"" else { return nil }
        var out = "", chars = rest.dropFirst()
        while let c = chars.first {
            chars = chars.dropFirst()
            if c == "\"" { rest = chars; return out }
            guard c == "\\", let next = chars.first else { out.append(c); continue }
            chars = chars.dropFirst()
            switch next {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "0": out.append("\0")
            case "x":
                let hex = chars.prefix(4).prefix { $0.isHexDigit }
                chars = chars.dropFirst(hex.count)
                if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) { out.unicodeScalars.append(scalar) }
            default: out.append(next)
            }
        }
        return nil
    }

    /// Folders moved to the Trash when a program is deleted: its private copy (with its own
    /// prefix and snapshots when it has one), and its dedicated environment when asked.
    func deletionFolders(for launcher: Launcher, environmentToo: Bool) throws -> [URL] {
        var folders: [URL] = []
        if launcher.kind != .installed { folders.append(try directory(launcher)) }
        if environmentToo, let environment = launcher.environment { folders += try environmentFolders(environment) }
        try folders.forEach(requireLocal)
        return folders.filter { fm.fileExists(atPath: $0.path) }
    }

    /// A dedicated environment's prefix and its migration snapshots. Never the shared one.
    func environmentFolders(_ environment: String) throws -> [URL] {
        guard Launcher.validEnvironment(environment) else { throw AlchemacError.message("Wine 환경 이름이 올바르지 않습니다.") }
        let parent = root.appendingPathComponent("prefixes", isDirectory: true)
        let snapshots = ((try? fm.contentsOfDirectory(atPath: parent.path)) ?? [])
            .filter { $0.hasPrefix(environment + ".backup.") }.sorted().map { parent.appendingPathComponent($0, isDirectory: true) }
        let folders = [prefix(environment: environment)] + snapshots
        try folders.forEach(requireLocal)
        return folders.filter { fm.fileExists(atPath: $0.path) }
    }

    func allocatedSize(_ folders: [URL]) -> Int64 {
        folders.reduce(0) { total, folder in
            guard let items = fm.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return total }
            var size: Int64 = 0
            for case let item as URL in items {
                size += Int64((try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
            }
            return total + size
        }
    }
}

extension LauncherStore {
    /// Values of one key in a Wine .reg file; `key` is its path as written there, e.g. `Software\\Wine\\Mac Driver`.
    static func registryValues(_ text: String, key: String) -> [String: String] {
        var values: [String: String] = [:], inside = false
        let header = "[" + key.lowercased() + "]"
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("[") { inside = line.lowercased().hasPrefix(header); continue }
            if inside, line.hasPrefix("\""), let (name, value) = registryValue(line) { values[name.lowercased()] = value }
        }
        return values
    }

    /// Whether an environment renders at the Retina screen's own resolution.
    func retinaEnabled(environment: String?) -> Bool { retinaEnabled(prefix: prefix(environment: environment)) }
    func retinaEnabled(prefix: URL) -> Bool {
        guard let text = try? String(contentsOf: prefix.appendingPathComponent("user.reg"), encoding: .utf8),
              let mode = Self.registryValues(text, key: #"Software\\Wine\\Mac Driver"#)["retinamode"]?.lowercased().first else { return false }
        return "yt1".contains(mode)
    }

    /// Settings regedit applies to switch an environment's Retina mode. On: native resolution at
    /// 192 DPI, keeping sizes, and Wine scales every DPI-unaware window by default (installers and
    /// their helpers); programs started from the app keep their own awareness via a per-name value.
    static func retinaRegistry(on: Bool) -> String {
        let dpi = on ? "000000c0" : "00000060"
        return ["REGEDIT4", "",
                #"[HKEY_CURRENT_USER\Software\Wine\Mac Driver]"#, #""RetinaMode"=""# + (on ? "y" : "n") + "\"", "",
                #"[HKEY_CURRENT_USER\Software\Wine\Fonts]"#, #""LogPixels"=dword:"# + dpi, "",
                #"[HKEY_CURRENT_USER\Control Panel\Desktop]"#, #""LogPixels"=dword:"# + dpi, "",
                #"[HKEY_LOCAL_MACHINE\System\CurrentControlSet\Hardware Profiles\Current\Software\Fonts]"#, #""LogPixels"=dword:"# + dpi, "",
                #"[HKEY_CURRENT_USER\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers]"#, on ? #"@="~ DPIUNAWARE""# : "@=-", ""]
            .joined(separator: "\r\n")
    }

    /// How an environment draws: the default (Retina off), at the Retina screen's own resolution,
    /// or at point size and scaled up to the Retina size by DXMT's MetalFX spatial upscaler.
    enum DisplayChoice: Equatable { case standard, retina, metalFX }
    static let metalFXSwapchainName = "DXMT_METALFX_SPATIAL_SWAPCHAIN"
    static let metalFXConfigName = "DXMT_CONFIG"
    static let metalFXFactorKey = "d3d11.metalSpatialUpscaleFactor"
    static let metalFXFactor = 2

    /// The `key=value` pairs of a DXMT_CONFIG value (separated by `;`), without empty ones.
    static func configPairs(_ config: String?) -> [String] {
        (config ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    private static func configKey(_ pair: String) -> String {
        pair.split(separator: "=", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }
    /// The MetalFX upscale factor in a DXMT_CONFIG value, if it has one.
    static func upscaleFactor(config: String?) -> Double? {
        guard let pair = configPairs(config).first(where: { configKey($0) == metalFXFactorKey }),
              let value = pair.split(separator: "=", maxSplits: 1).dropFirst().first else { return nil }
        return Double(value.trimmingCharacters(in: .whitespaces))
    }
    /// A DXMT_CONFIG value with only the upscale pair added, replaced (`factor`) or removed (nil); other pairs are kept
    /// in order. nil means the value should not exist (nothing is left).
    static func dxmtConfig(_ existing: String?, factor: Int?) -> String? {
        var pairs = configPairs(existing), placed = false
        pairs = pairs.compactMap { pair in
            guard configKey(pair) == metalFXFactorKey else { return pair }
            guard let factor, !placed else { return nil }
            placed = true
            return "\(metalFXFactorKey)=\(factor)"
        }
        if let factor, !placed { pairs.append("\(metalFXFactorKey)=\(factor)") }
        return pairs.isEmpty ? nil : pairs.joined(separator: ";")
    }
    /// Whether the environment values (names lower-cased, as `registryValues` returns them) turn the MetalFX upscaler on.
    static func metalFXEnabled(environment values: [String: String]) -> Bool {
        values[metalFXSwapchainName.lowercased()] == "1" && (upscaleFactor(config: values[metalFXConfigName.lowercased()]) ?? 0) > 1
    }
    /// The display choice a user.reg describes: Retina wins over MetalFX values left behind.
    static func displayChoice(userReg text: String?) -> DisplayChoice {
        guard let text else { return .standard }
        if let mode = registryValues(text, key: #"Software\\Wine\\Mac Driver"#)["retinamode"]?.lowercased().first, "yt1".contains(mode) { return .retina }
        return metalFXEnabled(environment: registryValues(text, key: "Environment")) ? .metalFX : .standard
    }
    func displayChoice(prefix: URL) -> DisplayChoice {
        Self.displayChoice(userReg: try? String(contentsOf: prefix.appendingPathComponent("user.reg"), encoding: .utf8))
    }
    func displayChoice(environment: String?) -> DisplayChoice { displayChoice(prefix: prefix(environment: environment)) }
    private static func regString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    /// Settings regedit applies to switch an environment to a display choice. Retina on removes the MetalFX values;
    /// MetalFX turns Retina off (the same settings as the default) and sets the two environment values; the default
    /// removes MetalFX values only if there are some. Other DXMT_CONFIG pairs the environment has are kept.
    static func displayRegistry(_ choice: DisplayChoice, userReg text: String?) -> String {
        let values = registryValues(text ?? "", key: "Environment")
        let config = values[metalFXConfigName.lowercased()]
        var lines: [String] = []
        if choice == .metalFX {
            lines = ["\"\(metalFXSwapchainName)\"=" + regString("1"),
                     dxmtConfig(config, factor: metalFXFactor).map { "\"\(metalFXConfigName)\"=" + regString($0) } ?? "\"\(metalFXConfigName)\"=-"]
        } else if values[metalFXSwapchainName.lowercased()] != nil || upscaleFactor(config: config) != nil {
            lines = ["\"\(metalFXSwapchainName)\"=-",
                     dxmtConfig(config, factor: nil).map { "\"\(metalFXConfigName)\"=" + regString($0) } ?? "\"\(metalFXConfigName)\"=-"]
        }
        var out = retinaRegistry(on: choice == .retina)
        if !lines.isEmpty { out += ([#"[HKEY_CURRENT_USER\Environment]"#] + lines + [""]).joined(separator: "\r\n") }
        return out
    }
    func displayRegistry(_ choice: DisplayChoice, prefix: URL) -> String {
        Self.displayRegistry(choice, userReg: try? String(contentsOf: prefix.appendingPathComponent("user.reg"), encoding: .utf8))
    }

    /// A .reg file for regedit, kept beside the library and removed by the caller.
    func registryScript(_ text: String) throws -> URL {
        let folder = root.appendingPathComponent("registry.noindex", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent(UUID().uuidString + ".reg")
        try Data(text.utf8).write(to: file)
        try requireLocal(file)
        return file
    }
}
