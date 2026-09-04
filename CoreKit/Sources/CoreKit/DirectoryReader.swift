import Foundation

/// 디렉터리 항목 하나. 이름을 **디스크에 저장된 원시 바이트**로 들고 있다.
public struct DirectoryEntry: Equatable, Sendable {
    /// 저장된 그대로의 UTF-8 바이트. 정규화 판정은 반드시 이 값으로 한다.
    public let nameBytes: [UInt8]
    public let isDirectory: Bool

    /// 표시·경로 조립용. 유효하지 않은 UTF-8이면 대체 문자가 섞이므로,
    /// 정규화 비교에는 ``nameBytes``를 쓴다.
    public var name: String { String(decoding: nameBytes, as: UTF8.self) }

    /// 저장된 바이트가 그대로 유효한 UTF-8인가. 아니면 이 항목은 건드리지 않는다.
    public var isValidUTF8: Bool { Array(name.utf8) == nameBytes }
}

/// 디렉터리를 `readdir(3)`으로 직접 읽는다.
///
/// `FileManager.contentsOfDirectory`도 저장된 바이트를 보존하는 것으로 실측됐지만
/// (`docs/rename-measurements.md` 3장), 검증만큼은 String을 한 번도 거치지 않는
/// 경로로 하고 싶어 직접 읽는다. 이름 변경이 실제로 먹혔는지 판단하는 마지막
/// 관문이기 때문이다.
public enum DirectoryReader {

    /// 디렉터리 항목을 읽는다. `.`과 `..`은 제외한다.
    /// 열 수 없으면 `errno`를 던지는 대신 `nil`을 돌려준다 — 권한 없는 폴더는
    /// 오류가 아니라 "건너뜀"으로 다뤄야 한다 (FR-1).
    public static func entries(at directory: String) -> [DirectoryEntry]? {
        guard let handle = directory.withCString({ opendir($0) }) else { return nil }
        defer { closedir(handle) }

        var out: [DirectoryEntry] = []
        while let raw = readdir(handle) {
            let entry = raw.pointee
            var storage = entry.d_name
            let length = Int(entry.d_namlen)
            let name: [UInt8] = withUnsafeBytes(of: &storage) { buffer in
                (0..<length).map { buffer[$0] }
            }
            if name == Array(".".utf8) || name == Array("..".utf8) { continue }
            out.append(DirectoryEntry(nameBytes: name,
                                      isDirectory: entry.d_type == DT_DIR))
        }
        return out
    }

    /// 이 디렉터리에 정확히 이 바이트열의 이름이 있는가.
    ///
    /// 이름 변경 검증에 쓴다. 존재 여부를 `lstat`으로 확인하면 안 된다 —
    /// 정규화를 무시하는 볼륨에서는 NFD 이름으로도 NFC 파일이 찾아지므로
    /// 아무것도 검증하지 못한다.
    public static func containsExactName(_ name: String, in directory: String) -> Bool {
        guard let entries = entries(at: directory) else { return false }
        let target = Array(name.utf8)
        return entries.contains { $0.nameBytes == target }
    }
}
