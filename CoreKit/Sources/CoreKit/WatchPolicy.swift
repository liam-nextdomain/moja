import Foundation

/// 최근에 우리가 직접 바꾼 경로를 잠시 무시한다 (FR-5).
///
/// 앱이 이름을 바꾸면 FSEvents가 그 사실을 알려 오고, 우리는 그걸 또 처리하려 든다.
/// 1차 방어선은 "이미 조합형이면 아무것도 하지 않는다"는 규칙이라 사실 이것만으로도
/// 루프는 끊긴다. 이 목록은 그 위에 얹는 두 번째 방어선으로, 불필요한 열거와 로그를 줄인다.
///
/// 경로는 **조합형으로 정규화한 바이트**를 열쇠로 쓴다. 이름을 바꾸기 전후의 경로가
/// 같은 파일을 가리키므로, 어느 형태로 이벤트가 와도 같은 항목으로 잡힌다.
public struct IgnoreList {

    /// 이 시간이 지나면 다시 정상 처리한다.
    public static let lifetime: TimeInterval = 3.0

    private var entries: [[UInt8]: Date] = [:]
    private let lifetime: TimeInterval

    public init(lifetime: TimeInterval = IgnoreList.lifetime) {
        self.lifetime = lifetime
    }

    public var count: Int { entries.count }

    private func key(_ path: String) -> [UInt8] {
        Array(path.precomposedStringWithCanonicalMapping.utf8)
    }

    public mutating func ignore(_ path: String, at time: Date) {
        entries[key(path)] = time
    }

    public func contains(_ path: String, at time: Date) -> Bool {
        guard let recorded = entries[key(path)] else { return false }
        return time.timeIntervalSince(recorded) < lifetime
    }

    /// 만료된 항목을 실제로 버린다. 주기적으로 부르지 않으면 24시간 감시에서 계속 자란다 (T15).
    public mutating func purge(at time: Date) {
        entries = entries.filter { time.timeIntervalSince($0.value) < lifetime }
    }
}

/// 이벤트를 모았다가 잠잠해지면 한 번에 처리한다 (FR-2).
///
/// 시각을 주입받는 순수 상태 기계다. 타이머는 소유자가 ``deadline``을 보고 건다.
/// 덕분에 타이밍에 의존하지 않고 전부 테스트할 수 있다.
public struct Debouncer {

    /// 마지막 이벤트로부터 이만큼 조용하면 처리한다.
    public static let quietPeriod: TimeInterval = 1.5

    /// 첫 이벤트로부터 아무리 늦어도 이 안에는 처리한다.
    ///
    /// 순수 디바운스만 쓰면 큰 파일을 받는 중인 다운로드 폴더처럼 이벤트가 끊이지 않는
    /// 곳에서 영영 처리가 미뤄진다. 그 폴더의 다른 파일들이 볼모가 되면 안 된다.
    public static let maximumWait: TimeInterval = 5.0

    private var pending: [[UInt8]: String] = [:]
    private var firstEventAt: Date?
    private var lastEventAt: Date?

    private let quietPeriod: TimeInterval
    private let maximumWait: TimeInterval

    public init(quietPeriod: TimeInterval = Debouncer.quietPeriod,
                maximumWait: TimeInterval = Debouncer.maximumWait) {
        self.quietPeriod = quietPeriod
        self.maximumWait = maximumWait
    }

    public var isEmpty: Bool { pending.isEmpty }

    /// 이벤트가 온 경로들을 담아 둔다.
    public mutating func record(_ paths: [String], at time: Date) {
        for path in paths {
            // 같은 경로가 분해형·조합형 두 형태로 와도 한 번만 처리한다.
            pending[Array(path.precomposedStringWithCanonicalMapping.utf8)] = path
        }
        if firstEventAt == nil { firstEventAt = time }
        lastEventAt = time
    }

    /// 언제 처리해야 하는가. 대기 중인 것이 없으면 `nil`.
    public var deadline: Date? {
        guard let firstEventAt, let lastEventAt, !pending.isEmpty else { return nil }
        return min(lastEventAt.addingTimeInterval(quietPeriod),
                   firstEventAt.addingTimeInterval(maximumWait))
    }

    /// 모아 둔 경로를 꺼내고 상태를 비운다.
    public mutating func drain() -> [String] {
        let paths = Array(pending.values)
        pending.removeAll(keepingCapacity: true)
        firstEventAt = nil
        lastEventAt = nil
        return paths
    }
}
