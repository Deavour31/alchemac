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
    var after: (() -> Void)?
    var deadline: DispatchWorkItem?

    init(prefix: String, launcherID: String?, title: String, process: Process, output: FileHandle) {
        self.prefix = prefix; self.launcherID = launcherID; self.title = title; self.process = process; self.output = output
    }
}

/// Programs in different Wine prefixes run side by side. standalone-run allows one
/// supervisor per prefix, so sessions are keyed by prefix and a second program in a
/// busy prefix is refused here with a clear message rather than by exit 75.
@MainActor
final class SessionController: ObservableObject {
    @Published private(set) var sessions: [String: Session] = [:]
    @Published var message = "프로그램을 선택한 뒤 실행해 주세요."
    /// Runs when the last session has ended.
    var finished: (() -> Void)?
    private let runtime: URL

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

    private func start(id: String?, title: String, running: String, then: (() -> Void)? = nil, configure: (Process) throws -> Void) throws {
        let next = Process()
        try configure(next)
        let prefix = URL(fileURLWithPath: next.environment!["WINEPREFIX"]!).standardizedFileURL.path
        if let current = sessions[prefix] {
            throw AlchemacError.message("같은 Wine 환경에서 ‘\(current.title)’이(가) 실행 중입니다. 먼저 종료하거나, 이 프로그램을 전용 Wine 환경에 두면 동시에 실행할 수 있습니다.")
        }
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
        let session = Session(prefix: prefix, launcherID: id, title: title, process: next, output: handle)
        do { try next.run() } catch {
            try? handle.close()
            throw error
        }
        session.after = then
        sessions[prefix] = session
        message = running
    }

    private func ended(_ child: Process, prefix: String) {
        guard let session = sessions[prefix], session.process === child else { return }
        session.deadline?.cancel()
        try? session.output.close()
        sessions[prefix] = nil
        switch child.terminationStatus {
        case 0: message = "\(session.title): 세션이 종료됐습니다."
        case 143 where session.stopping: message = "\(session.title): 세션을 종료했습니다."
        case 75: message = "\(session.title): 같은 Wine 환경의 세션이 이미 실행 중입니다. 기존 세션을 먼저 종료해 주세요."
        default: message = "\(session.title): 실행이 종료됐습니다 (코드 \(child.terminationStatus)). 진단 로그를 확인해 주세요."
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
