import Foundation

/// 감시 폴더 하나.
public struct WatchedFolder: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    /// 절대 경로. 샌드박스를 쓰지 않으므로 security-scoped bookmark가 필요 없다 (FR-11).
    public var path: String
    /// 폴더별 켜기/끄기 (FR-1).
    public var isEnabled: Bool

    public init(id: UUID = UUID(), path: String, isEnabled: Bool = true) {
        self.id = id
        self.path = path
        self.isEnabled = isEnabled
    }

    /// 메뉴에 보여 줄 이름. 홈 아래면 `~`로 줄인다.
    public var displayName: String {
        let name = PathTools.lastComponent(of: path)
        return name.isEmpty ? path : name
    }

    /// 지금 접근할 수 있는가. 외장 디스크가 빠지면 거짓이 된다 (FR-1, T11).
    public var isReachable: Bool {
        DirectoryReader.entries(at: path) != nil
    }
}

/// 앱 설정. `UserDefaults`에 담는다 (FR-11).
///
/// 폴더 목록은 JSON 한 덩어리로 저장한다. 경로에 어떤 바이트가 들어 있든
/// 그대로 왕복해야 하므로, 키를 경로로 쓰지 않는다.
public final class SettingsStore {

    private enum Key {
        static let folders = "watchedFolders"
        static let paused = "isPaused"
        static let onboarded = "hasCompletedOnboarding"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var folders: [WatchedFolder] {
        get {
            guard let data = defaults.data(forKey: Key.folders),
                  let decoded = try? JSONDecoder().decode([WatchedFolder].self, from: data)
            else { return [] }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Key.folders)
        }
    }

    public var isPaused: Bool {
        get { defaults.bool(forKey: Key.paused) }
        set { defaults.set(newValue, forKey: Key.paused) }
    }

    /// 온보딩은 폴더를 하나 이상 추가하기 전까지 다시 뜬다 (FR-8).
    public var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Key.onboarded) && !folders.isEmpty }
        set { defaults.set(newValue, forKey: Key.onboarded) }
    }

    // MARK: - 편집

    /// 폴더를 추가한다. 이미 있는 폴더면 아무것도 하지 않는다.
    ///
    /// 같은 폴더인지는 경로 문자열이 아니라 ``FileIdentity``로 따진다. 사용자는
    /// 같은 곳을 `/Users/나/바탕화면`으로도, 심볼릭 링크를 거쳐서도 고를 수 있다.
    @discardableResult
    public func addFolder(path: String) -> Bool {
        var current = folders
        let identity = FileIdentity(path: path)

        let alreadyThere = current.contains { existing in
            if existing.path == path { return true }
            guard let identity, let other = FileIdentity(path: existing.path) else { return false }
            return identity == other
        }
        guard !alreadyThere else { return false }

        current.append(WatchedFolder(path: path))
        folders = current
        return true
    }

    public func removeFolder(id: UUID) {
        folders = folders.filter { $0.id != id }
    }

    public func setFolder(id: UUID, enabled: Bool) {
        folders = folders.map { folder in
            guard folder.id == id else { return folder }
            var updated = folder
            updated.isEnabled = enabled
            return updated
        }
    }
}
