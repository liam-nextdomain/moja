import CoreKit
import Foundation

/// 일괄 변환 창 하나의 상태 (FR-6).
///
/// 훑기와 변환은 파일 큐에서 돌고, 여기 `@Published` 값은 메인 액터에서만 바뀐다.
@MainActor
final class BatchSession: ObservableObject {

    enum Phase: Equatable {
        /// 폴더를 훑는 중.
        case scanning
        /// 사용자가 "변환"을 누르기를 기다린다. 아직 아무것도 바꾸지 않았다.
        case ready(BatchPreview)
        case converting(done: Int, total: Int)
        case finished(BatchResult)
        case unavailable
    }

    @Published private(set) var phase: Phase = .scanning

    let folderName: String
    private let root: String
    private let queue: DispatchQueue
    private let renamer: Renamer
    /// 변환이 시작하고 끝나는 것을 바깥에 알린다. 메뉴바 아이콘이 이걸 보고 채워진다.
    private let onConverting: (Bool) -> Void
    private let onFinish: ([RenameResult]) -> Void
    private let onClose: () -> Void

    init(root: String,
         folderName: String,
         queue: DispatchQueue,
         renamer: Renamer,
         onConverting: @escaping (Bool) -> Void,
         onFinish: @escaping ([RenameResult]) -> Void,
         onClose: @escaping () -> Void) {
        self.root = root
        self.folderName = folderName
        self.queue = queue
        self.renamer = renamer
        self.onConverting = onConverting
        self.onFinish = onFinish
        self.onClose = onClose
    }

    /// 폴더를 훑는다. 읽기만 한다.
    func scan() {
        phase = .scanning
        let root = root
        queue.async { [weak self] in
            let outcome = BatchConverter.preview(root: root)
            Task { @MainActor in
                guard let self else { return }
                switch outcome {
                case .unavailable:       self.phase = .unavailable
                case .preview(let plan): self.phase = .ready(plan)
                }
            }
        }
    }

    /// 사용자가 "변환"을 눌렀다. 여기서 처음으로 이름이 바뀐다.
    func convert() {
        guard case .ready(let preview) = phase else { return }
        phase = .converting(done: 0, total: preview.count)
        onConverting(true)

        let renamer = renamer
        // 창이 먼저 닫혀 이 세션이 사라지더라도 "변환 중" 표시는 반드시 꺼야 한다.
        // self를 거치면 그때 알림이 통째로 사라지므로 클로저만 따로 붙든다.
        let onConverting = self.onConverting
        queue.async { [weak self] in
            let result = BatchConverter.apply(preview, using: renamer) { done, total in
                Task { @MainActor in
                    guard let self, case .converting = self.phase else { return }
                    self.phase = .converting(done: done, total: total)
                }
            }
            Task { @MainActor in
                onConverting(false)
                guard let self else { return }
                self.phase = .finished(result)
                self.onFinish(result.results)
            }
        }
    }

    /// 창을 닫는다. 감시 재개는 여기서 일어난다.
    func close() {
        onClose()
    }
}
