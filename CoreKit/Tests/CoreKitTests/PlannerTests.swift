import XCTest
@testable import CoreKit

/// `Planner` — 무엇을 건드리고 무엇을 건너뛸지, 어떤 순서로 처리할지 정한다 (FR-2, FR-4, FR-5).
///
/// 파일시스템을 만지지 않는다. 항목의 서술(`FileItem`)만 받아 계획을 돌려주므로
/// 위험한 경우를 전부 테스트로 재현할 수 있다.
final class PlannerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// 충분히 오래된 수정 시각 — "아직 쓰는 중" 판정에 걸리지 않는다.
    private var settled: Date { now.addingTimeInterval(-60) }

    private func item(_ path: String,
                      isDirectory: Bool = false,
                      isPackage: Bool = false,
                      modified: Date? = nil) -> FileItem {
        FileItem(path: path,
                 isDirectory: isDirectory,
                 isPackage: isPackage,
                 modificationDate: modified ?? settled)
    }

    /// NFD로 분해된 경로를 만든다. 실제 파인더가 저장하는 형태.
    private func nfd(_ path: String) -> String {
        path.decomposedStringWithCanonicalMapping
    }

    private func plan(_ items: [FileItem], limit: Int? = nil) -> Plan {
        Planner.plan(items: items, now: now, limit: limit)
    }

    // MARK: - 기본 판정

    func testDecomposedNameIsPlannedForConversion() {
        let p = plan([item(nfd("/W/한글.txt"))])
        XCTAssertEqual(p.conversions.count, 1)
        XCTAssertEqual(Array(p.conversions[0].newName.utf8),
                       Array("한글.txt".precomposedStringWithCanonicalMapping.utf8))
        XCTAssertEqual(p.conversions[0].newPath,
                       "/W/" + "한글.txt".precomposedStringWithCanonicalMapping)
    }

    func testAlreadyComposedNameIsSkipped() {
        let p = plan([item("/W/" + "한글.txt".precomposedStringWithCanonicalMapping)])
        XCTAssertTrue(p.conversions.isEmpty)
        XCTAssertEqual(p.skipped.first?.reason, .alreadyNormalized)
    }

    /// 건너뛴 항목은 통계에 남되 "변환 안 함"의 이유가 구분돼야 한다 (FR-6 미리보기).
    func testSkippedItemsCarryTheirReason() {
        let p = plan([
            item(nfd("/W/.숨김.txt")),
            item("/W/.DS_Store"),
            item(nfd("/W/받는중.download")),
            item(nfd("/W/~$문서.docx")),
        ])
        XCTAssertTrue(p.conversions.isEmpty)
        XCTAssertEqual(p.skipped.map(\.reason),
                       [.hidden, .hidden, .temporaryDownload, .officeTemporary])
    }

    // MARK: - 건너뛰기 규칙 (FR-2)

    func testHiddenFilesAreSkipped() {
        for name in [".숨김파일.txt", ".DS_Store", ".localized"] {
            let p = plan([item(nfd("/W/\(name)"))])
            XCTAssertTrue(p.conversions.isEmpty, "'\(name)' 을 건드렸다")
        }
    }

    func testDownloadInProgressExtensionsAreSkipped() {
        for ext in ["download", "crdownload", "part", "partial", "tmp", "temp"] {
            let p = plan([item(nfd("/W/받는 중.\(ext)"))])
            XCTAssertTrue(p.conversions.isEmpty, "'.\(ext)' 를 건드렸다 — 다운로드가 깨진다")
            XCTAssertEqual(p.skipped.first?.reason, .temporaryDownload)
        }
    }

    func testTemporaryExtensionMatchIsCaseInsensitive() {
        let p = plan([item(nfd("/W/받는 중.DOWNLOAD"))])
        XCTAssertTrue(p.conversions.isEmpty)
    }

    /// 확장자가 임시 확장자로 "끝나는" 게 아니라 정확히 일치해야 한다.
    func testNamesMerelyEndingWithTempWordAreNotSkipped() {
        let p = plan([item(nfd("/W/한글.notatmp"))])
        XCTAssertEqual(p.conversions.count, 1, "'.notatmp' 는 임시 파일이 아니다")
    }

    func testOfficeTemporaryFilesAreSkipped() {
        let p = plan([item(nfd("/W/~$보고서.docx"))])
        XCTAssertTrue(p.conversions.isEmpty)
        XCTAssertEqual(p.skipped.first?.reason, .officeTemporary)
    }

    // MARK: - 패키지 (T9)

    /// 번들 **자체**의 이름은 바꾼다.
    func testPackageItselfIsConverted() {
        let p = plan([item(nfd("/W/한글 앱.app"), isDirectory: true, isPackage: true)])
        XCTAssertEqual(p.conversions.count, 1)
    }

    /// 번들 **내부**는 건드리지 않는다. 앱 서명이 깨진다.
    func testContentsInsidePackageAreSkipped() {
        let p = plan([item(nfd("/W/한글 앱.app/Contents/Resources/한글.png"))])
        XCTAssertTrue(p.conversions.isEmpty)
        XCTAssertEqual(p.skipped.first?.reason, .insidePackage)
    }

    func testAllKnownPackageExtensionsShieldTheirContents() {
        for ext in ["app", "photoslibrary", "bundle", "framework", "pkg"] {
            let p = plan([item(nfd("/W/묶음.\(ext)/안쪽/한글.txt"))])
            XCTAssertTrue(p.conversions.isEmpty, "'.\(ext)' 내부를 건드렸다")
        }
    }

    func testPackageExtensionMatchIsCaseInsensitive() {
        let p = plan([item(nfd("/W/묶음.APP/안쪽/한글.txt"))])
        XCTAssertTrue(p.conversions.isEmpty)
    }

    /// 확장자가 우연히 겹치는 평범한 폴더는 보호 대상이 아니다.
    func testDirectoryWithoutPackageExtensionIsNotShielded() {
        let p = plan([item(nfd("/W/평범한 폴더/한글.txt"))])
        XCTAssertEqual(p.conversions.count, 1)
    }

    // MARK: - 쓰는 중일 수 있는 파일 (FR-2)

    func testRecentlyModifiedItemIsDeferred() {
        let p = plan([item(nfd("/W/방금 저장.txt"), modified: now.addingTimeInterval(-1))])
        XCTAssertTrue(p.conversions.isEmpty, "1초 전 수정 — 아직 쓰는 중일 수 있다")
        XCTAssertEqual(p.skipped.first?.reason, .recentlyModified)
    }

    func testItemModifiedLongerAgoIsProcessed() {
        let p = plan([item(nfd("/W/저장 끝.txt"), modified: now.addingTimeInterval(-3))])
        XCTAssertEqual(p.conversions.count, 1)
    }

    /// 미래 시각(시계 어긋남·네트워크 볼륨)도 "방금"으로 본다. 확신이 없으면 건드리지 않는다.
    func testFutureModificationDateIsTreatedAsRecent() {
        let p = plan([item(nfd("/W/미래.txt"), modified: now.addingTimeInterval(60))])
        XCTAssertTrue(p.conversions.isEmpty)
        XCTAssertEqual(p.skipped.first?.reason, .recentlyModified)
    }

    // MARK: - 처리 순서 (FR-4)

    /// 깊은 것부터. 상위 폴더를 먼저 바꾸면 하위 경로가 무효가 된다.
    func testDeeperPathsAreProcessedFirst() {
        let p = plan([
            item(nfd("/W/가나"), isDirectory: true),
            item(nfd("/W/가나/다라/마바.txt")),
            item(nfd("/W/가나/다라"), isDirectory: true),
        ])
        let depths = p.conversions.map { $0.path.split(separator: "/").count }
        XCTAssertEqual(depths, depths.sorted(by: >), "깊이 내림차순이 아니다")
        XCTAssertEqual(p.conversions.last?.path, nfd("/W/가나"), "상위 폴더가 마지막이어야 한다")
    }

    /// 같은 깊이면 파일 먼저, 폴더 나중 (T6).
    func testFilesComeBeforeDirectoriesAtTheSameDepth() {
        let p = plan([
            item(nfd("/W/가나"), isDirectory: true),
            item(nfd("/W/다라.txt")),
        ])
        XCTAssertEqual(p.conversions.first?.path, nfd("/W/다라.txt"))
        XCTAssertEqual(p.conversions.last?.path, nfd("/W/가나"))
    }

    /// 순서가 입력 순서에 흔들리면 안 된다.
    func testOrderingIsStableRegardlessOfInputOrder() {
        let items = [
            item(nfd("/W/가/나/다.txt")),
            item(nfd("/W/가/나"), isDirectory: true),
            item(nfd("/W/가"), isDirectory: true),
        ]
        let forward = plan(items).conversions.map(\.path)
        let backward = plan(items.reversed()).conversions.map(\.path)
        XCTAssertEqual(forward, backward)
    }

    // MARK: - 폭주 방지 (FR-5, T10)

    func testBatchOverLimitIsRefusedEntirely() {
        let many = (0..<501).map { item(nfd("/W/파일\($0).txt")) }
        let p = plan(many, limit: 500)
        XCTAssertTrue(p.isOverflowing)
        XCTAssertTrue(p.conversions.isEmpty, "폭주 시에는 하나도 처리하지 않는다")
        XCTAssertEqual(p.candidateCount, 501, "몇 개였는지는 사용자에게 알려야 한다")
    }

    func testBatchAtLimitIsProcessed() {
        let many = (0..<500).map { item(nfd("/W/파일\($0).txt")) }
        let p = plan(many, limit: 500)
        XCTAssertFalse(p.isOverflowing)
        XCTAssertEqual(p.conversions.count, 500)
    }

    /// 일괄 변환은 개수 제한이 없다 (FR-6). 제한은 실시간 감시에만 건다.
    func testNoLimitMeansNoOverflow() {
        let many = (0..<5_000).map { item(nfd("/W/파일\($0).txt")) }
        let p = plan(many, limit: nil)
        XCTAssertFalse(p.isOverflowing)
        XCTAssertEqual(p.conversions.count, 5_000)
    }

    /// 건너뛴 항목은 폭주 계산에 넣지 않는다.
    func testSkippedItemsDoNotCountTowardTheLimit() {
        var items = (0..<400).map { item(nfd("/W/파일\($0).txt")) }
        items += (0..<400).map { item(nfd("/W/.숨김\($0).txt")) }
        let p = plan(items, limit: 500)
        XCTAssertFalse(p.isOverflowing)
        XCTAssertEqual(p.conversions.count, 400)
    }

    // MARK: - 순회 범위 (T9)

    func testDescendsIntoOrdinaryDirectory() {
        XCTAssertTrue(Planner.shouldDescend(into: item(nfd("/W/자료 모음"), isDirectory: true)))
    }

    func testDoesNotDescendIntoFile() {
        XCTAssertFalse(Planner.shouldDescend(into: item(nfd("/W/한글.txt"))))
    }

    /// 번들 안으로 들어가지 않는다. 확장자로도, `isPackage` 플래그로도 막는다.
    func testDoesNotDescendIntoPackage() {
        XCTAssertFalse(Planner.shouldDescend(
            into: item(nfd("/W/한글 앱.app"), isDirectory: true, isPackage: false)),
            "확장자만으로도 막아야 한다")
        XCTAssertFalse(Planner.shouldDescend(
            into: item(nfd("/W/사진 보관함"), isDirectory: true, isPackage: true)),
            "확장자가 없어도 isPackage면 막아야 한다")
    }

    func testDoesNotDescendIntoHiddenDirectory() {
        XCTAssertFalse(Planner.shouldDescend(into: item("/W/.git", isDirectory: true)))
    }

    func testDoesNotDescendIntoDirectoryAlreadyInsideAPackage() {
        XCTAssertFalse(Planner.shouldDescend(
            into: item(nfd("/W/한글 앱.app/Contents"), isDirectory: true)))
    }

    // MARK: - 경계값

    func testEmptyInputProducesEmptyPlan() {
        let p = plan([])
        XCTAssertTrue(p.conversions.isEmpty)
        XCTAssertTrue(p.skipped.isEmpty)
        XCTAssertFalse(p.isOverflowing)
    }

    /// 감시 폴더 자체(루트)가 목록에 들어와도 이름을 바꾸지 않는다.
    func testRootPathIsNeverRenamed() {
        let p = plan([item("/", isDirectory: true)])
        XCTAssertTrue(p.conversions.isEmpty)
    }
}
