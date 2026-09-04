import CoreServices
import Foundation

/// FSEvents가 알려 온 변화 하나.
struct FileSystemEvent {
    let path: String
    let flags: FSEventStreamEventFlags

    /// 이벤트가 뭉뚱그려졌다. 이 아래를 전부 다시 훑어야 한다.
    var mustScanSubDirectories: Bool {
        flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
    }

    /// 감시 중인 루트 자체가 옮겨지거나 지워졌다 (`WatchRoot` 플래그 덕분에 온다).
    var rootChanged: Bool {
        flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0
    }

    /// 볼륨이 빠졌다. 외장 디스크 분리 (T11).
    var unmounted: Bool {
        flags & FSEventStreamEventFlags(kFSEventStreamEventFlagUnmount) != 0
    }
}

/// `FSEventStream`의 얇은 래퍼.
///
/// `DispatchSource`는 최상위 폴더만 보므로 쓰지 않는다 (요구사항 6장).
/// 콜백은 생성 시 넘긴 직렬 큐에서 불린다.
final class FSEventsStream {

    /// FSEvents가 이벤트를 모아 두는 시간.
    ///
    /// 요구사항 6장은 1.0초를 제안했지만 0.3초로 줄였다. 뒤이어 1.5초 디바운스와
    /// 2초 안정화 대기가 붙어서, 1.0초를 쓰면 T1의 "2초 안에" 기준에서 너무 멀어진다.
    /// 0.3초는 이벤트를 뭉치는 효과를 대부분 유지하면서 첫 반응을 앞당긴다.
    static let latency: CFTimeInterval = 0.3

    private let root: String
    private let queue: DispatchQueue
    private let handler: ([FileSystemEvent]) -> Void
    private var stream: FSEventStreamRef?

    init(root: String, queue: DispatchQueue, handler: @escaping ([FileSystemEvent]) -> Void) {
        self.root = root
        self.queue = queue
        self.handler = handler
    }

    deinit { tearDown() }

    var isRunning: Bool { stream != nil }

    /// 감시를 시작한다. 폴더가 없거나 스트림을 만들 수 없으면 `false`.
    func start() -> Bool {
        guard stream == nil else { return true }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents   // 파일 단위로 받는다
                | kFSEventStreamCreateFlagNoDefer      // 첫 이벤트를 미루지 않는다
                | kFSEventStreamCreateFlagWatchRoot    // 루트가 옮겨지면 알려 준다
        )

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            eventCallback,
            &context,
            [root] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.latency,
            flags
        ) else { return false }

        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }

        stream = created
        return true
    }

    func stop() { tearDown() }

    private func tearDown() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    fileprivate func deliver(_ events: [FileSystemEvent]) {
        handler(events)
    }
}

/// C 콜백. `info`에 담아 둔 스트림으로 되돌아온다.
private let eventCallback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
    guard let info else { return }
    let stream = Unmanaged<FSEventsStream>.fromOpaque(info).takeUnretainedValue()

    // UseCFTypes를 켰으므로 CFArray of CFString이다.
    guard let cfPaths = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }

    var events: [FileSystemEvent] = []
    events.reserveCapacity(count)
    for index in 0..<count where index < cfPaths.count {
        events.append(FileSystemEvent(path: cfPaths[index], flags: flags[index]))
    }
    stream.deliver(events)
}
