import AppKit
import Combine
import CoreKit
import SwiftUI

/// 감시 폴더 하나의 현재 상태. 메뉴가 이 값을 그대로 그린다.
struct FolderStatus: Identifiable, Equatable {
    var folder: WatchedFolder
    var condition: Condition

    var id: UUID { folder.id }
    var name: String { folder.displayName }

    enum Condition: Equatable {
        case watching
        case off
        /// 폴더를 열 수 없다. 외장 디스크가 빠졌다 (FR-1, T11).
        case disconnected
        /// 한 번에 처리하기엔 너무 많다 (FR-5, T10).
        case overflowing(candidates: Int)
        /// 이 디스크는 변환을 지원하지 않는다 (HFS+·exFAT).
        case unsupported(fileSystem: String)

        /// 메뉴에 폴더 이름 옆으로 붙일 문구.
        var note: String? {
            switch self {
            case .watching, .off:              return nil
            case .disconnected:                return "연결 안 됨"
            case .overflowing:                 return "항목이 많습니다 — 일괄 변환을 사용하세요"
            case .unsupported(let fileSystem): return "이 디스크(\(fileSystem))는 지원하지 않습니다"
            }
        }

        var isProblem: Bool {
            switch self {
            case .watching, .off: return false
            default:              return true
            }
        }
    }
}

/// 앱 전역 상태. 감시·설정·로그를 잇는다.
///
/// 파일 처리는 전부 `fileQueue`(단일 직렬 큐)에서 돌고, 여기 `@Published` 값은
/// 메인 액터에서만 바뀐다 (요구사항 6장).
@MainActor
final class AppModel: ObservableObject {

    // MARK: - 공개 상태

    @Published private(set) var statuses: [FolderStatus] = []
    @Published private(set) var isPaused: Bool = false
    @Published private(set) var recentEntries: [LogEntry] = []
    @Published private(set) var launchAtLogin: Bool = false
    /// 로그인 항목 등록이 막혔을 때의 안내 문구 (FR-9).
    @Published private(set) var loginItemNotice: String?

    let presenter = WindowPresenter()

    // MARK: - 내부

    private let settings: SettingsStore
    private let log: LogStore
    private let fileQueue = DispatchQueue(label: "dev.liampark.moja.files", qos: .utility)
    private var watchers: [UUID: FolderWatcher] = [:]
    /// 볼륨 능력 판정은 앱 전체에서 공유한다. 폴더마다 다시 측정할 이유가 없다.
    private let volumes = VolumeCapabilities()

    init(settings: SettingsStore = SettingsStore(), log: LogStore = LogStore()) {
        self.settings = settings
        self.log = log
        self.isPaused = settings.isPaused
        self.launchAtLogin = LoginItem.isEnabled
        refreshStatuses()
    }

    // MARK: - 생애주기

    func start() {
        log.note("모자를 시작했습니다 (\(settings.folders.count)개 폴더)")
        if settings.hasCompletedOnboarding {
            syncWatchers()
        } else {
            showOnboarding()
        }
    }

    func quit() {
        log.note("모자를 종료했습니다")
        NSApplication.shared.terminate(nil)
    }

    // MARK: - 메뉴바 표시 (FR-7)

    var iconSymbolName: String {
        hasProblem ? "textformat.abc.dottedunderline" : "textformat.abc"
    }

    var iconOpacity: Double { isPaused ? 0.4 : 1.0 }

    private var hasProblem: Bool { statuses.contains { $0.condition.isProblem } }

    var statusLineText: String {
        if settings.folders.isEmpty { return "감시 중인 폴더가 없습니다" }
        if isPaused { return "일시정지됨" }
        let active = statuses.filter { $0.condition == .watching }.count
        return "감시 중 (\(active)개 폴더)"
    }

    var statusAccessibilityLabel: String {
        "모자, " + statusLineText
    }

    // MARK: - 폴더 (FR-1)

    func addFolders(_ paths: [String]) {
        var added = 0
        for path in paths where settings.addFolder(path: path) { added += 1 }
        guard added > 0 else { return }

        log.note("폴더를 추가했습니다: \(paths.joined(separator: ", "))")
        refreshStatuses()
        syncWatchers()
    }

    func removeFolder(id: UUID) {
        watchers[id]?.stop()
        watchers[id] = nil
        settings.removeFolder(id: id)
        refreshStatuses()
    }

    func setFolder(id: UUID, enabled: Bool) {
        settings.setFolder(id: id, enabled: enabled)
        refreshStatuses()
        syncWatchers()
    }

    // MARK: - 일시정지 (FR-7)

    func togglePause() {
        isPaused.toggle()
        settings.isPaused = isPaused
        log.note(isPaused ? "감시를 일시정지했습니다" : "감시를 재개했습니다")

        if isPaused {
            watchers.values.forEach { $0.stop() }
            watchers.removeAll()
        } else {
            // 재개 시 전체 재스캔 — 정지 중에 쌓인 파일을 놓치지 않는다 (미결 사항 3번의 결정).
            syncWatchers()
        }
        refreshStatuses()
    }

    // MARK: - 로그인 항목 (FR-9)

    func setLaunchAtLogin(_ enabled: Bool) {
        loginItemNotice = LoginItem.setEnabled(enabled)
        launchAtLogin = LoginItem.isEnabled
    }

    func openLoginItemSettings() {
        LoginItem.openSystemSettings()
    }

    // MARK: - 감시자 관리

