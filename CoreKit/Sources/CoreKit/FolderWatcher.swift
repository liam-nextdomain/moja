import Foundation

/// 감시 폴더 하나에서 일어난 일.
public enum WatchActivity: Equatable, Sendable {
    /// 이름을 바꿨다. 비어 있지 않은 경우에만 온다.
    case converted([RenameResult])
    /// 한 배치가 감당할 양을 넘었다. 일괄 변환으로 안내해야 한다 (FR-5, T10).
    case overflowed(candidates: Int)
    /// 폴더를 열 수 없다. 외장 디스크가 빠졌거나 권한이 없다 (FR-1, T11).
    case unavailable
    /// 이 볼륨은 조합형 이름을 저장할 수 없다 (HFS+·exFAT).
    case unsupportedVolume(fileSystem: String)
}

/// 폴더 하나를 실시간으로 감시하며 분해된 이름을 조합형으로 되돌린다 (FR-1, FR-2, FR-5).
///
/// ## 흐름
///
/// ```
/// FSEvents ──▶ 디바운스(1.5초, 최대 5초) ──▶ 바뀐 폴더만 얕게 훑기
///                                              ├─ 500개 초과 → 폭주 보고, 처리 안 함
///                                              ├─ "쓰는 중" 항목 → 잠시 뒤 다시 확인
///                                              └─ 나머지 → 이름 변경 후 무시 목록에 등록
/// ```
///
/// 모든 상태 변경은 생성 시 받은 직렬 큐에서만 일어난다 (요구사항 6장).
public final class FolderWatcher {

    /// 미룬 항목을 다시 확인하기까지 기다리는 시간.
    ///
    /// 이게 없으면 "아직 쓰는 중"으로 미뤄진 파일이 영영 처리되지 않는다.
    /// 새 이벤트가 올 때까지 기다릴 수는 없다 — 파일 생성은 이미 끝났고,
    /// 더 이상 이벤트가 오지 않기 때문이다.
    static let retryDelay: TimeInterval = 1.5

    public let root: String

    private let queue: DispatchQueue
    private let renamer: Renamer
    private let batchLimit: Int?
    private let onActivity: (WatchActivity) -> Void

    private var stream: FSEventsStream?
    private var debouncer = Debouncer()
    private var ignoreList = IgnoreList()
    private var timer: DispatchSourceTimer?
    private var needsFullRescan = false

    /// - Parameters:
    ///   - root: 감시할 폴더.
    ///   - queue: 파일 처리를 도맡을 직렬 큐.
    ///   - batchLimit: 한 배치 상한. 기본값은 ``Planner/watchBatchLimit``.
    ///   - onActivity: 결과 알림. `queue`에서 불린다.
    public init(root: String,
                queue: DispatchQueue,
                renamer: Renamer = Renamer(),
                batchLimit: Int? = Planner.watchBatchLimit,
                onActivity: @escaping (WatchActivity) -> Void) {
        self.root = root
        self.queue = queue
        self.renamer = renamer
        self.batchLimit = batchLimit
        self.onActivity = onActivity
    }

    deinit {
        stream?.stop()
        timer?.cancel()
    }

    // MARK: - 시작·정지

    /// 감시를 시작하고 곧바로 전체를 한 번 훑는다.
    ///
    /// 앱이 꺼져 있는 동안 생긴 파일을 잡기 위해서다. 일시정지에서 재개할 때도
    /// 같은 경로를 탄다 (미결 사항 3번의 결정: 재개 시 전체 재스캔).
    public func start() {
        queue.async { [self] in
            guard stream == nil else { return }

            let created = FSEventsStream(root: root, queue: queue) { [weak self] events in
                self?.handle(events)
            }
            guard created.start() else {
                onActivity(.unavailable)
                return
            }
            stream = created
            performFullRescan()
        }
    }

    public func stop() {
        queue.async { [self] in
            stream?.stop()
            stream = nil
            timer?.cancel()
            timer = nil
            _ = debouncer.drain()
        }
    }

    /// 전체를 다시 훑는다. 일시정지 재개와 "연결 안 됨"에서 복귀할 때 쓴다.
    public func rescan() {
        queue.async { [self] in performFullRescan() }
    }

