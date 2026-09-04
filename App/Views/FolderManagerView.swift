import CoreKit
import SwiftUI

/// 감시 폴더를 보태고 빼는 창 (FR-7 "폴더 관리…").
struct FolderManagerView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.statuses.isEmpty {
                emptyState
            } else {
                List(model.statuses, selection: $selection) { status in
                    row(status)
                        .tag(status.id)
                }
                .listStyle(.inset)
            }

            HStack {
                Button("추가…") { model.presentFolderPicker() }
                Button("제거") {
                    if let selection { model.removeFolder(id: selection) }
                    selection = nil
                }
                .disabled(selection == nil)

                Spacer()
                Text("폴더 안의 하위 폴더까지 함께 지켜봅니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 280)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("지켜보는 폴더가 없습니다")
                .foregroundStyle(.secondary)
            Button("폴더 추가…") { model.presentFolderPicker() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ status: FolderStatus) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { status.folder.isEnabled },
                set: { model.setFolder(id: status.id, enabled: $0) }
            ))
            .labelsHidden()
            .disabled(status.condition.isProblem)

            VStack(alignment: .leading, spacing: 2) {
                Text(status.name)
                Text(status.folder.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if let note = status.condition.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }
}
