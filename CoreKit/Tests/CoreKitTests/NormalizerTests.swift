import XCTest
@testable import CoreKit

/// `Normalizer` — 이름 하나를 NFC로 바꾸고, 바꿀 필요가 있는지 판정한다.
///
/// 이 타입의 판정이 틀리면 두 가지 중 하나가 일어난다.
/// 너무 좁으면 아무것도 안 바뀌고, 너무 넓으면 앱이 자기가 바꾼 이름을 다시 바꾸며
/// 무한 루프에 빠진다. 그래서 경계를 촘촘히 못 박는다.
final class NormalizerTests: XCTestCase {

    // MARK: - 헬퍼

    /// 바이트 단위 비교. `XCTAssertEqual(String, String)`은 정규화를 무시하므로 쓰지 않는다.
    private func assertBytes(_ actual: String, _ expected: String,
                             _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Array(actual.utf8), Array(expected.utf8), message, file: file, line: line)
    }

    // MARK: - 한글

    func testDecomposedHangulNeedsConversion() {
        let nfd = "한글 문서.txt".decomposedStringWithCanonicalMapping
        XCTAssertTrue(Normalizer.needsConversion(nfd))
        assertBytes(Normalizer.normalized(nfd), "한글 문서.txt".precomposedStringWithCanonicalMapping)
    }

    func testComposedHangulIsLeftAlone() {
        let nfc = "한글 문서.txt".precomposedStringWithCanonicalMapping
        XCTAssertFalse(Normalizer.needsConversion(nfc))
        assertBytes(Normalizer.normalized(nfc), nfc)
    }

    /// 확장자를 포함한 이름 전체가 대상이다 (FR-2).
    func testConversionAppliesToTheWholeNameIncludingExtension() {
        let nfd = "보고서.첨부".decomposedStringWithCanonicalMapping
        let out = Normalizer.normalized(nfd)
        assertBytes(out, "보고서.첨부".precomposedStringWithCanonicalMapping)
        XCTAssertFalse(Normalizer.needsConversion(out))
    }

    /// 이름 일부만 분해된 경우도 잡아야 한다.
    func testPartiallyDecomposedNameIsConverted() {
        let mixed = "한" + "글".decomposedStringWithCanonicalMapping + ".txt"
        XCTAssertTrue(Normalizer.needsConversion(mixed))
        assertBytes(Normalizer.normalized(mixed), "한글.txt".precomposedStringWithCanonicalMapping)
    }

    // MARK: - 무한 루프 방지

    /// 멱등성. 변환 결과를 다시 변환해도 바이트가 같아야 한다 (FR-5).
    func testNormalizationIsIdempotent() {
        for name in ["한글.txt", "café.txt", "Ω.txt", "가나다라마바사.pdf"] {
            let once = Normalizer.normalized(name.decomposedStringWithCanonicalMapping)
            let twice = Normalizer.normalized(once)
            assertBytes(twice, once, "'\(name)' 이 멱등이 아니다")
            XCTAssertFalse(Normalizer.needsConversion(once), "'\(name)' 변환 후에도 대상으로 남는다")
        }
    }

    // MARK: - 건드리면 안 되는 것들

    /// 호환 자모(U+3131 등)는 NFC의 대상이 아니다. NFKC를 쓰면 여기서 깨진다.
    func testCompatibilityJamoIsNotTouched() {
        let name = "\u{3131}\u{3134}.txt"      // ㄱㄴ.txt — 낱자 그대로가 파일명인 경우
        XCTAssertFalse(Normalizer.needsConversion(name))
        assertBytes(Normalizer.normalized(name), name)
    }

    /// 전각 문자도 NFC의 대상이 아니다.
    func testFullwidthCharactersAreNotTouched() {
        let name = "ＡＢＣ１２３.txt"
        XCTAssertFalse(Normalizer.needsConversion(name))
        assertBytes(Normalizer.normalized(name), name)
    }

    func testASCIIIsNeverConverted() {
        for name in ["report.txt", "a", "UPPER.TXT", "with space.pdf", "dash-under_score.md"] {
            XCTAssertFalse(Normalizer.needsConversion(name), "'\(name)'")
        }
    }

    /// 이모지·ZWJ 결합은 이미 NFC다.
    func testEmojiIsNotTouched() {
        let name = "가족 👨‍👩‍👧‍👦 사진.jpg".precomposedStringWithCanonicalMapping
        XCTAssertFalse(Normalizer.needsConversion(name))
    }

    // MARK: - 경계값

    func testEmptyNameIsNotConverted() {
        XCTAssertFalse(Normalizer.needsConversion(""))
    }

    /// `.`과 `..`은 절대 건드리지 않는다. 바꾸려 드는 순간 상위 디렉터리가 위험하다.
    func testDotEntriesAreNeverConverted() {
        XCTAssertFalse(Normalizer.needsConversion("."))
        XCTAssertFalse(Normalizer.needsConversion(".."))
        assertBytes(Normalizer.normalized("."), ".")
        assertBytes(Normalizer.normalized(".."), "..")
    }

    /// 경로 구분자가 섞인 입력은 이름이 아니다. 변환 대상에서 뺀다.
    func testNamesContainingSeparatorAreRejected() {
        let bad = "폴더/파일.txt".decomposedStringWithCanonicalMapping
        XCTAssertFalse(Normalizer.needsConversion(bad),
                       "경로가 섞인 문자열을 이름으로 취급하면 안 된다")
    }

    // MARK: - 한글 외 문자

    func testDecomposedLatinIsConverted() {
        let nfd = "café résumé.txt".decomposedStringWithCanonicalMapping
        XCTAssertTrue(Normalizer.needsConversion(nfd))
        assertBytes(Normalizer.normalized(nfd), "café résumé.txt".precomposedStringWithCanonicalMapping)
    }

    /// 정준 등가인 단일 문자도 NFC 대상이다. 옹스트롬 기호 → Å.
    /// 한글 앱이지만 규칙은 유니코드 표준을 그대로 따른다는 것을 문서화해 둔다.
    func testCanonicalSingletonIsConverted() {
        let angstrom = "\u{212B}.txt"           // ANGSTROM SIGN
        XCTAssertTrue(Normalizer.needsConversion(angstrom))
        assertBytes(Normalizer.normalized(angstrom), "\u{00C5}.txt")
    }
}
