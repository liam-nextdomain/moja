import CoreKit
import SwiftUI

/// 최근 변환 내역 (FR-10). 마지막 100건, 최근 것이 위에 온다.
struct HistoryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.recentEntries.isEmpty {
                Text("아직 바꾼 이름이 없습니다.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.recentEntries) { entry in
                    row(entry)
                }
                .listStyle(.inset)
            }

            HStack {
                Text("기록은 이 맥에만 남습니다. 모자는 인터넷에 아무것도 보내지 않습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("로그 파일 보기") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.logFileURL])
                }
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 360)
    }

    private func row(_ entry: LogEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(entry.date, format: .dateTime.hour().minute().second())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                if let newName = entry.newName {
                    Text(newName)
                    Text(entry.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(entry.outcome.description)
                    if !entry.path.isEmpty {
                        Text(entry.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            Spacer()

            if entry.outcome != .converted {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("문제 있음")
            }
        }
        .padding(.vertical, 2)
    }
}

/// 도움말 겸 정보 창. 기술 용어(NFD·NFC)는 여기서만 쓴다 (요구사항 11장 원칙).
struct HelpView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("모자 \(version)")
                    .font(.title2.weight(.semibold))

                section("무엇을 하나요",
                        "맥은 한글 파일 이름을 자모가 분리된 형태(NFD)로 저장합니다. "
                        + "Windows와 대부분의 웹은 조합된 형태(NFC)를 쓰기 때문에, "
                        + "맥에서 만든 파일 이름이 Windows에서 흩어져 보입니다. "
                        + "모자는 지켜보는 폴더 안에서 그런 이름을 조합된 형태로 되돌립니다.")

                section("건드리지 않는 것",
                        "숨김 파일, 받는 중인 파일, 워드·엑셀이 만드는 임시 파일, "
                        + "그리고 앱 꾸러미 안쪽은 그대로 둡니다. "
                        + "방금 저장된 파일은 잠시 기다렸다가 손댑니다.")

                section("한계",
                        "모자는 디스크에 적힌 이름만 바꿉니다. "
                        + "일부 앱은 파일을 보낼 때 이름을 다시 바꿀 수 있습니다. "
                        + "USB 메모리(exFAT)나 오래된 형식의 디스크는 macOS가 이름을 "
                        + "되돌려 저장하기 때문에 변환할 수 없습니다.")

                section("개인정보",
                        "인터넷에 아무것도 보내지 않습니다. 기록은 이 맥에만 남습니다.")

                Text("MIT 라이선스")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 420, minHeight: 340)
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
