import Foundation

public enum ScanOutcome: Equatable, Sendable {
    /// 루트를 열 수 없다. 외장 디스크가 빠졌거나 권한이 없다 — 오류가 아니다 (FR-1, T11).
    case unavailable
    case scanned(Plan)
}

/// 디스크를 훑어 ``Planner``에 넘길 항목을 모은다.
///
/// 순회 규칙은 ``Planner/shouldDescend(into:)``를 따른다. 심볼릭 링크는 절대 따라가지
/// 않는다 — 따라갔다가는 감시 폴더 **밖**의 파일 이름을 바꾸게 된다. `lstat`을 쓰므로
/// 링크는 디렉터리로 보이지 않고, 자연히 들어가지 않는다. 링크 자체의 이름은 변환한다.
public enum Scanner {

    /// 루트 아래 전체를 훑는다. 일괄 변환과 일시정지 재개 시의 재스캔에 쓴다.
    public static func scan(root: String, now: Date, limit: Int?) -> ScanOutcome {
        guard DirectoryReader.entries(at: root) != nil else { return .unavailable }

        var items: [FileItem] = []
        var queue = [root]

        while let directory = queue.popLast() {
            guard let entries = DirectoryReader.entries(at: directory) else { continue }
            for entry in entries {
                guard entry.isValidUTF8 else { continue }
                let path = directory + "/" + entry.name
                guard let item = describe(path) else { continue }
                items.append(item)
                if Planner.shouldDescend(into: item) { queue.append(path) }
            }
        }

        return .scanned(Planner.plan(items: items, now: now, limit: limit))
    }

    /// 주어진 디렉터리들만 **한 겹** 훑는다. 실시간 감시가 쓴다.
    ///
    /// FSEvents는 바뀐 디렉터리를 알려 주므로 매번 전체를 훑을 이유가 없다.
    /// 사라진 디렉터리는 조용히 건너뛴다 — 처리하는 사이에 지워질 수 있다.
    public static func scanShallow(directories: [String], now: Date, limit: Int?) -> ScanOutcome {
        var items: [FileItem] = []
        var seen = Set<FileIdentity>()

        for directory in directories {
            // 경로 문자열이 아니라 파일 신원으로 중복을 거른다. 같은 폴더가 여러 경로로
            // 들어올 수 있다 — FSEvents는 `/private/var/…`를, 설정은 `/var/…`를 준다.
            guard let identity = FileIdentity(path: directory) else { continue }
            guard seen.insert(identity).inserted else { continue }
            guard let entries = DirectoryReader.entries(at: directory) else { continue }
            for entry in entries {
                guard entry.isValidUTF8 else { continue }
                guard let item = describe(directory + "/" + entry.name) else { continue }
                items.append(item)
            }
        }

        return .scanned(Planner.plan(items: items, now: now, limit: limit))
    }

    // MARK: - 항목 서술

    /// `lstat`으로 항목을 서술한다. 링크를 따라가지 않는 것이 핵심이다.
    static func describe(_ path: String) -> FileItem? {
        guard let status = POSIXFile.status(of: path) else { return nil }
        let kind = status.st_mode & S_IFMT
        let isDirectory = kind == S_IFDIR

        return FileItem(path: path,
                        isDirectory: isDirectory,
                        isPackage: isDirectory && isPackage(path),
                        modificationDate: modificationDate(status))
    }

    /// 번들인가. `NSWorkspace` 대신 Foundation의 자원 값을 쓴다 (kb/wiki/spec/requirements.md 12.2).
    ///
    /// 확장자로도 한 번 더 확인한다. 자원 값 조회는 실패할 수 있고, 실패했을 때
    /// "번들이 아니다"로 넘어가면 번들 내부로 들어가 버린다.
    private static func isPackage(_ path: String) -> Bool {
        if let ext = Planner.fileExtension(of: PathTools.lastComponent(of: path)),
           Planner.packageExtensions.contains(ext) {
            return true
        }
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey])
        return values?.isPackage ?? false
    }

    private static func modificationDate(_ status: stat) -> Date {
        let seconds = TimeInterval(status.st_mtimespec.tv_sec)
        let nanoseconds = TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000
        return Date(timeIntervalSince1970: seconds + nanoseconds)
    }
}
