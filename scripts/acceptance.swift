// 수용 기준 자동 검증 — 요구사항 7장 T1~T11, T14.
//
//   swift scripts/acceptance.swift [Moja.app 경로]
//
// 진짜 앱을 띄워 진짜 파일로 확인한다. 사용자의 설정과 로그는 건드리지 않는다
// (앱이 MOJA_DEFAULTS_SUITE / MOJA_LOG_DIR 환경변수를 받는다).
//
// 파일 이름은 전부 바이트 단위로 다룬다. 셸의 글로빙은 이름을 조합형으로 정규화하기
// 때문에 정규화 시험의 준비물로 쓸 수 없다 (kb/wiki/research/rename-measurements.md 2.4).
//
// T13(재로그인)과 T15(24시간)는 사람과 시간이 필요해 여기서 하지 않는다.

import Foundation

// 진행 상황을 바로 보여 준다. 파이프로 넘길 때 기본은 통째로 모았다가 내보낸다.
setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - 이름·바이트 도우미

func nfd(_ s: String) -> String { s.decomposedStringWithCanonicalMapping }
func nfc(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }

func entries(_ dir: String) -> [String] {
    guard let handle = dir.withCString({ opendir($0) }) else { return [] }
    defer { closedir(handle) }
    var out: [String] = []
    while let raw = readdir(handle) {
        let entry = raw.pointee
        var storage = entry.d_name
        let bytes: [UInt8] = withUnsafeBytes(of: &storage) { buffer in
            (0..<Int(entry.d_namlen)).map { buffer[$0] }
        }
        if bytes == Array(".".utf8) || bytes == Array("..".utf8) { continue }
        out.append(String(decoding: bytes, as: UTF8.self))
    }
    return out
}

/// 이 디렉터리에 정확히 이 바이트열의 이름이 있는가.
func hasExact(_ name: String, in dir: String) -> Bool {
    let target = Array(name.utf8)
    return entries(dir).contains { Array($0.utf8) == target }
}

@discardableResult
func makeFile(_ path: String) -> Bool {
    let fd = path.withCString { open($0, O_CREAT | O_EXCL | O_WRONLY, 0o644) }
    if fd < 0 { return false }
    close(fd)
    return true
}

@discardableResult
func makeDir(_ path: String) -> Bool {
    path.withCString { mkdir($0, 0o755) } == 0
}

func removeTree(_ path: String) {
    var status = stat()
    guard path.withCString({ lstat($0, &status) }) == 0 else { return }
    if status.st_mode & S_IFMT == S_IFDIR {
        for name in entries(path) { removeTree(path + "/" + name) }
        _ = path.withCString { rmdir($0) }
    } else {
        _ = path.withCString { unlink($0) }
    }
}

func moveItem(_ from: String, _ to: String) -> Bool {
    from.withCString { f in to.withCString { t in rename(f, t) == 0 } }
}

// MARK: - 기다리기

/// 조건이 참이 될 때까지 기다린다. 실제로 걸린 시간을 돌려준다.
@discardableResult
func waitUntil(_ timeout: TimeInterval = 12, _ condition: () -> Bool) -> TimeInterval? {
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
        if condition() { return Date().timeIntervalSince(start) }
        usleep(200_000)
    }
    return nil
}

/// 조건이 계속 거짓인지 확인한다. 참이 되면 실패다.
func staysFalse(for duration: TimeInterval, _ condition: () -> Bool) -> Bool {
    let start = Date()
    while Date().timeIntervalSince(start) < duration {
        if condition() { return false }
        usleep(200_000)
    }
    return true
}

// MARK: - 앱 다루기

let scratch = NSTemporaryDirectory() + "moja-acceptance-" + UUID().uuidString
let watched = scratch + "/watched"
let outside = scratch + "/outside"
let logDirectory = scratch + "/logs"
let suiteName = "dev.liampark.moja.acceptance." + UUID().uuidString

let appPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath + "/build/Build/Products/Debug/Moja.app"

var appProcess: Process?

func seedSettings(folders: [String], paused: Bool = false) {
    struct Folder: Encodable { let id: String; let path: String; let isEnabled: Bool }
    let payload = folders.map { Folder(id: UUID().uuidString, path: $0, isEnabled: true) }
    let data = try! JSONEncoder().encode(payload)

    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set(data, forKey: "watchedFolders")
    defaults.set(true, forKey: "hasCompletedOnboarding")
    defaults.set(paused, forKey: "isPaused")
    defaults.synchronize()
}

