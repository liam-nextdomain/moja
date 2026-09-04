import SwiftUI

/// 모자 — 한글 파일명을 조합형(NFC)으로 유지해 주는 메뉴바 상주 앱.
///
/// 별도 메인 창은 없다 (FR-7). Dock 아이콘도 없다 (`LSUIElement`).
@main
struct MojaApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(model)
        } label: {
            Image(systemName: model.statusSymbolName)
                .accessibilityLabel(model.statusAccessibilityLabel)
        }
        .menuBarExtraStyle(.menu)
    }
}
