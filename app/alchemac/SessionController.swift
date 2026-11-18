import Foundation
import Combine

/// One retained standalone supervisor. Its trap stops only its own prefix.
@MainActor
final class Session {
    let prefix: String
    let launcherID: String?
    let title: String
    let process: Process
    let output: FileHandle
    var stopping = false
    /// Set when this run started a migration of the Wine environment to a new runtime build.
    var migrationRuntime: URL?
    /// The status text shown while migrating, and the one that replaces it once the migration is over.
    var migrationMessage = "", runningMessage = ""
    /// The migration is still under way (`.hadron-prefix-ready` is rewritten when it ends), so stopping now interrupts that update.
    var migrating: Bool {
        migrationRuntime.map { PrefixMigration.isMigrating(prefix: URL(fileURLWithPath: prefix), runtime: $0) } ?? false
    }
    var after: (() -> Void)?
    var deadline: DispatchWorkItem?
    let started = Date()
    /// The app's own log of this run (the supervisor's stdout/stderr, created by the controller).
    let outerLog: URL

    init(prefix: String, launcherID: String?, title: String, process: Process, output: FileHandle, outerLog: URL) {
        self.prefix = prefix; self.launcherID = launcherID; self.title = title; self.process = process; self.output = output
        self.outerLog = outerLog
    }

