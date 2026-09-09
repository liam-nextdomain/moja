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
/// 내용은 README와 짝을 맞춘다. 한쪽을 고치면 다른 쪽도 함께 고친다.
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
                        + "모자는 감시 중인 폴더 안에서 그런 이름을 조합된 형태로 되돌립니다. "
                        + "하위 폴더까지 함께 봅니다.")

                section("이렇게 씁니다",
                        "파일을 만들거나, 이름을 바꾸거나, 다른 곳에서 끌어다 놓으면 "
                        + "몇 초 안에 정리됩니다. "
                        + "이미 있던 파일은 메뉴의 '기존 항목 일괄 변환'으로 한 번에 처리합니다. "
                        + "무엇이 어떻게 바뀔지 먼저 보여 줍니다. "
                        + "폴더는 여러 개 등록할 수 있고, 각각 켜고 끌 수 있습니다. "
                        + "한 번에 500개가 넘게 들어오면 자동 변환을 멈추고 알려 드립니다. "
                        + "그때는 일괄 변환을 쓰시면 됩니다.")

                section("바꾸지 않는 파일",
                        "숨김 파일, 받는 중인 파일, 워드·엑셀이 문서를 열어 둔 동안 만드는 파일, "
                        + "그리고 앱 번들 안쪽은 그대로 둡니다. 번들 자체의 이름은 바꿉니다. "
                        + "방금 저장된 파일은 잠시 기다렸다가 손댑니다.")

                section("한계",
                        "모자는 이 맥의 디스크에 적힌 이름만 바꿉니다. "
                        + "메일이나 메신저로 파일을 보내는 과정에서 이름이 다시 깨질 수 있는데, "
                        + "그건 모자가 막을 수 없습니다. "
                        + "USB 메모리(exFAT)나 오래된 형식(HFS+)의 디스크는 macOS가 이름을 "
                        + "되돌려 저장하기 때문에 변환할 수 없습니다. "
                        + "그런 디스크는 메뉴에 '변환을 지원하지 않습니다'로 표시합니다.")

                section("개인정보",
                        "개인정보를 요청하지 않습니다. "
                        + "변환 기록과 설정은 이 맥에만 저장합니다. "
                        + "인터넷에 아무것도 보내지 않습니다.")

                section("문의", "liam.nextdomain@gmail.com")

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
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
