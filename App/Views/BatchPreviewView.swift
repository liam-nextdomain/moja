import CoreKit
import SwiftUI

/// 일괄 변환 미리보기 (FR-6, T12).
///
/// "변환"을 누르기 전까지는 이름이 하나도 바뀌지 않는다.
struct BatchPreviewView: View {
    @ObservedObject var session: BatchSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(session.folderName)
                .font(.title3.weight(.semibold))

            switch session.phase {
            case .scanning:
                centered { ProgressView("살펴보는 중…") }

            case .unavailable:
                centered {
                    Text("폴더를 열 수 없습니다. 디스크가 연결돼 있는지 확인해 주세요.")
                        .foregroundStyle(.secondary)
                }

            case .ready(let preview):
                readyView(preview)

            case .converting(let done, let total):
                centered {
                    VStack(spacing: 8) {
                        ProgressView(value: Double(done), total: Double(max(total, 1)))
                        Text("\(done) / \(total)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 280)
                }

            case .finished(let result):
                finishedView(result)
            }

            Divider()
            buttons
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 400)
    }

    // MARK: - 조각

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func readyView(_ preview: BatchPreview) -> some View {
        if preview.isEmpty {
            centered {
                VStack(spacing: 6) {
                    Text("바꿀 이름이 없습니다.")
                    if preview.skippedTotal > 0 {
                        Text("\(preview.skippedTotal)개 항목은 그대로 두어도 됩니다.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            Text("이름 \(preview.count)개를 바꿉니다.")
                .foregroundStyle(.secondary)

            List {
                ForEach(Array(preview.displayed.enumerated()), id: \.offset) { _, conversion in
                    changeRow(conversion)
                }
                if preview.hiddenCount > 0 {
                    Text("외 \(preview.hiddenCount)개")
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)

            skippedSummary(preview)
        }
    }

    private func changeRow(_ conversion: Conversion) -> some View {
        HStack(spacing: 8) {
            Text(conversion.currentName)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("바뀝니다")
            Text(conversion.newName)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private func skippedSummary(_ preview: BatchPreview) -> some View {
        if preview.skippedTotal > 0 {
            VStack(alignment: .leading, spacing: 2) {
                Text("그대로 두는 항목 \(preview.skippedTotal)개")
                    .font(.callout)
                ForEach(sortedReasons(preview), id: \.reason) { entry in
                    Text("· \(entry.reason.displayText) \(entry.count)개")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func sortedReasons(_ preview: BatchPreview) -> [(reason: SkipReason, count: Int)] {
        preview.skippedCounts
            .map { (reason: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    @ViewBuilder
    private func finishedView(_ result: BatchResult) -> some View {
        centered {
            VStack(spacing: 6) {
                Text("이름 \(result.succeeded)개를 바꿨습니다.")
                    .font(.headline)
                if result.failed > 0 {
                    Text("\(result.failed)개는 바꾸지 못했습니다. 최근 변환 내역에서 이유를 볼 수 있습니다.")
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
                if result.skipped > 0 {
                    Text("\(result.skipped)개는 그 사이에 사라졌거나 이미 올바른 이름이었습니다.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            Spacer()
            switch session.phase {
            case .ready(let preview):
                Button("취소") { session.close() }
                    .keyboardShortcut(.cancelAction)
                Button("변환") { session.convert() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview.isEmpty)
            case .converting:
                Button("변환 중…") {}.disabled(true)
            case .scanning, .unavailable:
                Button("닫기") { session.close() }
                    .keyboardShortcut(.cancelAction)
            case .finished:
                Button("닫기") { session.close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
