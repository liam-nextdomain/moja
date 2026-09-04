import Foundation

/// 파일 하나의 신원. 같은 파일인지 다른 파일인지 가르는 유일한 근거다.
///
/// 이름이 같아 보인다고 같은 파일이 아니고, 달라 보인다고 다른 파일이 아니다.
/// 정규화를 무시하는 볼륨에서는 NFD 이름과 NFC 이름이 같은 파일을 가리키고,
/// 하드링크는 이름이 둘이지만 파일은 하나다.
public struct FileIdentity: Hashable, Sendable {
    public let device: dev_t
    public let inode: UInt64

    public init?(path: String) {
        guard let st = POSIXFile.status(of: path) else { return nil }
        device = st.st_dev
        inode = st.st_ino
    }
}

/// POSIX 파일 호출의 얇은 래퍼.
///
/// 경로는 `String.withCString`으로만 만든다. Foundation의
/// `fileSystemRepresentation`은 경로를 **NFD로 분해**하기 때문에, 그걸 쓰면
/// NFC 이름을 아예 만들 수 없다 (`docs/rename-measurements.md` 3장).
///
/// 모든 함수는 성공 시 `0`, 실패 시 `errno`를 돌려준다.
enum POSIXFile {

    /// `RENAME_EXCL` — 목적지가 이미 있으면 `EEXIST`로 실패한다. `<stdio.h>`의 매크로라
    /// Swift로 넘어오지 않으므로 값을 직접 적는다.
    static let renameExclusiveFlag: UInt32 = 0x0000_0004

    static func status(of path: String) -> stat? {
        var st = stat()
        guard path.withCString({ lstat($0, &st) }) == 0 else { return nil }
        return st
    }

    static func exists(_ path: String) -> Bool {
        status(of: path) != nil
    }

    /// 목적지가 이미 있으면 실패한다. **덮어쓰지 않는다.**
    ///
    /// 정규화를 무시하는 볼륨에서 NFD → NFC 변경은 커널이 같은 파일로 인식해
    /// `EEXIST` 없이 성공한다. 실측으로 확인했다.
    /// 드라이버가 지원하지 않으면 `ENOTSUP`을 돌려준다 (exFAT).
    static func moveExclusive(_ from: String, to: String) -> Int32 {
        from.withCString { f in
            to.withCString { t in
                renamex_np(f, t, renameExclusiveFlag) == 0 ? 0 : errno
            }
        }
    }

    /// 평범한 `rename(2)`. **목적지가 있으면 조용히 덮어쓴다.**
    /// 호출 전에 목적지가 같은 파일임을 ``FileIdentity``로 확인해야 한다.
    static func move(_ from: String, to: String) -> Int32 {
        from.withCString { f in
            to.withCString { t in
                rename(f, t) == 0 ? 0 : errno
            }
        }
    }

    static func remove(_ path: String) -> Int32 {
        path.withCString { unlink($0) == 0 ? 0 : errno }
    }

    /// 볼륨의 파일시스템 이름 (`apfs`, `hfs`, `exfat`, `smbfs` …).
    static func fileSystemName(at path: String) -> String? {
        var fs = statfs()
        guard path.withCString({ statfs($0, &fs) }) == 0 else { return nil }
        return withUnsafeBytes(of: &fs.f_fstypename) {
            String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }

    static func errorText(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}

// MARK: - 경로 다루기

/// 경로를 성분으로 나누는 최소한의 도우미.
///
/// `NSString`의 경로 API를 쓰지 않는 이유는 위와 같다 — 정규화를 건드린다.
/// 구분자 `/`는 ASCII라 바이트 단위로 안전하게 다룰 수 있다.
enum PathTools {

    static func lastComponent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// 마지막 `/`까지 포함한 앞부분. 루트면 `"/"`.
    static func directoryPrefix(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[...slash])
    }

    static func replacingLastComponent(of path: String, with name: String) -> String {
        directoryPrefix(of: path) + name
    }

    /// 마지막 `/`를 뗀 부모 경로. 열거에 쓴다.
    static func parent(of path: String) -> String {
        let prefix = directoryPrefix(of: path)
        if prefix == "/" || prefix.isEmpty { return prefix.isEmpty ? "." : "/" }
        return String(prefix.dropLast())
    }
}