    /// The runtime's own log of this run: standalone-run names it `<session>-<its pid>.session.log`, and its pid
    /// is the one this process was started with.
    var runtimeLog: URL? {
        guard let name = process.arguments?.first else { return nil }
        let url = outerLog.deletingLastPathComponent().appendingPathComponent("\(name)-\(process.processIdentifier).session.log")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// Turns the last lines of a run's logs into a Korean reason and a suggested action. The English fragments
/// are the exact failure messages of the runtime's start scripts and of prefix-profile.
enum LaunchDiagnostics {
    static let known: [(pattern: String, text: String)] = [
        ("watchdog: only .* of disk left", "디스크 여유 공간이 5GB 아래로 내려가 프로그램을 자동으로 멈췄습니다. 공간을 확보한 뒤(6GB 이상 권장) 다시 실행해 주세요."),
        ("watchdog: (critical memory pressure|swap grew|Wine resident memory)", "Mac의 메모리가 부족해질 수 있어 프로그램을 자동으로 멈췄습니다. 다른 앱을 종료해 메모리를 확보한 뒤 다시 실행해 주세요."),
        ("runtime path too long", "런타임 경로가 너무 길어 Wine을 시작하지 못했습니다. 사용자 폴더 경로가 긴 Mac에서 생길 수 있습니다. 앱을 최신 버전으로 바꿔 보고, 계속되면 이 로그를 개발자에게 알려 주세요."),
        ("scope mismatch", "이 Wine 환경의 세션 정보가 맞지 않아 시작하지 못했습니다. 앱을 완전히 종료한 뒤 다시 실행해 주세요."),
        ("runtime selection lock failed", "런타임을 고르는 중 잠금을 얻지 못했습니다. 다른 Alchemac 작업이 끝난 뒤 다시 시도해 주세요."),
        ("existing unmanaged Wine session", "이 Wine 환경에 앱이 관리하지 않는 Wine 프로세스가 남아 있습니다. 그 프로그램을 종료하거나 Mac을 다시 시작한 뒤 실행해 주세요."),
        ("prefix migration incomplete", "Wine 환경을 새 런타임에 맞추는 작업이 중간에 멈춘 환경입니다. 프로그램을 다시 실행하면 ‘다시 시도’ 또는 ‘업데이트 전 상태로 복원’을 고르는 창이 나옵니다. 환경 폴더 옆의 ‘.backup.’ 이름 폴더가 이전 상태의 복사본입니다."),
        ("partial snapshot", "환경을 옮기기 전 복사본을 만들다 멈췄습니다. 디스크 여유 공간을 확인하고 다시 시도해 주세요."),
        ("refusing an incomplete or foreign prefix", "이 Wine 환경을 안전하게 사용할 수 없어 실행하지 않았습니다. 환경이 완전하지 않거나 이 앱이 만든 환경이 아닙니다. 파일은 아무것도 바꾸거나 지우지 않았습니다. ‘환경 폴더 보기’로 폴더를 확인해 주세요."),
        ("initialization failed", "새 Wine 환경을 만들지 못했습니다. 디스크 여유 공간을 확인하고 다시 시도해 주세요."),
        ("staging path already exists", "이전 Wine 환경 초기화가 남긴 임시 폴더가 있어 실행하지 않았습니다. ‘환경 폴더 보기’로 같은 위치의 ‘.hadron-new.’ 폴더를 확인해 주세요. 무엇인지 확실하지 않으면 그대로 두고 로그와 함께 문의해 주세요."),
        ("runtime has no BUILD-ID", "앱의 런타임 파일이 손상됐습니다. 앱을 다시 설치해 주세요."),
        ("selected runtime has no entry point", "이 Wine 환경이 쓰는 런타임 사본이 손상됐습니다. 앱을 다시 설치해 주세요."),
        ("unsafe path", "경로에 사용할 수 없는 문자가 있습니다. 프로그램 폴더와 Wine 환경 이름을 확인해 주세요."),
        ("prefix symlinks are not accepted", "Wine 환경 폴더가 바로가기(링크)여서 사용할 수 없습니다."),
        ("EXE not found", "실행할 파일을 찾을 수 없습니다. 프로그램 폴더를 확인해 주세요."),
        ("OpenGL needs Zink", "그래픽 구성요소가 앱에서 빠져 있습니다. 앱을 다시 설치해 주세요."),
        ("Wine Mono package missing", ".NET 실행 환경(Wine Mono) 설치 파일이 앱에 없습니다. 앱을 다시 설치해 주세요."),
        ("Wine Mono install failed", ".NET 실행 환경(Wine Mono) 설치를 시작하지 못했습니다. 다시 실행해 보고, 계속되면 이 로그를 확인해 주세요."),
        ("Wine Mono install exit=[1-9]", ".NET 실행 환경(Wine Mono) 설치가 실패했습니다. 다시 실행해 보고, 계속되면 이 로그를 확인해 주세요."),
        ("launcher file failed", "프로그램 실행 파일을 열 수 없습니다. 프로그램 폴더에 파일이 그대로 있는지 확인해 주세요."),
        ("original launcher CreateProcess failed", "Windows 프로그램을 시작하지 못했습니다. 파일이 손상됐거나 이 환경에서 실행할 수 없는 형식일 수 있습니다."),
        ("font (copy|registry key|registry value) failed", "한글 글꼴을 환경에 설치하지 못했습니다. 디스크 여유 공간과 환경 상태를 확인해 주세요."),
        ("Windows directory failed", "Wine 환경의 Windows 폴더에 접근하지 못했습니다. 환경이 손상됐을 수 있습니다."),
    ]

    /// Failures whose fix starts with looking at the Wine environment's folder ("환경 폴더 보기" in the window).
    static let environmentFolderPatterns = ["refusing an incomplete or foreign prefix", "staging path already exists", "prefix migration incomplete", "Windows directory failed"]

    static func wantsEnvironmentFolder(_ text: String) -> Bool {
        environmentFolderPatterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// The status text once a migration has ended: the normal running text, keeping anything appended after the
    /// migration notice. nil when the message is no longer the migration notice (something else replaced it).
    static func settledMessage(current: String, migration: String, running: String) -> String? {
        guard !migration.isEmpty, current.hasPrefix(migration) else { return nil }
        return running + current.dropFirst(migration.count)
    }

    /// How long after the supervisor's last log line the session may last for an early exit to count.
    static let quickEnd: TimeInterval = 20

    /// The exit code the helper recorded for a program that ended within its first seconds.
    static func earlyExit(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "target exited early, code=(0x[0-9a-fA-F]+)"),
              let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    static func early(_ code: String) -> String {
        "프로그램이 시작 직후 종료됐습니다 (코드 \(code)). 필요한 구성요소가 없거나 이 환경에서 지원되지 않는 프로그램일 수 있습니다. 로그를 확인해 주세요."
    }

    /// A known failure's Korean explanation, else the last meaningful line of the log, else nil.
    static func explain(_ text: String) -> String? {
        for (pattern, korean) in known where text.range(of: pattern, options: .regularExpression) != nil { return korean }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let notable = lines.last { $0.contains("standalone:") || $0.contains("prefix-profile:") || $0.contains("watchdog:") || $0.localizedCaseInsensitiveContains("error")
            || $0.localizedCaseInsensitiveContains("fail") }
        guard let line = notable ?? lines.last else { return nil }
        return "마지막 로그 줄: " + String(line.prefix(200))
    }

    /// The last `limit` bytes of a file, as text.
    static func tail(_ url: URL, limit: Int = 16384) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return "" }
        try? handle.seek(toOffset: size > UInt64(limit) ? size - UInt64(limit) : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }

    /// The message for an ended session, or nil when the run looks normal. `failed`: the supervisor reported an error.
    @MainActor static func report(for session: Session, failed: Bool, ended: Date = Date()) -> String? {
        let runtimeLog = session.runtimeLog
        let outer = tail(session.outerLog), inner = runtimeLog.map { tail($0) } ?? ""
        if failed { return explain(outer + "\n" + inner) }
        if let code = earlyExit(in: inner), let modified = runtimeLog.flatMap({ (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }),
           ended.timeIntervalSince(modified) < quickEnd { return early(code) }
        return nil
    }
}

/// The start of an app update's first run migrates a Wine environment (snapshot, `wineboot --update`) and leaves
/// `.hadron-migration-incomplete` until it finishes. An interrupted run leaves it behind and the runtime then
/// refuses every launch, so the app offers to retry or restore the snapshot.
struct MigrationInterrupted: LocalizedError {
    let prefix: URL
    var errorDescription: String? { "이 Wine 환경의 업데이트가 중간에 멈춰 실행할 수 없습니다. 같은 프로그램을 다시 실행하면 다시 시도하거나 복원할 수 있습니다." }
}

/// A Wine session the app did not start in this run (it crashed or was force-quit; the supervisor and Wine kept
/// running) still holds the environment's session lock. The app offers to stop it.
struct OrphanSession: LocalizedError {
    let prefix: URL
    var errorDescription: String? { "이전에 시작한 Wine 세션이 아직 이 환경을 쓰고 있습니다. ‘남은 세션 종료’로 끝낸 뒤 다시 시도해 주세요." }
}

enum PrefixMigration {
    static let markerName = ".hadron-migration-incomplete", readyName = ".hadron-prefix-ready"
    static func marker(_ prefix: URL) -> URL { prefix.appendingPathComponent(markerName) }
    static func isInterrupted(_ prefix: URL) -> Bool { FileManager.default.fileExists(atPath: marker(prefix).path) }

    /// The runtime migrates a complete environment recorded under another BUILD-ID on its next launch.
    static func isMigrating(prefix: URL, runtime: URL) -> Bool {
        func id(_ url: URL) -> String? {
            (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let recorded = id(prefix.appendingPathComponent(readyName)), let current = id(runtime.appendingPathComponent("BUILD-ID")),
              !current.isEmpty else { return false }
        return recorded != current
    }

    /// The snapshot the runtime recorded, only if it is a plain sibling backup of this environment that still looks
    /// like a complete one. Anything else is refused: the restore moves the current environment to the Trash.
    static func snapshot(for prefix: URL, store: LauncherStore) -> URL? {
        let fm = FileManager.default
        guard let text = try? String(contentsOf: marker(prefix), encoding: .utf8) else { return nil }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), !path.contains("\0"), !URL(fileURLWithPath: path).pathComponents.contains("..") else { return nil }
        let snapshot = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let parent = prefix.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath().path
        var info = stat()
        guard snapshot.deletingLastPathComponent().resolvingSymlinksInPath().path == parent,
              snapshot.lastPathComponent.hasPrefix(prefix.lastPathComponent + ".backup."),
              lstat(snapshot.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              (try? store.requireLocal(snapshot)) != nil,
              fm.fileExists(atPath: snapshot.appendingPathComponent(readyName).path),
              fm.fileExists(atPath: snapshot.appendingPathComponent("drive_c").path),
              !fm.fileExists(atPath: snapshot.appendingPathComponent(markerName).path) else { return nil }
        return snapshot
    }

    /// The runtime's per-environment session lock, a sibling of the prefix that survives its creation and rename.
    static func lockURL(_ prefix: URL) -> URL {
        prefix.deletingLastPathComponent().appendingPathComponent(".\(prefix.lastPathComponent).hadron-session.lock")
    }

    /// Whether a supervisor holds the environment's session lock right now. The lock is only tested (taken and
    /// released at once), so this never blocks a session that starts afterwards for longer than the test itself.
    /// An absent lock file or one that cannot be opened counts as free: callers that must not race use `withEnvironmentFree`.
    static func isEnvironmentBusy(_ prefix: URL) -> Bool {
        let fd = Darwin.open(lockURL(prefix).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return errno == EWOULDBLOCK }
        flock(fd, LOCK_UN)
        return false
    }

    /// Runs `body` while holding the runtime's per-environment session lock (taken there with `lockf`, i.e. flock),
    /// so no Wine session can start or still be using the environment. An absent lock file means nobody holds it.
    /// A held lock throws `OrphanSession`: callers check the app's own sessions first, so the holder is one the
    /// app does not own (started by an earlier run of the app).
    static func withEnvironmentFree<T>(_ prefix: URL, _ body: () throws -> T) throws -> T {
        let lock = lockURL(prefix)
        let fd = Darwin.open(lock.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            guard errno == ENOENT else { throw AlchemacError.message("Wine 환경의 잠금 파일을 확인할 수 없습니다 (\(String(cString: strerror(errno)))).") }
            return try body()
        }
        defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw OrphanSession(prefix: prefix) }
        return try body()
    }

    /// "다시 시도": only the marker goes. `.hadron-prefix-ready` still holds the old id unless wineboot finished,
    /// so the runtime re-snapshots and re-runs `wineboot --update` on the next launch.
    static func clearMarker(_ prefix: URL) throws {
        try withEnvironmentFree(prefix) { try FileManager.default.removeItem(at: marker(prefix)) }
    }

    /// "업데이트 전 상태로 복원": the snapshot is cloned (it stays), the current environment goes to the Trash and the
    /// clone takes its place. At no point are both missing; each failure says what state things are in.
    static func restore(_ prefix: URL, from snapshot: URL) throws {
        let fm = FileManager.default
        try withEnvironmentFree(prefix) {
            let copy = prefix.deletingLastPathComponent().appendingPathComponent(prefix.lastPathComponent + ".alchemac-restore-" + UUID().uuidString, isDirectory: true)
            do { try fm.copyItem(at: snapshot, to: copy) } catch {
                try? fm.trashItem(at: copy, resultingItemURL: nil)
                throw AlchemacError.message("백업을 복사하지 못해 아무것도 바꾸지 않았습니다. 환경은 그대로입니다. (\(error.localizedDescription))")
            }
            do { try fm.trashItem(at: prefix, resultingItemURL: nil) } catch {
                try? fm.trashItem(at: copy, resultingItemURL: nil)
                throw AlchemacError.message("현재 환경을 휴지통으로 옮기지 못해 아무것도 바꾸지 않았습니다. 환경은 그대로입니다. (\(error.localizedDescription))")
            }
            do { try fm.moveItem(at: copy, to: prefix) } catch {
                throw AlchemacError.message("현재 환경은 휴지통으로 옮겼지만 복사본을 제자리로 옮기지 못했습니다. 휴지통의 환경을 되돌려 놓거나, 복사본 폴더 ‘\(copy.path)’의 이름을 ‘\(prefix.lastPathComponent)’로 바꿔 주세요. (\(error.localizedDescription))")
            }
        }
    }

    /// Free space is low enough for the watchdog (HADRON_DISK_MIN_GB, 5 GB by default) to stop a session soon
    /// after it starts. nil when the space cannot be read: the launch is not blocked then.
    static let minimumFreeBytes: Int64 = 6 << 30
    static func lowDiskError(availableBytes: Int64?) -> AlchemacError? {
        guard let bytes = availableBytes, bytes < minimumFreeBytes else { return nil }
        let gb = String(format: "%.1f", Double(bytes) / Double(1 << 30))
        return .message("디스크 여유 공간이 부족합니다 (남은 공간 약 \(gb) GB). 실행 중 여유 공간이 5GB 아래로 내려가면 프로그램이 자동으로 멈추므로, 6GB 이상 확보한 뒤 다시 실행해 주세요.")
    }

    /// Available capacity (counting purgeable space, like Finder) of the volume holding `url`, walking up to an existing folder.
    static func availableBytes(near url: URL) -> Int64? {
        var folder = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: folder.path), folder.pathComponents.count > 1 { folder.deleteLastPathComponent() }
        guard let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]) else { return nil }
        return values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init)
    }
}

