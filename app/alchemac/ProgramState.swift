import Foundation

// Pure rules behind the library window (no AppKit, no filesystem), so they can be tested on their own:
// what a program may do right now, what its row shows, the results inbox and the quit summary.

/// What the window needs to know about one Wine session.
struct SessionSnapshot: Equatable {
    /// The standardized path of the Wine environment the session holds.
    let prefix: String
    /// The registered program that started it; nil for installers, registry jobs and the like.
    let launcherID: String?
    let title: String
    let stopping: Bool
    /// The Wine environment is being updated to the new runtime before the program starts.
    let preparing: Bool

    enum Phase: String { case running = "실행 중", preparing = "준비 중", stopping = "종료 중" }
    var phase: Phase { stopping ? .stopping : preparing ? .preparing : .running }
}

/// What one program may do, from the registry entry, the sessions, the busy task, an update and the startup cleanup.
/// Every button and menu item asks this one place.
struct ProgramAvailability: Equatable {
    var canRun = false
    var runReason: String?
    var canStopEnvironment = false
    var canRename = false, canRemove = false
    var modifyReason: String?
    var canDelete = false
    var deleteReason: String?
    var canToggleRetina = false
    var retinaReason: String?
    var canToggleScaled = false
    var canRunTool = false
    var toolReason: String?
    /// The title of the session that holds this program's Wine environment, if any.
    var environmentSession: String?
    /// Whether that session was started by this very program.
    var ownSession = false

    static let retinaBusyReason = "이 환경의 프로그램이 모두 끝나면 바꿀 수 있습니다"

    /// `prefix`: the program's standardized Wine environment path; nil when it cannot be determined.
    /// `task`: the name of the task that holds the library (an import, a deletion, ...), nil when idle.
    static func make(launcherID: String, prefix: String?, sessions: [SessionSnapshot], task: String?, updating: Bool, maintenance: Bool) -> ProgramAvailability {
        var a = ProgramAvailability()
        let inEnvironment = prefix.flatMap { prefix in sessions.first { $0.prefix == prefix } }
        let own = sessions.contains { $0.launcherID == launcherID }
        a.environmentSession = inEnvironment?.title
        a.ownSession = own
        let locked: String? = updating ? "업데이트를 준비하는 중입니다" : task.map { "‘\($0)’ 작업이 끝난 뒤 다시 시도해 주세요" }

        // Run
        if let locked { a.runReason = locked }
        else if maintenance { a.runReason = "보관함을 준비하는 중입니다" }
        else if prefix == nil { a.runReason = "Wine 환경을 찾을 수 없습니다" }
        else if own { a.runReason = "이미 실행 중입니다" }
        else if let inEnvironment { a.runReason = "같은 Wine 환경에서 ‘\(inEnvironment.title)’ 실행 중" }
        a.canRun = a.runReason == nil

        // Stopping the environment is allowed while the library is busy: it only ends programs the user asked to end.
        a.canStopEnvironment = inEnvironment.map { !$0.stopping } ?? false

        // Rename / remove / delete
        if let locked { a.modifyReason = locked }
        else if own { a.modifyReason = "실행 중에는 바꿀 수 없습니다. 먼저 종료해 주세요" }
        a.canRename = a.modifyReason == nil
        a.canRemove = a.modifyReason == nil
        a.deleteReason = a.modifyReason ?? inEnvironment.map { "같은 Wine 환경에서 ‘\($0.title)’ 실행 중입니다. 먼저 종료해 주세요" }
        a.canDelete = a.deleteReason == nil

        // Display settings
        a.canToggleScaled = locked == nil
        if let locked { a.retinaReason = locked }
        else if prefix == nil { a.retinaReason = "Wine 환경을 찾을 수 없습니다" }
        else if inEnvironment != nil { a.retinaReason = retinaBusyReason }
        a.canToggleRetina = a.retinaReason == nil

        // Another EXE in the same environment: joins a running session, or starts one.
        if let locked { a.toolReason = locked }
        else if prefix == nil { a.toolReason = "Wine 환경을 찾을 수 없습니다" }
        else if let inEnvironment, inEnvironment.stopping { a.toolReason = "Wine 환경의 프로그램을 종료하는 중입니다" }
        else if inEnvironment == nil, maintenance { a.toolReason = "보관함을 준비하는 중입니다" }
        a.canRunTool = a.toolReason == nil
        return a
    }
}

/// What a program's row shows: at most one badge, or the name of the program that holds a shared Wine environment.
struct RowStatus: Equatable {
    enum Badge: Equatable { case running, preparing, stopping, failed }
    var badge: Badge?
    /// Another program started the session in this row's Wine environment.
    var sharedWith: String?

    static func make(launcherID: String, prefix: String?, sessions: [SessionSnapshot], failed: Bool) -> RowStatus {
        var status = RowStatus()
        if let own = sessions.first(where: { $0.launcherID == launcherID }) {
            switch own.phase { case .running: status.badge = .running; case .preparing: status.badge = .preparing; case .stopping: status.badge = .stopping }
            return status
        }
        if let prefix, let other = sessions.first(where: { $0.prefix == prefix }) { status.sharedWith = other.title; return status }
        if failed { status.badge = .failed }
        return status
    }

