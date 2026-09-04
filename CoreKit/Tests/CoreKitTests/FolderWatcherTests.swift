import XCTest
@testable import CoreKit

/// `FolderWatcher` 통합 테스트 — 진짜 FSEvents로 진짜 파일을 감시한다 (T1~T4, T10, T11).
///
/// 커널 이벤트를 기다리므로 느리다. 그래도 이 계층은 실제로 돌려 보지 않으면
/// 검증했다고 할 수 없다. 대기 시간은 넉넉히 잡되, **실제 걸린 시간을 기록**한다.
final class FolderWatcherTests: XCTestCase {

    private var root: String!
    private var queue: DispatchQueue!
    private var watcher: FolderWatcher?

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "moja-watch-" + UUID().uuidString
        XCTAssertEqual(root.withCString { mkdir($0, 0o755) }, 0)
        queue = DispatchQueue(label: "moja.test.watch")
    }

    override func tearDownWithError() throws {
        watcher?.stop()
        watcher = nil
        guard let root else { return }
        removeTree(root)
    }

    // MARK: - 헬퍼

    private func nfd(_ s: String) -> String { s.decomposedStringWithCanonicalMapping }
    private func nfc(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }

    @discardableResult
    private func makeFile(_ path: String) -> String {
        let fd = path.withCString { open($0, O_CREAT | O_EXCL | O_WRONLY, 0o644) }
        XCTAssertGreaterThanOrEqual(fd, 0, "생성 실패: \(path)")
        if fd >= 0 { close(fd) }
        return path
    }

    private func removeTree(_ path: String) {
        var st = stat()
        guard path.withCString({ lstat($0, &st) }) == 0 else { return }
        if st.st_mode & S_IFMT == S_IFDIR {
            for entry in DirectoryReader.entries(at: path) ?? [] {
                removeTree(path + "/" + entry.name)
            }
            _ = path.withCString { rmdir($0) }
        } else {
            _ = POSIXFile.remove(path)
        }
    }

    /// 감시를 시작하고, 원하는 활동이 올 때까지 기다린다. 걸린 시간을 함께 돌려준다.
    private func watchUntil(
        batchLimit: Int? = Planner.watchBatchLimit,
        timeout: TimeInterval = 20,
        setUp: () -> Void,
        matching predicate: @escaping (WatchActivity) -> Bool
    ) -> (activity: WatchActivity?, elapsed: TimeInterval) {
        let expectation = expectation(description: "감시 활동")
        let lock = NSLock()
        var matched: WatchActivity?
        var started = Date()

        let created = FolderWatcher(root: root, queue: queue, batchLimit: batchLimit) { activity in
            guard predicate(activity) else { return }
            lock.lock()
            if matched == nil {
                matched = activity
                expectation.fulfill()
            }
            lock.unlock()
        }
        watcher = created
        created.start()

        // 최초 전체 스캔이 끝날 짬을 준 뒤에 파일을 만든다. 그래야 FSEvents 경로를 탄다.
        queue.sync {}
        started = Date()
        setUp()

        wait(for: [expectation], timeout: timeout)

        lock.lock(); defer { lock.unlock() }
        return (matched, Date().timeIntervalSince(started))
    }

    // MARK: - T1. 감시 폴더에 분해된 이름의 파일 생성

    func testConvertsFileCreatedWhileWatching() {
        let (activity, elapsed) = watchUntil {
            makeFile("\(root!)/\(nfd("한글 문서.txt"))")
        } matching: {
            if case .converted = $0 { return true } else { return false }
        }

        guard case .converted(let results)? = activity else {
            return XCTFail("변환 알림이 오지 않았다")
        }
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(DirectoryReader.containsExactName(nfc("한글 문서.txt"), in: root))

        // 실제 소요 시간을 기록한다. T1의 기준치를 정하는 근거다.
        print("‼️ T1 소요 시간: \(String(format: "%.2f", elapsed))초")
    }

    // MARK: - T2. 이미 조합형이면 아무 일도 없다

    func testComposedFileProducesNoActivity() {
        let expectation = expectation(description: "조용해야 한다")
        expectation.isInverted = true

        let created = FolderWatcher(root: root, queue: queue) { activity in
            if case .converted = activity { expectation.fulfill() }
        }
        watcher = created
        created.start()
        queue.sync {}

        makeFile("\(root!)/\(nfc("이미 조합형.txt"))")

        wait(for: [expectation], timeout: 8)
        XCTAssertTrue(DirectoryReader.containsExactName(nfc("이미 조합형.txt"), in: root))
    }

    // MARK: - T4. 다른 폴더에서 옮겨 온 파일

    func testConvertsFileMovedIntoWatchedFolder() {
        let outside = NSTemporaryDirectory() + "moja-src-" + UUID().uuidString
        XCTAssertEqual(outside.withCString { mkdir($0, 0o755) }, 0)
        defer { removeTree(outside) }

        let source = makeFile("\(outside)/\(nfd("옮겨 온 파일.txt"))")

        let (activity, _) = watchUntil {
            let destination = "\(self.root!)/\(self.nfd("옮겨 온 파일.txt"))"
            XCTAssertEqual(POSIXFile.move(source, to: destination), 0)
        } matching: {
            if case .converted = $0 { return true } else { return false }
        }

        XCTAssertNotNil(activity)
        XCTAssertTrue(DirectoryReader.containsExactName(nfc("옮겨 온 파일.txt"), in: root))
    }

    // MARK: - 시작 시 전체 스캔

    /// 앱이 꺼져 있는 동안 생긴 파일도 잡아야 한다.
    func testConvertsFilesThatExistedBeforeWatchingStarted() {
        makeFile("\(root!)/\(nfd("먼저 있던 파일.txt"))")

        let (activity, _) = watchUntil(timeout: 20) {
            // 시작 시 전체 스캔이 알아서 잡는다. 따로 할 일이 없다.
        } matching: {
            if case .converted = $0 { return true } else { return false }
        }

        XCTAssertNotNil(activity)
        XCTAssertTrue(DirectoryReader.containsExactName(nfc("먼저 있던 파일.txt"), in: root))
    }

    // MARK: - T10. 폭주 방지

    func testLargeBatchIsReportedAsOverflowWithoutConverting() {
        for i in 0..<30 { makeFile("\(root!)/\(nfd("한글\(i).txt"))") }

        let (activity, _) = watchUntil(batchLimit: 10) {
        } matching: {
            if case .overflowed = $0 { return true } else { return false }
        }

        guard case .overflowed(let candidates)? = activity else {
            return XCTFail("폭주로 보고하지 않았다")
        }
        XCTAssertEqual(candidates, 30)

        // 하나도 바뀌지 않았어야 한다.
        XCTAssertTrue(DirectoryReader.containsExactName(nfd("한글0.txt"), in: root))
        XCTAssertFalse(DirectoryReader.containsExactName(nfc("한글0.txt"), in: root))
    }

    // MARK: - T11. 없는 폴더

    func testMissingFolderIsReportedAsUnavailable() {
        let missing = "\(root!)/없는폴더"
        let expectation = expectation(description: "연결 안 됨")

        let created = FolderWatcher(root: missing, queue: queue) { activity in
            if activity == .unavailable { expectation.fulfill() }
        }
        watcher = created
        created.start()

        wait(for: [expectation], timeout: 10)
    }

    // MARK: - 무한 루프 방지 (FR-5)

    /// 우리가 바꾼 이름이 다시 우리를 부르는 일이 없어야 한다.
    ///
    /// 한 번 변환된 뒤로는 추가 변환 알림이 오지 않아야 한다. 온다면 앱이
    /// 자기 꼬리를 물고 있는 것이다.
    func testConversionDoesNotTriggerFurtherConversions() {
        let first = expectation(description: "첫 변환")
        let extra = expectation(description: "추가 변환은 없어야 한다")
        extra.isInverted = true

        let counter = NSLock()
        var conversions = 0

        let created = FolderWatcher(root: root, queue: queue) { activity in
            guard case .converted = activity else { return }
            counter.lock()
            conversions += 1
            let count = conversions
            counter.unlock()
            if count == 1 { first.fulfill() } else { extra.fulfill() }
        }
        watcher = created
        created.start()
        queue.sync {}

        makeFile("\(root!)/\(nfd("루프 시험.txt"))")

        wait(for: [first], timeout: 20)
        wait(for: [extra], timeout: 8)
        XCTAssertTrue(DirectoryReader.containsExactName(nfc("루프 시험.txt"), in: root))
    }
}
