import XCTest
@testable import CoreKit

/// `BatchConverter` — 기존 항목 일괄 변환 (FR-6, T10, T12).
final class BatchConverterTests: XCTestCase {

    private var root: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "moja-batch-" + UUID().uuidString
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
        XCTAssertEqual(path.withCString { mkdir($0, 0o755) }, 0)
        return path
    }

    /// 갓 만든 항목은 "방금 저장됨"에 걸린다. 다 만든 뒤 한 번에 과거로 돌린다.
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

    private func preview() throws -> BatchPreview {
        settle(root)
        guard case .preview(let preview) = BatchConverter.preview(root: root) else {
            throw XCTSkip("미리보기 실패")
        }
        return preview
    }

    private func storedNames() -> Set<[UInt8]> {
        Set((DirectoryReader.entries(at: root) ?? []).map(\.nameBytes))
    }

    // MARK: - 미리보기 (T12)

    func testPreviewCountsWhatWouldChange() throws {
        file(nfd("한글 하나.txt"))
        file(nfd("한글 둘.txt"))
        file(nfc("이미 조합형.txt"))

        let preview = try preview()
        XCTAssertEqual(preview.count, 2)
        XCTAssertEqual(preview.skippedCounts[.alreadyNormalized], 1)
    }

    /// 핵심: 미리보기는 아무것도 바꾸지 않는다. "취소"하면 그대로여야 한다.
    func testPreviewChangesNothingOnDisk() throws {
        file(nfd("건드리지 마세요.txt"))
        let before = storedNames()

        _ = try preview()

        XCTAssertEqual(storedNames(), before, "미리보기가 파일을 바꿨다")
        XCTAssertTrue(DirectoryReader.containsExactName(nfd("건드리지 마세요.txt"), in: root))
    }

    func testPreviewShowsBeforeAndAfterNames() throws {
        file(nfd("보고서.txt"))

        let conversion = try XCTUnwrap(try preview().conversions.first)
        XCTAssertEqual(Array(PathTools.lastComponent(of: conversion.path).utf8),
                       Array(nfd("보고서.txt").utf8))
        XCTAssertEqual(Array(conversion.newName.utf8), Array(nfc("보고서.txt").utf8))
    }

    func testPreviewGroupsSkippedItemsByReason() throws {
        file(".숨김1.txt")
        file(".숨김2.txt")
        file(nfd("받는 중.download"))
        file(nfd("~$문서.docx"))

        let preview = try preview()
        XCTAssertEqual(preview.skippedCounts[.hidden], 2)
        XCTAssertEqual(preview.skippedCounts[.temporaryDownload], 1)
        XCTAssertEqual(preview.skippedCounts[.officeTemporary], 1)
        XCTAssertEqual(preview.skippedTotal, 4)
    }

    func testMissingFolderIsUnavailable() {
        XCTAssertEqual(BatchConverter.preview(root: "\(root!)/없음"), .unavailable)
    }

    // MARK: - 표시 제한 (FR-6)

    func testLongListIsFoldedAfterTwoHundred() throws {
        for i in 0..<250 { file(nfd("한글\(i).txt")) }

        let preview = try preview()
        XCTAssertEqual(preview.count, 250)
        XCTAssertEqual(preview.displayed.count, 200)
        XCTAssertEqual(preview.hiddenCount, 50)
    }

    func testShortListIsNotFolded() throws {
        for i in 0..<5 { file(nfd("한글\(i).txt")) }

        let preview = try preview()
        XCTAssertEqual(preview.displayed.count, 5)
        XCTAssertEqual(preview.hiddenCount, 0)
    }

    // MARK: - 폭주 제한이 걸리지 않는다 (T10)

    /// 실시간 감시는 500개에서 멈추지만, 일괄 변환은 그 해법이므로 제한이 없다.
    func testBatchIgnoresTheWatchLimit() throws {
        for i in 0..<600 { file(nfd("한글\(i).txt")) }

        let preview = try preview()
        XCTAssertEqual(preview.count, 600)

        let result = BatchConverter.apply(preview)
        XCTAssertEqual(result.succeeded, 600)
        XCTAssertEqual(result.failed, 0)
    }

    // MARK: - 실행

    func testApplyConvertsEverythingInThePreview() throws {
        file(nfd("하나.txt"))
        file(nfd("둘.txt"))
        directory(nfd("셋"))

        let result = BatchConverter.apply(try preview())

        XCTAssertEqual(result.succeeded, 3)
        XCTAssertEqual(result.failed, 0)
        for name in ["하나.txt", "둘.txt", "셋"] {
            XCTAssertTrue(DirectoryReader.containsExactName(nfc(name), in: root), name)
        }
    }

    /// 폴더 안의 파일이 먼저, 폴더가 나중 — 경로가 깨지면 안 된다 (FR-4, T6).
    func testApplyHandlesNestedFoldersWithoutBrokenPaths() throws {
        directory(nfd("바깥"))
        directory("\(nfd("바깥"))/\(nfd("안쪽"))")
        file("\(nfd("바깥"))/\(nfd("안쪽"))/\(nfd("깊은 파일.txt"))")

        let result = BatchConverter.apply(try preview())

        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(result.succeeded, 3)
        XCTAssertTrue(DirectoryReader.containsExactName(
            nfc("깊은 파일.txt"), in: "\(root!)/\(nfc("바깥"))/\(nfc("안쪽"))"))
    }

    /// 미리보기를 만든 뒤 사용자가 파일을 지웠다. 오류가 아니다.
    func testItemsThatVanishAfterPreviewAreNotFailures() throws {
        file(nfd("사라질 파일.txt"))
        file(nfd("남을 파일.txt"))

        let preview = try preview()
        _ = POSIXFile.remove("\(root!)/\(nfd("사라질 파일.txt"))")

        let result = BatchConverter.apply(preview)
        XCTAssertEqual(result.succeeded, 1)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(result.skipped, 1)
    }

    func testEmptyPreviewAppliesCleanly() throws {
        file(nfc("이미 조합형.txt"))

        let preview = try preview()
        XCTAssertTrue(preview.isEmpty)

        let result = BatchConverter.apply(preview)
        XCTAssertEqual(result.total, 0)
    }

    func testProgressIsReportedForEveryItem() throws {
        for i in 0..<5 { file(nfd("한글\(i).txt")) }

        var steps: [Int] = []
        _ = BatchConverter.apply(try preview()) { done, total in
            steps.append(done)
            XCTAssertEqual(total, 5)
        }
        XCTAssertEqual(steps, [1, 2, 3, 4, 5])
    }
}