/// The most recent run of a registered program that failed, until it runs again successfully or the user dismisses it.
struct RunFailure: Equatable {
    let date: Date
    let logs: [URL]
    let prefix: URL?
    /// The status text the failure produced.
    let summary: String
}

/// Programs in different Wine prefixes run side by side. standalone-run allows one
/// supervisor per prefix, so sessions are keyed by prefix and a second program in a
/// busy prefix is refused here with a clear message rather than by exit 75.
@MainActor
final class SessionController: ObservableObject {
    @Published private(set) var sessions: [String: Session] = [:]
    @Published var message = "프로그램을 선택한 뒤 실행해 주세요."
    /// Logs of the last run that failed or ended at once, until another run starts.
    @Published private(set) var lastProblemLogs: [URL] = []
    /// The Wine environment of that run when its failure points at the environment itself.
    @Published private(set) var lastProblemPrefix: URL?
    /// Per registered program (by launcher ID): its most recent failed run. Cleared when the program starts again or on `dismissFailure`.
    @Published private(set) var failures: [String: RunFailure] = [:]
    func dismissFailure(_ id: String) { failures[id] = nil }
    /// Runs when a run failed or ended at once, with the session that did (also for sessions without a registered program).
    var failed: ((Session, RunFailure) -> Void)?
    /// Runs when the last session has ended.
    var finished: (() -> Void)?
    private let runtime: URL
    /// `session-attach` processes still starting their program.
    private var attached: [Process] = []