    // MARK: - 이벤트 처리

    private func handle(_ events: [FileSystemEvent]) {
        // 이 콜백은 이미 `queue`에서 불린다.
        if events.contains(where: { $0.unmounted || $0.rootChanged }) {
            onActivity(.unavailable)
            return
        }

        if events.contains(where: \.mustScanSubDirectories) {
            // 이벤트가 뭉뚱그려졌다. 어디가 바뀌었는지 알 수 없으니 전부 다시 본다.
            needsFullRescan = true
        }

        // 파일 이벤트가 오므로 그 파일이 담긴 폴더를 훑어야 한다.
        // 이벤트 대상이 폴더면 그 폴더 자체도 본다. 열 수 없는 경로는 스캔이 알아서 건너뛴다.
        var directories: [String] = []
        for event in events {
            directories.append(PathTools.parent(of: event.path))
            directories.append(event.path)
        }

        debouncer.record(directories, at: Date())
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard let deadline = debouncer.deadline else { return }
        let delay = max(0, deadline.timeIntervalSinceNow)

        timer?.cancel()
        let created = DispatchSource.makeTimerSource(queue: queue)
        created.schedule(deadline: .now() + delay)
        created.setEventHandler { [weak self] in self?.flush() }
        created.resume()
        timer = created
    }

    private func flush() {
        timer?.cancel()
        timer = nil

        let directories = debouncer.drain()

        if needsFullRescan {
            needsFullRescan = false
            performFullRescan()
            return
        }
        guard !directories.isEmpty else { return }

        process(Scanner.scanShallow(directories: directories, now: Date(), limit: batchLimit),
                deferredDirectories: directories)
    }

    private func performFullRescan() {
        process(Scanner.scan(root: root, now: Date(), limit: batchLimit),
                deferredDirectories: [root])
    }

    // MARK: - 실행

    private func process(_ outcome: ScanOutcome, deferredDirectories: [String]) {
        switch outcome {
        case .unavailable:
            onActivity(.unavailable)

        case .scanned(let plan):
            guard !plan.isOverflowing else {
                onActivity(.overflowed(candidates: plan.candidateCount))
                return
            }
            apply(plan)
            scheduleRetryIfNeeded(for: plan, directories: deferredDirectories)
        }
    }

    private func apply(_ plan: Plan) {
        let now = Date()
        ignoreList.purge(at: now)

        // 최근에 우리가 직접 바꾼 경로는 건너뛴다 (FR-5).
        let pending = plan.conversions.filter { !ignoreList.contains($0.path, at: now) }
        guard !pending.isEmpty else { return }

        var results: [RenameResult] = []
        var unsupported: String?

        for conversion in pending {
            let result = renamer.rename(conversion)
            switch result {
            case .renamed(let path, let newName):
                // 바꾸기 전후 두 경로 모두 무시 목록에 넣는다. 어느 쪽으로 이벤트가
                // 돌아오든 우리가 만든 것임을 알아본다.
                let at = Date()
                ignoreList.ignore(path, at: at)
                ignoreList.ignore(PathTools.replacingLastComponent(of: path, with: newName), at: at)
                results.append(result)
            case .unsupportedVolume(let fileSystem):
                unsupported = fileSystem
            case .notNeeded, .vanished:
                break
            case .conflict, .verificationFailed, .failed:
                results.append(result)
            }
        }

        if let unsupported {
            onActivity(.unsupportedVolume(fileSystem: unsupported))
            return
        }
        if !results.isEmpty {
            onActivity(.converted(results))
        }
    }

    /// "아직 쓰는 중"으로 미룬 항목이 있으면 잠시 뒤 다시 본다.
    ///
    /// 파일 저장은 이미 끝났을 수 있고, 그렇다면 새 이벤트가 오지 않는다.
    /// 우리가 다시 오지 않으면 그 파일은 영영 분해된 이름으로 남는다.
    private func scheduleRetryIfNeeded(for plan: Plan, directories: [String]) {
        guard plan.skipped.contains(where: { $0.reason == .recentlyModified }) else { return }

        debouncer.record(directories, at: Date().addingTimeInterval(Self.retryDelay - Debouncer.quietPeriod))
        scheduleFlush()
    }
}
