import AppKit
import SwiftUI

@MainActor
final class LibraryModel: ObservableObject {
    let store: LauncherStore
    let session = SessionController()
    @Published var registry: Registry
    @Published var importing = false
    @Published var importMessage = ""
    /// Programs' own icons, filled in after extraction; the list shows a symbol until then.
    @Published var icons: [String: NSImage] = [:]

    /// Environment names for the Wine environment menu, "" first for the shared one.
    @Published var environmentNames: [String] = [""]
    /// Retina mode per Wine prefix path: shared, dedicated and programs' own prefixes.
    @Published var retina: [String: Bool] = [:]

    init(store: LauncherStore) throws { self.store = store; registry = try store.read(); refreshRetina(); refreshAddons() }
    func loadIcon(_ launcher: Launcher) async {
        guard icons[launcher.id] == nil, let exe = try? store.executable(launcher), let dir = try? store.directory(launcher) else { return }
        let png = await Task.detached(priority: .utility) { ExeIcon.cachedPNG(exe: exe, dir: dir) }.value
        if let png, let image = NSImage(data: png) { icons[launcher.id] = image }
    }
    func refreshRetina() {
        environmentNames = [""] + store.environments()
        var states: [String: Bool] = [:]
        var prefixes = environmentNames.map { store.prefix(environment: $0.isEmpty ? nil : $0) }
        prefixes += registry.launchers.filter(\.privatePrefix).compactMap { try? store.prefix($0) }
        for prefix in prefixes { states[prefix.standardizedFileURL.path] = store.retinaEnabled(prefix: prefix) }
        retina = states
    }
    func retinaOn(prefix: URL) -> Bool { retina[prefix.standardizedFileURL.path] == true }
    func retinaOn(environment: String?) -> Bool { retinaOn(prefix: store.prefix(environment: environment)) }
    func retinaOn(_ launcher: Launcher) -> Bool { (try? store.prefix(launcher)).map(retinaOn(prefix:)) ?? false }
    func place(_ environment: String?) -> String { environment.map { "전용 Wine 환경 ‘\($0)’" } ?? "공용 Wine 환경" }
    func place(_ launcher: Launcher) -> String { launcher.privatePrefix ? "‘\(launcher.name)’ 전용 Wine 환경" : place(launcher.environment) }
    func toggleRetina(environment: String?) { toggleRetina(prefix: store.prefix(environment: environment), place: place(environment)) }
    func toggleRetina(_ launcher: Launcher) {
        guard let prefix = try? store.prefix(launcher) else { return }
        toggleRetina(prefix: prefix, place: place(launcher))
    }
    func toggleRetina(prefix: URL, place: String) {
        guard FileManager.default.fileExists(atPath: prefix.appendingPathComponent("system.reg").path) else {
            self.error(AlchemacError.message("\(place)이 아직 만들어지지 않았습니다. 프로그램을 한 번 실행한 뒤 다시 시도해 주세요.")); return
        }
        applyRetina(!retinaOn(prefix: prefix), prefix: prefix, place: place) { _ in }
    }
    /// Switches a prefix's Retina mode with regedit; creates the environment if it is new.
    func applyRetina(_ on: Bool, prefix: URL, place: String, then: @escaping (Bool) -> Void) {
        var script: URL?
        do {
            let file = try store.registryScript(LauncherStore.retinaRegistry(on: on))
            script = file
            try session.applyRegistry(file, prefix: prefix, title: place + (on ? " 선명한 화면 켜기" : " 선명한 화면 끄기"), store: store) { [weak self] in
                try? FileManager.default.removeItem(at: file)
                guard let self else { return }
                self.refreshRetina()
                let ok = self.retinaOn(prefix: prefix) == on
                self.session.message += ok
                    ? "\n\(place)의 선명한 화면을 \(on ? "켰습니다" : "껐습니다"). 다음에 실행하는 프로그램부터 적용됩니다."
                    : "\n설정이 적용되지 않았습니다. 진단 로그를 확인해 주세요."
                then(ok)
            }
        } catch {
            if let script { try? FileManager.default.removeItem(at: script) }
            self.error(error); then(false)
        }
    }
    /// Add-ons, refreshed whenever they change.
    @Published var addons: [Addon] = []
    func refreshAddons() { addons = store.installedAddons() }
    func installAddon() {
        let panel = NSOpenPanel()
        panel.title = "애드온(.alchemacaddon) 선택"
        panel.message = "애드온은 프로그램별 실행 설정만 담고 있으며 코드를 실행하지 않습니다."
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let addon = try store.installAddon(from: url)
            refreshAddons()
            session.message = "애드온 ‘\(addon.name)’ \(addon.version)을(를) 설치했습니다." + (addon.summary.map { "\n" + $0 } ?? "")
        } catch { self.error(error) }
    }
    func removeAddon(_ addon: Addon) {
        let users = registry.launchers.filter { $0.addon == addon.id }
        let alert = NSAlert(); alert.messageText = "애드온 ‘\(addon.name)’을(를) 제거할까요?"
        alert.informativeText = users.isEmpty
            ? "애드온 설정만 휴지통으로 옮깁니다."
            : "이 애드온을 쓰는 프로그램(\(users.map(\.name).joined(separator: ", ")))은 애드온을 다시 설치할 때까지 실행할 수 없습니다. 프로그램 파일과 Wine 환경은 그대로입니다."
        alert.addButton(withTitle: "제거"); alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: store.addonFolder(addon.id), resultingItemURL: nil)
            refreshAddons(); session.message = "애드온 ‘\(addon.name)’을(를) 제거했습니다."
        } catch { self.error(error) }
    }
    func revealEnvironment(_ environment: String?) { NSWorkspace.shared.open(store.prefix(environment: environment)) }
    /// Moves a dedicated environment no registered program uses to the Trash.
    func deleteEnvironment(_ name: String) {
        if let user = registry.launchers.first(where: { !$0.privatePrefix && $0.environment == name }) {
            self.error(AlchemacError.message("‘\(user.name)’이(가) 이 환경을 사용합니다. 그 프로그램을 먼저 삭제하거나 목록에서 제거해 주세요.")); return
        }
        if let running = session.session(in: store.prefix(environment: name)) {
            self.error(AlchemacError.message("이 환경에서 ‘\(running.title)’이(가) 실행 중입니다. 세션을 먼저 종료해 주세요.")); return
        }
        let prefix = store.prefix(environment: name)
        if PrefixMigration.isEnvironmentBusy(prefix) { self.error(OrphanSession(prefix: prefix)); return }
        do {
            let folders = try store.environmentFolders(name)
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.messageText = "전용 Wine 환경 ‘\(name)’을(를) 삭제할까요?"
            alert.informativeText = "환경 안에 설치된 파일과 설정, 백업(약 \(Self.size(store.allocatedSize(folders))))을 휴지통으로 옮깁니다."
            alert.addButton(withTitle: "휴지통으로 옮기기"); alert.addButton(withTitle: "취소")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            importing = true; importMessage = "휴지통으로 옮기는 중입니다…"
            DispatchQueue.global(qos: .userInitiated).async {
                // Under the session lock: a supervisor started after the check above makes this fail instead of pulling the folder away.
                let result = Result { try PrefixMigration.withEnvironmentFree(prefix) { try folders.forEach { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) } } }
                DispatchQueue.main.async {
                    self.importing = false; self.refreshRetina()
                    switch result {
                    case .success: self.session.message = "전용 Wine 환경 ‘\(name)’을(를) 휴지통으로 옮겼습니다."
                    case .failure(let error): self.session.message = "삭제하지 못했습니다."; self.error(error)
                    }
                }
            }
        } catch { self.error(error) }
    }
    func toggleScaled() {
        guard let selected, let index = registry.launchers.firstIndex(where: { $0.id == selected.id }) else { return }
        registry.launchers[index].scaled.toggle(); save()
        session.message = registry.launchers[index].scaled
            ? "\(selected.name): 크기 보정을 켰습니다. 다음 실행부터 Windows처럼 확대해 표시합니다(조금 흐릴 수 있습니다)."
            : "\(selected.name): 크기 보정을 껐습니다. 다음 실행부터 프로그램 자체 해상도로 표시합니다."
    }
    var selected: Launcher? { registry.launchers.first { $0.id == registry.selectedID } }

    func error(_ error: Error) {
        if let interrupted = error as? MigrationInterrupted { recoverMigration(interrupted.prefix, retry: nil); return }
        if let orphan = error as? OrphanSession { offerOrphanStop([(environmentTitle(orphan.prefix), orphan.prefix)], startup: false); return }
        let alert = NSAlert(); alert.messageText = "작업을 완료하지 못했습니다"
        alert.informativeText = error.localizedDescription; alert.runModal()
    }
    /// Offered when a runtime migration of a Wine environment was interrupted and its marker blocks every launch.
    /// `retry` starts the program again after "다시 시도". Synchronous: the restore is an APFS clone and two renames.
    func recoverMigration(_ prefix: URL, retry: (() -> Void)?) {
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "이 Wine 환경의 업데이트가 중간에 멈췄습니다"
        alert.informativeText = "앱을 업데이트한 뒤 첫 실행에서 Wine 환경을 새 버전에 맞추는 작업이 끝나기 전에 중단돼 환경이 잠겨 있습니다. ‘다시 시도’는 작업을 처음부터 다시 하고, ‘업데이트 전 상태로 복원’은 작업 직전에 만들어 둔 백업으로 환경을 되돌립니다."
        alert.addButton(withTitle: "다시 시도"); alert.addButton(withTitle: "업데이트 전 상태로 복원"); alert.addButton(withTitle: "취소")
        let choice = alert.runModal()
        guard choice == .alertFirstButtonReturn || choice == .alertSecondButtonReturn else { return }
        func fail(_ text: String) {
            let failed = NSAlert(); failed.alertStyle = .warning; failed.messageText = "작업을 완료하지 못했습니다"; failed.informativeText = text; failed.runModal()
        }
        guard session.session(in: prefix) == nil else { return fail("이 환경을 쓰는 프로그램이 실행 중입니다. 먼저 종료해 주세요.") }
        if choice == .alertFirstButtonReturn {
            do { try PrefixMigration.clearMarker(prefix) } catch { if error is OrphanSession { self.error(error); return }; return fail(error.localizedDescription) }
            if let retry { retry() } else { session.message = "업데이트 잠금을 풀었습니다. 프로그램을 다시 실행해 주세요." }
            return
        }
        guard let snapshot = PrefixMigration.snapshot(for: prefix, store: store) else {
            return fail("기록된 백업 폴더를 복원에 쓸 수 없습니다. 백업이 없어졌거나 이 환경의 백업이 아닙니다. 아무것도 바꾸지 않았습니다. ‘다시 시도’를 고르거나, 환경 폴더 옆의 ‘.backup.’ 폴더를 확인해 주세요.")
        }
        let confirm = NSAlert(); confirm.alertStyle = .warning; confirm.messageText = "업데이트 전 상태로 복원할까요?"
        confirm.informativeText = "지금 환경은 휴지통으로 옮기고, 백업 ‘\(snapshot.lastPathComponent)’을(를) 복사해 그 자리에 둡니다. 백업 폴더는 그대로 남습니다."
        confirm.addButton(withTitle: "복원"); confirm.addButton(withTitle: "취소")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        do {
            try PrefixMigration.restore(prefix, from: snapshot)
            session.message = "업데이트 전 상태로 복원했습니다. 다시 실행하면 새 버전에 맞추는 작업을 처음부터 다시 합니다."
        } catch { if error is OrphanSession { self.error(error) } else { fail(error.localizedDescription) } }
    }
    /// Tells the user once what `LauncherStore.read()` repaired; called after the window is up.
    func showRecoveryNotice() {
        guard let text = store.recoveryNotice else { return }
        let alert = NSAlert(); alert.alertStyle = .informational; alert.messageText = "프로그램 목록을 복구했습니다"
        alert.informativeText = text; alert.runModal()
    }
    // MARK: Sessions an earlier run of the app left behind

    func environmentTitle(_ prefix: URL) -> String {
        store.knownEnvironments(registry).first { $0.prefix.standardizedFileURL == prefix.standardizedFileURL }?.title ?? prefix.lastPathComponent
    }
    /// Environments whose session lock is held although this run of the app has no session there.
    func orphanedEnvironments() -> [(title: String, prefix: URL)] {
        store.knownEnvironments(registry).filter { session.session(in: $0.prefix) == nil && PrefixMigration.isEnvironmentBusy($0.prefix) }
    }
    /// At launch (`startup`) only speaks up when something is left; the menu item also says when nothing is.
    func checkOrphans(startup: Bool) {
        let found = orphanedEnvironments()
        if !found.isEmpty { offerOrphanStop(found, startup: startup); return }
        guard !startup else { return }
        let alert = NSAlert(); alert.alertStyle = .informational; alert.messageText = "남은 세션이 없습니다"
        alert.informativeText = "이전에 시작한 Wine 세션이 이 환경들을 쓰고 있지 않습니다."; alert.runModal()
    }
    func offerOrphanStop(_ found: [(title: String, prefix: URL)], startup: Bool) {
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "이전에 시작한 세션이 아직 실행 중입니다"
        alert.informativeText = "Alchemac이 예기치 않게 종료됐지만 Wine 세션이 남아 있습니다. 그동안 이 환경에서는 프로그램 실행, 삭제, 설정 변경을 할 수 없습니다.\n"
            + found.map { "• " + $0.title }.joined(separator: "\n")
            + "\n\n‘남은 세션 종료’는 이 환경에서 실행 중인 Wine 프로그램을 모두 닫습니다. 열려 있는 작업이 있다면 먼저 저장해 주세요."
        alert.addButton(withTitle: "남은 세션 종료"); alert.addButton(withTitle: startup ? "나중에" : "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        stopOrphans(found)
    }
    /// Sends TERM to each verified supervisor, then waits (up to 30 s, without blocking the window) for its lock to be free.
    func stopOrphans(_ found: [(title: String, prefix: URL)]) {
        var signaled: [(title: String, prefix: URL)] = [], unverified: [String] = []
        for item in found where PrefixMigration.isEnvironmentBusy(item.prefix) {
            if OrphanSessions.terminate(support: store.support, prefix: item.prefix) { signaled.append(item) } else { unverified.append(item.title) }
        }
        importing = true; importMessage = "남은 세션을 종료하는 중입니다…"
        Task {
            var stuck: [String] = []
            for item in signaled where !(await OrphanSessions.waitUntilFree(item.prefix)) { stuck.append(item.title) }
            self.importing = false; self.refreshRetina()
            var problems: [String] = []
            if !unverified.isEmpty { problems.append("다음 환경은 남은 세션의 프로세스를 확인하지 못해 아무것도 종료하지 않았습니다. Mac을 다시 시작해 주세요.\n" + unverified.map { "• " + $0 }.joined(separator: "\n")) }
            if !stuck.isEmpty { problems.append("세션이 아직 끝나지 않았습니다. 잠시 후 다시 시도하거나 Mac을 다시 시작해 주세요.\n" + stuck.map { "• " + $0 }.joined(separator: "\n")) }
            if problems.isEmpty { self.session.message = "남은 세션을 종료했습니다."; return }
            self.session.message = "남은 세션을 모두 종료하지 못했습니다."
            let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "남은 세션을 모두 종료하지 못했습니다"
            alert.informativeText = problems.joined(separator: "\n\n"); alert.runModal()
        }
    }

    // MARK: Cleanup of leftovers

    /// Once per launch, in the background. No session starts while it runs (SessionController.maintenance), which
    /// gives the user a clear message instead of the runtime's busy exit.
    func startCleanup() {
        guard !session.maintenance else { return }
        session.maintenance = true
        let store = self.store, runtime = AlchemacRuntime.root
        DispatchQueue.global(qos: .utility).async {
            let summary = StartupCleanup.run(store: store, runtime: runtime)
            DispatchQueue.main.async {
                self.session.maintenance = false
                if summary.freed > 500_000_000, !self.session.busy { self.session.message = "이전 실행 환경 사본 등 약 \(Self.size(summary.freed))를 정리했습니다." }
            }
        }
    }

    // MARK: Backups

    /// "환경 백업 정리…": keeps the newest snapshot of each environment and moves the others to the Trash.
    func manageBackups() {
        let environments = store.knownEnvironments(registry), store = self.store
        importing = true; importMessage = "환경 백업을 찾는 중입니다…"
        DispatchQueue.global(qos: .userInitiated).async {
            let found = environments.map { (environment: $0, snapshots: Backups.snapshots(of: $0.prefix)) }.filter { !$0.snapshots.isEmpty }
            let sizes = found.map { store.allocatedSize($0.snapshots.map(\.url)) }
            DispatchQueue.main.async { self.importing = false; self.offerBackupCleanup(found, sizes: sizes) }
        }
    }
    private func offerBackupCleanup(_ found: [(environment: (title: String, prefix: URL), snapshots: [Backups.Snapshot])], sizes: [Int64]) {
        let alert = NSAlert()
        guard found.contains(where: { $0.snapshots.count > 1 }) else {
            alert.messageText = "정리할 환경 백업이 없습니다"
            alert.informativeText = found.isEmpty ? "환경 옆에 업데이트 전 백업(‘.backup.’ 폴더)이 없습니다." : "백업이 환경마다 1개뿐이라 남길 것만 있습니다."
            alert.runModal(); return
        }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let lines = zip(found, sizes).map { entry, size -> String in
            let newest = Backups.newest(entry.snapshots)?.date.map { formatter.string(from: $0) } ?? "날짜 알 수 없음"
            return "• \(entry.environment.title): 백업 \(entry.snapshots.count)개 · 가장 최근 \(newest) · 합계 약 \(Self.size(size))"
        }
        alert.alertStyle = .warning
        alert.messageText = "환경 백업을 정리할까요?"
        alert.informativeText = lines.joined(separator: "\n")
            + "\n\n환경마다 가장 최근 백업 1개만 남기고 나머지는 휴지통으로 옮깁니다. 휴지통에서 되살릴 수 있습니다. 업데이트가 중단된 환경이 복원에 쓸 백업은 항상 남깁니다. 백업은 APFS 복제본이라 공간을 서로 나눠 쓰므로 실제로 비워지는 공간은 더 작을 수 있습니다. 세션이 실행 중인 환경은 건너뜁니다."
        alert.addButton(withTitle: "가장 최근 백업만 남기기"); alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let environments = found.map(\.environment)
        importing = true; importMessage = "백업을 휴지통으로 옮기는 중입니다…"
        DispatchQueue.global(qos: .userInitiated).async {
            var moved = 0, busy: [String] = [], failed: [String] = []
            for environment in environments {
                do {
                    // Recomputed under the session lock, so the choice matches what is on disk when it is applied.
                    try PrefixMigration.withEnvironmentFree(environment.prefix) {
                        for url in Backups.removable(Backups.snapshots(of: environment.prefix), protected: Backups.protected(environment.prefix)) {
                            try FileManager.default.trashItem(at: url, resultingItemURL: nil); moved += 1
                        }
                    }
                } catch is OrphanSession { busy.append(environment.title) }
                catch { failed.append(environment.title + " (" + error.localizedDescription + ")") }
            }
            let result = (moved, busy, failed)
            DispatchQueue.main.async {
                self.importing = false
                var text = "백업 \(result.0)개를 휴지통으로 옮겼습니다."
                if !result.1.isEmpty { text += "\n세션이 실행 중이라 건너뜀: " + result.1.joined(separator: ", ") }
                if !result.2.isEmpty { text += "\n옮기지 못함: " + result.2.joined(separator: ", ") }
                self.session.message = text
                if !result.1.isEmpty || !result.2.isEmpty {
                    let note = NSAlert(); note.alertStyle = .warning; note.messageText = "일부 환경의 백업을 정리하지 못했습니다"; note.informativeText = text; note.runModal()
                }
            }
        }
    }

    func save() { do { try store.write(registry) } catch { self.error(error) } }
    func start() {
        guard let selected else { return }
        // An add-on can ask for an English layout for programs that fail on a Korean one.
        let wantsEnglish = selected.addon.flatMap(store.addon)?.englishInput ?? false
        let switched = wantsEnglish ? EnglishInput.ensure() : nil
        do { try session.start(selected, store: store) }
        catch let interrupted as MigrationInterrupted {
            recoverMigration(interrupted.prefix) { [weak self] in self?.start() }
            return
        } catch { self.error(error); return }
        if let exe = try? store.executable(selected), let prefix = try? store.prefix(selected), store.needsWineMono(exe, in: prefix) {
            session.message += "\n.NET 실행 환경(Wine Mono)을 처음 한 번 설치합니다. 창이 뜰 때까지 1~2분 걸립니다."
        }
        if let switched {
            session.message += "\n입력기를 \(switched)(으)로 바꿨습니다. 이 프로그램 창은 영문 입력 상태에서 눌러 주세요. 한글 입력 상태에서는 오류가 날 수 있습니다."
        }
    }
    /// The session holding the selected program's Wine environment, if any.
    var selectedSession: Session? {
        guard let selected, let prefix = try? store.prefix(selected) else { return nil }
        return session.session(in: prefix)
    }
    func stop() {
        guard let running = selectedSession else { return }
        let alert = NSAlert(); alert.messageText = "‘\(running.title)’ 세션을 종료할까요?"
        alert.informativeText = "열려 있는 작업이나 게임이 있다면 먼저 저장해 주세요. 같은 Wine 환경에서 이 앱이 시작한 프로그램이 함께 종료되고, 다른 환경의 프로그램은 계속 실행됩니다."
        if running.migrating {
            alert.informativeText += "\n\n지금은 앱 업데이트 후 Wine 환경을 새 버전에 맞추는 중입니다. 지금 종료하면 이 업데이트가 중단되며, 다음 실행 때 다시 시도하거나 업데이트 전 상태로 복원할 수 있습니다."
        }
        alert.addButton(withTitle: "세션 종료"); alert.addButton(withTitle: "취소")
        if alert.runModal() == .alertFirstButtonReturn { session.stop(running) }
    }
    func add() {
        let panel = NSOpenPanel()
        panel.title = "등록할 Windows 프로그램(.exe) 선택"
        panel.message = "설치한 프로그램은 해당 Wine 환경의 Program Files에서 고르세요. 그 밖의 EXE는 폴더를 보관함에 복사합니다. 설치된 애드온이 있는 프로그램은 그 설정으로 등록됩니다."
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.treatsFilePackagesAsDirectories = true
        let programs = store.sharedPrefix.appendingPathComponent("drive_c/Program Files", isDirectory: true)
        if FileManager.default.fileExists(atPath: programs.path) { panel.directoryURL = programs }
        guard panel.runModal() == .OK, let file = panel.url else { return }
        // An EXE inside a Wine environment belongs to it; a copied folder can run in any.
        var choice = EnvironmentChoice(name: nil, fresh: false, retina: false)
        if store.matchingAddon(file) == nil, store.installedLocation(of: file) == nil {
            guard let picked = chooseEnvironment(for: file, purpose: "복사한 프로그램을 실행할 Wine 환경을 선택해 주세요.") else { return }
            choice = picked
        }
        prepare(choice) { [weak self] in self?.importProgram(file, environment: choice.name) }
    }
    private func importProgram(_ file: URL, environment: String?) {
        importing = true; importMessage = "프로그램을 보관함에 등록하는 중입니다…"
        let store = self.store
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try store.importProgram(from: file, environment: environment) }
            DispatchQueue.main.async {
                self.importing = false
                switch result {
                case .success(let launcher):
                    self.registry.launchers.append(launcher); self.registry.selectedID = launcher.id; self.save()
                    self.session.message = "\(launcher.name)을(를) 등록했습니다. 원본 파일은 그대로 보존됩니다."
                case .failure(let error): self.session.message = "가져오지 못했습니다."; self.error(error)
                }
            }
        }
    }
    func install() {
        let panel = NSOpenPanel()
        panel.title = "Windows 설치 파일(.exe) 선택"
        panel.message = "다음 단계에서 설치할 Wine 환경을 선택합니다. 설치 파일은 수정하지 않습니다."
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let file = panel.url else { return }
        guard let choice = chooseEnvironment(for: file, purpose: "어느 Wine 환경에 설치할까요?") else { return }
        prepare(choice) { [weak self] in
            guard let self else { return }
            let environment = choice.name, before = self.store.installedExecutables(in: environment)
            do {
                try self.session.install(file, environment: environment, store: self.store) { [weak self] in self?.offerInstalled(since: before, in: environment) }
            } catch { self.error(error) }
        }
    }
    /// Runs a patch or tool EXE in the selected program's own Wine environment.
    func runTool() {
        guard let launcher = selected else { return }
        let panel = NSOpenPanel()
        panel.title = "‘\(launcher.name)’ 환경에서 실행할 EXE 선택"
        panel.message = "패치나 도구를 이 프로그램과 같은 Wine 환경에서 실행합니다. 프로그램이 실행 중이면 그 세션에 합류합니다. 선택한 파일은 수정하지 않습니다."
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let file = panel.url else { return }
        if let id = launcher.addon, store.addon(id)?.englishInput == true, let name = EnglishInput.ensure() {
            session.message = "입력 소스를 ‘\(name)’(으)로 바꿨습니다."
        }
        do {
            if let running = selectedSession {
                guard !running.stopping else { throw AlchemacError.message("세션을 종료하는 중입니다. 끝난 뒤 다시 시도해 주세요.") }
                try session.attachTool(file, for: launcher, store: store)
            } else {
                try session.runTool(file, for: launcher, store: store) { [weak self] in self?.refreshRetina() }
            }
            if let prefix = try? store.prefix(launcher), store.needsWineMono(file, in: prefix) {
                session.message += "\n.NET 실행 환경(Wine Mono)을 처음 한 번 설치합니다. 창이 뜰 때까지 1~2분 걸립니다."
            }
            if launcher.kind == .copied, let game = try? store.game(launcher) {
                session.message += "\n프로그램 폴더를 물으면 \(AlchemacRuntime.windows(game)) 를 지정하세요."
            }
        } catch { self.error(error) }
    }
    struct EnvironmentChoice {
        /// nil is the shared environment.
        let name: String?
        /// A dedicated environment that does not exist yet.
        let fresh: Bool
        /// Create it in Retina mode before anything runs in it.
        let retina: Bool
    }
    /// nil when cancelled.
    func chooseEnvironment(for file: URL, purpose: String) -> EnvironmentChoice? {
        let fresh = store.newEnvironmentName(for: file)
        let existing = store.environments()
        let alert = NSAlert(); alert.messageText = purpose
        alert.informativeText = "공용 환경은 여러 프로그램이 함께 씁니다. 전용 환경은 다른 프로그램의 영향을 받지 않지만 약 1GB를 더 쓰고 첫 실행 때 초기화 시간이 걸립니다."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 26), pullsDown: false)
        popup.addItem(withTitle: "공용 Wine 환경")
        existing.forEach { popup.addItem(withTitle: "전용 Wine 환경: " + $0) }
        popup.addItem(withTitle: "새 전용 Wine 환경 만들기: " + fresh)
        let retinaBox = NSButton(checkboxWithTitle: "새 환경은 선명한 화면(Retina)으로 만들기", target: nil, action: nil)
        retinaBox.state = retinaOn(environment: nil) ? .on : .off
        let stack = NSStackView(views: [popup, retinaBox]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 340, height: 60)
        alert.accessoryView = stack
        alert.addButton(withTitle: "계속"); alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let index = popup.indexOfSelectedItem
        if index == 0 { return EnvironmentChoice(name: nil, fresh: false, retina: false) }
        if index <= existing.count { return EnvironmentChoice(name: existing[index - 1], fresh: false, retina: false) }
        return EnvironmentChoice(name: fresh, fresh: true, retina: retinaBox.state == .on)
    }
    /// Creates a fresh environment in Retina mode first when asked, then continues.
    func prepare(_ choice: EnvironmentChoice, then: @escaping () -> Void) {
        guard choice.fresh, choice.retina else { then(); return }
        applyRetina(true, prefix: store.prefix(environment: choice.name), place: place(choice.name)) { ok in if ok { then() } }
    }
    /// After an installer: offer what it added, named after its shortcuts.
    func offerInstalled(since before: Set<String>, in environment: String?) {
        refreshRetina()
        let store = self.store
        let registered = Set(registry.launchers.filter { $0.kind == .installed && $0.environment == environment }.map { $0.executable.lowercased() })
        DispatchQueue.global(qos: .userInitiated).async {
            let found = store.newPrograms(since: before, in: environment)
            DispatchQueue.main.async {
                let fresh = found.filter { candidate in
                    guard let location = store.installedLocation(of: candidate.exe) else { return false }
                    return !registered.contains(location.path.lowercased())
                }
                guard !fresh.isEmpty else {
                    self.session.message += "\n새로 설치된 프로그램을 찾지 못했습니다. ‘프로그램 등록’에서 설치된 EXE를 직접 선택해 주세요."
                    return
                }
                let alert = NSAlert(); alert.messageText = "설치된 프로그램을 등록할까요?"
                alert.informativeText = "설치 파일이 \(self.place(environment))에 추가한 프로그램입니다. 등록할 항목을 선택해 주세요."
                let boxes = fresh.map { candidate -> NSButton in
                    let box = NSButton(checkboxWithTitle: candidate.title, target: nil, action: nil)
                    box.state = candidate.shortcut ? .on : .off
                    box.toolTip = candidate.exe.path
                    return box
                }
                let stack = NSStackView(views: boxes); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
                stack.frame = NSRect(x: 0, y: 0, width: 340, height: CGFloat(boxes.count) * 24)
                alert.accessoryView = stack
                alert.addButton(withTitle: "등록"); alert.addButton(withTitle: "건너뛰기")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                var added: [Launcher] = []
                for (candidate, box) in zip(fresh, boxes) where box.state == .on {
                    do {
                        var launcher = try store.importProgram(from: candidate.exe)
                        launcher.name = candidate.title
                        added.append(launcher)
                    } catch { self.error(error) }
                }
                guard let last = added.last else { return }
                self.registry.launchers += added; self.registry.selectedID = last.id; self.save()
                self.session.message += "\n\(added.map(\.name).joined(separator: ", "))을(를) 등록했습니다."
            }
        }
    }
    /// Deletes the selected program the way its kind allows; files go to the Trash.
    func deleteProgram() {
        guard let selected, !session.isRunning(selected.id) else { return }
        let programPrefix = try? store.prefix(selected)
        if let prefix = programPrefix, let running = session.session(in: prefix) {
            self.error(AlchemacError.message("같은 Wine 환경에서 ‘\(running.title)’이(가) 실행 중입니다. 세션을 먼저 종료해 주세요.")); return
        }
        if let prefix = programPrefix, PrefixMigration.isEnvironmentBusy(prefix) { self.error(OrphanSession(prefix: prefix)); return }
        let sharing = registry.launchers.filter { $0.id != selected.id && !$0.privatePrefix && $0.environment == selected.environment }
        let ownEnvironment = !selected.privatePrefix && selected.environment != nil && sharing.isEmpty
        let entry = store.uninstallEntry(for: selected)
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "‘\(selected.name)’을(를) 삭제할까요?"
        var environmentBox: NSButton?
        enum Plan { case trash(environmentToo: Bool), uninstall(UninstallEntry) }
        var choices: [Plan] = []
        switch selected.kind {
        case .copied where selected.privatePrefix:
            let size = (try? store.deletionFolders(for: selected, environmentToo: false)).map(store.allocatedSize) ?? 0
            alert.informativeText = "보관함의 프로그램 복사본과 이 프로그램 전용 Wine 환경, 그 백업(약 \(Self.size(size)))을 휴지통으로 옮깁니다. 프로그램이 저장한 계정 설정도 함께 옮겨집니다. 처음 가져온 원본 폴더는 그대로입니다."
            alert.addButton(withTitle: "휴지통으로 옮기기"); choices = [.trash(environmentToo: false)]
        case .copied:
            let size = (try? store.deletionFolders(for: selected, environmentToo: false)).map(store.allocatedSize) ?? 0
            alert.informativeText = "보관함에 복사한 프로그램 폴더(약 \(Self.size(size)))를 휴지통으로 옮깁니다. 처음 선택한 원본 폴더는 그대로입니다."
            if ownEnvironment, let name = selected.environment {
                let box = NSButton(checkboxWithTitle: "이 프로그램만 쓰는 전용 Wine 환경 ‘\(name)’도 휴지통으로 옮기기", target: nil, action: nil)
                alert.accessoryView = box; environmentBox = box
            }
            alert.addButton(withTitle: "휴지통으로 옮기기"); choices = [.trash(environmentToo: false)]
        case .installed:
            if ownEnvironment, let name = selected.environment {
                let size = (try? store.deletionFolders(for: selected, environmentToo: true)).map(store.allocatedSize) ?? 0
                alert.informativeText = "이 프로그램만 쓰는 전용 Wine 환경 ‘\(name)’(약 \(Self.size(size)))을 통째로 휴지통으로 옮기면 설치한 파일과 설정이 모두 정리됩니다."
                    + (entry.map { "\n또는 Windows 제거 프로그램(‘\($0.name)’)만 실행할 수도 있습니다." } ?? "")
                alert.addButton(withTitle: "Wine 환경째 휴지통으로"); choices.append(.trash(environmentToo: true))
                if let entry { alert.addButton(withTitle: "제거 프로그램 실행"); choices.append(.uninstall(entry)) }
            } else if let entry {
                alert.informativeText = "Windows 제거 프로그램(‘\(entry.name)’)을 실행합니다. 같은 Wine 환경의 다른 프로그램과 공용 구성요소는 그대로 남습니다. 제거가 끝나 실행 파일이 사라지면 목록에서도 뺍니다."
                alert.addButton(withTitle: "제거 프로그램 실행"); choices.append(.uninstall(entry))
            } else {
                self.error(AlchemacError.message("Windows 제거 정보를 찾지 못했습니다. 공용 Wine 환경의 파일은 다른 프로그램과 얽혀 있을 수 있어 직접 지우지 않습니다. 목록에서만 빼려면 ‘목록에서 제거’를 사용해 주세요."))
                return
            }
        }
        alert.addButton(withTitle: "취소")
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard index >= 0, index < choices.count else { return }
        switch choices[index] {
        case .uninstall(let entry):
            do {
                try session.uninstall(selected, command: entry.command, store: store) { [weak self] in
                    guard let self else { return }
                    if let exe = try? self.store.executable(selected), FileManager.default.fileExists(atPath: exe.path) {
                        self.session.message += "\n제거 프로그램이 끝났지만 실행 파일이 남아 있어 목록에 그대로 둡니다."
                    } else {
                        self.unregister(selected); self.session.message += "\n\(selected.name)을(를) 제거하고 목록에서 뺐습니다."
                    }
                }
            } catch { self.error(error) }
        case .trash(let environmentToo):
            let also = environmentToo || environmentBox?.state == .on
            do {
                let folders = try store.deletionFolders(for: selected, environmentToo: also)
                importing = true; importMessage = "휴지통으로 옮기는 중입니다…"
                DispatchQueue.global(qos: .userInitiated).async {
                    // The program's folders may hold or sit beside its environment: move them only while no supervisor uses it.
                    let move = { try folders.forEach { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) } }
                    let result = Result { if let prefix = programPrefix { try PrefixMigration.withEnvironmentFree(prefix, move) } else { try move() } }
                    DispatchQueue.main.async {
                        self.importing = false
                        switch result {
                        case .success:
                            self.unregister(selected)
                            self.session.message = "\(selected.name)을(를) 휴지통으로 옮기고 목록에서 뺐습니다. 휴지통에서 되살릴 수 있습니다."
                        case .failure(let error): self.session.message = "삭제하지 못했습니다."; self.error(error)
                        }
                    }
                }
            } catch { self.error(error) }
        }
    }
    private func unregister(_ launcher: Launcher) {
        registry.launchers.removeAll { $0.id == launcher.id }
        if registry.selectedID == launcher.id { registry.selectedID = registry.launchers.first?.id }
        save()
    }
    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    func rename() {
        guard let selected, let index = registry.launchers.firstIndex(where: { $0.id == selected.id }) else { return }
        let alert = NSAlert(); alert.messageText = "프로그램 이름 변경"
        let field = NSTextField(string: selected.name); field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: "저장"); alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { return }
        registry.launchers[index].name = name; save()
    }
    func remove() {
        guard let selected else { return }
        let alert = NSAlert(); alert.messageText = "목록에서 제거할까요?"
        alert.informativeText = selected.kind == .installed
            ? "설치된 파일은 삭제하지 않습니다. 공용 Wine 환경에 그대로 남습니다."
            : "프로그램 파일과 계정 데이터는 삭제하지 않습니다. 보관함 폴더에 남습니다."
        alert.addButton(withTitle: "목록에서 제거"); alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        registry.launchers.removeAll { $0.id == selected.id }; registry.selectedID = registry.launchers.first?.id; save()
    }
    func revealGame() {
        if let selected, let game = try? store.game(selected) { NSWorkspace.shared.open(game) }
    }
    /// Selects the last problem run's own log files in Finder.
    func revealProblemLog() {
        let logs = session.lastProblemLogs.filter { FileManager.default.fileExists(atPath: $0.path) }
        if logs.isEmpty { revealLogs() } else { NSWorkspace.shared.activateFileViewerSelecting(logs) }
    }
    func revealLogs() {
        let url = store.logs
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}