    init(runtime: URL = AlchemacRuntime.root) { self.runtime = runtime }

    var busy: Bool { !sessions.isEmpty }
    /// Every remaining session is already being stopped.
    var allStopping: Bool { sessions.values.allSatisfy(\.stopping) }
    func session(in prefix: URL) -> Session? { sessions[prefix.standardizedFileURL.path] }
    func isRunning(_ id: String) -> Bool { sessions.values.contains { $0.launcherID == id } }

    func start(_ launcher: Launcher, store: LauncherStore) throws {
        try start(id: launcher.id, title: launcher.name,
                  running: "\(launcher.name) 실행 중 · 프로그램이 모두 끝날 때까지 세션을 유지합니다.") {
            try AlchemacRuntime.configure($0, launcher: launcher, store: store, runtime: self.runtime)
        }
    }

    /// `then` runs once on the main actor after the installer's whole Wine session ends.
    func install(_ setup: URL, environment: String?, store: LauncherStore, then: @escaping () -> Void) throws {
        let place = environment.map { "전용 Wine 환경 ‘\($0)’" } ?? "공용 Wine 환경"
        try start(id: nil, title: setup.lastPathComponent,
                  running: "\(setup.lastPathComponent) 설치 중 · \(place)에 설치합니다. 설치가 끝나면 새 프로그램 등록을 안내합니다.", then: then) {
            try AlchemacRuntime.configureInstaller($0, setup: setup, environment: environment, store: store, runtime: self.runtime)
        }
    }

