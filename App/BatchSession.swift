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
    private let onFinish: ([RenameResult]) -> Void
    private let onClose: () -> Void

    init(root: String,
         folderName: String,
         queue: DispatchQueue,
         renamer: Renamer,
         onFinish: @escaping ([RenameResult]) -> Void,
         onClose: @escaping () -> Void) {
        self.root = root
        self.folderName = folderName
        self.queue = queue
        self.renamer = renamer
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

        let renamer = renamer
        queue.async { [weak self] in
            let result = BatchConverter.apply(preview, using: renamer) { done, total in
                Task { @MainActor in
                    guard let self, case .converting = self.phase else { return }
                    self.phase = .converting(done: done, total: total)
                }
            }
            Task { @MainActor in
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
