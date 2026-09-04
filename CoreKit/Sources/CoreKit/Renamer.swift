import Foundation

/// 이름 변경 한 건의 결과.
public enum RenameResult: Equatable, Sendable {
    /// 바꿨고, 디스크에 NFC로 저장된 것을 확인했다.
    /// `path`는 바꾸기 전 경로, `newName`은 새 이름 (FR-10의 로그 형식).
    case renamed(path: String, newName: String)
    /// 바꿀 필요가 없었다. 이미 조합형이다.
    case notNeeded
    /// 원본이 없다. 사용자가 지웠거나 옮겼다 — 오류가 아니다.
    case vanished
    /// 목적지에 **다른 파일**이 있다. 덮어쓰지 않고 물러났다.
    case conflict(existing: String)
    /// 이 볼륨은 조합형 이름을 저장할 수 없다 (HFS+·exFAT).
    case unsupportedVolume(fileSystem: String)
    /// 호출은 성공했는데 저장된 바이트가 조합형이 아니다.
    /// 재시도하지 않는다. 다음 이벤트 때 자연히 다시 시도된다 (FR-3).
    case verificationFailed
    /// 시스템 호출이 실패했다.
    case failed(stage: String, errno: Int32)
}

/// 이름 하나를 조합형(NFC)으로 바꾸고, 정말 바뀌었는지 확인한다 (FR-3).
///
/// ## 순서
///
/// ```
/// 1. renamex_np(RENAME_EXCL)      목적지가 있으면 EEXIST. 절대 덮어쓰지 않는다
///    ├─ 성공                       → 4번 검증
///    ├─ EEXIST / ENOTSUP          → 2번
///    └─ 그 외                      → 실패
/// 2. 목적지의 FileIdentity 비교
///    ├─ 같은 파일                   → rename(2)로 진행 (안전) → 4번 검증
///    └─ 다른 파일                   → 중단. conflict로 보고
/// 3. 검증 실패 시 2단계 폴백:  현재 → .moja-tmp-<uuid> → 목표
///    2단계가 실패하면 원래 이름으로 되돌린다
/// 4. 검증: 부모를 다시 나열해 저장된 **원시 바이트**가 목표와 일치하는지 확인
/// 5. 그래도 아니면 볼륨 능력을 실측해 "지원 안 함"과 "일시적 실패"를 가른다
/// ```
///
/// 실측 근거는 `docs/rename-measurements.md`. APFS에서는 1번이 바로 성공하며
/// 저장 바이트가 NFC로 바뀐다.
public struct Renamer: Sendable {

    private let volumes: VolumeCapabilities
    private let forceTwoStepFallback: Bool
    private let failSecondStepForTesting: Bool

    public init(volumes: VolumeCapabilities = VolumeCapabilities()) {
        self.volumes = volumes
        self.forceTwoStepFallback = false
        self.failSecondStepForTesting = false
    }

    /// 테스트 전용. APFS에서는 1번이 늘 성공해서 폴백 경로가 영영 돌지 않으므로,
    /// 그 경로를 실제로 태워 보기 위한 문이다.
    init(forceTwoStepFallback: Bool,
         failSecondStepForTesting: Bool = false,
         volumes: VolumeCapabilities = VolumeCapabilities()) {
        self.volumes = volumes
        self.forceTwoStepFallback = forceTwoStepFallback
        self.failSecondStepForTesting = failSecondStepForTesting
    }

    // MARK: - 배치

    /// 계획을 순서대로 실행한다.
    ///
    /// ``Planner``가 깊은 경로부터 오도록 정렬해 두므로, 상위 폴더의 이름을 바꾸는
    /// 시점에는 그 아래가 이미 끝나 있다. 따라서 중간에 경로가 무효가 되지 않는다 (FR-4).
    public func apply(_ plan: Plan) -> [RenameResult] {
        plan.conversions.map(rename)
    }

    // MARK: - 한 건

