import Foundation
import CryptoKit
import Darwin

extension LauncherStore {
    /// Every Wine environment the app knows: the shared one, dedicated ones and registered programs' own, once each.
    func knownEnvironments(_ registry: Registry) -> [(title: String, prefix: URL)] {
        var found: [(title: String, prefix: URL)] = [("공용 Wine 환경", sharedPrefix)]
        found += environments().map { ("전용 Wine 환경 ‘\($0)’", prefix(environment: $0)) }
        found += registry.launchers.filter(\.privatePrefix).compactMap { launcher in (try? prefix(launcher)).map { ("‘\(launcher.name)’ 전용 Wine 환경", $0) } }
        var seen = Set<String>()
        return found.filter { seen.insert($0.prefix.standardizedFileURL.path).inserted }
    }
}

/// Finds and stops a standalone-run supervisor an earlier run of the app left behind. The supervisor (/bin/sh)
/// holds the environment's session lock for the whole session and stops only its own prefix on TERM.
enum OrphanSessions {
    /// Same path standalone-run computes: `cd "$(dirname "$WINEPREFIX")" && pwd -P`, then the basename.
    /// realpath(3) rather than resolvingSymlinksInPath, which would shorten /private/var to /var.
    static func realPrefixPath(_ prefix: URL) -> String? {
        guard let parent = realpath(prefix.standardizedFileURL.deletingLastPathComponent().path, nil) else { return nil }
        defer { free(parent) }
        return String(cString: parent) + "/" + prefix.lastPathComponent
    }

