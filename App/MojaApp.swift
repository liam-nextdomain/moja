import SwiftUI

/// 모자 — 한글 파일 이름을 조합형으로 유지해 주는 메뉴바 상주 앱.
///
/// 별도 메인 창은 없다 (FR-7). Dock 아이콘도 없다 (`LSUIElement`).
@main
struct MojaApp: App {
    @StateObject private var model = AppModel()
    @State private var didStart = false

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(model)
        } label: {
            Image(nsImage: model.iconImage)
                .opacity(model.iconOpacity)
                .accessibilityLabel(model.statusAccessibilityLabel)
                .task {
                    // 메뉴바 항목이 자리를 잡은 뒤 한 번만 시작한다.
                    guard !didStart else { return }
                    didStart = true
                    model.start()
                }
        }
        .menuBarExtraStyle(.menu)
    }
}
