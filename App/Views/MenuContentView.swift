import SwiftUI

/// 메뉴바 아이콘을 클릭했을 때 나오는 메뉴.
///
/// 커밋 1에서는 상태 줄과 "종료"만 있다. 폴더 토글·일괄 변환·최근 내역 등
/// FR-7의 나머지 항목은 커밋 5~6에서 붙인다.
struct MenuContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Text(model.statusLineText)

        Divider()

        Button("모자 종료") {
            model.quit()
        }
        .keyboardShortcut("q")
    }
}
