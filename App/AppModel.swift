import AppKit
import Combine
import CoreKit
import SwiftUI

/// 앱 전역 상태. 파일 처리는 CoreKit의 직렬 큐에서 돌고, 여기로 올라오는 값은
/// 전부 메인 액터에서만 갱신한다 (요구사항 6장 동시성 규칙).
@MainActor
final class AppModel: ObservableObject {

    /// 메뉴바 아이콘이 표현해야 하는 상태 (FR-7).
    enum WatchState {
        /// 감시 중. 연결된 폴더 개수를 함께 들고 있다.
        case watching(folderCount: Int)
        /// 사용자가 일시정지함. 아이콘이 흐려진다.
        case paused
        /// 감시 폴더가 아직 없음 — 온보딩이 필요한 상태.
        case needsSetup
    }

    @Published private(set) var state: WatchState = .needsSetup

    // MARK: - 메뉴바 아이콘

    var statusSymbolName: String {
        switch state {
        case .watching:   return "textformat.abc"
        case .paused:     return "textformat.abc"
        case .needsSetup: return "textformat.abc"
        }
    }

    /// VoiceOver용 (요구사항 5장 접근성).
    var statusAccessibilityLabel: String {
        switch state {
        case .watching(let count): return "모자, \(count)개 폴더 감시 중"
        case .paused:              return "모자, 감시 일시정지됨"
        case .needsSetup:          return "모자, 감시 폴더 없음"
        }
    }

    // MARK: - 메뉴 상태 줄

    var statusLineText: String {
        switch state {
        case .watching(let count): return "감시 중 (\(count)개 폴더)"
        case .paused:              return "일시정지됨"
        case .needsSetup:          return "감시 중인 폴더가 없습니다"
        }
    }

    // MARK: - 동작

    func quit() {
        NSApplication.shared.terminate(nil)
    }
}
