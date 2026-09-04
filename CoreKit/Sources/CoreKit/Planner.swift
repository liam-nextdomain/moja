import Foundation

/// 처리 대상 항목 하나의 서술.
///
/// 파일시스템을 직접 읽지 않고 이 값만 받는 덕분에, 위험한 상황을 전부 테스트로
/// 재현할 수 있다. 실제 값은 순회하는 쪽에서 채운다.
public struct FileItem: Equatable, Sendable {
    /// 절대 경로. 디스크에 저장된 그대로의 바이트여야 한다 (정규화하지 않은 상태).
    public let path: String
    public let isDirectory: Bool
    /// `URLResourceValues.isPackage`. `NSWorkspace`를 쓰지 않는 이유는 REQUIREMENTS 12.2.
    public let isPackage: Bool
    public let modificationDate: Date

    public init(path: String, isDirectory: Bool, isPackage: Bool, modificationDate: Date) {
        self.path = path
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.modificationDate = modificationDate
    }

    /// 경로의 마지막 성분. 정규화하지 않는다.
    public var name: String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }
}

/// 건드리지 않은 이유. 일괄 변환 미리보기에 그대로 쓰인다 (FR-6).
public enum SkipReason: String, Equatable, Sendable {
    /// 이름이 없거나 `.`·`..`·루트. 애초에 바꿀 수 없다.
    case unnamed
    /// 번들 내부. 건드리면 앱 서명이 깨진다.
    case insidePackage
    /// `.`으로 시작하는 숨김 항목 (`.DS_Store` 포함).
    case hidden
    /// 워드·엑셀이 문서를 열어 두는 동안 만드는 `~$` 파일.
    case officeTemporary
    /// 받는 중이거나 임시 파일. 완료 전에 건드리면 다운로드가 깨진다.
    case temporaryDownload
    /// 이미 조합형이다. 아무것도 할 필요가 없다 — 대부분의 항목이 여기로 온다.
    case alreadyNormalized
    /// 방금 수정됐다. 아직 쓰는 중일 수 있으므로 미룬다.
    case recentlyModified
}

public struct SkippedItem: Equatable, Sendable {
    public let item: FileItem
    public let reason: SkipReason
}

/// 이름 하나를 어떻게 바꿀지.
public struct Conversion: Equatable, Sendable {
    /// 원래 절대 경로 (디스크에 저장된 바이트 그대로).
    public let path: String
    /// 바꿀 이름 (NFC).
    public let newName: String

    public var newPath: String {
        guard let slash = path.lastIndex(of: "/") else { return newName }
        return String(path[...slash]) + newName
    }
}

/// 한 배치를 어떻게 처리할지에 대한 결정.
public struct Plan: Equatable, Sendable {
    /// 처리 순서대로 정렬돼 있다 (깊은 것부터). 폭주 시에는 비어 있다.
    public let conversions: [Conversion]
    public let skipped: [SkippedItem]
    /// 폭주 여부와 무관하게, 변환 대상이던 항목 수. 사용자에게 보여 줄 숫자다.
    public let candidateCount: Int
    /// 한 배치가 감당할 수 있는 양을 넘었다 (FR-5). 이때는 하나도 처리하지 않는다.
    public let isOverflowing: Bool
}

/// 무엇을 건드리고 무엇을 건너뛸지, 어떤 순서로 처리할지 정한다 (FR-2, FR-4, FR-5).
///
/// 파일시스템에 접근하지 않는 순수 로직이다.
public enum Planner {

    /// 이 시간 안에 수정된 항목은 아직 쓰는 중일 수 있어 미룬다 (FR-2).
    public static let settleInterval: TimeInterval = 2.0

    /// 실시간 감시 한 배치의 상한 (FR-5). 넘으면 일괄 변환으로 넘긴다.
    public static let watchBatchLimit = 500

    /// 다운로드·저장 중일 수 있는 확장자. 완료되면 확장자가 바뀌면서 다시 이벤트가 온다.
    static let temporaryExtensions: Set<String> = [
        "download", "crdownload", "part", "partial", "tmp", "temp"
    ]

    /// 내부를 건드리면 안 되는 번들 확장자. 번들 자체의 이름은 변환 대상이다.
    static let packageExtensions: Set<String> = [
        "app", "photoslibrary", "bundle", "framework", "pkg"
    ]

    // MARK: - 계획

