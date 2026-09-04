import XCTest
@testable import CoreKit

/// `SettingsStore`와 `LogStore` — 설정 보존(FR-11)과 변환 내역(FR-10).
final class StoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var logDirectory: URL!

    override func setUpWithError() throws {
        suiteName = "moja.test." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        logDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("moja-logs-" + UUID().uuidString)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: logDirectory)
    }

    private func settings() -> SettingsStore { SettingsStore(defaults: defaults) }
    private func log(maximumFileSize: Int = LogStore.maximumFileSize,
                     capacity: Int = LogStore.memoryCapacity) -> LogStore {
        LogStore(directory: logDirectory, fileName: "Test.log",
                 capacity: capacity, maximumFileSize: maximumFileSize)
    }

    private func temporaryDirectory() -> String {
        let path = NSTemporaryDirectory() + "moja-folder-" + UUID().uuidString
        XCTAssertEqual(path.withCString { mkdir($0, 0o755) }, 0)
        return path
    }

    // MARK: - 설정 (FR-11)

    func testFoldersSurviveARestart() {
        let store = settings()
        store.addFolder(path: "/Users/나/데스크탑")
        store.addFolder(path: "/Users/나/다운로드")

        // 새 인스턴스 = 앱 재시작
        let reopened = settings()
        XCTAssertEqual(reopened.folders.map(\.path), ["/Users/나/데스크탑", "/Users/나/다운로드"])
        XCTAssertTrue(reopened.folders.allSatisfy(\.isEnabled))
    }

    /// 경로에 분해된 한글이 들어 있어도 바이트가 그대로 왕복해야 한다.
    func testDecomposedPathRoundTripsByteForByte() {
        let path = "/Users/나/" + "자료 모음".decomposedStringWithCanonicalMapping
        let store = settings()
        store.addFolder(path: path)

        let stored = try? XCTUnwrap(settings().folders.first?.path)
        XCTAssertEqual(Array((stored ?? "").utf8), Array(path.utf8))
    }

    func testTogglePersists() throws {
        let store = settings()
        store.addFolder(path: "/Users/나/데스크탑")
        let id = try XCTUnwrap(store.folders.first?.id)

        store.setFolder(id: id, enabled: false)
        XCTAssertEqual(settings().folders.first?.isEnabled, false)
    }

    func testRemoveFolder() throws {
        let store = settings()
        store.addFolder(path: "/A")
        store.addFolder(path: "/B")
        let id = try XCTUnwrap(store.folders.first?.id)

        store.removeFolder(id: id)
        XCTAssertEqual(settings().folders.map(\.path), ["/B"])
    }

    func testAddingTheSamePathTwiceIsIgnored() {
        let store = settings()
        XCTAssertTrue(store.addFolder(path: "/Users/나/데스크탑"))
        XCTAssertFalse(store.addFolder(path: "/Users/나/데스크탑"))
        XCTAssertEqual(store.folders.count, 1)
    }

    /// 같은 폴더를 다른 경로로 고를 수 있다. 두 번 감시하면 일을 두 번 한다.
    func testSameFolderReachedByAnotherPathIsIgnored() {
        let path = temporaryDirectory()
        defer { _ = path.withCString { rmdir($0) } }
        let alias = "/private" + path
        try? XCTSkipUnless(POSIXFile.exists(alias), "이 경로에는 /private 별칭이 없다")

        let store = settings()
        XCTAssertTrue(store.addFolder(path: path))
        XCTAssertFalse(store.addFolder(path: alias), "같은 폴더를 두 번 등록했다")
    }

    func testPauseStatePersists() {
        let store = settings()
        store.isPaused = true
        XCTAssertTrue(settings().isPaused)
    }

    /// 온보딩은 폴더가 하나도 없으면 다시 떠야 한다 (FR-8).
    func testOnboardingReappearsUntilAFolderIsAdded() {
        let store = settings()
        store.hasCompletedOnboarding = true
        XCTAssertFalse(store.hasCompletedOnboarding, "폴더가 없는데 온보딩을 건너뛰었다")

        store.addFolder(path: "/Users/나/데스크탑")
        XCTAssertTrue(store.hasCompletedOnboarding)
    }

    // MARK: - 로그 (FR-10)

    func testConversionIsRecordedInMemoryAndOnDisk() throws {
        let store = log()
        store.record([.renamed(path: "/W/한글.txt", newName: "한글.txt")])

        XCTAssertEqual(store.recent.count, 1)
        XCTAssertEqual(store.recent.first?.outcome, .converted)

        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("/W/한글.txt"))
    }

    /// T2: 아무 일도 없으면 로그도 없다.
    func testNothingToDoProducesNoEntries() {
        let store = log()
        store.record([.notNeeded, .vanished, .notNeeded])

        XCTAssertTrue(store.recent.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path),
                       "기록할 것이 없는데 파일을 만들었다")
    }

    func testMemoryIsCappedAtCapacity() {
        let store = log(capacity: 10)
        for i in 0..<50 {
            store.record([.renamed(path: "/W/파일\(i).txt", newName: "파일\(i).txt")])
        }
        XCTAssertEqual(store.recent.count, 10)
    }

    func testMostRecentEntryComesFirst() {
        let store = log()
        store.record([.renamed(path: "/W/먼저.txt", newName: "먼저.txt")])
        store.record([.renamed(path: "/W/나중.txt", newName: "나중.txt")])

        XCTAssertEqual(store.recent.first?.path, "/W/나중.txt")
    }

    func testFailureIsRecordedWithAReadableReason() {
        let store = log()
        store.record([.conflict(existing: "/W/한글.txt")])

        let outcome = store.recent.first?.outcome
        XCTAssertEqual(outcome, .conflict)
        XCTAssertTrue(outcome?.description.contains("건너뛰었습니다") == true)
    }

    // MARK: - 회전 (FR-10)

    func testFileRotatesOnceItGrowsPastTheLimit() throws {
        let store = log(maximumFileSize: 512)
        for i in 0..<200 {
            store.record([.renamed(path: "/W/충분히 긴 이름의 파일\(i).txt", newName: "파일\(i).txt")])
        }

        let rotated = logDirectory.appendingPathComponent("Test.log.1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated.path), "회전 파일이 없다")

        let size = try XCTUnwrap(
            (FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.size] as? NSNumber)?.intValue)
        XCTAssertLessThanOrEqual(size, 512 * 2, "회전 후에도 파일이 계속 자란다")
    }

    /// 회전본은 하나만 보관한다. 무한정 쌓이면 안 된다.
    func testOnlyOneRotatedFileIsKept() throws {
        let store = log(maximumFileSize: 256)
        for i in 0..<400 {
            store.record([.renamed(path: "/W/충분히 긴 이름의 파일\(i).txt", newName: "파일\(i).txt")])
        }

        let files = try FileManager.default.contentsOfDirectory(atPath: logDirectory.path)
        XCTAssertEqual(Set(files), ["Test.log", "Test.log.1"])
    }

    func testNoteGoesToTheFileButNotTheMenu() throws {
        let store = log()
        store.note("감시를 시작했습니다")

        XCTAssertTrue(store.recent.isEmpty, "상태 메시지가 변환 내역에 섞였다")
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("감시를 시작했습니다"))
    }
}
