import XCTest
@testable import CoreKit

/// `DirectoryReader`와 `VolumeCapabilities` — 이름 변경이 정말 먹혔는지 판단하는 마지막 관문.
///
/// `Renamer` 통합 테스트만으로는 이 계층이 검증되지 않는다. APFS에서는 rename이
/// 실제로 성공하기 때문에, 검증 로직이 망가져 있어도 통합 테스트는 통과한다.
/// 그래서 판정 자체를 여기서 직접 확인한다.
final class DirectoryReaderTests: XCTestCase {

    private var root: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "moja-reader-" + UUID().uuidString
        XCTAssertEqual(root.withCString { mkdir($0, 0o755) }, 0)
    }

    override func tearDownWithError() throws {
        guard let root else { return }
        for entry in DirectoryReader.entries(at: root) ?? [] {
            let path = root + "/" + entry.name
            _ = entry.isDirectory ? path.withCString { rmdir($0) } : POSIXFile.remove(path)
        }
        _ = root.withCString { rmdir($0) }
    }

    private func nfd(_ s: String) -> String { s.decomposedStringWithCanonicalMapping }
    private func nfc(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }

    private func makeFile(_ name: String) {
        let fd = "\(root!)/\(name)".withCString { open($0, O_CREAT | O_EXCL | O_WRONLY, 0o644) }
        XCTAssertGreaterThanOrEqual(fd, 0)
        if fd >= 0 { close(fd) }
    }

    // MARK: - 저장된 바이트를 그대로 읽는가

    func testReadsComposedNameAsStored() {
        makeFile(nfc("한글.txt"))
        let entries = DirectoryReader.entries(at: root) ?? []
        XCTAssertEqual(entries.map(\.nameBytes), [Array(nfc("한글.txt").utf8)])
    }

    func testReadsDecomposedNameAsStored() {
        makeFile(nfd("한글.txt"))
        let entries = DirectoryReader.entries(at: root) ?? []
        XCTAssertEqual(entries.map(\.nameBytes), [Array(nfd("한글.txt").utf8)])
    }

    // MARK: - 핵심: 두 형태를 구분하는가

    /// 저장된 것이 NFC일 때, NFC 이름으로는 찾고 NFD 이름으로는 못 찾아야 한다.
    ///
    /// 이 구분이 무너지면 `Renamer`의 검증이 아무것도 검증하지 못한다.
    /// `lstat`으로 확인하면 정확히 이렇게 무너진다 — 정규화를 무시하는 볼륨에서는
    /// 두 경로가 모두 같은 파일을 찾아내기 때문이다.
    func testExactNameMatchDistinguishesNormalizationForms() {
        makeFile(nfc("한글.txt"))

        XCTAssertTrue(DirectoryReader.containsExactName(nfc("한글.txt"), in: root))
        XCTAssertFalse(DirectoryReader.containsExactName(nfd("한글.txt"), in: root),
                       "NFD 이름으로도 찾아진다면 검증이 무의미하다")
    }

    /// 대조군: `lstat`은 둘 다 찾아낸다. 그래서 검증에 쓰면 안 된다.
    func testLstatCannotBeUsedForVerification() {
        makeFile(nfc("한글.txt"))

        XCTAssertTrue(POSIXFile.exists("\(root!)/\(nfc("한글.txt"))"))
        XCTAssertTrue(POSIXFile.exists("\(root!)/\(nfd("한글.txt"))"),
                      "이 전제가 깨졌다면 볼륨이 정규화를 구분한다는 뜻이다")
    }

    func testExactNameMatchIsFalseWhenStoredAsDecomposed() {
        makeFile(nfd("한글.txt"))
        XCTAssertFalse(DirectoryReader.containsExactName(nfc("한글.txt"), in: root),
                       "아직 안 바뀐 파일을 바뀌었다고 보고하면 안 된다")
    }

    // MARK: - 그 밖

    func testDirectoryFlagIsReported() {
        makeFile("file.txt")
        XCTAssertEqual("\(root!)/dir".withCString { mkdir($0, 0o755) }, 0)

        let entries = DirectoryReader.entries(at: root) ?? []
        XCTAssertEqual(entries.first { $0.name == "dir" }?.isDirectory, true)
        XCTAssertEqual(entries.first { $0.name == "file.txt" }?.isDirectory, false)
    }

    func testDotEntriesAreExcluded() {
        makeFile("a.txt")
        XCTAssertEqual(DirectoryReader.entries(at: root)?.count, 1)
    }

    /// 열 수 없는 디렉터리는 오류가 아니라 `nil`이다 (FR-1: 조용히 건너뛴다).
    func testUnreadableDirectoryReturnsNil() {
        XCTAssertNil(DirectoryReader.entries(at: "\(root!)/없는폴더"))
        XCTAssertFalse(DirectoryReader.containsExactName("아무거나", in: "\(root!)/없는폴더"))
    }

    // MARK: - 볼륨 능력 측정

    func testAPFSIsReportedAsSupported() {
        XCTAssertEqual(VolumeCapabilities().support(forDirectory: root), .supported)
    }

    /// 검사 파일을 남기지 않는다. 사용자 폴더에 쓰레기를 흘리면 안 된다.
    func testProbeLeavesNothingBehind() {
        makeFile("기존.txt")
        _ = VolumeCapabilities().support(forDirectory: root)
        XCTAssertEqual(DirectoryReader.entries(at: root)?.count, 1,
                       "검사 파일이 남았다")
    }

    /// 볼륨당 한 번만 측정한다. 같은 인스턴스로 여러 번 물어도 파일을 다시 만들지 않는다.
    func testResultIsCachedPerVolume() {
        let capabilities = VolumeCapabilities()
        XCTAssertEqual(capabilities.support(forDirectory: root), .supported)
        XCTAssertEqual(capabilities.support(forDirectory: NSTemporaryDirectory()), .supported)
        XCTAssertEqual(DirectoryReader.entries(at: root)?.count, 0)
    }
}