struct LibraryView: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject var session: SessionController
    private var locked: Bool { model.importing }
    private var selectedRunning: Bool { model.selected.map { session.isRunning($0.id) } ?? false }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "leaf.circle.fill").font(.system(size: 46)).foregroundStyle(.mint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Alchemac").font(.system(size: 25, weight: .semibold, design: .rounded))
                    Text("Windows 프로그램 보관함").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Text("v\(AlchemacRuntime.appVersion)" + (AlchemacRuntime.isDevelopment ? " · 개발 버전" : "")).font(.callout.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.teal, in: Capsule())
            }
            HStack {
                Text("등록된 프로그램").font(.headline)
                Spacer()
                Button(action: model.install) { Label("설치 파일 실행", systemImage: "shippingbox") }.disabled(locked)
                Button(action: model.add) { Label("프로그램 등록", systemImage: "plus") }.disabled(locked)
            }
            List(selection: $model.registry.selectedID) {
                ForEach(model.registry.launchers) { launcher in
                    HStack(spacing: 12) {
                        Group {
                            if let icon = model.icons[launcher.id] {
                                Image(nsImage: icon).resizable().interpolation(.high).scaledToFit().padding(5)
                            } else {
                                Image(systemName: "gamecontroller.fill").font(.title2).foregroundStyle(.mint)
                            }
                        }.frame(width: 42, height: 42).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                            .task(id: launcher.id + launcher.executable) { await model.loadIcon(launcher) }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(launcher.name).font(.headline)
                            Text(launcher.detail + (model.retinaOn(launcher) ? " · 선명한 화면" : "") + (launcher.scaled ? " · 크기 보정" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if session.isRunning(launcher.id) {
                            ProgressView().controlSize(.small)
                            Text("실행 중").font(.caption).foregroundStyle(.teal)
                        }
                    }.padding(.vertical, 7).tag(launcher.id)
                }
            }
            .listStyle(.inset).frame(minHeight: 145)
            .overlay {
                if model.registry.launchers.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray").font(.largeTitle).foregroundStyle(.secondary)
                        Text("등록된 프로그램이 없습니다").font(.headline)
                        Text("‘설치 파일 실행’으로 설치하거나 ‘프로그램 등록’에서 EXE를 선택하세요.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.disabled(locked)
            .onChange(of: model.registry.selectedID) { _, _ in model.save() }
            HStack {
                Button("프로그램 폴더", action: model.revealGame).disabled(model.selected == nil)
                Menu("관리") {
                    Button("이름 변경", action: model.rename).disabled(locked || selectedRunning || model.selected == nil)
                    Button("목록에서 제거", action: model.remove).disabled(locked || selectedRunning || model.selected == nil)
                    Button("프로그램 삭제…", action: model.deleteProgram).disabled(locked || selectedRunning || model.selected == nil)
                    Button("이 프로그램 환경에서 EXE 실행…", action: model.runTool).disabled(locked || model.selected == nil || model.selectedSession?.stopping == true)
                    if let selected = model.selected {
                        Divider()
                        let scope = selected.privatePrefix ? "이 프로그램 Wine 환경의" : "이 Wine 환경의"
                        Button(model.retinaOn(selected) ? scope + " 선명한 화면 끄기" : scope + " 선명한 화면(Retina) 켜기",
                               action: { model.toggleRetina(selected) }).disabled(locked || model.selectedSession != nil)
                        Button(selected.scaled ? "크기 보정 끄기" : "크기 보정 켜기 (작게 보일 때)", action: model.toggleScaled).disabled(locked)
                    }
                    Divider()
                    Button("이 실행의 로그 열기", action: model.revealProblemLog).disabled(session.lastProblemLogs.isEmpty)
                    Button("진단 로그 열기", action: model.revealLogs)
                    Button("오픈소스 라이선스") { NSWorkspace.shared.open(AlchemacRuntime.licenses) }
                }.fixedSize()
                Menu("애드온") {
                    ForEach(model.addons) { addon in
                        Menu(addon.name + " " + addon.version) {
                            if let summary = addon.summary { Text(summary) }
                            Button("제거…") { model.removeAddon(addon) }.disabled(locked)
                        }
                    }
                    if !model.addons.isEmpty { Divider() }
                    Button("애드온 설치…", action: model.installAddon).disabled(locked)
                }.fixedSize()
                Menu("Wine 환경") {
                    ForEach(model.environmentNames, id: \.self) { key in
                        let environment: String? = key.isEmpty ? nil : key
                        let busy = session.session(in: model.store.prefix(environment: environment)) != nil
                        let sharp = model.retinaOn(environment: environment)
                        Menu(model.place(environment) + (sharp ? " · 선명한 화면" : "")) {
                            Button(sharp ? "선명한 화면 끄기" : "선명한 화면(Retina) 켜기") { model.toggleRetina(environment: environment) }
                                .disabled(locked || busy)
                            Button("폴더 열기") { model.revealEnvironment(environment) }
                            if let name = environment {
                                Divider()
                                Button("환경 삭제…") { model.deleteEnvironment(name) }.disabled(locked || busy)
                            }
                        }
                    }
                    Divider()
                    Button("남은 세션 확인…") { model.checkOrphans(startup: false) }.disabled(locked)
                    Button("환경 백업 정리…", action: model.manageBackups).disabled(locked)
                }.fixedSize()
                Spacer()
                if let running = model.selectedSession {
                    if running.launcherID != model.selected?.id {
                        Text("같은 Wine 환경에서 ‘\(running.title)’ 실행 중").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("세션 종료", action: model.stop).disabled(running.stopping)
                } else {
                    Button(action: model.start) { Label("선택한 프로그램 실행", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent).tint(.teal).disabled(model.selected == nil || model.importing)
                }
            }
            Divider()
            HStack(alignment: .top, spacing: 8) {
                if locked || session.busy { ProgressView().controlSize(.small) }
                VStack(alignment: .leading, spacing: 2) {
                    if session.sessions.count > 1 {
                        Text("동시에 실행 중 \(session.sessions.count)개: " + session.sessions.values.map(\.title).sorted().joined(separator: ", "))
                            .font(.caption.weight(.medium))
                    }
                    Text(model.importing ? model.importMessage : session.message).font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if !model.importing, !session.busy, !session.lastProblemLogs.isEmpty {
                        Button("이 실행의 로그 열기", action: model.revealProblemLog).font(.caption)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 32, alignment: .top)
            Text("Windows 프로그램 실행 플랫폼 · 프로그램마다 동작이 다를 수 있습니다.")
                .font(.caption).foregroundStyle(.secondary)
            Text("앱 v\(AlchemacRuntime.appVersion) · 실행 환경 \(AlchemacRuntime.buildID)")
                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .padding(26).frame(minWidth: 590, minHeight: 480)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow?
    var model: LibraryModel?
    var waitingToQuit = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let model = try LibraryModel(store: LauncherStore()); self.model = model
            model.session.finished = { [weak self] in
                guard let self, self.waitingToQuit else { return }
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 535),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Alchemac v" + AlchemacRuntime.appVersion; window.delegate = self; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: LibraryView(model: model, session: model.session))
            window.minSize = NSSize(width: 600, height: 510)
            window.center(); window.makeKeyAndOrderFront(nil); self.window = window
            NSApp.activate(ignoringOtherApps: true)
            // Opening the app never starts Wine or a launcher.
            model.showRecoveryNotice()
            model.checkOrphans(startup: true)
            model.startCleanup()
        } catch {
            let alert = NSAlert(); alert.messageText = "보관함을 열 수 없습니다"; alert.informativeText = error.localizedDescription
            alert.runModal(); NSApp.terminate(nil)
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil); return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.importing {
            let alert = NSAlert(); alert.messageText = "가져오기가 진행 중입니다"; alert.informativeText = "복사가 끝난 뒤 앱을 종료해 주세요."; alert.runModal()
            return .terminateCancel
        }
        guard model.session.busy else { return .terminateNow }
        if model.session.allStopping { waitingToQuit = true; return .terminateLater }
        let alert = NSAlert(); alert.messageText = "실행 중인 세션을 종료하고 앱을 닫을까요?"
        alert.informativeText = "열려 있는 작업이나 게임을 먼저 저장해 주세요. 실행 중인 프로그램이 모두 종료된 뒤 앱을 닫습니다."
        if model.session.sessions.values.contains(where: \.migrating) {
            alert.informativeText += "\n\n지금은 앱 업데이트 후 Wine 환경을 새 버전에 맞추는 중입니다. 지금 종료하면 이 업데이트가 중단되며, 다음 실행 때 다시 시도하거나 업데이트 전 상태로 복원할 수 있습니다."
        }
        alert.addButton(withTitle: "세션 종료 후 앱 닫기"); alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        waitingToQuit = true; model.session.stopAll(); return .terminateLater
    }
}

extension Launcher {
    var detail: String {
        let place = privatePrefix ? "이 프로그램 전용 Wine 환경" : environment.map { "전용 Wine 환경: " + $0 } ?? "공용 Wine 환경"
        let recipe = addon.map { " · 애드온 " + $0 } ?? ""
        switch kind {
        case .installed: return "설치된 프로그램 · " + place + recipe
        case .copied: return "복사한 프로그램 폴더 · " + place + recipe
        }
    }
}