    static func badgeText(_ badge: Badge) -> String {
        switch badge { case .running: return "실행 중"; case .preparing: return "준비 중"; case .stopping: return "종료 중"; case .failed: return "실행 오류" }
    }

    /// The precise wording, for tooltips and accessibility only. `time` is the failure time, already formatted.
    static func help(_ badge: Badge, time: String?) -> String {
        switch badge {
        case .running: return "이 프로그램이 시작한 Wine 세션이 실행 중입니다."
        case .preparing: return "앱을 업데이트한 뒤 첫 실행이라 Wine 환경을 새 버전에 맞추는 중입니다. 끝날 때까지 종료하지 마세요."
        case .stopping: return "이 Wine 환경의 프로그램을 종료하는 중입니다."
        case .failed: return "가장 최근 실행이 오류로 끝났습니다" + (time.map { " (\($0))" } ?? "") + ". 오른쪽 클릭으로 오류 로그를 볼 수 있습니다."
        }
    }

    static func sharedText(_ title: String) -> String { "같은 Wine 환경에서 ‘\(title)’ 실행 중" }
}

/// Sessions with no row in the list (installers, tools, registry jobs): shown in their own area under the list.
enum UnregisteredSessions {
    static func filter(_ sessions: [SessionSnapshot], registered: Set<String>) -> [SessionSnapshot] {
        sessions.filter { $0.launcherID.map { !registered.contains($0) } ?? true }.sorted { ($0.title, $0.prefix) < ($1.title, $1.prefix) }
    }
}

// MARK: Results inbox

struct ResultItem: Identifiable {
    enum Kind {
        /// `launcherID` is the program whose row shows the failure badge, nil for sessions without a row.
        case launchFailure(program: String, launcherID: String?, environment: String, logs: [URL], detail: String)
        /// An installer ended; its candidates are re-checked when the chooser opens again.
        case installFinished(installer: String, environment: String, environmentName: String?, candidates: [InstalledCandidate])
        case updateAvailable(UpdateManifest)
        /// Anything else that would have been an alert.
        case notice(title: String, text: String)
    }
    let id = UUID()
    var date: Date
    var kind: Kind

    /// Two items with the same key are the same event: the newer replaces the older.
    var key: String {
        switch kind {
        case .launchFailure(let program, let id, let environment, _, _): return "fail:\(id ?? program):\(environment)"
        case .installFinished(let installer, _, let name, _): return "install:\(name ?? ""):\(installer)"
        case .updateAvailable(let manifest): return "update:\(manifest.build)"
        case .notice(let title, _): return "notice:\(title)"
        }
    }
}

enum ResultsInbox {
    static let limit = 30

    /// Adds `item`, or replaces the item with the same key (keeping its place). Returns false when nothing changed
    /// (an update already listed for the same build).
    @discardableResult
    static func add(_ item: ResultItem, to items: inout [ResultItem]) -> Bool {
        if let index = items.firstIndex(where: { $0.key == item.key }) {
            if case .updateAvailable = item.kind { return false }
            items[index] = item
            return true
        }
        items.append(item)
        if items.count > limit { items.removeFirst(items.count - limit) }
        return true
    }

    static func remove(_ id: UUID, from items: inout [ResultItem]) { items.removeAll { $0.id == id } }

    /// While the library window is visible and the app is active the user sees what happens at once (an alert, the status line):
    /// nothing is added to the inbox then. Otherwise it is added and no modal alert appears.
    static func shouldStore(windowVisible: Bool, appActive: Bool) -> Bool { !(windowVisible && appActive) }

    /// Candidates whose EXE still exists, for re-opening the chooser. `exists` is injected for tests.
    static func remainingCandidates(_ candidates: [InstalledCandidate], exists: (URL) -> Bool) -> [InstalledCandidate] {
        candidates.filter { exists($0.exe) }
    }
}

// MARK: Quit summary

enum QuitSummary {
    static let title = "실행 중인 프로그램을 모두 종료하고 Alchemac을 종료할까요?"
    static let confirmButton = "모두 종료하고 Alchemac 종료"

    /// `place`: the plain name of a session's Wine environment.
    static func text(sessions: [SessionSnapshot], place: (String) -> String, migrating: Bool) -> String {
        var text = "아래 Wine 환경에서 Alchemac이 시작한 프로그램이 모두 종료됩니다. 열려 있는 작업이나 게임을 먼저 저장해 주세요. 모두 끝난 뒤 앱이 종료됩니다.\n\n"
        text += sessions.sorted { ($0.title, $0.prefix) < ($1.title, $1.prefix) }
            .map { "• \(place($0.prefix)) — \($0.title) (\($0.phase.rawValue))" }.joined(separator: "\n")
        if migrating {
            text += "\n\n지금은 앱 업데이트 후 Wine 환경을 새 버전에 맞추는 중입니다. 지금 종료하면 이 업데이트가 중단되며, 다음 실행 때 다시 시도하거나 업데이트 전 상태로 복원할 수 있습니다."
        }
        return text
    }
}

extension Session {
    /// `accurate` reads the environment's files to tell whether it is still being updated; the cheap form only knows an update was started.
    func snapshot(accurate: Bool = false) -> SessionSnapshot {
        SessionSnapshot(prefix: prefix, launcherID: launcherID, title: title, stopping: stopping,
                        preparing: accurate ? migrating : migrationRuntime != nil)
    }
}