    public func rename(_ conversion: Conversion) -> RenameResult {
        let source = conversion.path
        let name = PathTools.lastComponent(of: source)
        let target = conversion.newName

        // 호출부의 실수를 여기서 막는다. 목표 이름은 원래 이름의 NFC여야 한다.
        guard Normalizer.isConvertibleName(name), Normalizer.isConvertibleName(target),
              Array(target.utf8) == Array(Normalizer.normalized(name).utf8) else {
            return .failed(stage: "요청 검증", errno: EINVAL)
        }
        guard Array(name.utf8) != Array(target.utf8) else { return .notNeeded }

        guard POSIXFile.exists(source) else { return .vanished }

        let destination = conversion.newPath
        let directory = PathTools.parent(of: source)

        if !forceTwoStepFallback {
            switch guardedMove(from: source, to: destination) {
            case .conflict:
                return .conflict(existing: destination)
            case .vanished:
                return .vanished
            case .failed(let code):
                return .failed(stage: "이름 변경", errno: code)
            case .moved:
                if isStored(target, in: directory) {
                    return .renamed(path: source, newName: target)
                }
            }
        }

        return twoStepFallback(source: source, destination: destination,
                               directory: directory, target: target)
    }

    // MARK: - 1·2번: 덮어쓰지 않는 이름 변경

    private enum GuardedMove {
        case moved
        /// 목적지가 **다른 파일**이다. 아무것도 하지 않았다.
        case conflict
        case vanished
        case failed(Int32)
    }

    /// 목적지에 다른 파일이 있으면 절대 덮어쓰지 않고 옮긴다.
    ///
    /// `RENAME_EXCL`이 1순위다. 드라이버가 지원하지 않거나(exFAT의 `ENOTSUP`)
    /// 정규화 무시 볼륨이 목적지를 "이미 있음"으로 볼 때(`EEXIST`)는,
    /// 목적지가 정말 같은 파일인지 ``FileIdentity``로 확인한 뒤에만 `rename(2)`로 넘어간다.
    private func guardedMove(from source: String, to destination: String) -> GuardedMove {
        guard let sourceID = FileIdentity(path: source) else { return .vanished }

        let code = POSIXFile.moveExclusive(source, to: destination)
        switch code {
        case 0:
            return .moved

        case EEXIST, ENOTSUP:
            if let destinationID = FileIdentity(path: destination), destinationID != sourceID {
                // 정규화를 구분하는 볼륨에서 남의 파일을 지울 뻔했다. 물러난다.
                return .conflict
            }
            let plain = POSIXFile.move(source, to: destination)
            switch plain {
            case 0:      return .moved
            case ENOENT: return .vanished
            default:     return .failed(plain)
            }

        case ENOENT:
            return .vanished

        default:
            return .failed(code)
        }
    }

    // MARK: - 3번: 2단계 폴백

    private func twoStepFallback(source: String, destination: String,
                                 directory: String, target: String) -> RenameResult {
        // 첫 시도가 성공했다면 파일은 목적지 이름으로도 접근된다. 실제로 있는 쪽을 잡는다.
        let current = POSIXFile.exists(source) ? source
                    : POSIXFile.exists(destination) ? destination
                    : nil
        guard let current else { return .vanished }

        let temporary = PathTools.directoryPrefix(of: source) + ".moja-tmp-\(UUID().uuidString)"

        switch guardedMove(from: current, to: temporary) {
        case .moved:    break
        case .vanished: return .vanished
        case .conflict: return .failed(stage: "임시 이름으로 변경", errno: EEXIST)
        case .failed(let code): return .failed(stage: "임시 이름으로 변경", errno: code)
        }

        let toTarget: GuardedMove = failSecondStepForTesting
            ? .failed(EIO)
            : guardedMove(from: temporary, to: destination)

        if case .moved = toTarget {
            // 계속 진행
        } else {
            // 사용자 파일을 임시 이름으로 남겨 두지 않는다. 무슨 일이 있어도 되돌린다.
            _ = POSIXFile.move(temporary, to: current)
            let code: Int32 = if case .failed(let c) = toTarget { c } else { EEXIST }
            return .failed(stage: "최종 이름으로 변경", errno: code)
        }

        if isStored(target, in: directory) {
            return .renamed(path: source, newName: target)
        }

        // 5번: 이 볼륨이 애초에 조합형을 저장할 수 없는 것인지 가른다.
        switch volumes.support(forDirectory: directory) {
        case .unsupported(let fileSystem):
            return .unsupportedVolume(fileSystem: fileSystem)
        case .supported, .unknown:
            return .verificationFailed
        }
    }

    // MARK: - 4번: 검증

    /// 부모를 다시 나열해 목표 이름이 **그 바이트 그대로** 저장됐는지 확인한다.
    ///
    /// `lstat`으로 확인하면 안 된다. 정규화를 무시하는 볼륨에서는 NFD 경로로도
    /// NFC 파일이 찾아지므로 아무것도 검증하지 못한다.
    private func isStored(_ target: String, in directory: String) -> Bool {
        DirectoryReader.containsExactName(target, in: directory)
    }
}
