import Foundation

/// 파일·폴더 **이름 하나**를 조합형(NFC)으로 바꾸고, 바꿀 필요가 있는지 판정한다.
///
/// 경로가 아니라 이름 한 성분만 다룬다. 부수 효과가 없는 순수 함수라 파일시스템 없이
/// 전부 테스트할 수 있다.
///
/// ## 두 가지 규칙
///
/// **정준(canonical) 매핑만 쓴다.** `precomposedStringWithCanonicalMapping`(NFC)이고,
/// `precomposedStringWithCompatibilityMapping`(NFKC)이 아니다. NFKC는 전각 문자와
/// 호환 자모를 다른 글자로 바꿔 버린다. 파일명은 사용자의 것이므로 눈에 보이는 글자를
/// 바꾸는 변환은 허용하지 않는다.
///
/// **비교는 바이트로 한다.** Swift의 `==`는 정규화를 무시해서 NFD와 NFC를 같다고
/// 판정한다. 그걸로 판단하면 이 앱은 아무것도 하지 않는다.
/// (`UnicodeAssumptionTests`가 이 성질을 못 박아 두고 있다.)
public enum Normalizer {

    /// 이름을 NFC로 정규화한다. 바꿀 수 없거나 바꿔서는 안 되는 이름은 그대로 돌려준다.
    public static func normalized(_ name: String) -> String {
        guard isConvertibleName(name) else { return name }
        return name.precomposedStringWithCanonicalMapping
    }

    /// 이 이름을 실제로 바꿔야 하는가.
    ///
    /// NFC 정규화 결과가 원래 이름과 **바이트 단위로** 다를 때만 참이다 (FR-2).
    /// 같으면 아무것도 하지 않는다 — 무한 루프 방지의 핵심이다.
    public static func needsConversion(_ name: String) -> Bool {
        guard isConvertibleName(name) else { return false }
        return Array(name.utf8) != Array(name.precomposedStringWithCanonicalMapping.utf8)
    }

    /// 이름으로서 다룰 수 있는 문자열인가.
    ///
    /// 다음은 변환 대상이 아니다.
    /// - 빈 문자열
    /// - `.` 과 `..` — 디렉터리 자기 자신과 상위. 바꾸려 드는 순간 위험하다
    /// - 경로 구분자가 섞인 것 — 이름이 아니라 경로다. 호출부의 실수를 여기서 막는다
    static func isConvertibleName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.utf8.contains(UInt8(ascii: "/"))
    }
}