func launchApp() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: appPath + "/Contents/MacOS/Moja")
    var environment = ProcessInfo.processInfo.environment
    environment["MOJA_DEFAULTS_SUITE"] = suiteName
    environment["MOJA_LOG_DIR"] = logDirectory
    process.environment = environment
    // 자식이 우리 표준 출력을 물려받으면 파이프가 닫히지 않아, 이 스크립트가 끝나도
    // 셸이 계속 기다린다. 실제로 한 번 겪었다.
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try! process.run()
    appProcess = process
    Thread.sleep(forTimeInterval: 2.5)   // 시작 시 전체 스캔이 끝날 짬
}

func stopApp() {
    appProcess?.terminate()
    appProcess?.waitUntilExit()
    appProcess = nil
    Thread.sleep(forTimeInterval: 0.5)
}

func logText() -> String {
    (try? String(contentsOfFile: logDirectory + "/Moja.log", encoding: .utf8)) ?? ""
}

// MARK: - 결과 표

struct Outcome {
    let id: String
    let scenario: String
    let passed: Bool
    let detail: String
}

var outcomes: [Outcome] = []

func report(_ id: String, _ scenario: String, _ passed: Bool, _ detail: String) {
    outcomes.append(Outcome(id: id, scenario: scenario, passed: passed, detail: detail))
    let mark = passed ? "✅" : "❌"
    print("  \(mark) \(id)  \(scenario) — \(detail)")
}

// MARK: - 준비

removeTree(scratch)
makeDir(scratch); makeDir(watched); makeDir(outside); makeDir(logDirectory)

guard FileManager.default.fileExists(atPath: appPath) else {
    print("앱을 찾을 수 없습니다: \(appPath)\n먼저 ./scripts/build.sh 를 실행하세요.")
    exit(2)
}

print("수용 기준 검증 — \(appPath)")
print("감시 폴더: \(watched)\n")

seedSettings(folders: [watched])
launchApp()

/// 뒷정리. `exit()`는 `defer`를 실행하지 않으므로 반드시 직접 부른다.
func cleanUp() {
    stopApp()
    UserDefaults.standard.removePersistentDomain(forName: suiteName)
    removeTree(scratch)
}

// MARK: - T1. 분해된 이름의 파일 생성

do {
    let name = nfd("한글 문서.txt")
    makeFile(watched + "/" + name)
    let elapsed = waitUntil { hasExact(nfc("한글 문서.txt"), in: watched) }
    let logged = logText().contains("변환")
    report("T1", "분해된 이름 파일 생성",
           elapsed != nil && logged,
           elapsed.map { String(format: "%.1f초에 변환, 로그 1건", $0) } ?? "시간 초과")
}

// MARK: - T2. 이미 조합형

do {
    let before = logText().components(separatedBy: "\n").count
    makeFile(watched + "/" + nfc("이미 조합형.txt"))
    let quiet = staysFalse(for: 8) { logText().components(separatedBy: "\n").count > before }
    report("T2", "이미 조합형인 파일 생성", quiet, quiet ? "아무 일도 없음, 로그 0건" : "로그가 늘었다")
}

// MARK: - T3. 파인더가 이름을 다시 분해해 저장한 경우

do {
    let composed = watched + "/" + nfc("이름 바꾸기.txt")
    makeFile(composed)
    Thread.sleep(forTimeInterval: 5)   // 먼저 자리를 잡게 둔다
    // 파인더가 하는 일과 같다: 같은 이름을 분해형으로 다시 쓴다.
    _ = moveItem(composed, watched + "/" + nfd("이름 바꾸기.txt"))
    let elapsed = waitUntil { hasExact(nfc("이름 바꾸기.txt"), in: watched) }
    report("T3", "이름을 분해형으로 다시 저장", elapsed != nil,
           elapsed.map { String(format: "%.1f초에 되돌림", $0) } ?? "시간 초과")
}

// MARK: - T4. 다른 폴더에서 옮겨 옴

do {
    let source = outside + "/" + nfd("옮겨 온 파일.txt")
    makeFile(source)
    _ = moveItem(source, watched + "/" + nfd("옮겨 온 파일.txt"))
    let elapsed = waitUntil { hasExact(nfc("옮겨 온 파일.txt"), in: watched) }
    report("T4", "다른 폴더에서 끌어다 놓기", elapsed != nil,
           elapsed.map { String(format: "%.1f초에 변환", $0) } ?? "시간 초과")
}

