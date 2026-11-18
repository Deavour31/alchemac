import Foundation
import CryptoKit
import Darwin

/// Where updates come from. Every release publishes `update.json` (the manifest), `update.json.sig` (an Ed25519
/// signature of its exact bytes, made with the release signing key), the DMG and optional delta archives.
enum UpdateFeed {
    static let base = URL(string: "https://github.com/Deavour31/alchemac/releases/latest/download/")!
    /// Base64 raw Ed25519 public key of the release signing key (`update-sign keygen` prints it).
    static let publicKey = "XDffSzk79YFJdeO1XM7AEuaGOZ/WRqC1G0uKxrb8cZY="
    static let bundleID = "io.github.deavour31.alchemac"
    static let releaseBase = "https://github.com/Deavour31/alchemac/releases/download/"

    /// Development builds may read the feed from elsewhere (UserDefaults "UpdateFeedURL": an http(s) or file URL).
    /// The signature is required all the same.
    static func feedOverride(development: Bool = AlchemacRuntime.isDevelopment, defaults: UserDefaults = .standard) -> URL? {
        guard development, let text = defaults.string(forKey: "UpdateFeedURL"), let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else { return nil }
        return text.hasSuffix("/") ? url : URL(string: text + "/")
    }
    static func feedBase(development: Bool = AlchemacRuntime.isDevelopment, defaults: UserDefaults = .standard) -> URL {
        feedOverride(development: development, defaults: defaults) ?? base
    }
    static func assetURL(version: String, name: String, development: Bool = AlchemacRuntime.isDevelopment, defaults: UserDefaults = .standard) -> URL {
        if let override = feedOverride(development: development, defaults: defaults) { return override.appendingPathComponent(name) }
        return URL(string: releaseBase + "v" + version + "/" + name)!
    }
}

extension AlchemacRuntime {
    static var appBuild: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0 }
}

enum UpdateError: LocalizedError {
    /// The app cannot replace itself where it is (translocated, read-only or DMG volume, not writable, other volume
    /// than the backup folder): the UI offers the release page instead.
    case cannotReplace
    case signature
    case manifest(String)
    case download(String)
    case verification(String)
    case install(String)
    var errorDescription: String? {
        switch self {
        case .cannotReplace: return "이 위치에서는 앱이 스스로 교체할 수 없습니다."
        case .signature: return "업데이트 정보의 서명을 확인하지 못했습니다. 아무것도 바꾸지 않았습니다."
        case .manifest(let text): return "업데이트 정보가 올바르지 않습니다. (\(text))"
        case .download(let text): return "업데이트를 내려받지 못했습니다. (\(text))"
        case .verification(let text): return "내려받은 업데이트를 확인하지 못해 적용하지 않았습니다. (\(text))"
        case .install(let text): return "업데이트를 설치하지 못했습니다. (\(text))"
        }
    }
}

struct UpdateManifest: Codable, Equatable {
    struct Asset: Codable, Equatable { let name: String; let size: Int64; let sha256: String }
    struct Delta: Codable, Equatable { let fromBuild: Int; let name: String; let size: Int64; let sha256: String }
    struct Entry: Codable, Equatable {
        let path: String
        let type: String            // "file", "dir" or "link"
        var size: Int64? = nil
        var sha256: String? = nil
        var executable: Bool? = nil
        var target: String? = nil
    }
    let schema: Int
    let bundleID: String
    let version: String
    let build: Int
    let minimumSystem: String
    let releaseURL: String
    let dmg: Asset
    let deltas: [Delta]
    let entries: [Entry]

    func delta(fromBuild build: Int) -> Delta? { deltas.first { $0.fromBuild == build } }
}

enum Updater {
    typealias Progress = @Sendable (String, Double?) -> Void

    // MARK: Manifest

    static func isHex64(_ text: String) -> Bool { text.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }

