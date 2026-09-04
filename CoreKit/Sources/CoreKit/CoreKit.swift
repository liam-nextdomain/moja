import Foundation

/// 모자의 순수 로직 계층.
///
/// UI(AppKit/SwiftUI)에 의존하지 않는다. 앱을 띄우지 않고
/// `swift test --package-path CoreKit` 으로 전부 검증할 수 있어야 한다.
///
/// 구성 (커밋 2~4에서 채운다):
/// - `Normalizer` — 이름 → NFC, 변환 필요 여부 판정
/// - `Planner`    — 건너뛰기 규칙, 깊이 우선 정렬
/// - `Renamer`    — rename 시도와 검증
/// - `Watcher`    — FSEvents 래퍼, 디바운스, 무시 목록
/// - `Store`      — 설정, 로그
public enum CoreKit {
    public static let version = "0.1.0"
}
