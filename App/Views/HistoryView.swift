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
                Text("기록은 이 맥에만 남습니다. Moja는 인터넷에 아무것도 보내지 않습니다.")
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
                Text("Moja \(version)")
                    .font(.title2.weight(.semibold))

                section("뭘 하는 앱인가요",
                        "맥에서 파일 이름을 한글로 저장하고, 이걸 윈도우 사용자에게 보내면 "
                        + "'ㅂㅗㄱㅗㅅㅓ.docx' 처럼 파일 이름이 깨집니다. "
                        + "맥은 한글 이름을 자모가 분리된 형태(NFD)로 저장하는데, "
                        + "윈도우와 대부분의 웹은 자모가 조합된 형태(NFC)를 쓰기 때문입니다. "
                        + "Moja는 윈도우에서도 한글 파일 이름이 멀쩡하게 보이도록 관리해 줍니다.")

                section("기능",
                        "관리 대상 폴더 안에서 한글 파일 이름을 자모가 조합된 형태로 변환합니다. "
                        + "관리 대상 폴더의 하위 폴더까지 함께 관리합니다. "
                        + "폴더 안에 파일을 만들거나, 파일 이름을 바꾸거나, "
                        + "다른 경로에서 파일을 가져오기만 해도 몇 초 안에 정리됩니다. "
                        + "폴더 안에 이미 있던 파일은 '기존 항목 일괄 변환' 메뉴로 "
                        + "한 번에 처리할 수 있습니다. "
                        + "실행하기 전에 어떤 이름이 어떻게 바뀌는지 먼저 보여 줍니다. "
                        + "폴더를 여러 개 관리할 수 있고, 폴더마다 따로 켜고 끌 수 있습니다. "
                        + "한 번에 500개가 넘게 들어오면 자동 변환을 멈추고 알려 드립니다. "
                        + "이때는 일괄 변환으로 처리해 주시면 됩니다.")

                section("바꾸지 않는 파일",
                        "숨김 파일, 다운로드 중인 파일, "
                        + "워드·엑셀이 문서를 열어 둔 동안 만드는 파일은 바꾸지 않습니다. "
                        + "앱 번들 안쪽도 바꾸지 않습니다. 이름을 바꾸면 앱이 실행되지 않기 "
                        + "때문인데, 번들 자체의 이름은 바꿉니다. "
                        + "방금 저장한 파일은 아직 저장하는 중일 수 있어서 잠시 기다립니다.")

                section("한계",
                        "Moja는 개인 컴퓨터에 있는 파일 이름은 자모가 합쳐진 상태로 바꿉니다. "
                        + "그런데 이 파일을 이메일이나, 카톡, 슬랙 등으로 전송하는 과정에서 "
                        + "조합이 다시 깨질 가능성이 있습니다. "
                        + "이거는 Moja가 해결할 수 없는 부분입니다. "
                        + "변환할 수 없는 디스크도 있습니다. "
                        + "USB 메모리처럼 exFAT이나 HFS+로 만들어진 디스크에서는 "
                        + "어떤 방법으로도 바꿀 수 없습니다. "
                        + "Moja는 이런 디스크를 인식해서 "
                        + "'이 디스크(exFAT)는 변환을 지원하지 않습니다'라고 표시합니다.")

                section("개인정보",
                        "개인정보 입력을 요청하지 않습니다. "
                        + "작업 기록과 설정은 설치하신 맥 안에만 저장합니다. "
                        + "인터넷 연결 없이 동작하므로, 저장한 설정이나 기록을 몰래 빼내서 "
                        + "정체 모를 서버로 전송하거나 그러지 않습니다.")

                section("문의",
                        "사용법이나 오류 등 문의할 내용이 있으시다면 아래로 연락주세요. "
                        + "가능한 범위 안에서 답변 드리겠습니다.\n"
                        + "liam.nextdomain@gmail.com")

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
