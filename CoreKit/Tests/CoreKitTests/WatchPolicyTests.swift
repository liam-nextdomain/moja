import XCTest
@testable import CoreKit

/// `IgnoreList`와 `Debouncer` — 감시가 자기 꼬리를 물지 않게 하는 두 장치 (FR-2, FR-5).
///
/// 시각을 주입받는 순수 상태 기계라 타이머 없이 전부 검증한다.
final class WatchPolicyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func t(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: - 무시 목록 (FR-5)

    func testRecentlyRenamedPathIsIgnored() {
        var list = IgnoreList()
        list.ignore("/W/한글.txt", at: t0)
        XCTAssertTrue(list.contains("/W/한글.txt", at: t(1)))
    }

    func testIgnoreExpiresAfterThreeSeconds() {
        var list = IgnoreList()
        list.ignore("/W/한글.txt", at: t0)
        XCTAssertTrue(list.contains("/W/한글.txt", at: t(2.9)))
        XCTAssertFalse(list.contains("/W/한글.txt", at: t(3.1)))
    }

    /// 우리가 바꾼 이름은 두 형태 모두 무시해야 한다.
    ///
    /// rename 직후 FSEvents는 바뀌기 전 경로로도, 바뀐 뒤 경로로도 이벤트를 줄 수 있다.
    /// 둘은 같은 파일이므로 어느 쪽이 와도 무시한다.
    func testBothNormalizationFormsOfTheSamePathAreIgnored() {
        var list = IgnoreList()
        list.ignore("/W/" + "한글.txt".precomposedStringWithCanonicalMapping, at: t0)

        XCTAssertTrue(list.contains("/W/" + "한글.txt".decomposedStringWithCanonicalMapping, at: t(1)),
                      "분해형 경로로 온 이벤트를 놓쳤다")
    }

    func testUnrelatedPathIsNotIgnored() {
        var list = IgnoreList()
        list.ignore("/W/한글.txt", at: t0)
        XCTAssertFalse(list.contains("/W/다른.txt", at: t(1)))
    }

    /// 만료된 항목은 실제로 버려야 한다. 24시간 감시에서 메모리가 늘면 안 된다 (T15).
    func testExpiredEntriesArePurged() {
        var list = IgnoreList()
        for i in 0..<1_000 { list.ignore("/W/파일\(i).txt", at: t0) }
        XCTAssertEqual(list.count, 1_000)

        list.purge(at: t(4))
        XCTAssertEqual(list.count, 0)
    }

    func testPurgeKeepsLiveEntries() {
        var list = IgnoreList()
        list.ignore("/W/오래된.txt", at: t0)
        list.ignore("/W/최근.txt", at: t(2.5))

        list.purge(at: t(4))
        XCTAssertEqual(list.count, 1)
        XCTAssertTrue(list.contains("/W/최근.txt", at: t(4)))
    }

    /// 같은 경로를 다시 무시하면 시계가 다시 시작된다.
    func testReIgnoringExtendsTheWindow() {
        var list = IgnoreList()
        list.ignore("/W/한글.txt", at: t0)
        list.ignore("/W/한글.txt", at: t(2))
        XCTAssertTrue(list.contains("/W/한글.txt", at: t(4)))
        XCTAssertEqual(list.count, 1)
    }

    // MARK: - 디바운스 (FR-2)

    func testNothingPendingMeansNoDeadline() {
        let debouncer = Debouncer()
        XCTAssertNil(debouncer.deadline)
    }

    func testDeadlineIsQuietPeriodAfterTheLastEvent() {
        var debouncer = Debouncer()
        debouncer.record(["/W"], at: t0)
        XCTAssertEqual(debouncer.deadline, t(1.5))
    }

    /// 이벤트가 이어지면 기다린다. 복사가 끝난 뒤에 처리하려는 것이다.
    func testNewEventPushesTheDeadlineBack() {
        var debouncer = Debouncer()
        debouncer.record(["/W"], at: t0)
        debouncer.record(["/W"], at: t(1))
        XCTAssertEqual(debouncer.deadline, t(2.5))
    }

    /// 다만 무한정 미루지는 않는다.
    ///
    /// 큰 파일을 받는 중인 다운로드 폴더는 이벤트가 끊이지 않는다. 순수 디바운스라면
    /// 그동안 그 폴더의 다른 파일이 영영 처리되지 않는다.
    func testDeadlineIsCappedByMaximumWait() {
        var debouncer = Debouncer()
        debouncer.record(["/W"], at: t0)
        for i in 1...10 { debouncer.record(["/W"], at: t(Double(i))) }
        XCTAssertEqual(debouncer.deadline, t(5), "최대 대기 시간을 넘겨 미뤘다")
    }

    func testDrainReturnsEveryDistinctPath() {
        var debouncer = Debouncer()
        debouncer.record(["/W/가", "/W/나"], at: t0)
        debouncer.record(["/W/나", "/W/다"], at: t(0.5))

        XCTAssertEqual(Set(debouncer.drain()), ["/W/가", "/W/나", "/W/다"])
    }

    func testDrainClearsTheState() {
        var debouncer = Debouncer()
        debouncer.record(["/W"], at: t0)
        _ = debouncer.drain()

        XCTAssertNil(debouncer.deadline)
        XCTAssertTrue(debouncer.drain().isEmpty)
    }

    /// 대기 시계는 비운 뒤 새로 시작한다. 이전 배치의 시각을 물려받으면 안 된다.
    func testClockRestartsAfterDrain() {
        var debouncer = Debouncer()
        debouncer.record(["/W"], at: t0)
        for i in 1...10 { debouncer.record(["/W"], at: t(Double(i))) }
        _ = debouncer.drain()

        debouncer.record(["/W"], at: t(20))
        XCTAssertEqual(debouncer.deadline, t(21.5))
    }

    /// 같은 경로가 두 형태로 와도 한 번만 처리한다.
    func testDistinctNormalizationFormsCollapseToOnePath() {
        var debouncer = Debouncer()
        debouncer.record(["/W/" + "가나".precomposedStringWithCanonicalMapping], at: t0)
        debouncer.record(["/W/" + "가나".decomposedStringWithCanonicalMapping], at: t(0.1))

        XCTAssertEqual(debouncer.drain().count, 1)
    }
}
