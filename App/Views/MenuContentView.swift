import CoreKit
import SwiftUI

/// 메뉴바 아이콘을 클릭하면 나오는 메뉴 (FR-7). 별도 메인 창은 없다.
struct MenuContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Text(model.statusLineText)

        if !model.statuses.isEmpty {
            Divider()
            folderToggles
        }

        Divider()

        Button("폴더 추가…") { model.presentFolderPicker() }
        Button("폴더 관리…") { model.showFolderManager() }

        Divider()

        batchMenu
        Button("최근 변환 내역…") { model.showHistory() }

        Divider()

        Button(model.isPaused ? "감시 재개" : "감시 일시정지") { model.togglePause() }

        Toggle("로그인 시 자동 실행", isOn: Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }
        ))

        if let notice = model.loginItemNotice {
            Button(notice) { model.openLoginItemSettings() }
        }

        Divider()

        Button("도움말 / 정보") { model.showHelp() }
        Button("모자 종료") { model.quit() }
            .keyboardShortcut("q")
    }

    /// 폴더를 골라 기존 항목을 한 번에 변환한다 (FR-6).
    /// 연결이 끊긴 폴더는 고를 수 없다.
    @ViewBuilder
    private var batchMenu: some View {
        let available = model.statuses.filter { $0.condition != .disconnected }
        if !available.isEmpty {
            Menu("기존 항목 일괄 변환") {
                ForEach(available) { status in
                    Button(status.name) { model.showBatchPreview(for: status.id) }
                }
            }
        }
    }

    /// 폴더별 켜기/끄기. 문제가 있는 폴더는 이름 옆에 이유를 적는다.
    @ViewBuilder
    private var folderToggles: some View {
        ForEach(model.statuses) { status in
            if let note = status.condition.note {
                // 켤 수 없는 상태다. 토글 대신 이유를 보여 준다.
                Text("\(status.name) — \(note)")
            } else {
                Toggle(status.name, isOn: Binding(
                    get: { status.folder.isEnabled },
                    set: { model.setFolder(id: status.id, enabled: $0) }
                ))
            }
        }
    }
}
