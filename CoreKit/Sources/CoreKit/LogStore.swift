import Foundation

/// 변환 내역 한 줄 (FR-10).
public struct LogEntry: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    /// 바꾸기 전 경로.
    public let path: String
    /// 바뀐 이름. 실패했으면 `nil`.
    public let newName: String?
    public let outcome: Outcome

    public enum Outcome: Equatable, Sendable {
        case converted
        case conflict
        case unsupportedVolume(fileSystem: String)
        case failed(reason: String)

        /// 메뉴에 그대로 보여 줄 문구. 기술 용어는 쓰지 않는다 (요구사항 11장 원칙).
        public var description: String {
            switch self {
            case .converted:                  return "바꿨습니다"
            case .conflict:                   return "같은 이름의 다른 파일이 있어 건너뛰었습니다"
            case .unsupportedVolume(let fs):  return "이 디스크(\(fs))는 변환을 지원하지 않습니다"
            case .failed(let reason):         return "실패했습니다 — \(reason)"
            }
        }
    }

    public init(id: UUID = UUID(), date: Date, path: String, newName: String?, outcome: Outcome) {
        self.id = id
        self.date = date
        self.path = path
        self.newName = newName
        self.outcome = outcome
    }
}

/// 최근 변환 내역을 메모리에 100건, 파일에 계속 남긴다 (FR-10).
///
/// 로그는 **로컬에만** 남는다. 이 앱은 어떤 네트워크 통신도 하지 않는다.
public final class LogStore {

    /// 메뉴의 "최근 변환 내역"에 보여 줄 건수.
    public static let memoryCapacity = 100
    /// 이 크기를 넘으면 회전한다.
    public static let maximumFileSize = 1_048_576

    private let directory: URL
    private let fileName: String
    private let capacity: Int
    private let maximumFileSize: Int
    private let lock = NSLock()
    private var buffer: [LogEntry] = []

    /// - Parameter directory: 기본값은 `~/Library/Logs/Moja`.
    public init(directory: URL = LogStore.defaultDirectory,
                fileName: String = "Moja.log",
                capacity: Int = LogStore.memoryCapacity,
                maximumFileSize: Int = LogStore.maximumFileSize) {
        self.directory = directory
        self.fileName = fileName
        self.capacity = capacity
        self.maximumFileSize = maximumFileSize
    }

    public static var defaultDirectory: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return library.appendingPathComponent("Logs/Moja", isDirectory: true)
    }

    public var fileURL: URL { directory.appendingPathComponent(fileName) }
    private var rotatedURL: URL { directory.appendingPathComponent(fileName + ".1") }

    /// 최근 것이 앞에 온다.
    public var recent: [LogEntry] {
        lock.lock(); defer { lock.unlock() }
        return buffer.reversed()
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        buffer.removeAll()
    }

    // MARK: - 기록

    /// 이름 변경 결과를 기록한다. 기록할 것이 없는 결과는 조용히 무시한다.
    public func record(_ results: [RenameResult], at date: Date = Date()) {
        let entries = results.compactMap { entry(for: $0, at: date) }
        guard !entries.isEmpty else { return }

        lock.lock()
        buffer.append(contentsOf: entries)
        if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
        lock.unlock()

        append(entries.map(line(for:)).joined())
    }

    /// 상태 메시지를 파일에만 남긴다 (시작·정지·폴더 추가 등).
    public func note(_ message: String, at date: Date = Date()) {
        append("\(Self.timestamp(date))  \(message)\n")
    }

    private func entry(for result: RenameResult, at date: Date) -> LogEntry? {
        switch result {
        case .renamed(let path, let newName):
            return LogEntry(date: date, path: path, newName: newName, outcome: .converted)
        case .conflict(let existing):
            return LogEntry(date: date, path: existing, newName: nil, outcome: .conflict)
        case .unsupportedVolume(let fileSystem):
            return LogEntry(date: date, path: "", newName: nil,
                            outcome: .unsupportedVolume(fileSystem: fileSystem))
        case .verificationFailed:
            return LogEntry(date: date, path: "", newName: nil,
                            outcome: .failed(reason: "확인하지 못했습니다"))
        case .failed(let stage, let code):
            return LogEntry(date: date, path: "", newName: nil,
                            outcome: .failed(reason: "\(stage): \(POSIXFile.errorText(code))"))
        case .notNeeded, .vanished:
            // 아무 일도 일어나지 않았다. T2가 요구하는 "로그 0건"이 여기서 지켜진다.
            return nil
        }
    }

    private func line(for entry: LogEntry) -> String {
        let time = Self.timestamp(entry.date)
        switch entry.outcome {
        case .converted:
            return "\(time)  변환  \(entry.path) → \(entry.newName ?? "")\n"
        default:
            let where_ = entry.path.isEmpty ? "" : "  \(entry.path)"
            return "\(time)  \(entry.outcome.description)\(where_)\n"
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime,
                                   .withDashSeparatorInDate, .withSpaceBetweenDateAndTime]
        return formatter.string(from: date)
    }

    // MARK: - 파일

    /// 파일에 덧붙인다. 실패해도 조용히 넘어간다 — 로그를 못 쓴다고 사용자 작업을
    /// 막을 이유는 없다 (5장 "실패 시 원칙").
    private func append(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }

        lock.lock(); defer { lock.unlock() }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        rotateIfNeeded()

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// 1MB를 넘으면 회전한다. 최근 1개만 보관한다 (FR-10).
    private func rotateIfNeeded() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size > maximumFileSize else { return }

        try? FileManager.default.removeItem(at: rotatedURL)
        try? FileManager.default.moveItem(at: fileURL, to: rotatedURL)
    }
}