    /// Runs another EXE in a registered program's Wine environment, marked as that program's session.
    func runTool(_ tool: URL, for launcher: Launcher, store: LauncherStore, then: @escaping () -> Void) throws {
        try start(id: launcher.id, title: tool.lastPathComponent,
                  running: "\(tool.lastPathComponent) 실행 중 · ‘\(launcher.name)’의 Wine 환경", then: then) {
            try AlchemacRuntime.configureTool($0, tool: tool, for: launcher, store: store, runtime: self.runtime)
        }
    }

    /// Starts another EXE inside the running session of that program's prefix. The supervisor
    /// already owns the session, so this short-lived process is not a session of its own.
    func attachTool(_ tool: URL, for launcher: Launcher, store: LauncherStore) throws {
        let next = Process()
        try AlchemacRuntime.configureAttachedTool(next, tool: tool, for: launcher, store: store, runtime: runtime)
        let name = tool.lastPathComponent
        next.standardOutput = FileHandle.nullDevice
        next.standardError = FileHandle.nullDevice
        next.terminationHandler = { [weak self] child in
            DispatchQueue.main.async {
                guard let self else { return }
                self.attached.removeAll { $0 === child }
                if child.terminationStatus == 75 {
                    self.message = "\(name): 실행 중인 세션에 합류하지 못했습니다. 프로그램 창이 뜬 뒤 다시 시도해 주세요."
                } else if child.terminationStatus != 0 {
                    self.message = "\(name): 실행하지 못했습니다 (코드 \(child.terminationStatus)). 진단 로그를 확인해 주세요."
                }
            }
        }
        try next.run()
        attached.append(next)
        message = "\(name) 실행 중 · ‘\(launcher.name)’ 세션에 합류했습니다."
    }

