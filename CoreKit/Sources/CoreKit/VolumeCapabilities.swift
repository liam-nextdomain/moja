import Foundation

/// 이 볼륨이 조합형(NFC) 이름을 저장할 수 있는가.
public enum VolumeSupport: Equatable, Sendable {
    /// 저장할 수 있다.
    case supported
    /// 커널이 이름을 분해해 저장한다. 어떤 방법으로도 변환이 불가능하다.
    case unsupported(fileSystem: String)
    /// 판단하지 못했다 (읽기 전용이거나 권한이 없다). 볼륨 탓으로 돌리지 않는다.
    case unknown
}

/// 볼륨이 NFC 이름을 저장할 수 있는지 **실측**하고 결과를 캐시한다.
///
/// HFS+와 exFAT은 커널이 파일명을 강제로 NFD로 되돌린다. NFC 이름으로 직접
/// 만들어도 NFD로 저장되므로 몇 번을 시도해도 성공할 수 없다
/// (`kb/wiki/research/rename-measurements.md`). 무한 재시도를 막으려면 구분이 필요하다.
///
/// `f_fstypename` 문자열로 거르지 않는다. SMB는 서버 구현에 따라 다르고,
/// 드라이버 동작은 OS 판올림으로 바뀔 수 있다. 대신 볼륨당 한 번 직접 만들어 본다.
///
/// 검사는 **이름 변경 검증이 실패했을 때만** 한다. 정상 동작하는 볼륨(APFS)에서는
/// 검사 파일이 하나도 만들어지지 않는다.
///
/// 여러 큐에서 함께 써도 된다. 유일한 가변 상태인 캐시는 잠금으로 지킨다.
public final class VolumeCapabilities: @unchecked Sendable {

    private var cache: [dev_t: VolumeSupport] = [:]
    private let lock = NSLock()

    public init() {}

    /// 이 디렉터리가 속한 볼륨의 능력. 볼륨(`st_dev`)당 한 번만 측정한다.
    public func support(forDirectory directory: String) -> VolumeSupport {
        guard let device = POSIXFile.status(of: directory)?.st_dev else { return .unknown }

        lock.lock()
        let cached = cache[device]
        lock.unlock()
        if let cached { return cached }

        let measured = measure(directory: directory)

        // 판단하지 못한 결과는 캐시하지 않는다. 권한이 생기면 다시 시도할 수 있어야 한다.
        if measured != .unknown {
            lock.lock()
            cache[device] = measured
            lock.unlock()
        }
        return measured
    }

    /// 조합형 이름의 숨김 파일을 하나 만들어 무엇으로 저장되는지 보고 지운다.
    private func measure(directory: String) -> VolumeSupport {
        // 자소가 분리될 수 있는 글자가 있어야 의미가 있다. 숨김이라 Planner가 건너뛴다.
        let probeName = ".moja-검사-\(UUID().uuidString)".precomposedStringWithCanonicalMapping
        let probePath = directory + "/" + probeName

        let fd = probePath.withCString { open($0, O_CREAT | O_EXCL | O_WRONLY, 0o600) }
        guard fd >= 0 else { return .unknown }
        close(fd)

        defer { cleanUp(probePath, name: probeName, in: directory) }

        guard let entries = DirectoryReader.entries(at: directory) else { return .unknown }
        let target = Array(probeName.utf8)
        let stored = entries.first { $0.nameBytes == target }

        if stored != nil { return .supported }

        let fileSystem = POSIXFile.fileSystemName(at: directory) ?? "알 수 없음"
        return .unsupported(fileSystem: fileSystem)
    }

    /// 검사 파일을 반드시 지운다. 저장된 이름이 우리가 준 것과 다를 수 있으므로
    /// 실제 항목을 찾아 그 이름으로도 시도한다.
    private func cleanUp(_ path: String, name: String, in directory: String) {
        if POSIXFile.remove(path) == 0 { return }

        guard let entries = DirectoryReader.entries(at: directory) else { return }
        let prefix = Array(".moja-검사-".precomposedStringWithCanonicalMapping.utf8)
        let decomposedPrefix = Array(".moja-검사-".decomposedStringWithCanonicalMapping.utf8)
        for entry in entries
        where entry.nameBytes.starts(with: prefix) || entry.nameBytes.starts(with: decomposedPrefix) {
            _ = POSIXFile.remove(directory + "/" + entry.name)
        }
    }
}