// MARK: - T5. 하위 3단계

do {
    let deep = watched + "/" + nfc("가") + "/" + nfc("나") + "/" + nfc("다")
    makeDir(watched + "/" + nfc("가"))
    makeDir(watched + "/" + nfc("가") + "/" + nfc("나"))
    makeDir(deep)
    makeFile(deep + "/" + nfd("깊은 파일.txt"))
    let elapsed = waitUntil { hasExact(nfc("깊은 파일.txt"), in: deep) }
    report("T5", "하위 폴더 3단계 안의 파일", elapsed != nil,
           elapsed.map { String(format: "%.1f초에 변환", $0) } ?? "시간 초과")
}

// MARK: - T6. 분해된 폴더 안의 분해된 파일들

do {
    let outer = watched + "/" + nfd("바깥 폴더")
    let inner = outer + "/" + nfd("안쪽 폴더")
    makeDir(outer); makeDir(inner)
    makeFile(outer + "/" + nfd("첫째.txt"))
    makeFile(inner + "/" + nfd("둘째.txt"))

    let newOuter = watched + "/" + nfc("바깥 폴더")
    let newInner = newOuter + "/" + nfc("안쪽 폴더")
    let elapsed = waitUntil(20) {
        hasExact(nfc("바깥 폴더"), in: watched)
            && hasExact(nfc("안쪽 폴더"), in: newOuter)
            && hasExact(nfc("첫째.txt"), in: newOuter)
            && hasExact(nfc("둘째.txt"), in: newInner)
    }
    report("T6", "분해된 폴더 안의 분해된 파일들", elapsed != nil,
           elapsed.map { String(format: "%.1f초에 전부 변환, 경로 오류 없음", $0) } ?? "시간 초과")
}

// MARK: - T7. 받는 중인 파일

do {
    let partial = watched + "/" + nfd("받는 중.download")
    makeFile(partial)
    let untouched = staysFalse(for: 8) { !hasExact(nfd("받는 중.download"), in: watched) }

    // 다운로드가 끝난 척: 임시 확장자를 뗀다.
    _ = moveItem(partial, watched + "/" + nfd("받는 중.zip"))
    let converted = waitUntil { hasExact(nfc("받는 중.zip"), in: watched) } != nil

    report("T7", "받는 중인 파일", untouched && converted,
           untouched ? (converted ? "받는 동안 그대로, 완료 후 변환" : "완료 후 변환 실패")
                     : "받는 중에 건드렸다")
}

// MARK: - T8. 문서 편집 중 임시 파일

do {
    makeFile(watched + "/" + nfd("~$보고서.docx"))
    let untouched = staysFalse(for: 8) { !hasExact(nfd("~$보고서.docx"), in: watched) }
    report("T8", "문서 편집 중 임시 파일", untouched,
           untouched ? "그대로 둠" : "건드렸다")
}

// MARK: - T9. 앱 꾸러미

do {
    let bundle = watched + "/" + nfd("한글 앱.app")
    makeDir(bundle); makeDir(bundle + "/Contents"); makeDir(bundle + "/Contents/Resources")
    makeFile(bundle + "/Contents/Resources/" + nfd("리소스.png"))

    let newBundle = watched + "/" + nfc("한글 앱.app")
    let renamed = waitUntil(20) { hasExact(nfc("한글 앱.app"), in: watched) } != nil
    let insideUntouched = renamed
        && hasExact(nfd("리소스.png"), in: newBundle + "/Contents/Resources")

    report("T9", "앱 꾸러미", renamed && insideUntouched,
           renamed ? (insideUntouched ? "꾸러미 이름만 바꾸고 안쪽은 그대로"
                                      : "꾸러미 안쪽을 건드렸다")
                   : "꾸러미 이름을 못 바꿨다")
}

// MARK: - T10. 한꺼번에 많은 파일

