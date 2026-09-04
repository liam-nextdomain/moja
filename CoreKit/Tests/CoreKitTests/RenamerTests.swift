import XCTest
@testable import CoreKit

/// `Renamer` 통합 테스트 — 임시 디렉터리에 진짜 NFD 파일을 만들어 검증한다 (T1~T6).
///
/// 검증은 `readdir(3)`을 직접 호출해 **디스크에 저장된 원시 바이트**를 본다.
/// `DirectoryReader`로 검증하면 같은 코드로 자기 자신을 확인하는 셈이라, 여기서는
/// 일부러 독립적으로 구현한 헬퍼를 쓴다.
final class RenamerTests: XCTestCase {

    private var root: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "moja-renamer-" + UUID().uuidString
        try XCTUnwrap(root.withCString { mkdir($0, 0o755) } == 0 ? () : nil,
                      "임시 디렉터리를 만들지 못했다")
    }

    override func tearDownWithError() throws {
        guard let root else { return }
        removeTree(root)
    }

    // MARK: - 헬퍼 (Foundation의 경로 변환을 거치지 않는다)

    private func nfd(_ s: String) -> String { s.decomposedStringWithCanonicalMapping }
    private func nfc(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }
    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    @discardableResult
    private func makeFile(_ path: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        let fd = path.withCString { open($0, O_CREAT | O_EXCL | O_WRONLY, 0o644) }
        XCTAssertGreaterThanOrEqual(fd, 0, "파일 생성 실패: \(path)", file: file, line: line)
        if fd >= 0 { close(fd) }
        return path
    }

    @discardableResult
    private func makeDir(_ path: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        XCTAssertEqual(path.withCString { mkdir($0, 0o755) }, 0,
                       "폴더 생성 실패: \(path)", file: file, line: line)
        return path
    }

    /// 독립 구현: 저장된 이름의 원시 바이트를 읽는다.
    private func storedNames(_ dir: String) -> [[UInt8]] {
        var out: [[UInt8]] = []
        guard let d = dir.withCString({ opendir($0) }) else { return out }
        defer { closedir(d) }
        while let e = readdir(d) {
            let ent = e.pointee
            var n = ent.d_name
            let b: [UInt8] = withUnsafeBytes(of: &n) { r in (0..<Int(ent.d_namlen)).map { r[$0] } }
            if b == bytes(".") || b == bytes("..") { continue }
            out.append(b)
        }
        return out.sorted { $0.lexicographicallyPrecedes($1) }
    }

    private func removeTree(_ path: String) {
        var st = stat()
        guard path.withCString({ lstat($0, &st) }) == 0 else { return }
        if st.st_mode & S_IFMT == S_IFDIR {
            for name in storedNames(path) {
                removeTree("\(path)/\(String(decoding: name, as: UTF8.self))")
            }
            _ = path.withCString { rmdir($0) }
        } else {
            _ = path.withCString { unlink($0) }
        }
    }

    private func conversion(_ path: String) -> Conversion {
        let name = String(path[path.index(after: path.lastIndex(of: "/")!)...])
        return Conversion(path: path, newName: Normalizer.normalized(name))
    }

    // MARK: - T1. NFD 이름 파일을 NFC로

    func testRenamesDecomposedFileToComposed() throws {
        let path = makeFile("\(root!)/\(nfd("한글 문서.txt"))")
        XCTAssertEqual(storedNames(root), [bytes(nfd("한글 문서.txt"))], "전제: NFD로 저장돼 있어야 한다")

        let result = Renamer().rename(conversion(path))

        guard case .renamed = result else { return XCTFail("변환 실패: \(result)") }
        XCTAssertEqual(storedNames(root), [bytes(nfc("한글 문서.txt"))],
                       "디스크에 저장된 바이트가 NFC가 아니다")
    }

    // MARK: - T2. 이미 NFC면 아무 일도 없다

    func testAlreadyComposedFileIsUntouched() throws {
        let path = makeFile("\(root!)/\(nfc("한글 문서.txt"))")
        let before = storedNames(root)

        XCTAssertEqual(Renamer().rename(conversion(path)), .notNeeded)
        XCTAssertEqual(storedNames(root), before)
    }

    func testASCIIFileIsUntouched() throws {
        let path = makeFile("\(root!)/report.txt")
        XCTAssertEqual(Renamer().rename(conversion(path)), .notNeeded)
    }

    // MARK: - T5. 하위 폴더 3단계

    func testRenamesFileNestedThreeLevelsDeep() throws {
        let a = makeDir("\(root!)/\(nfc("가"))")
        let b = makeDir("\(a)/\(nfc("나"))")
        let c = makeDir("\(b)/\(nfc("다"))")
        let path = makeFile("\(c)/\(nfd("깊은 파일.txt"))")

        guard case .renamed = Renamer().rename(conversion(path)) else {
            return XCTFail("깊은 경로에서 변환 실패")
        }
        XCTAssertEqual(storedNames(c), [bytes(nfc("깊은 파일.txt"))])
    }

    // MARK: - 폴더 이름 변경

    func testRenamingDirectoryKeepsItsContentsReachable() throws {
        let dir = makeDir("\(root!)/\(nfd("자료 모음"))")
        makeFile("\(dir)/inside.txt")

        guard case .renamed = Renamer().rename(conversion(dir)) else {
            return XCTFail("폴더 이름 변경 실패")
        }
        XCTAssertEqual(storedNames(root), [bytes(nfc("자료 모음"))])
        XCTAssertEqual(storedNames("\(root!)/\(nfc("자료 모음"))"), [bytes("inside.txt")],
                       "폴더를 바꾼 뒤 내용물을 잃었다")
    }

    // MARK: - T6. NFD 폴더 안의 NFD 파일들 — 파일 먼저, 폴더 나중

    func testConvertsNestedTreeWithoutBrokenPaths() throws {
        let outer = makeDir("\(root!)/\(nfd("바깥 폴더"))")
        let inner = makeDir("\(outer)/\(nfd("안쪽 폴더"))")
        makeFile("\(outer)/\(nfd("첫째.txt"))")
        makeFile("\(inner)/\(nfd("둘째.txt"))")

        let now = Date().addingTimeInterval(60)   // 방금 만든 파일이 "쓰는 중"에 걸리지 않도록
        let items = [
            FileItem(path: outer, isDirectory: true, isPackage: false, modificationDate: .distantPast),
            FileItem(path: inner, isDirectory: true, isPackage: false, modificationDate: .distantPast),
            FileItem(path: "\(outer)/\(nfd("첫째.txt"))", isDirectory: false, isPackage: false, modificationDate: .distantPast),
            FileItem(path: "\(inner)/\(nfd("둘째.txt"))", isDirectory: false, isPackage: false, modificationDate: .distantPast),
        ]
        let plan = Planner.plan(items: items, now: now, limit: nil)
        XCTAssertEqual(plan.conversions.count, 4)

        let results = Renamer().apply(plan)

        XCTAssertEqual(results.count, 4)
        for r in results {
            guard case .renamed = r else { return XCTFail("경로가 깨졌다: \(r)") }
        }

        let newOuter = "\(root!)/\(nfc("바깥 폴더"))"
        let newInner = "\(newOuter)/\(nfc("안쪽 폴더"))"
        XCTAssertEqual(storedNames(root), [bytes(nfc("바깥 폴더"))])
        XCTAssertEqual(storedNames(newOuter).sorted { $0.lexicographicallyPrecedes($1) },
                       [bytes(nfc("안쪽 폴더")), bytes(nfc("첫째.txt"))]
                            .sorted { $0.lexicographicallyPrecedes($1) })
        XCTAssertEqual(storedNames(newInner), [bytes(nfc("둘째.txt"))])
    }

    // MARK: - 2단계 폴백 (FR-3 2번)

    /// 첫 시도가 저장 형식을 못 바꾸는 볼륨을 흉내 내 폴백 경로를 실제로 태운다.
    /// APFS에서는 첫 시도가 늘 성공하므로, 강제하지 않으면 이 경로가 영영 안 돌아간다.
    func testTwoStepFallbackConvertsTheName() throws {
        let path = makeFile("\(root!)/\(nfd("폴백 대상.txt"))")

        let result = Renamer(forceTwoStepFallback: true).rename(conversion(path))

        guard case .renamed = result else { return XCTFail("폴백 실패: \(result)") }
        XCTAssertEqual(storedNames(root), [bytes(nfc("폴백 대상.txt"))])
    }

    /// 폴백 도중 실패해도 임시 이름을 남기지 않는다. 사용자 파일이 인질이 되면 안 된다.
    func testTwoStepFallbackRestoresOriginalNameOnFailure() throws {
        let path = makeFile("\(root!)/\(nfd("되돌림.txt"))")

        let result = Renamer(forceTwoStepFallback: true,
                             failSecondStepForTesting: true).rename(conversion(path))

        guard case .failed = result else { return XCTFail("실패로 보고해야 한다: \(result)") }
        XCTAssertEqual(storedNames(root), [bytes(nfd("되돌림.txt"))],
                       "원래 이름으로 되돌아오지 않았다")
        _ = path
    }

    // MARK: - 사라진 항목

    func testVanishedItemIsNotAnError() throws {
        let path = "\(root!)/\(nfd("없는 파일.txt"))"
        XCTAssertEqual(Renamer().rename(conversion(path)), .vanished)
    }

    /// 배치 도중 사용자가 파일을 지워도 나머지는 계속 처리한다.
    func testBatchContinuesAfterAVanishedItem() throws {
        let gone = "\(root!)/\(nfd("사라짐.txt"))"
        let alive = makeFile("\(root!)/\(nfd("살아남음.txt"))")

        let items = [gone, alive].map {
            FileItem(path: $0, isDirectory: false, isPackage: false, modificationDate: .distantPast)
        }
        let plan = Planner.plan(items: items, now: Date(), limit: nil)
        let results = Renamer().apply(plan)

        XCTAssertEqual(results.filter { $0 == .vanished }.count, 1)
        XCTAssertEqual(storedNames(root), [bytes(nfc("살아남음.txt"))])
    }

    // MARK: - 덮어쓰기 방지 (FR-3 안전 규칙)

    /// 목적지가 **다른 파일**이면 절대 진행하지 않는다.
    ///
    /// 로컬 볼륨(APFS·HFS+·exFAT)은 정규화를 무시해서 NFD·NFC 공존이 불가능하므로
    /// 이 상황을 파일로 재현할 수 없다 (docs/rename-measurements.md). SMB·NFS는 미측정이다.
    /// 그래서 판정 자체를 직접 검증한다.
    func testDifferentFileAtDestinationIsRefused() throws {
        let a = makeFile("\(root!)/a.txt")
        let b = makeFile("\(root!)/b.txt")

        let idA = try XCTUnwrap(FileIdentity(path: a))
        let idB = try XCTUnwrap(FileIdentity(path: b))

        XCTAssertNotEqual(idA, idB, "서로 다른 파일은 다른 신원을 가져야 한다")
        XCTAssertEqual(idA, try XCTUnwrap(FileIdentity(path: a)), "같은 파일은 같은 신원이어야 한다")
    }

    /// 하드링크는 같은 파일이다 — 이름만 다를 뿐이므로 진행해도 안전하다.
    func testHardLinkIsRecognizedAsTheSameFile() throws {
        let a = makeFile("\(root!)/a.txt")
        let b = "\(root!)/b.txt"
        XCTAssertEqual(a.withCString { ap in b.withCString { bp in link(ap, bp) } }, 0)

        XCTAssertEqual(try XCTUnwrap(FileIdentity(path: a)), try XCTUnwrap(FileIdentity(path: b)))
    }

    // MARK: - 변환이 불가능한 볼륨

    /// HFS+·exFAT은 커널이 이름을 NFD로 되돌린다. 실패를 조용히 반복하는 대신
    /// "이 디스크는 지원하지 않는다"로 판정해야 한다.
    ///
    /// 디스크 이미지를 만들어야 해서 평소 실행에서는 건너뛴다:
    /// ```sh
    /// hdiutil create -size 20m -fs "HFS+" -volname T -type UDIF /tmp/t.dmg
    /// hdiutil attach /tmp/t.dmg -nobrowse && mkdir -p /Volumes/T/t
    /// MOJA_VOLUME_PATH=/Volumes/T/t swift test --package-path CoreKit \
    ///     --filter testUnsupportedVolumeIsReported
    /// ```
    func testUnsupportedVolumeIsReported() throws {
        guard let dir = ProcessInfo.processInfo.environment["MOJA_VOLUME_PATH"] else {
            throw XCTSkip("MOJA_VOLUME_PATH 미지정 — 디스크 이미지가 필요하다")
        }
        let path = makeFile("\(dir)/\(nfd("지원 안 함.txt"))")
        defer { _ = path.withCString { unlink($0) } }

        let result = Renamer().rename(conversion(path))

        guard case .unsupportedVolume(let fileSystem) = result else {
            return XCTFail("지원 안 함으로 보고해야 한다: \(result)")
        }
        XCTAssertFalse(fileSystem.isEmpty)

        // 실패했더라도 파일은 그대로 있어야 한다.
        XCTAssertEqual(storedNames(dir), [bytes(nfd("지원 안 함.txt"))])
    }

    // MARK: - 검증 (FR-3 3번)

    /// 이름을 바꾼 뒤 반드시 다시 나열해 확인한다. String 비교로는 잡히지 않는다.
    func testVerificationComparesBytesNotStrings() throws {
        let path = makeFile("\(root!)/\(nfd("검증.txt"))")
        guard case .renamed(_, let to) = Renamer().rename(conversion(path)) else {
            return XCTFail("변환 실패")
        }
        let stored = try XCTUnwrap(storedNames(root).first)

        XCTAssertEqual(stored, bytes(nfc("검증.txt")))
        XCTAssertNotEqual(stored, bytes(nfd("검증.txt")))
        XCTAssertEqual(Array(to.utf8), stored, "보고한 이름과 저장된 이름이 다르다")
    }
}