    /// Imports a .reg file into an environment; `then` runs after the Wine session ends.
    func applyRegistry(_ script: URL, prefix: URL, title: String, store: LauncherStore, then: @escaping () -> Void) throws {
        try start(id: nil, title: title, running: "\(title) 적용 중…", then: then) {
            try AlchemacRuntime.configureRegistry($0, prefix: prefix, script: script, store: store, runtime: self.runtime)
        }
    }

    /// Runs the program's registered uninstaller; `then` runs after its whole Wine session ends.
    func uninstall(_ launcher: Launcher, command: String, store: LauncherStore, then: @escaping () -> Void) throws {
        try start(id: launcher.id, title: launcher.name + " 제거",
                  running: "\(launcher.name) 제거 프로그램 실행 중 · 제거가 끝나면 목록을 정리합니다.", then: then) {
            try AlchemacRuntime.configureUninstall($0, launcher: launcher, command: command, store: store, runtime: self.runtime)
        }
    }

    /// Set while the startup cleanup of leftovers runs; no session starts meanwhile and the window says so.
    @Published var maintenance = false
    private var migrationPoll: Task<Void, Never>?

    private func start(id: String?, title: String, running: String, then: (() -> Void)? = nil, configure: (Process) throws -> Void) throws {
        if maintenance { throw AlchemacError.message("앱이 보관함을 준비하는 중입니다. 잠시 후 다시 실행해 주세요.") }
        let next = Process()
        try configure(next) // computes the process only; no filesystem change yet
        let prefix = URL(fileURLWithPath: next.environment!["WINEPREFIX"]!).standardizedFileURL.path
        if let current = sessions[prefix] {
            throw AlchemacError.message("같은 Wine 환경에서 실행 중인 프로그램이 있습니다: ‘\(current.title)’. 먼저 종료하거나, 이 프로그램을 전용 Wine 환경에 두면 동시에 실행할 수 있습니다.")
        }
        let prefixURL = URL(fileURLWithPath: prefix, isDirectory: true)
        // Not one of this run's sessions, yet the lock is held: a supervisor an earlier run of the app left behind.
        if PrefixMigration.isEnvironmentBusy(prefixURL) { throw OrphanSession(prefix: prefixURL) }
        if PrefixMigration.isInterrupted(prefixURL) { throw MigrationInterrupted(prefix: prefixURL) }
        // standalone-run's watchdog stops the session below 5 GB free, so refuse before starting a doomed run.
        if let error = PrefixMigration.lowDiskError(availableBytes: PrefixMigration.availableBytes(near: prefixURL.deletingLastPathComponent())) { throw error }
        // The private runtime copy is user-writable (Wine's Z:), so it must still equal the signed bundle before it runs again.
        var resetCopy = false
        if let support = next.environment?["HADRON_SUPPORT"] {
            resetCopy = try RuntimeCopy.verifyAndReset(support: URL(fileURLWithPath: support, isDirectory: true), prefix: prefixURL, runtime: runtime) != nil
        }
        let migrating = PrefixMigration.isMigrating(prefix: prefixURL, runtime: runtime)
        // Accepted: now the directories. (prefix-profile refreshes d3d9.dll itself, after the runtime's migration.)
        try AlchemacRuntime.beforeLaunch(next)
        let logs = URL(fileURLWithPath: next.environment!["HADRON_LOGS"]!, isDirectory: true)
        let outer = logs.appendingPathComponent("app-" + UUID().uuidString + ".log")
        guard FileManager.default.createFile(atPath: outer.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw AlchemacError.message("진단 로그 파일을 만들 수 없습니다.")
        }
        let handle = try FileHandle(forWritingTo: outer)
        next.standardOutput = handle
        next.standardError = handle
        next.terminationHandler = { [weak self] child in
            DispatchQueue.main.async { self?.ended(child, prefix: prefix) }
        }
        let session = Session(prefix: prefix, launcherID: id, title: title, process: next, output: handle, outerLog: outer)
        do { try next.run() } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: outer)
            throw error
        }
        session.after = then
        session.runningMessage = running
        if migrating {
            session.migrationRuntime = runtime
            session.migrationMessage = "\(title) 실행 준비 중 · 앱 업데이트 후 첫 실행이라 Wine 환경을 새 버전에 맞추고 있습니다. 몇 분 걸릴 수 있으니 끝날 때까지 종료하지 마세요."
        }
        lastProblemLogs = []; lastProblemPrefix = nil
        if let id { failures[id] = nil }
        sessions[prefix] = session
        message = migrating ? session.migrationMessage : running
        if resetCopy { message += "\n" + RuntimeCopy.resetNotice }
        if migrating { watchMigrations() }
    }

    /// While some session is migrating its Wine environment, looks every 2 s whether that is over.
    private func watchMigrations() {
        guard migrationPoll == nil else { return }
        migrationPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                if !self.checkMigrations() { self.migrationPoll = nil; return }
            }
        }
    }

    /// Ends the "do not quit" notice of every session whose migration is over. Returns whether any is still migrating.
    @discardableResult
    func checkMigrations() -> Bool {
        var pending = false
        for session in sessions.values where session.migrationRuntime != nil {
            if session.migrating { pending = true; continue }
            if let text = LaunchDiagnostics.settledMessage(current: message, migration: session.migrationMessage, running: session.runningMessage) { message = text }
            objectWillChange.send()
            session.migrationRuntime = nil
        }
        return pending
    }

    private func ended(_ child: Process, prefix: String) {
        guard let session = sessions[prefix], session.process === child else { return }
        session.deadline?.cancel()
        try? session.output.close()
        sessions[prefix] = nil
        let status = child.terminationStatus
        let stopped = status == 143 && session.stopping
        let reason = stopped ? nil : LaunchDiagnostics.report(for: session, failed: status != 0)
        switch status {
        case 0:
            message = reason.map { "\(session.title): " + $0 } ?? "\(session.title): 세션이 종료됐습니다."
        case 143 where session.stopping: message = "\(session.title): 세션을 종료했습니다."
        case 75:
            message = "\(session.title): 같은 Wine 환경의 세션이 이미 실행 중입니다. 기존 세션을 먼저 종료해 주세요."
            if let reason, !reason.hasPrefix("마지막 로그 줄") { message = "\(session.title): " + reason }
        default:
            message = "\(session.title): 실행이 종료됐습니다 (코드 \(status))." + (reason.map { "\n" + $0 } ?? " 진단 로그를 확인해 주세요.")
        }
        if !stopped, status != 0 || reason != nil {
            lastProblemLogs = [session.runtimeLog, session.outerLog].compactMap { $0 }
            let logText = LaunchDiagnostics.tail(session.outerLog) + "\n" + (session.runtimeLog.map { LaunchDiagnostics.tail($0) } ?? "")
            lastProblemPrefix = LaunchDiagnostics.wantsEnvironmentFolder(logText) ? URL(fileURLWithPath: prefix, isDirectory: true) : nil
            let failure = RunFailure(date: Date(), logs: lastProblemLogs, prefix: lastProblemPrefix, summary: message)
            if let id = session.launcherID { failures[id] = failure }
            failed?(session, failure)
        }
        session.after?()
        if sessions.isEmpty { finished?() }
    }

    func stop(_ session: Session) {
        guard session.process.isRunning, !session.stopping else { return }
        objectWillChange.send()
        session.stopping = true; message = "\(session.title): 세션을 종료하는 중입니다…"
        session.process.terminate()
        let work = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session, self.sessions[session.prefix] === session else { return }
            self.message = "\(session.title): 종료를 기다리고 있습니다. 세션 정리가 끝날 때까지 앱을 유지해 주세요."
        }
        session.deadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    func stopAll() { sessions.values.forEach(stop) }
}