    /// 항목 목록을 받아 처리 계획을 만든다.
    ///
    /// - Parameters:
    ///   - items: 순회 결과. 순서는 상관없다.
    ///   - now: 기준 시각. 테스트에서 고정하기 위해 주입받는다.
    ///   - limit: 한 배치 상한. 실시간 감시는 ``watchBatchLimit``,
    ///            일괄 변환은 `nil`(제한 없음)을 넘긴다 (FR-6).
    public static func plan(items: [FileItem], now: Date, limit: Int?) -> Plan {
        var conversions: [Conversion] = []
        var skipped: [SkippedItem] = []

        for item in items {
            if let reason = skipReason(for: item, now: now) {
                skipped.append(SkippedItem(item: item, reason: reason))
            } else {
                conversions.append(Conversion(path: item.path,
                                              newName: Normalizer.normalized(item.name)))
            }
        }

        let count = conversions.count
        if let limit, count > limit {
            // 처리하지 않는다. 동기화 폴더 초기 복제 같은 상황에서 폭주를 막는다.
            return Plan(conversions: [], skipped: skipped,
                        candidateCount: count, isOverflowing: true)
        }

        return Plan(conversions: ordered(conversions, items: items),
                    skipped: skipped,
                    candidateCount: count,
                    isOverflowing: false)
    }

    // MARK: - 건너뛰기 판정

    /// 건드리지 않을 이유. `nil`이면 변환 대상이다.
    ///
    /// 순서에 의미가 있다. 안전 규칙(번들 내부)이 가장 앞이고, 가장 흔한 결과인
    /// "이미 조합형"이 비싼 판정보다 앞에 온다.
    public static func skipReason(for item: FileItem, now: Date) -> SkipReason? {
        let name = item.name

        guard Normalizer.isConvertibleName(name) else { return .unnamed }
        if isInsidePackage(item.path) { return .insidePackage }
        if name.hasPrefix(".") { return .hidden }
        if name.hasPrefix("~$") { return .officeTemporary }
        if let ext = fileExtension(of: name), temporaryExtensions.contains(ext) {
            return .temporaryDownload
        }
        if !Normalizer.needsConversion(name) { return .alreadyNormalized }

        // 미래 시각도 "방금"으로 본다. 시계가 어긋난 볼륨에서 확신 없이 건드리지 않는다.
        let age = now.timeIntervalSince(item.modificationDate)
        if age < settleInterval { return .recentlyModified }

        return nil
    }

    /// 이 디렉터리 안으로 들어가도 되는가. 순회하는 쪽(감시·일괄 변환)이 쓴다.
    ///
    /// 번들 내부와 숨김 폴더에는 들어가지 않는다. 번들 자체의 **이름**은
    /// ``skipReason(for:now:)``가 따로 판정한다.
    public static func shouldDescend(into item: FileItem) -> Bool {
        guard item.isDirectory, !item.isPackage else { return false }
        let name = item.name
        guard name != "." , name != ".." else { return false }
        if name.hasPrefix(".") { return false }
        if let ext = fileExtension(of: name), packageExtensions.contains(ext) { return false }
        return !isInsidePackage(item.path)
    }

    // MARK: - 순서 (FR-4)

    /// 깊은 것부터. 상위 폴더를 먼저 바꾸면 그 아래 경로가 전부 무효가 된다.
    /// 같은 깊이면 파일을 폴더보다 먼저 (T6), 그다음은 바이트 순으로 안정 정렬한다.
    private static func ordered(_ conversions: [Conversion], items: [FileItem]) -> [Conversion] {
        var isDirectory: [String: Bool] = [:]
        for item in items { isDirectory[item.path] = item.isDirectory }

        return conversions.sorted { a, b in
            let da = depth(of: a.path), db = depth(of: b.path)
            if da != db { return da > db }

            let aIsDir = isDirectory[a.path] ?? false
            let bIsDir = isDirectory[b.path] ?? false
            if aIsDir != bIsDir { return !aIsDir }

            // String의 `<`는 정규화를 무시해 NFD/NFC를 같다고 보므로 바이트로 비교한다.
            return a.path.utf8.lexicographicallyPrecedes(b.path.utf8)
        }
    }

    private static func depth(of path: String) -> Int {
        path.split(separator: "/").count
    }

    // MARK: - 경로 판정

    /// 조상 성분 중 번들 확장자를 가진 것이 있는가. 마지막 성분(자기 자신)은 보지 않는다.
    static func isInsidePackage(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        guard parts.count > 1 else { return false }
        return parts.dropLast().contains { part in
            guard let ext = fileExtension(of: String(part)) else { return false }
            return packageExtensions.contains(ext)
        }
    }

    /// 마지막 `.` 뒤의 확장자를 소문자로. 없으면 `nil`.
    static func fileExtension(of name: String) -> String? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let ext = name[name.index(after: dot)...]
        return ext.isEmpty ? nil : ext.lowercased()
    }
}
