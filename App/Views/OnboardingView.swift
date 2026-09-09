import CoreKit
import SwiftUI

/// 첫 실행 안내 (FR-8).
///
/// 데스크탑·다운로드·문서를 미리 체크해 두되, "추가"를 눌러야 실제로 등록된다.
/// 폴더를 하나도 고르지 않으면 이 창은 다음 실행에 다시 뜬다.
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel

    @State private var selected: Set<String> = Set(AppModel.suggestedFolders.map(\.path))
    @State private var launchAtLogin = true

    private let suggestions = AppModel.suggestedFolders

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Moja")
                    .font(.title2.weight(.semibold))
                Text("맥에서 저장한 한글 파일 이름은 윈도우에서 'ㅂㅗㄱㅗㅅㅓ.docx' 처럼 깨집니다.\n"
                     + "Moja는 윈도우에서도 한글 파일 이름이 멀쩡하게 보이도록 관리해 줍니다.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("관리할 폴더")
                    .font(.headline)

                ForEach(suggestions, id: \.path) { suggestion in
                    Toggle(suggestion.name, isOn: Binding(
                        get: { selected.contains(suggestion.path) },
                        set: { isOn in
                            if isOn { selected.insert(suggestion.path) }
                            else { selected.remove(suggestion.path) }
                        }
                    ))
                }

                Button("다른 폴더 고르기…") { model.presentFolderPicker() }
                    .buttonStyle(.link)
                    .padding(.top, 2)

                Text("데스크탑·다운로드·문서를 고르면 macOS가 접근을 허락할지 한 번 더 묻습니다. "
                     + "\"허용\"을 눌러 동의해 주시면 됩니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }

            Divider()

            Toggle("로그인 시 자동 실행", isOn: $launchAtLogin)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("나중에") { model.presenter.close(id: "onboarding") }
                Button("추가") { finish() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty && model.statuses.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 380)
    }

    private func finish() {
        model.addFolders(Array(selected))
        if launchAtLogin { model.setLaunchAtLogin(true) }
        model.finishOnboarding()
    }
}