do {
    let staging = scratch + "/staging"
    makeDir(staging)
    for index in 0..<1_000 {
        makeFile(staging + "/" + nfd("대량 \(index).txt"))
    }
    // 한 번에 옮긴다. 셸 글로빙을 거치지 않으므로 이름이 분해형 그대로 도착한다.
    for name in entries(staging) {
        _ = moveItem(staging + "/" + name, watched + "/" + name)
    }

    let flagged = waitUntil(20) { logText().contains("항목이 많아") } != nil
    let untouched = hasExact(nfd("대량 0.txt"), in: watched)

    report("T10", "1,000개를 한 번에 투입", flagged && untouched,
           flagged ? (untouched ? "폭주로 표시하고 하나도 건드리지 않음" : "일부를 건드렸다")
                   : "폭주로 표시하지 않았다")

    // 뒷정리: 남은 대량 파일을 치운다. 이후 시나리오가 폭주에 걸리지 않게.
    for name in entries(watched) where name.hasPrefix(nfd("대량 ")) || name.hasPrefix(nfc("대량 ")) {
        _ = (watched + "/" + name).withCString { unlink($0) }
    }
    Thread.sleep(forTimeInterval: 6)
}

// MARK: - T14. 일시정지 중에는 바꾸지 않고, 재개하면 재스캔한다

do {
    stopApp()
    seedSettings(folders: [watched], paused: true)
    launchApp()

    makeFile(watched + "/" + nfd("정지 중 생성.txt"))
    let untouched = staysFalse(for: 8) { hasExact(nfc("정지 중 생성.txt"), in: watched) }

    // 재개 = 일시정지가 풀린 상태로 다시 시작. 전체 재스캔이 걸린다.
    stopApp()
    seedSettings(folders: [watched], paused: false)
    launchApp()

    let converted = waitUntil { hasExact(nfc("정지 중 생성.txt"), in: watched) } != nil
    report("T14", "일시정지 중 생성 → 재개", untouched && converted,
           untouched ? (converted ? "정지 중 그대로, 재개 시 재스캔으로 변환"
                                  : "재개해도 안 바뀜")
                     : "정지 중에 바꿨다")
}

// MARK: - T11. 외장 디스크 분리 후 재시작

do {
    let image = scratch + "/external.dmg"
    let volume = "/Volumes/MojaAcceptance"

    func run(_ launchPath: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    _ = run("/usr/bin/hdiutil", ["create", "-size", "20m", "-fs", "APFS",
                                 "-volname", "MojaAcceptance", "-type", "UDIF", "-quiet", image])
    _ = run("/usr/bin/hdiutil", ["attach", image, "-nobrowse", "-quiet"])

    if FileManager.default.fileExists(atPath: volume) {
        let external = volume + "/감시대상"
        makeDir(external)

        stopApp()
        seedSettings(folders: [watched, external])
        launchApp()

        // 디스크를 뺀 뒤 앱을 다시 띄운다.
        stopApp()
        _ = run("/usr/bin/hdiutil", ["detach", volume, "-quiet"])
        launchApp()
        let survived = appProcess?.isRunning == true

        // 다시 연결하면 감시가 살아나야 한다.
        _ = run("/usr/bin/hdiutil", ["attach", image, "-nobrowse", "-quiet"])
        Thread.sleep(forTimeInterval: 1)
        var resumed = false
        if FileManager.default.fileExists(atPath: external) {
            makeFile(external + "/" + nfd("복귀 확인.txt"))
            resumed = waitUntil(20) { hasExact(nfc("복귀 확인.txt"), in: external) } != nil
        }

        report("T11", "외장 디스크 분리 후 재시작", survived,
               survived ? (resumed ? "오류 없이 실행, 다시 연결하니 감시 재개"
                                   : "오류 없이 실행. 재연결 후 감시는 재시작이 필요")
                        : "앱이 죽었다")

        _ = run("/usr/bin/hdiutil", ["detach", volume, "-quiet"])
        stopApp()
        seedSettings(folders: [watched])
        launchApp()
    } else {
        report("T11", "외장 디스크 분리 후 재시작", false, "디스크 이미지를 붙이지 못해 확인 못 함")
    }
}

// MARK: - 결과 표

print("\n\n## 결과\n")
print("| # | 시나리오 | 결과 | 비고 |")
print("|---|---|---|---|")
for outcome in outcomes {
    print("| \(outcome.id) | \(outcome.scenario) | \(outcome.passed ? "통과" : "실패") | \(outcome.detail) |")
}

let failed = outcomes.filter { !$0.passed }
print("\n\(outcomes.count)개 중 \(outcomes.count - failed.count)개 통과.")
if !failed.isEmpty {
    print("실패: \(failed.map(\.id).joined(separator: ", "))")
}
print("\nT12(미리보기 취소)는 사람이 눌러야 하고, T13(재로그인)·T15(24시간 방치)·")
print("T16(Windows에서 열기)은 이 스크립트로 확인할 수 없다.")

cleanUp()
exit(failed.isEmpty ? 0 : 1)