    static func safePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    static func plainName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
            && !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
    }

    /// A link target is relative and, resolved against the link's own directory, stays inside the bundle.
    static func linkStaysInside(path: String, target: String) -> Bool {
        guard !target.isEmpty, !target.hasPrefix("/"), !target.contains("\0") else { return false }
        var stack = path.split(separator: "/").dropLast().map(String.init)
        for part in target.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { guard !stack.isEmpty else { return false }; stack.removeLast() } else { stack.append(String(part)) }
        }
        return true
    }

    static func parseVersion(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        return parts.isEmpty || parts.contains(where: { $0 == nil }) ? nil : parts.map { $0! }
    }

    static func systemMeets(_ minimum: String, current: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> Bool {
        guard let wanted = parseVersion(minimum) else { return false }
        let have = [current.majorVersion, current.minorVersion, current.patchVersion]
        for index in 0..<max(wanted.count, 3) {
            let a = index < have.count ? have[index] : 0, b = index < wanted.count ? wanted[index] : 0
            if a != b { return a > b }
        }
        return true
    }

    /// Only a strictly newer build counts as an update.
    static func isNewer(build: Int, than current: Int) -> Bool { build > current }

    /// Verifies the signature first, then decodes and validates every field the installer will rely on.
    static func verifiedManifest(data: Data, signature: Data, publicKey: String) throws -> UpdateManifest {
        guard let keyBytes = Data(base64Encoded: publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes),
              let text = String(data: signature, encoding: .utf8),
              let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              key.isValidSignature(raw, for: data) else { throw UpdateError.signature }
        let manifest: UpdateManifest
        do { manifest = try JSONDecoder().decode(UpdateManifest.self, from: data) } catch { throw UpdateError.manifest("형식") }
        func bad(_ what: String) -> UpdateError { .manifest(what) }
        guard manifest.schema == 1 else { throw bad("schema") }
        guard manifest.bundleID == UpdateFeed.bundleID else { throw bad("bundleID") }
        guard manifest.version.range(of: #"^[0-9]+(\.[0-9]+)*$"#, options: .regularExpression) != nil, manifest.build >= 0 else { throw bad("version") }
        guard parseVersion(manifest.minimumSystem) != nil else { throw bad("minimumSystem") }
        guard let release = URL(string: manifest.releaseURL), release.scheme == "https", release.host != nil else { throw bad("releaseURL") }
        for asset in [(manifest.dmg.name, manifest.dmg.size, manifest.dmg.sha256)] + manifest.deltas.map({ ($0.name, $0.size, $0.sha256) }) {
            guard plainName(asset.0) else { throw bad("파일 이름 \(asset.0)") }
            guard asset.1 >= 0, isHex64(asset.2) else { throw bad("파일 정보 \(asset.0)") }
        }
        guard Set(manifest.deltas.map(\.fromBuild)).count == manifest.deltas.count,
              Set(manifest.deltas.map(\.name)).count == manifest.deltas.count else { throw bad("deltas") }
        var seen = Set<String>()
        for entry in manifest.entries {
            guard safePath(entry.path), seen.insert(entry.path).inserted else { throw bad("경로 \(entry.path)") }
            switch entry.type {
            case "file":
                guard let size = entry.size, size >= 0, let sha = entry.sha256, isHex64(sha), entry.executable != nil, entry.target == nil else { throw bad("파일 항목 \(entry.path)") }
            case "dir":
                guard entry.size == nil, entry.sha256 == nil, entry.target == nil else { throw bad("폴더 항목 \(entry.path)") }
            case "link":
                guard let target = entry.target, linkStaysInside(path: entry.path, target: target), entry.size == nil, entry.sha256 == nil else { throw bad("링크 \(entry.path)") }
            default: throw bad("종류 \(entry.path)")
            }
        }
        return manifest
    }

    // MARK: Check

    static func session(timeout: TimeInterval = 30) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    static func fetch(_ url: URL, limit: Int) async throws -> Data {
        let (data, response) = try await session().data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw UpdateError.download("HTTP \(http.statusCode)") }
        guard data.count <= limit else { throw UpdateError.download("너무 큰 응답") }
        return data
    }

    /// The manifest of a newer release this Mac can run, or nil.
    static func checkForUpdate(currentBuild: Int) async throws -> UpdateManifest? {
        let base = UpdateFeed.feedBase()
        let data = try await fetch(base.appendingPathComponent("update.json"), limit: 16 << 20)
        let signature = try await fetch(base.appendingPathComponent("update.json.sig"), limit: 4096)
        let manifest = try verifiedManifest(data: data, signature: signature, publicKey: UpdateFeed.publicKey)
        return isNewer(build: manifest.build, than: currentBuild) && systemMeets(manifest.minimumSystem) ? manifest : nil
    }

    // MARK: Settings

    static let automaticKey = "AutomaticUpdateCheck", lastCheckKey = "LastUpdateCheck"

    static func registerDefaults(_ defaults: UserDefaults = .standard) { defaults.register(defaults: [automaticKey: true]) }

    static func shouldCheckAutomatically(enabled: Bool, development: Bool, last: Date?, now: Date = Date()) -> Bool {
        guard enabled, !development else { return false }
        guard let last else { return true }
        return now.timeIntervalSince(last) > 24 * 3600
    }

    // MARK: Locations

    static var updatesFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Alchemac/updates", isDirectory: true)
    }

    static func stagingURL(app: URL, build: Int) -> URL {
        app.deletingLastPathComponent().appendingPathComponent(".Alchemac-update-\(build).app", isDirectory: true)
    }

    private static func device(_ url: URL) -> dev_t? {
        var info = stat()
        return stat(url.path, &info) == 0 ? info.st_dev : nil
    }

    /// The app can replace itself only from a normal, writable, read-write location on the volume of the backup folder.
    static func canReplace(app: URL, updates: URL) -> Bool {
        let parent = app.deletingLastPathComponent()
        guard !app.path.contains("/AppTranslocation/"), FileManager.default.isWritableFile(atPath: parent.path) else { return false }
        var info = statfs()
        guard statfs(parent.path, &info) == 0, info.f_flags & UInt32(MNT_RDONLY) == 0 else { return false }
        // The backup is a rename into the updates folder: the same volume keeps it atomic and quick.
        let folder = FileManager.default.fileExists(atPath: updates.path) ? updates : updates.deletingLastPathComponent()
        guard let a = device(parent), let b = device(folder), a == b else { return false }
        return true
    }

    // MARK: Subprocesses and hashing

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: Data) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe; process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }

    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: 1 << 20) } ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Download

    /// Streams a file into `destination`, hashing as it arrives; stops at `size` bytes (the manifest's) and checks the digest.
    final class Download: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let destination: URL, size: Int64, sha256: String, progress: Progress
        private var handle: FileHandle?, hasher = SHA256(), received: Int64 = 0, failure: Error?, continuation: CheckedContinuation<Void, Error>?
        private var task: URLSessionDataTask?
        init(destination: URL, size: Int64, sha256: String, progress: @escaping Progress) {
            self.destination = destination; self.size = size; self.sha256 = sha256; self.progress = progress
        }
        func run(_ url: URL) async throws {
            try? FileManager.default.removeItem(at: destination)     // our own earlier partial download
            guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                  let handle = try? FileHandle(forWritingTo: destination) else { throw UpdateError.download("파일을 만들 수 없음") }
            self.handle = handle
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30; configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false; configuration.urlCache = nil
            let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            let task = session.dataTask(with: url); self.task = task
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    self.continuation = continuation; task.resume()
                }
            } onCancel: { task.cancel() }
            session.finishTasksAndInvalidate()
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { failure = UpdateError.download("HTTP \(http.statusCode)"); completionHandler(.cancel); return }
            if response.expectedContentLength > size { failure = UpdateError.download("예상보다 큰 파일"); completionHandler(.cancel); return }
            completionHandler(.allow)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            received += Int64(data.count)
            guard received <= size else { failure = UpdateError.download("예상보다 큰 파일"); dataTask.cancel(); return }
            do { try handle?.write(contentsOf: data) } catch { failure = UpdateError.download("저장 실패"); dataTask.cancel(); return }
            hasher.update(data: data)
            progress("", size > 0 ? Double(received) / Double(size) : 1)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            try? handle?.close(); handle = nil
            var result: Error? = failure ?? error
            if result == nil {
                let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                if received != size { result = UpdateError.verification("파일 크기가 맞지 않음") }
                else if digest != sha256 { result = UpdateError.verification("파일의 SHA-256이 맞지 않음") }
            }
            if let result { try? FileManager.default.removeItem(at: destination); continuation?.resume(throwing: result) } else { continuation?.resume() }
            continuation = nil
        }
    }

    // MARK: Verification of a prepared app

    /// The tree comparison alone: exactly the manifest's entries, file sizes and SHA-256, executable bits, link targets.
    static func verifyTree(app: URL, manifest: UpdateManifest) throws {
        guard let found = RuntimeCopy.scan(app.path) else { throw UpdateError.verification("앱 폴더를 끝까지 읽을 수 없음") }
        var expected: [String: UpdateManifest.Entry] = [:]
        for entry in manifest.entries { expected[entry.path] = entry }
        for path in found.keys.sorted() where expected[path] == nil { throw UpdateError.verification("목록에 없는 항목 \(path)") }
        for path in expected.keys.sorted() {
            guard let have = found[path] else { throw UpdateError.verification("빠진 항목 \(path)") }
            let want = expected[path]!
            switch want.type {
            case "dir":
                guard have.kind == UInt16(S_IFDIR) else { throw UpdateError.verification("종류가 다른 항목 \(path)") }
            case "link":
                guard have.kind == UInt16(S_IFLNK), have.link == want.target else { throw UpdateError.verification("링크가 다른 항목 \(path)") }
            default:
                guard have.kind == UInt16(S_IFREG), have.size == want.size else { throw UpdateError.verification("파일이 다른 항목 \(path)") }
                let file = app.appendingPathComponent(path)
                var info = stat()
                guard lstat(file.path, &info) == 0, (info.st_mode & 0o111 != 0) == want.executable else { throw UpdateError.verification("실행 권한이 다른 항목 \(path)") }
                guard (try? sha256Hex(of: file)) == want.sha256 else { throw UpdateError.verification("내용이 다른 파일 \(path)") }
            }
        }
    }

    /// Info.plist identity and the code signature seal.
    static func verifyIdentity(app: URL, manifest: UpdateManifest, codesign: Bool = true) throws {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == manifest.bundleID,
              Int(info["CFBundleVersion"] as? String ?? "") == manifest.build else { throw UpdateError.verification("앱 정보(Info.plist)가 맞지 않음") }
        guard codesign else { return }
        let result = try? run("/usr/bin/codesign", ["--verify", "--strict", app.path])
        guard result?.status == 0 else { throw UpdateError.verification("코드 서명 봉인이 맞지 않음") }
    }

    static func verify(app: URL, manifest: UpdateManifest) throws {
        try verifyTree(app: app, manifest: manifest)
        try verifyIdentity(app: app, manifest: manifest)
    }

    // MARK: Delta

    /// Removes everything the manifest does not list (deepest first) and sets the executable bits it names.
    static func conform(app: URL, to manifest: UpdateManifest) throws {
        guard let found = RuntimeCopy.scan(app.path) else { throw UpdateError.verification("앱 폴더를 읽을 수 없음") }
        let wanted = Set(manifest.entries.map(\.path))
        let extra = found.keys.filter { !wanted.contains($0) }.sorted { $0.split(separator: "/").count > $1.split(separator: "/").count }
        for path in extra {
            let url = app.appendingPathComponent(path)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }           // went with its parent
            try FileManager.default.removeItem(at: url)                    // the update's own staging copy
        }
        for entry in manifest.entries where entry.type == "file" {
            let url = app.appendingPathComponent(entry.path)
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            let mode = info.st_mode & 0o7777, hasExec = mode & 0o111 != 0
            if hasExec == entry.executable { continue }
            let changed = entry.executable == true ? mode | ((mode & 0o444) >> 2) : mode & ~mode_t(0o111)
            guard chmod(url.path, changed) == 0 else { throw UpdateError.install("권한을 바꿀 수 없음 \(entry.path)") }
        }
    }

    static func applyDelta(archive: URL, to staging: URL, manifest: UpdateManifest) throws {
        let result = try run("/usr/bin/tar", ["--no-xattrs", "-xJf", archive.path, "-C", staging.path])
        guard result.status == 0 else { throw UpdateError.verification("변경분 압축을 풀 수 없음") }
        try conform(app: staging, to: manifest)
    }

    // MARK: Prepare

    private static func log(_ text: String) { fputs("Alchemac: update: \(text)\n", stderr) }

    static func discard(_ url: URL) { try? FileManager.default.removeItem(at: url) }       // our own staging / download files

    /// Brings a verified copy of the new app next to the installed one and returns it. Tries the delta first; any failure
    /// there falls back to the full DMG. Throws `UpdateError.cannotReplace` before anything is downloaded when the app
    /// cannot replace itself where it is.
    static func prepare(_ manifest: UpdateManifest, app: URL, currentBuild: Int, updates: URL = updatesFolder, progress: @escaping Progress) async throws -> URL {
        let fm = FileManager.default
        guard canReplace(app: app, updates: updates) else { throw UpdateError.cannotReplace }
        let staging = stagingURL(app: app, build: manifest.build)
        discard(staging)
        let downloads = updates.appendingPathComponent(String(manifest.build), isDirectory: true)
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { discard(downloads) }
        if let delta = manifest.delta(fromBuild: currentBuild) {
            do {
                progress("변경된 파일을 내려받는 중입니다…", 0)
                let archive = downloads.appendingPathComponent(delta.name)
                let url = UpdateFeed.assetURL(version: manifest.version, name: delta.name)
                try await Download(destination: archive, size: delta.size, sha256: delta.sha256) { _, fraction in progress("변경된 파일을 내려받는 중입니다…", fraction) }.run(url)
                progress("현재 앱을 복제하고 변경분을 적용하는 중입니다…", nil)
                try fm.copyItem(at: app, to: staging)
                try applyDelta(archive: archive, to: staging, manifest: manifest)
                progress("업데이트를 검증하는 중입니다…", nil)
                try verify(app: staging, manifest: manifest)
                return staging
            } catch {
                if error is CancellationError { discard(staging); throw error }
                log("delta path failed (\(error.localizedDescription)); using the full download")
                discard(staging)
            }
        }
        do {
            let image = downloads.appendingPathComponent(manifest.dmg.name)
            let url = UpdateFeed.assetURL(version: manifest.version, name: manifest.dmg.name)
            progress("새 버전을 내려받는 중입니다…", 0)
            try await Download(destination: image, size: manifest.dmg.size, sha256: manifest.dmg.sha256) { _, fraction in progress("새 버전을 내려받는 중입니다…", fraction) }.run(url)
            progress("디스크 이미지에서 앱을 꺼내는 중입니다…", nil)
            try copyFromImage(image, to: staging, scratch: downloads)
            progress("업데이트를 검증하는 중입니다…", nil)
            try verify(app: staging, manifest: manifest)
            return staging
        } catch { discard(staging); throw error }
    }

    static func copyFromImage(_ image: URL, to staging: URL, scratch: URL) throws {
        let mounts = scratch.appendingPathComponent("mount-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: mounts, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attached = try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountrandom", mounts.path, "-plist", image.path])
        guard attached.status == 0, let list = try? PropertyListSerialization.propertyList(from: attached.output, format: nil) as? [String: Any],
              let entities = list["system-entities"] as? [[String: Any]],
              let mount = entities.compactMap({ $0["mount-point"] as? String }).first else { throw UpdateError.verification("디스크 이미지를 열 수 없음") }
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", "-force", mount]) }
        let copied = try run("/bin/cp", ["-R", mount + "/Alchemac.app", staging.path])
        guard copied.status == 0 else { throw UpdateError.verification("앱을 복사할 수 없음") }
    }

    // MARK: Install

    static let helperScript = """
    #!/bin/sh
    # Alchemac update helper. Arguments: pid app staging backup [--no-open]. Paths are never part of this text.
    pid="$1"; app="$2"; staging="$3"; backup="$4"; mode="$5"
    reopen() { [ "$mode" = "--no-open" ] || /usr/bin/open "$1"; }
    tries=0
    while kill -0 "$pid" 2>/dev/null; do
      tries=$((tries + 1))
      [ "$tries" -gt 600 ] && exit 1
      sleep 0.2
    done
    [ -d "$staging" ] || { reopen "$app"; exit 1; }
    if ! /bin/mv "$app" "$backup"; then reopen "$app"; exit 1; fi
    if ! /bin/mv "$staging" "$app"; then
      /bin/mv "$backup" "$app"
      reopen "$app"
      exit 1
    fi
    reopen "$app"

    """

    static func backupURL(oldVersion: String, updates: URL) -> URL {
        let previous = updates.appendingPathComponent("previous", isDirectory: true)
        let safe = String(oldVersion.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
        var url = previous.appendingPathComponent("Alchemac-\(safe).app", isDirectory: true), n = 1
        while FileManager.default.fileExists(atPath: url.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
            n += 1; url = previous.appendingPathComponent("Alchemac-\(safe)-\(n).app", isDirectory: true)
        }
        return url
    }

    /// Starts the helper that swaps the apps once this process has exited. The caller terminates the app afterwards.
    /// `waitFor`/`open` exist for tests: the pid to wait for, and false to skip the final `open`.
    static func installAndRelaunch(staging: URL, app: URL, oldVersion: String, updates: URL = updatesFolder,
                                   waitFor pid: Int32 = getpid(), open: Bool = true, wait: Bool = false) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: updates.appendingPathComponent("previous", isDirectory: true), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let script = updates.appendingPathComponent("install-helper.sh")
            try? fm.removeItem(at: script)
            try Data(helperScript.utf8).write(to: script)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path, String(pid), app.path, staging.path, backupURL(oldVersion: oldVersion, updates: updates).path] + (open ? [] : ["--no-open"])
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
            if wait { process.waitUntilExit(); if process.terminationStatus != 0 { throw UpdateError.install("helper exit \(process.terminationStatus)") } }
        } catch let error as UpdateError { throw error } catch { throw UpdateError.install(error.localizedDescription) }
    }

    // MARK: Cleanup at launch

    /// Old app copies go to the Trash; the update's own download folders for builds up to the running one and stale
    /// staging copies beside the app are removed. For a background queue.
    static func cleanup(app: URL = Bundle.main.bundleURL, currentBuild: Int = AlchemacRuntime.appBuild, updates: URL = updatesFolder) {
        let fm = FileManager.default
        let previous = updates.appendingPathComponent("previous", isDirectory: true)
        for name in StartupCleanup.names(previous) where name.hasSuffix(".app") {
            let url = previous.appendingPathComponent(name, isDirectory: true)
            guard StartupCleanup.isPlainDirectory(url) else { continue }
            do { try fm.trashItem(at: url, resultingItemURL: nil) } catch { log("could not trash \(name): \(error.localizedDescription)") }
        }
        for name in StartupCleanup.names(updates) {
            guard let build = Int(name), build <= currentBuild, StartupCleanup.isPlainDirectory(updates.appendingPathComponent(name)) else { continue }
            discard(updates.appendingPathComponent(name, isDirectory: true))
        }
        let parent = app.deletingLastPathComponent()
        for name in StartupCleanup.names(parent) where name.hasPrefix(".Alchemac-update-") && name.hasSuffix(".app") {
            let url = parent.appendingPathComponent(name, isDirectory: true)
            if StartupCleanup.isPlainDirectory(url) { discard(url) }
        }
    }
}
