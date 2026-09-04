import XCTest
@testable import CoreKit

/// 이 앱의 설계가 통째로 기대고 있는 플랫폼 동작을 못 박아 두는 테스트.
///
/// 여기서 검증하는 것은 우리 코드가 아니라 **Swift 표준 라이브러리의 성질**이다.
/// 언젠가 이 테스트가 깨진다면 `Normalizer` 이하 전부를 다시 봐야 한다는 신호다.
final class UnicodeAssumptionTests: XCTestCase {

    /// 자소가 분리된 "한글 문서.txt" — 파인더가 실제로 디스크에 쓰는 형태.
    private let nfd = "\u{1112}\u{1161}\u{11AB}\u{1100}\u{1173}\u{11AF} 문서.txt"
        .decomposedStringWithCanonicalMapping

    /// 조합형 "한글 문서.txt" — Windows·리눅스·웹이 기대하는 형태.
    private let nfc = "한글 문서.txt".precomposedStringWithCanonicalMapping

    /// 함정: Swift의 `==`는 정규화를 무시한다.
    ///
    /// 그래서 `nfd == nfc`가 **참**이다. 변환 필요 여부를 `==`로 판정하면
    /// 이 앱은 아무것도 하지 않는다. 모든 비교는 바이트로 해야 한다.
    func testStringEqualityIgnoresNormalization() {
        XCTAssertEqual(nfd, nfc, "Swift == 가 정규화를 무시한다는 전제가 깨졌다")
    }

    /// 해법: UTF-8 바이트로 비교하면 두 형태가 확실히 구분된다.
    func testUTF8BytesDistinguishNormalizationForms() {
        XCTAssertNotEqual(Array(nfd.utf8), Array(nfc.utf8))
        XCTAssertNotEqual(Array(nfd.unicodeScalars), Array(nfc.unicodeScalars))
    }

    /// NFC 변환은 NFD를 정확히 NFC로 옮긴다.
    func testPrecomposedMappingProducesNFCBytes() {
        XCTAssertEqual(
            Array(nfd.precomposedStringWithCanonicalMapping.utf8),
            Array(nfc.utf8)
        )
    }

    /// 멱등성 — 무한 루프 방지의 1차 방어선.
    ///
    /// 이미 NFC인 이름을 다시 NFC로 바꿔도 바이트가 그대로여야, 앱이 자기가 만든
    /// 이벤트를 보고 또 이름을 바꾸는 일이 생기지 않는다 (FR-5).
    func testNFCIsIdempotent() {
        let once = nfd.precomposedStringWithCanonicalMapping
        let twice = once.precomposedStringWithCanonicalMapping
        XCTAssertEqual(Array(once.utf8), Array(twice.utf8))
    }

    /// NFKC를 쓰면 안 되는 이유를 남겨 둔다.
    ///
    /// 호환 매핑은 전각 문자·호환 자모를 다른 글자로 바꿔 버린다.
    /// 파일명은 사용자의 것이므로 정준(canonical) 변환만 허용한다.
    func testCompatibilityMappingIsDestructiveAndMustNotBeUsed() {
        let fullwidth = "ＡＢＣ.txt"
        XCTAssertEqual(
            Array(fullwidth.precomposedStringWithCanonicalMapping.utf8),
            Array(fullwidth.utf8),
            "NFC는 전각 문자를 건드리지 않아야 한다"
        )
        XCTAssertNotEqual(
            Array(fullwidth.precomposedStringWithCompatibilityMapping.utf8),
            Array(fullwidth.utf8),
            "NFKC는 전각 문자를 파괴한다 — 그래서 쓰지 않는다"
        )
    }
}
