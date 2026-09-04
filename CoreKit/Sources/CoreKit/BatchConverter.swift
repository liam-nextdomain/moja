import Foundation

/// 일괄 변환을 실행하기 전에 보여 줄 내용 (FR-6).
public struct BatchPreview: Equatable, Sendable {
    public let root: String
    /// 바꿀 항목 전부. 실시간 감시와 달리 개수 제한이 없다.
    public let conversions: [Conversion]
    /// 건드리지 않을 항목 수를 이유별로.
    public let skippedCounts: [SkipReason: Int]

    public var count: Int { conversions.count }
    public var skippedTotal: Int { skippedCounts.values.reduce(0, +) }
    public var isEmpty: Bool { conversions.isEmpty }

    /// 미리보기 창에 실제로 나열할 항목. 나머지는 "외 N개"로 접는다 (FR-6).
    public static let displayLimit = 200

    public var displayed: [Conversion] { Array(conversions.prefix(Self.displayLimit)) }
    public var hiddenCount: Int { max(0, conversions.count - Self.displayLimit) }
}

/// 일괄 변환의 결과.
public struct BatchResult: Equatable, Sendable {
    public let succeeded: Int
    public let failed: Int
    /// 미리보기를 만든 뒤 사라졌거나 이미 조합형이 된 항목.
    public let skipped: Int
    public let results: [RenameResult]

    public var total: Int { succeeded + failed + skipped }
}

public enum BatchPreviewOutcome: Equatable, Sendable {
    /// 폴더를 열 수 없다.
    case unavailable
    case preview(BatchPreview)
}

/// 지정한 폴더의 기존 항목을 한 번에 변환한다 (FR-6).
///
/// 미리보기와 실행이 나뉘어 있다. **미리보기는 디스크를 읽기만 한다** — 사용자가
/// "변환"을 누르기 전에는 이름이 하나도 바뀌지 않는다 (T12).
public enum BatchConverter {

    /// 폴더 전체를 훑어 무엇을 바꿀지 계산한다. 아무것도 바꾸지 않는다.
    public static func preview(root: String, now: Date = Date()) -> BatchPreviewOutcome {
        // 제한 없음: 일괄 변환은 폭주 방지의 대상이 아니라 그 해법이다 (FR-5, T10).
        switch Scanner.scan(root: root, now: now, limit: nil) {
        case .unavailable:
            return .unavailable
        case .scanned(let plan):
            var counts: [SkipReason: Int] = [:]
            for item in plan.skipped { counts[item.reason, default: 0] += 1 }
            return .preview(BatchPreview(root: root,
                                         conversions: plan.conversions,
                                         skippedCounts: counts))
        }
    }

    /// 미리보기에서 확인한 계획을 실행한다.
    ///
    /// 미리보기를 만든 뒤 사용자가 파일을 지우거나 옮겼을 수 있다. ``Renamer``가
    /// 그런 항목을 `vanished`·`notNeeded`로 걸러 내므로 오류로 세지 않는다.
    public static func apply(_ preview: BatchPreview,
                             using renamer: Renamer = Renamer(),
                             progress: ((Int, Int) -> Void)? = nil) -> BatchResult {
        var results: [RenameResult] = []
        var succeeded = 0, failed = 0, skipped = 0
        let total = preview.conversions.count

        for (index, conversion) in preview.conversions.enumerated() {
            let result = renamer.rename(conversion)
            results.append(result)

            switch result {
            case .renamed:
                succeeded += 1
            case .notNeeded, .vanished:
                skipped += 1
            case .conflict, .unsupportedVolume, .verificationFailed, .failed:
                failed += 1
            }
            progress?(index + 1, total)
        }

        return BatchResult(succeeded: succeeded, failed: failed,
                           skipped: skipped, results: results)
    }
}

extension SkipReason {
    /// 미리보기에 보여 줄 문구. 기술 용어는 쓰지 않는다.
    public var displayText: String {
        switch self {
        case .unnamed:           return "이름을 바꿀 수 없는 항목"
        case .insidePackage:     return "앱 꾸러미 안쪽"
        case .hidden:            return "숨김 항목"
        case .officeTemporary:   return "문서 편집 중 만들어진 임시 파일"
        case .temporaryDownload: return "받는 중이거나 임시 파일"
        case .alreadyNormalized: return "이미 올바른 이름"
        case .recentlyModified:  return "방금 저장돼 잠시 뒤에 처리"
        }
    }
}
