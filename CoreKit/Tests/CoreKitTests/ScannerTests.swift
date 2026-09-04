import XCTest
@testable import CoreKit

/// `Scanner` — 디스크를 훑어 처리 계획을 만든다. 실제 임시 디렉터리로 검증한다.
final class ScannerTests: XCTestCase {

    private var root: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "moja-scanner-" + UUID().uuidString
        XCTAssertEqual(root.withCString { mkdir($0, 0o755) }, 0)
    }

    override func tearDownWithError() throws {
        guard let root else { return }
        removeTree(root)
    }

    // MARK: - 헬퍼

    private func nfd(_ s: String) -> String { s.decomposedStringWithCanonicalMapping }
    private func nfc(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }

    @discardableResult
    private func file(_ relative: String) -> String {
        let path = "\(root!)/\(relative)"
        let fd = path.withCString { open($0, O_CREAT | O_EXCL | O_WRONLY, 0o644) }
        XCTAssertGreaterThanOrEqual(fd, 0, "생성 실패: \(relative)")
        if fd >= 0 { close(fd) }
        return path
    }

    @discardableResult
    private func directory(_ relative: String) -> String {
        let path = "\(root!)/\(relative)"
        XCTAssertEqual(path.withCString { mkdir($0, 0o755) }, 0, "생성 실패: \(relative)")
        return path
    }

    /// 트리 전체의 수정 시각을 과거로 돌린다.
    ///
    /// 갓 만든 항목은 "아직 쓰는 중일 수 있다"는 규칙(FR-2)에 걸려 전부 미뤄진다.
    /// 특히 폴더는 안에 파일을 만들 때마다 수정 시각이 갱신되므로, 항목을 다 만든
    /// **뒤에** 한 번에 되돌려야 한다. 그 규칙 자체는 `PlannerTests`가 검증한다.
    private func settle(_ path: String) {
        var status = stat()
        guard path.withCString({ lstat($0, &status) }) == 0 else { return }
        if status.st_mode & S_IFMT == S_IFDIR {
            for entry in DirectoryReader.entries(at: path) ?? [] {
                settle(path + "/" + entry.name)
            }
        }
        var times = [timeval(tv_sec: 1_600_000_000, tv_usec: 0),
                     timeval(tv_sec: 1_600_000_000, tv_usec: 0)]
        _ = path.withCString { p in times.withUnsafeMutableBufferPointer { utimes(p, $0.baseAddress) } }
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

    private func scan(limit: Int? = nil) -> ScanOutcome {
        settle(root)
        return Scanner.scan(root: root, now: Date(), limit: limit)
    }

    private func plan(limit: Int? = nil) throws -> Plan {
        guard case .scanned(let plan) = scan(limit: limit) else {
            throw XCTSkip("스캔 실패")
        }
        return plan
    }

    private func names(_ plan: Plan) -> Set<String> {
        Set(plan.conversions.map { PathTools.lastComponent(of: $0.path) })
    }

    // MARK: - 기본

    func testFindsDecomposedNamesAtTopLevel() throws {
        file(nfd("한글.txt"))
        file(nfc("이미 조합형.txt"))
        file("ascii.txt")

        let plan = try plan()
        XCTAssertEqual(names(plan), [nfd("한글.txt")])
    }

    func testEmptyDirectoryProducesEmptyPlan() throws {
        XCTAssertTrue(try plan().conversions.isEmpty)
    }

    /// 없는 폴더는 오류가 아니다. 외장 디스크를 뺀 상태다 (FR-1, T11).
    func testMissingRootIsReportedAsUnavailable() {
        XCTAssertEqual(Scanner.scan(root: "\(root!)/없는폴더", now: Date(), limit: nil),
                       .unavailable)
    }

    // MARK: - 재귀 (T5, T6)

    func testDescendsIntoSubdirectories() throws {
        directory(nfc("가"))
        directory(nfc("가/나"))
        directory(nfc("가/나/다"))
        file(nfd("가/나/다/깊은 파일.txt"))

        XCTAssertEqual(names(try plan()), [nfd("깊은 파일.txt")])
    }

    func testCollectsDirectoriesAndFilesTogether() throws {
        directory(nfd("바깥 폴더"))
        file("\(nfd("바깥 폴더"))/\(nfd("안쪽 파일.txt"))")

        let plan = try plan()
        XCTAssertEqual(plan.conversions.count, 2)
        XCTAssertEqual(PathTools.lastComponent(of: plan.conversions.last!.path), nfd("바깥 폴더"),
                       "상위 폴더가 마지막이어야 한다 (FR-4)")
    }

    // MARK: - 들어가지 않는 곳 (T9)

    func testDoesNotDescendIntoPackages() throws {
        directory(nfd("한글 앱.app"))
        directory("\(nfd("한글 앱.app"))/Contents")
        file("\(nfd("한글 앱.app"))/Contents/\(nfd("리소스.png"))")

        let plan = try plan()
        XCTAssertEqual(names(plan), [nfd("한글 앱.app")],
                       "번들 자체만 바꾸고 내부는 건드리지 않아야 한다")
    }

    func testDoesNotDescendIntoHiddenDirectories() throws {
        directory(".hidden")
        file(".hidden/\(nfd("안쪽.txt"))")

        XCTAssertTrue(try plan().conversions.isEmpty)
    }

    /// 심볼릭 링크를 따라가면 감시 폴더 **밖**의 파일 이름을 바꾸게 된다.
    func testDoesNotFollowSymbolicLinks() throws {
        let outside = NSTemporaryDirectory() + "moja-outside-" + UUID().uuidString
        XCTAssertEqual(outside.withCString { mkdir($0, 0o755) }, 0)
        defer { removeTree(outside) }

        let victim = "\(outside)/\(nfd("바깥 파일.txt"))"
        let fd = victim.withCString { open($0, O_CREAT | O_EXCL | O_WRONLY, 0o644) }
        if fd >= 0 { close(fd) }

        let link = "\(root!)/link"
        XCTAssertEqual(outside.withCString { o in link.withCString { l in symlink(o, l) } }, 0)

        let plan = try plan()
        XCTAssertFalse(plan.conversions.contains { $0.path.contains(outside) },
                       "링크를 따라가 감시 폴더 밖을 건드렸다")

        // 링크된 폴더 안의 파일은 그대로 남아 있어야 한다.
        XCTAssertTrue(DirectoryReader.containsExactName(nfd("바깥 파일.txt"), in: outside))
    }

    // MARK: - 폭주 방지 (FR-5, T10)

    func testOverflowIsReportedWithoutConverting() throws {
        for i in 0..<20 { file(nfd("한글\(i).txt")) }

        let plan = try plan(limit: 10)
        XCTAssertTrue(plan.isOverflowing)
        XCTAssertTrue(plan.conversions.isEmpty)
        XCTAssertEqual(plan.candidateCount, 20)
    }

    func testNoLimitScansEverything() throws {
        for i in 0..<20 { file(nfd("한글\(i).txt")) }

        let plan = try plan(limit: nil)
        XCTAssertFalse(plan.isOverflowing)
        XCTAssertEqual(plan.conversions.count, 20)
    }

    // MARK: - 한 폴더만 훑기

    /// 이벤트가 온 폴더 하나만 얕게 본다. 이벤트마다 전체를 훑으면 안 된다.
    func testShallowScanLooksAtOneDirectoryOnly() throws {
        directory(nfc("가"))
        file(nfd("겉.txt"))
        file("\(nfc("가"))/\(nfd("속.txt"))")

        settle(root)
        guard case .scanned(let plan) = Scanner.scanShallow(directories: [root],
                                                            now: Date(), limit: nil) else {
            return XCTFail("스캔 실패")
        }
        XCTAssertEqual(names(plan), [nfd("겉.txt")])
    }

    /// 같은 폴더가 여러 경로로 들어와도 한 번만 훑는다.
    ///
    /// FSEvents는 심볼릭 링크를 푼 경로(`/private/var/…`)를 주는데 설정에는 원래
    /// 경로(`/var/…`)가 들어 있다. 문자열로 중복을 거르면 같은 폴더를 두 번 처리한다.
    func testShallowScanDeduplicatesByFileIdentityNotPathString() throws {
        file(nfd("한 번만.txt"))
        settle(root)

        let viaSymlink = "/private" + root
        try XCTSkipUnless(POSIXFile.exists(viaSymlink), "이 경로에는 /private 별칭이 없다")

        guard case .scanned(let plan) = Scanner.scanShallow(directories: [root, viaSymlink],
                                                            now: Date(), limit: nil) else {
            return XCTFail("스캔 실패")
        }
        XCTAssertEqual(plan.conversions.count, 1, "같은 폴더를 두 번 훑었다")
    }

    func testShallowScanSkipsDirectoriesThatVanished() throws {
        file(nfd("있음.txt"))

        settle(root)
        guard case .scanned(let plan) = Scanner.scanShallow(
            directories: [root, "\(root!)/사라짐"], now: Date(), limit: nil) else {
            return XCTFail("사라진 폴더 때문에 전체가 실패했다")
        }
        XCTAssertEqual(names(plan), [nfd("있음.txt")])
    }
}