    static func md5Hex(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `<support>/prefix-sessions/<md5 of the prefix's real path>`; nil when the folders cannot be resolved.
    static func scopeDirectory(support: URL, prefix: URL) -> URL? {
        guard let real = realPrefixPath(prefix), let base = realpath(support.path, nil) else { return nil }
        defer { free(base) }
        return URL(fileURLWithPath: String(cString: base)).appendingPathComponent("prefix-sessions/" + md5Hex(real), isDirectory: true)
    }

    /// argv of a process from its KERN_PROCARGS2 block: argc, the exec path, NUL padding, then argc strings.
    static func arguments(fromProcArgs data: Data) -> [String] {
        let bytes = [UInt8](data)
        guard bytes.count > 4 else { return [] }
        let argc = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        var at = 4
        while at < bytes.count, bytes[at] != 0 { at += 1 }      // exec path
        while at < bytes.count, bytes[at] == 0 { at += 1 }      // padding
        var arguments: [String] = []
        while arguments.count < argc, at < bytes.count {
            var end = at
            while end < bytes.count, bytes[end] != 0 { end += 1 }
            arguments.append(String(decoding: bytes[at..<end], as: UTF8.self))
            at = end + 1
        }
        return arguments
    }

    static func arguments(ofProcess pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return arguments(fromProcArgs: Data(buffer.prefix(size)))
    }

    /// The command line of the runtime's supervisor: `/bin/sh <runtime>/scripts/standalone-run <id> …`.
    static func isSupervisor(_ arguments: [String]) -> Bool {
        arguments.count >= 2 && arguments[0] == "/bin/sh" && arguments[1].hasSuffix("/scripts/standalone-run")
    }

    static func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    /// The pid recorded for the environment's session, only when the scope really belongs to this prefix and the
    /// process is a live standalone-run supervisor. nil otherwise: nothing is then sent to anybody.
    static func verifiedSupervisor(support: URL, prefix: URL, arguments: (pid_t) -> [String]? = arguments(ofProcess:)) -> pid_t? {
        guard let real = realPrefixPath(prefix), let scope = scopeDirectory(support: support, prefix: prefix),
              let owner = try? String(contentsOf: scope.appendingPathComponent("owner-prefix"), encoding: .utf8),
              owner.trimmingCharacters(in: .newlines) == real,
              let text = try? String(contentsOf: scope.appendingPathComponent("supervisor-pid"), encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1, isAlive(pid),
              let argv = arguments(pid), isSupervisor(argv) else { return nil }
        return pid
    }

    /// Sends TERM to the supervisor of an environment whose lock is still held. The supervisor's trap runs the
    /// runtime's prefix-scoped stop and exits 143. False when the process could not be verified (nothing is sent).
    static func terminate(support: URL, prefix: URL) -> Bool {
        guard PrefixMigration.isEnvironmentBusy(prefix), let pid = verifiedSupervisor(support: support, prefix: prefix) else { return false }
        return kill(pid, SIGTERM) == 0
    }

    /// Waits (off the main thread's way: it sleeps between checks) until the lock is free.
    static func waitUntilFree(_ prefix: URL, timeout: TimeInterval = 30) async -> Bool {
        let limit = Date().addingTimeInterval(timeout)
        while PrefixMigration.isEnvironmentBusy(prefix) {
            if Date() >= limit { return false }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return true
    }
}

/// Leftovers an app crash, a force-quit or a failed update left in the library. Planning only reads the file
/// system and returns what to remove; applying takes each environment's session lock first.
enum StartupCleanup {
    enum Action { case trash, remove }
    /// `prefix`: the environment whose session lock must be held while the item goes (nil: none concerned).
    struct Item: Equatable { let url: URL; let action: Action; let prefix: URL? }

    static func isPlainDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    static func names(_ folder: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() }

    /// The BUILD-ID of a runtime folder, in the form the runtime's own `runtime_id` accepts.
    static func runtimeID(_ runtime: URL) -> String? {
        guard let text = try? String(contentsOf: runtime.appendingPathComponent("BUILD-ID"), encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first.map(String.init),
              !line.isEmpty, !line.hasPrefix("."), line.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { return nil }
        return line
    }

    /// `<name>.hadron-new.<pid>` staging folders of an environment's creation, with the environment they belong to.
    static func stagingLeftovers(in parent: URL) -> [(prefix: URL, staging: URL)] {
        names(parent).compactMap { name in
            guard let range = name.range(of: #"\.hadron-new\.[0-9]+$"#, options: .regularExpression), range.lowerBound > name.startIndex else { return nil }
            let staging = parent.appendingPathComponent(name, isDirectory: true)
            guard isPlainDirectory(staging) else { return nil }
            return (parent.appendingPathComponent(String(name[..<range.lowerBound]), isDirectory: true), staging)
        }
    }

    /// What goes: staging folders of the app's own work, leftovers beside environments, and the private runtime
    /// copies and bookkeeping of every scope. `processes`: the command lines of the running processes, so a scope
    /// that Wine still has files of is left alone. `exists` says whether an environment folder is still there.
    static func plan(root: URL, support: URL, runtimeID bundled: String?, processes: String,
                     exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                     alive: (pid_t) -> Bool = OrphanSessions.isAlive) -> [Item] {
        var items: [Item] = []
        // The app's own staging: a program import copy, an add-on install, a registry script (all removed by their
        // owner when it finishes, so at startup, with only one app instance running, every one is a leftover).
        for name in names(root) where name.hasPrefix(".import-") && isPlainDirectory(root.appendingPathComponent(name)) {
            items.append(Item(url: root.appendingPathComponent(name, isDirectory: true), action: .trash, prefix: nil))
        }
        let addons = root.appendingPathComponent("addons", isDirectory: true)
        for name in names(addons) where name.hasPrefix(".install-") && isPlainDirectory(addons.appendingPathComponent(name)) {
            items.append(Item(url: addons.appendingPathComponent(name, isDirectory: true), action: .trash, prefix: nil))
        }
        let scripts = root.appendingPathComponent("registry.noindex", isDirectory: true)
        for name in names(scripts) where name.hasSuffix(".reg") {
            var info = stat()
            if lstat(scripts.appendingPathComponent(name).path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG {
                items.append(Item(url: scripts.appendingPathComponent(name), action: .trash, prefix: nil))
            }
        }
        // Environment creation leftovers, beside the shared/dedicated prefixes and beside each program's own prefix.
        let prefixes = root.appendingPathComponent("prefixes", isDirectory: true)
        let launchers = root.appendingPathComponent("launchers", isDirectory: true)
        for parent in [prefixes] + names(launchers).map({ launchers.appendingPathComponent($0, isDirectory: true) }) where isPlainDirectory(parent) {
            for (prefix, staging) in stagingLeftovers(in: parent) { items.append(Item(url: staging, action: .trash, prefix: prefix)) }
        }
        // Per-environment scopes. Nothing user-owned lives there: owner-prefix/active-prefix/supervisor-pid/stop-request/
        // source/runtime link, the runtimes/ copies of the bundled runtime and the Dock bundles of play (apps/).
        let sessions = support.appendingPathComponent("prefix-sessions", isDirectory: true)
        for key in names(sessions) {
            let scope = sessions.appendingPathComponent(key, isDirectory: true)
            guard key.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil, isPlainDirectory(scope) else { continue }
            let owner = (try? String(contentsOf: scope.appendingPathComponent("owner-prefix"), encoding: .utf8))?.trimmingCharacters(in: .newlines) ?? ""
            if owner.isEmpty {
                items.append(Item(url: scope, action: .remove, prefix: nil))
                continue
            }
            // A scope is named after its owner's path; anything else is not understood and stays.
            guard owner.hasPrefix("/"), OrphanSessions.md5Hex(owner) == key else { continue }
            let prefix = URL(fileURLWithPath: owner, isDirectory: true)
            if !exists(owner) {
                items.append(Item(url: scope, action: .remove, prefix: prefix))
                continue
            }
            if processes.contains(scope.path + "/") { continue }
            let runtimes = scope.appendingPathComponent("runtimes", isDirectory: true)
            if let bundled {
                for name in names(runtimes) where name != bundled && name != ".launches" {
                    let url = runtimes.appendingPathComponent(name, isDirectory: true)
                    guard isPlainDirectory(url) else { continue }
                    // Only a stale half copy or a complete copy of another build (what runtime_prune deletes too).
                    if name.hasPrefix(".new.") || FileManager.default.fileExists(atPath: url.appendingPathComponent("BUILD-ID").path) {
                        items.append(Item(url: url, action: .remove, prefix: prefix))
                    }
                }
            }
            let launches = runtimes.appendingPathComponent(".launches", isDirectory: true)
            for name in names(launches) {
                let file = launches.appendingPathComponent(name)
                var info = stat()
                guard lstat(file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                      let pid = pid_t(name.split(separator: ".").last ?? ""), !alive(pid) else { continue }
                items.append(Item(url: file, action: .remove, prefix: prefix))
            }
            for name in ["active-prefix", "owner-prefix"] {
                let file = scope.appendingPathComponent(name)
                var info = stat()
                if lstat(file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size == 0 { items.append(Item(url: file, action: .remove, prefix: prefix)) }
            }
        }
        return items
    }

    struct Summary { var freed: Int64 = 0, removed = 0, skipped = 0 }

    /// Applies a plan: each environment's items under its session lock (an environment in use is skipped silently).
    /// Removals the plan marked `.remove` are app caches; the rest goes to the Trash.
    static func apply(_ items: [Item], store: LauncherStore) -> Summary {
        let fm = FileManager.default
        var result = Summary()
        func take(_ item: Item) {
            // Bookkeeping already gone (a whole scope removed above it) is not an error.
            guard fm.fileExists(atPath: item.url.path) || (try? fm.destinationOfSymbolicLink(atPath: item.url.path)) != nil else { return }
            let size = store.allocatedSize([item.url])
            do {
                if item.action == .trash { try fm.trashItem(at: item.url, resultingItemURL: nil) } else { try fm.removeItem(at: item.url) }
                result.freed += size; result.removed += 1
            } catch { result.skipped += 1; fputs("Alchemac: cleanup could not remove \(item.url.lastPathComponent): \(error.localizedDescription)\n", stderr) }
        }
        var order: [String] = [], grouped: [String: [Item]] = [:]
        for item in items {
            let key = item.prefix?.path ?? ""
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(item)
        }
        for key in order {
            let group = grouped[key]!
            if key.isEmpty { group.forEach(take); continue }
            do { try PrefixMigration.withEnvironmentFree(URL(fileURLWithPath: key, isDirectory: true)) { group.forEach(take) } }
            catch { result.skipped += group.count }
        }
        return result
    }

    /// Command lines of this user's processes, for `plan(processes:)`; empty when `ps` cannot run.
    static func processCommands() -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-U", String(getuid()), "-o", "command="]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// The whole pass, for a background queue.
    static func run(store: LauncherStore, runtime: URL) -> Summary {
        let items = plan(root: store.root, support: store.support, runtimeID: runtimeID(runtime), processes: processCommands())
        let result = apply(items, store: store)
        fputs("Alchemac: startup cleanup removed \(result.removed) item(s), about \(result.freed / 1_000_000) MB (clones share space), skipped \(result.skipped)\n", stderr)
        return result
    }
}

/// Migration snapshots, `<environment>.backup.YYYYMMDD-HHMMSS.<pid>` beside the environment.
enum Backups {
    struct Snapshot: Equatable { let url: URL; let date: Date? }

    static func date(fromName name: String, environment: String) -> Date? {
        guard let range = name.range(of: "^" + NSRegularExpression.escapedPattern(for: environment) + #"\.backup\.([0-9]{8}-[0-9]{6})(\.[0-9]+)?$"#, options: .regularExpression) else { return nil }
        let stamp = name[range].dropFirst(environment.count + 8).prefix(15)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.date(from: String(stamp))
    }

    /// Plain directories named `<environment>.backup.*` beside the environment; links are not snapshots.
    static func snapshots(of prefix: URL) -> [Snapshot] {
        let parent = prefix.deletingLastPathComponent(), name = prefix.lastPathComponent
        return StartupCleanup.names(parent).filter { $0.hasPrefix(name + ".backup.") }.compactMap { entry in
            let url = parent.appendingPathComponent(entry, isDirectory: true)
            return StartupCleanup.isPlainDirectory(url) ? Snapshot(url: url, date: date(fromName: entry, environment: name)) : nil
        }
    }

    /// The newest snapshot: latest date, an unreadable date counting as oldest, ties and those by name.
    static func newest(_ snapshots: [Snapshot]) -> Snapshot? {
        snapshots.max { ($0.date ?? .distantPast, $0.url.lastPathComponent) < ($1.date ?? .distantPast, $1.url.lastPathComponent) }
    }

    /// The snapshot an unfinished migration's marker names; it must never be removed (a restore would need it).
    static func protected(_ prefix: URL) -> URL? {
        guard let text = try? String(contentsOf: PrefixMigration.marker(prefix), encoding: .utf8) else { return nil }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath() : nil
    }

    /// All but the newest, minus the protected one.
    static func removable(_ snapshots: [Snapshot], protected: URL?) -> [URL] {
        guard let keep = newest(snapshots) else { return [] }
        return snapshots.filter { $0 != keep && $0.url.standardizedFileURL.resolvingSymlinksInPath() != protected }.map(\.url)
    }
}

/// Checks the app's private runtime copy of an environment before a new session runs from it (review finding 5-#5).
/// standalone-run clones the signed bundle runtime into `<support>/prefix-sessions/<key>/runtimes/<BUILD-ID>/` and executes
/// that user-writable copy from then on, so a Windows program that wrote it through Wine's Z: drive would keep running on
/// every later launch, even after the app is reinstalled. Nothing writes inside a copy at runtime, and st_ctime cannot be set
/// from user space (utimes/SetFileTime change only atime/mtime; any write, chmod, rename or link change bumps it). A copy is
/// staged as `.new.<pid>` and renamed into place after all its entries exist, so its top directory's ctime is the latest.
/// Measured on real copies after many sessions: every entry's ctime is within 1 s of the top's. The reasoning also holds for
/// the full-copy fallback on a non-APFS volume: entries are created over the whole copy duration, but the rename comes last.
enum RuntimeCopy {
    struct Problem: Equatable { let reason: String }

    struct Entry: Equatable {
        let kind: UInt16        // st_mode & S_IFMT
        let size: Int64         // regular files only (0 otherwise)
        let link: String?       // symlink destination
        let ctime: Int64        // nanoseconds
    }

    /// ctime spread allowed around the top directory (copy time + rename; real copies measured within 1 s).
    static let slack: TimeInterval = 2

    private static func nanoseconds(_ t: timespec) -> Int64 { Int64(t.tv_sec) * 1_000_000_000 + Int64(t.tv_nsec) }

    /// Every entry below `root` (relative path → type/size/link/ctime), walking with fts(3) without following symlinks.
    /// nil when something cannot be read: a tree that cannot be looked at is not trusted.
    static func scan(_ root: String) -> [String: Entry]? {
        guard let rootC = strdup(root) else { return nil }
        defer { free(rootC) }
        var paths: [UnsafeMutablePointer<CChar>?] = [rootC, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return nil }
        defer { fts_close(fts) }
        var entries: [String: Entry] = [:]
        let prefixLength = root.utf8.count + 1
        while let node = fts_read(fts) {
            switch Int32(node.pointee.fts_info) {
            case FTS_DP: continue                                       // directory after its children
            case FTS_D, FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT: break
            default: return nil                                         // FTS_ERR, FTS_DNR, FTS_NS
            }
            if node.pointee.fts_level == 0 { continue }
            guard let info = node.pointee.fts_statp?.pointee else { return nil }
            let full = String(cString: node.pointee.fts_path)
            let relative = String(decoding: Array(full.utf8.dropFirst(prefixLength)), as: UTF8.self)
            let kind = info.st_mode & S_IFMT
            var link: String?
            if kind == S_IFLNK {
                var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                guard readlink(full, &buffer, Int(PATH_MAX)) >= 0 else { return nil }
                link = String(cString: buffer)
            }
            entries[relative] = Entry(kind: UInt16(kind), size: kind == S_IFREG ? Int64(info.st_size) : 0, link: link, ctime: nanoseconds(info.st_ctimespec))
        }
        return entries
    }

    /// The bundle is signed and immutable while the app runs: its entry list is read once per run.
    private static let cacheLock = NSLock()
    private static var bundleCache: [String: [String: Entry]] = [:]
    static func bundleEntries(_ bundle: URL) -> [String: Entry]? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let known = bundleCache[bundle.path] { return known }
        guard let found = scan(bundle.path) else { return nil }
        bundleCache[bundle.path] = found
        return found
    }

    /// nil when the copy is exactly the bundle: same entry set and types, same sizes and link targets, ctimes within
    /// `slack` of the top directory's, and the host scripts byte for byte equal. A copy that is not there is nothing to verify.
    static func verify(copy: URL, bundle: URL, slack: TimeInterval = RuntimeCopy.slack) -> Problem? {
        var top = stat()
        guard lstat(copy.path, &top) == 0 else { return errno == ENOENT ? nil : Problem(reason: "사본을 읽을 수 없음") }
        guard top.st_mode & S_IFMT == S_IFDIR else { return Problem(reason: "사본이 폴더가 아님") }
        guard let expected = bundleEntries(bundle) else { return nil }          // cannot read the bundle: nothing to compare with
        guard let found = scan(copy.path) else { return Problem(reason: "사본을 끝까지 읽을 수 없음") }
        for path in found.keys.sorted() where expected[path] == nil { return Problem(reason: "번들에 없는 항목 \(path)") }
        for path in expected.keys.sorted() {
            guard let have = found[path] else { return Problem(reason: "빠진 항목 \(path)") }
            let want = expected[path]!
            if have.kind != want.kind || have.size != want.size || have.link != want.link { return Problem(reason: "달라진 항목 \(path)") }
        }
        // A write, chmod, rename or link change after the copy was made leaves the entry newer than the top directory
        // (or, when the top was touched afterwards to hide that, the top newer than everything inside it).
        let top1 = nanoseconds(top.st_ctimespec), limit = Int64(slack * 1_000_000_000)
        for path in found.keys.sorted() where found[path]!.ctime > top1 + limit { return Problem(reason: "복사 뒤에 수정된 항목 \(path)") }
        if let newest = found.values.map(\.ctime).max(), top1 > newest + limit { return Problem(reason: "사본 폴더가 복사 뒤에 수정됨") }
        // The host shell scripts run first and are small: compare their bytes too (ctime is bypassable by touching everything).
        for path in found.keys.sorted() where found[path]!.kind == UInt16(S_IFREG) && (!path.contains("/") || path.hasPrefix("scripts/")) {
            if !FileManager.default.contentsEqual(atPath: copy.appendingPathComponent(path).path, andPath: bundle.appendingPathComponent(path).path) {
                return Problem(reason: "내용이 달라진 파일 \(path)")
            }
        }
        return nil
    }

    /// `<support>/prefix-sessions/<key>/runtimes/<bundled BUILD-ID>`; nil when the bundle has no readable BUILD-ID.
    static func copyURL(support: URL, prefix: URL, runtime: URL) -> URL? {
        guard let id = StartupCleanup.runtimeID(runtime), let scope = OrphanSessions.scopeDirectory(support: support, prefix: prefix) else { return nil }
        return scope.appendingPathComponent("runtimes/" + id, isDirectory: true)
    }

    /// Verifies the environment's copy of the bundled runtime under the environment's session lock and, when it differs,
    /// removes it (an app cache: this launch's standalone-run clones a fresh one). Returns the reason it was reset.
    /// The scope's `runtime` link needs no care: standalone-run only runs runtime_point after runtime_copy, which
    /// recreates the folder at the same path (a dangling link then works again, and a link to elsewhere is replaced).
    /// Throws when the copy could not be removed, so the launch is refused rather than run from a changed copy.
    static func verifyAndReset(support: URL, prefix: URL, runtime: URL) throws -> String? {
        guard let copy = copyURL(support: support, prefix: prefix, runtime: runtime) else { return nil }
        return try PrefixMigration.withEnvironmentFree(prefix) {
            guard let problem = verify(copy: copy, bundle: runtime) else { return nil }
            do { try FileManager.default.removeItem(at: copy) } catch {
                throw AlchemacError.message("이 Wine 환경에서 쓰는 런타임 사본이 바뀌어 있지만(\(problem.reason)) 사본을 초기화하지 못해 실행하지 않았습니다. 앱을 다시 설치한 뒤에도 같으면 ‘\(copy.deletingLastPathComponent().deletingLastPathComponent().path)’ 폴더를 휴지통으로 옮겨 주세요. (\(error.localizedDescription))")
            }
            FileHandle.standardError.write(Data("alchemac: runtime copy reset (\(problem.reason)): \(copy.path)\n".utf8))
            return problem.reason
        }
    }

    static let resetNotice = "이 Wine 환경에서 쓰는 런타임 사본이 바뀌어 있어 새로 만들었습니다. 예상하지 못한 변경이라면 최근에 실행한 프로그램을 확인해 주세요."
}
