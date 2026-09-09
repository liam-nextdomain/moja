import Foundation

/// Moja의 순수 로직 계층.
///
/// UI(AppKit/SwiftUI)에 의존하지 않는다. 앱을 띄우지 않고
/// `swift test --package-path CoreKit` 으로 전부 검증할 수 있어야 한다.
///
/// 구성:
/// - ``Normalizer`` — 이름 → NFC, 변환 필요 여부 판정
/// - ``Planner``    — 건너뛰기 규칙, 깊이 우선 정렬, 폭주 방지
/// - `Renamer`      — rename 시도와 검증 (커밋 3)
/// - `Watcher`      — FSEvents 래퍼, 디바운스, 무시 목록 (커밋 4)
/// - `Store`        — 설정, 로그 (커밋 5)
///
/// ## 이 계층의 금지 사항
///
/// 실측 결과(`kb/wiki/research/rename-measurements.md`)에 따라 다음을 쓰지 않는다.
/// - `FileManager.moveItem` / `createFile(atPath:)` — 경로를 NFD로 분해해 저장한다
/// - `NSString.fileSystemRepresentation` / `URL.withUnsafeFileSystemRepresentation`
/// - `String ==` 로 이름 비교 — 정규화를 무시한다. 항상 `Array(name.utf8)`로 비교한다
///
/// 경로는 `String.withCString`으로 직접 만든다. 디렉터리 **열거**는 안전하다.
public enum CoreKit {
    public static let version = "0.1.0"
}