    private func syncWatchers() {
        let wanted = isPaused ? [] : settings.folders.filter(\.isEnabled)
        let wantedIDs = Set(wanted.map(\.id))

        for (id, watcher) in watchers where !wantedIDs.contains(id) {
            watcher.stop()
            watchers[id] = nil
        }

        for folder in wanted where watchers[folder.id] == nil {
            let watcher = FolderWatcher(
                root: folder.path,
                queue: fileQueue,
                renamer: Renamer(volumes: volumes)
            ) { [weak self] activity in
                Task { @MainActor in self?.handle(activity, from: folder.id) }
            }
            watchers[folder.id] = watcher
            watcher.start()
        }
    }

    private func handle(_ activity: WatchActivity, from folderID: UUID) {
        switch activity {
        case .converted(let results):
            log.record(results)
            recentEntries = log.recent
            updateCondition(folderID, to: .watching)

        case .overflowed(let candidates):
            updateCondition(folderID, to: .overflowing(candidates: candidates))
            log.note("항목이 많아 자동 변환을 건너뛰었습니다 (\(candidates)개)")

        case .unavailable:
            updateCondition(folderID, to: .disconnected)

        case .unsupportedVolume(let fileSystem):
            updateCondition(folderID, to: .unsupported(fileSystem: fileSystem))
            log.note("변환을 지원하지 않는 디스크입니다 (\(fileSystem))")
        }
    }

    private func updateCondition(_ id: UUID, to condition: FolderStatus.Condition) {
        guard let index = statuses.firstIndex(where: { $0.id == id }),
              statuses[index].condition != condition else { return }
        statuses[index].condition = condition
    }

    /// 설정을 읽어 표시용 상태를 다시 만든다. 도달 가능 여부는 디스크를 건드리므로
    /// 파일 큐에서 확인하고 메인으로 돌아온다.
    private func refreshStatuses() {
        let folders = settings.folders

        statuses = folders.map {
            FolderStatus(folder: $0, condition: $0.isEnabled ? .watching : .off)
        }

        fileQueue.async { [weak self] in
            let unreachable = folders.filter { !$0.isReachable }.map(\.id)
            guard !unreachable.isEmpty else { return }
            Task { @MainActor in
                guard let self else { return }
                for id in unreachable { self.updateCondition(id, to: .disconnected) }
            }
        }
    }

    // MARK: - 창

    func showOnboarding() {
        presenter.show(id: "onboarding", title: "모자", size: CGSize(width: 460, height: 400)) {
            OnboardingView().environmentObject(self)
        }
    }

    func finishOnboarding() {
        settings.hasCompletedOnboarding = true
        presenter.close(id: "onboarding")
        syncWatchers()
    }

    func showFolderManager() {
        presenter.show(id: "folders", title: "폴더 관리", size: CGSize(width: 460, height: 320)) {
            FolderManagerView().environmentObject(self)
        }
    }

    // MARK: - 일괄 변환 (FR-6)

    /// 폴더 하나를 골라 기존 항목을 한 번에 변환한다.
    ///
    /// 변환하는 동안 그 폴더의 실시간 감시를 멈춘다. 켜 두면 우리가 바꾸는 이름마다
    /// 이벤트가 돌아와 같은 일을 두 번 하려 든다.
    func showBatchPreview(for folderID: UUID) {
        guard let status = statuses.first(where: { $0.id == folderID }) else { return }

        suspendWatcher(folderID)

        let session = BatchSession(
            root: status.folder.path,
            folderName: status.name,
            queue: fileQueue,
            renamer: Renamer(volumes: volumes),
            onFinish: { [weak self] results in
                Task { @MainActor in
                    guard let self else { return }
                    self.log.record(results)
                    self.recentEntries = self.log.recent
                }
            },
            onClose: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.presenter.close(id: Self.batchWindowID(folderID))
                    self.syncWatchers()   // 감시 재개
                }
            }
        )

        log.note("일괄 변환을 시작했습니다: \(status.folder.path)")
        presenter.show(id: Self.batchWindowID(folderID),
                       title: "기존 항목 일괄 변환",
                       size: CGSize(width: 560, height: 440)) {
            BatchPreviewView(session: session)
        }
        session.scan()
    }

    private static func batchWindowID(_ id: UUID) -> String { "batch-\(id.uuidString)" }

    /// 일괄 변환 중에만 쓰는 일시 중지. 설정의 일시정지 상태는 건드리지 않는다.
    private func suspendWatcher(_ id: UUID) {
        watchers[id]?.stop()
        watchers[id] = nil
    }

    func showHistory() {
        recentEntries = log.recent
        presenter.show(id: "history", title: "최근 변환 내역", size: CGSize(width: 560, height: 420)) {
            HistoryView().environmentObject(self)
        }
    }

    func showHelp() {
        presenter.show(id: "help", title: "모자 정보", size: CGSize(width: 460, height: 380)) {
            HelpView()
        }
    }

    var logFileURL: URL { log.fileURL }

    // MARK: - 폴더 고르기 (FR-8)

    /// 폴더 선택 창을 띄운다. 여러 개 고를 수 있다.
    func presentFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "추가"
        panel.message = "감시할 폴더를 고르세요."

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        addFolders(panel.urls.map(\.path))
    }

    /// 온보딩에서 미리 제시하는 폴더들. 사용자가 확인해야 실제로 등록된다.
    static var suggestedFolders: [(name: String, path: String)] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            ("데스크탑", home + "/Desktop"),
            ("다운로드", home + "/Downloads"),
            ("문서", home + "/Documents"),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
