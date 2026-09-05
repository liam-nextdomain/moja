// kb/ 지식 베이스 도구. 문서 사이의 관계를 그래프로 만들고, 질문에 답할 절을 찾고,
// 문서를 고쳤을 때 영향받는 곳을 알려 준다.
//
//   swift scripts/kb.swift build                 세 산출물을 다시 만든다
//   swift scripts/kb.swift query "질문" [-k 8] [--json]
//   swift scripts/kb.swift impact <파일경로>      바뀐 문서의 파급 범위
//   swift scripts/kb.swift check                 끊긴 참조가 있으면 exit 1
//   swift scripts/kb.swift selftest              파서 자체 검사
//   swift scripts/kb.swift hook                  훅 payload를 stdin으로 받아 위를 순서대로
//
// 파일을 쪼개지 않은 이유: `swift a.swift b.swift`는 b.swift를 컴파일하지 않고 인자로 넘긴다.
// 파일을 나누면 파서를 복제해야 하고, 복제본이 어긋나면 절의 줄 범위가 조용히 틀어져
// 엉뚱한 슬라이스를 돌려준다. 잡아 줄 컴파일러도 테스트도 없다.
//
// 이 파일이 지키는 세 가지 (전부 실측으로 확인한 함정이다):
//
//  1. Swift 정규식의 \b는 한글 옆에서 못 믿는다. 같은 패턴이 "T10에"는 잡고 "T16과"는
//     놓친다. 경고도 없이 심볼이 사라진다. 그래서 경계를 lookbehind로 직접 적고,
//     lookbehind를 지원하지 않는 네이티브 Regex 대신 NSRegularExpression만 쓴다.
//  2. JSONEncoder는 키 순서를 뒤섞고 콜론 앞에 공백을 넣는다. git이 추적하는 산출물로
//     쓸 수 없다. 순서를 보존하는 writer를 직접 만든다. Set과 불안정 정렬도 같은 이유로
//     피한다. 산출물이 매번 요동치면 훅이 diff 생성기가 되고 아무도 안 보게 된다.
//  3. 절 id의 슬러그는 반드시 NFC로 정규화한다. graph.json은 git 추적 대상이라
//     파인더에서 복사한 NFD 제목이 한 번 섞이면 id가 조용히 갈라진다. 이 저장소가
//     앱에서 금지하는 바로 그 버그를 도구가 저지르면 안 된다.

import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - 경로와 상수

let PROJECT_ROOT: String = {
    // scripts/kb.swift 기준으로 저장소 뿌리를 찾는다. 어디서 실행하든 같은 곳을 본다.
    let this = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let root = this.deletingLastPathComponent().deletingLastPathComponent()
    if FileManager.default.fileExists(atPath: root.appendingPathComponent("project.yml").path) {
        return root.path
    }
    return FileManager.default.currentDirectoryPath
}()

let WIKI_DIR = PROJECT_ROOT + "/kb/wiki"
let RAW_DIR = PROJECT_ROOT + "/kb/raw"
let GRAPH_PATH = WIKI_DIR + "/graph.json"
let SECTIONS_PATH = WIKI_DIR + "/graph_sections.json"
let PROGRESS_DIR = PROJECT_ROOT + "/.claude/progress"
let ROADMAP_PATH = PROGRESS_DIR + "/roadmap.md"
let TASKS_PATH = PROGRESS_DIR + "/graph_tasks.json"
let IMPACT_PATH = PROGRESS_DIR + "/impact-report.json"
/// 번역 지시서. 지식이 아니라 다음 턴의 할 일이라 impact-report.json과 같은 자리에 둔다.
let SYNC_PATH = PROGRESS_DIR + "/sync-manifest.json"

/// implements 엣지를 찾을 때 훑는 곳. 테스트는 엔티티를 구현하지 않고 인용만 한다.
let CODE_ROOTS = ["App", "CoreKit/Sources", "scripts"]
/// cites 엣지는 테스트 주석도 본다. 시나리오 번호가 거기 적혀 있다.
let CITE_ROOTS = ["App", "CoreKit/Sources", "CoreKit/Tests", "scripts"]
/// 생성물. CoreKit/.build/.../runner.swift가 실재하므로 반드시 걸러야 한다.
let SKIP_DIRS: Set<String> = [".build", "build", "DerivedData", ".git", ".swiftpm", "fixtures"]

/// 같은 심볼을 여러 문서가 선언 형태로 적을 때 누가 주인인지. 숫자가 작을수록 앞선다.
/// requirements가 FR-*와 T*의 원본이고, acceptance-results는 T*를 다시 나열할 뿐이다.
let DECLARING_TYPE_RANK: [String: Int] = [
    "requirements": 0, "design": 1, "measurement": 3,
    "verification": 4, "ops": 6, "review": 8,
]
let DEFAULT_TYPE_RANK = 9

/// 문서를 가리키는 이름표. 상호 참조에서 "REQUIREMENTS 12.1" 같은 표기를 푼다.
let DOC_LABELS: [(String, String)] = [
    ("REQUIREMENTS", "requirements"), ("requirements", "requirements"), ("요구사항", "requirements"),
    ("rename-measurements", "rename-measurements"), ("acceptance-results", "acceptance-results"),
]

// MARK: - 정본과 번역본

/// 번역본을 알아보는 접미사. 언어를 늘리면 이 목록만 늘린다.
/// 한국어가 정본이고 영어가 번역본이다. 사람은 정본을 쓰고 고치며, 클로드는 번역본을 읽는다.
let TRANSLATION_SUFFIXES = [".en.md"]

/// kb/wiki 안에서 파일이 맡은 역할.
/// - canonical: 한국어 정본. 사람이 고친다. 버전의 주인이다.
/// - translation: 영어 번역본. 클로드가 읽고 그래프가 색인한다.
/// - apparatus: index.md와 log.md. 문서가 아니라 장치다.
enum WikiRole { case canonical, translation, apparatus }

/// kb/wiki 기준 상대 경로를 받는다. "spec/requirements.en.md" 처럼.
func classifyWiki(_ wikiRel: String) -> WikiRole {
    let name = wikiRel.contains("/") ? String(wikiRel.split(separator: "/").last!) : wikiRel
    // 하위 폴더의 index.md도 장치로 본다. 예전에는 loadDocs가 최상위만 걸러서
    // kb/wiki/spec/index.md가 그래프 문서가 되는데 훅은 그것을 장치로 보고 건너뛰었다.
    if name == "index.md" || name == "log.md" { return .apparatus }
    if TRANSLATION_SUFFIXES.contains(where: { name.hasSuffix($0) }) { return .translation }
    return .canonical
}

/// 저장소 뿌리 기준 경로를 받아 kb/wiki 안의 마크다운이면 역할과 함께 준다.
/// cmdBump·cmdImpact·cmdHook이 전부 뿌리 기준 경로를 다루므로 classifyWiki와 따로 둔다.
func wikiFile(repoRel: String) -> (wikiRel: String, role: WikiRole)? {
    guard repoRel.hasPrefix("kb/wiki/"), repoRel.hasSuffix(".md") else { return nil }
    let wikiRel = String(repoRel.dropFirst("kb/wiki/".count))
    return (wikiRel, classifyWiki(wikiRel))
}

/// 정본 → 번역본. "spec/requirements.md" → "spec/requirements.en.md"
func translationPath(ofCanonical wikiRel: String) -> String {
    String(wikiRel.dropLast(3)) + TRANSLATION_SUFFIXES[0]
}

/// 번역본 → 정본. 접미사가 안 붙어 있으면 nil.
func canonicalPath(ofTranslation wikiRel: String) -> String? {
    for s in TRANSLATION_SUFFIXES where wikiRel.hasSuffix(s) {
        return String(wikiRel.dropLast(s.count)) + ".md"
    }
    return nil
}

let TODAY: String = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    return f.string(from: Date())
}()

// MARK: - 작은 도우미

func warn(_ s: String) { FileHandle.standardError.write(("⚠ " + s + "\n").data(using: .utf8)!) }
func die(_ s: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write(("✖ " + s + "\n").data(using: .utf8)!)
    exit(code)
}

/// 순서를 보존하는 중복 제거. Set은 순서가 없어서 산출물을 요동치게 만든다.
func orderedUnique<T: Hashable>(_ xs: [T]) -> [T] {
    var seen = Set<T>(), out: [T] = []
    out.reserveCapacity(xs.count)
    for x in xs where seen.insert(x).inserted { out.append(x) }
    return out
}

/// 겹치지 않는 부분 문자열 개수. Python의 str.count와 같다.
///
/// Swift의 range(of:)는 정준 동치로 비교하므로 NFD로 친 질의어가 NFC 본문에 걸린다.
/// 본문 검색에서는 이게 이득이다. 이름 비교(Renamer)에서는 절대 아니다.
func occurrences(of needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var n = 0
    var i = haystack.startIndex
    while i < haystack.endIndex,
          let r = haystack.range(of: needle, range: i..<haystack.endIndex) {
        n += 1
        i = r.upperBound > r.lowerBound ? r.upperBound : haystack.index(after: r.lowerBound)
    }
    return n
}

/// 편집기가 N번째 줄이라고 부르는 것과 같게 쪼갠다.
/// Python의 splitlines()나 Swift의 enumerateLines는 \r에서도 쪼개져 줄 번호가 어긋난다.
func splitLines(_ text: String) -> [String] {
    var ls = text.components(separatedBy: "\n")
    if ls.last == "" { ls.removeLast() }
    return ls
}

func readFile(_ path: String) -> String? {
    guard let d = FileManager.default.contents(atPath: path) else { return nil }
    return String(data: d, encoding: .utf8)
}

func relPath(_ absolute: String, from base: String) -> String {
    let b = base.hasSuffix("/") ? base : base + "/"
    return absolute.hasPrefix(b) ? String(absolute.dropFirst(b.count)) : absolute
}

/// 하위 디렉터리를 훑되 생성물은 건너뛴다.
func walk(_ root: String, ext: String) -> [String] {
    var out: [String] = []
    let fm = FileManager.default
    guard let e = fm.enumerator(atPath: root) else { return out }
    for case let rel as String in e {
        let parts = rel.split(separator: "/").map(String.init)
        if parts.contains(where: { SKIP_DIRS.contains($0) || ($0.hasPrefix(".") && $0 != ".") }) {
            if let last = parts.last, last == parts.first, SKIP_DIRS.contains(last) { e.skipDescendants() }
            continue
        }
        if rel.hasSuffix(ext) { out.append(root + "/" + rel) }
    }
    return out.sorted()
}

// MARK: - 정규식 도우미

/// NSRegularExpression 얇은 껍데기. 네이티브 Regex는 lookbehind를 못 해서 쓸 수 없다.
struct Rx {
    let re: NSRegularExpression
    init(_ pattern: String, _ opts: NSRegularExpression.Options = []) {
        guard let r = try? NSRegularExpression(pattern: pattern, options: opts) else {
            die("정규식이 잘못되었습니다: \(pattern)")
        }
        re = r
    }

    private func caps(_ m: NSTextCheckingResult, _ s: String) -> [String] {
        var out: [String] = []
        out.reserveCapacity(m.numberOfRanges)
        for i in 0..<m.numberOfRanges {
            // NSRange는 UTF-16 기준이다. 반드시 Range(_:in:)로 옮겨야 제목의 ⚠️ 같은
            // 서로게이트 쌍이 잘리지 않는다.
            if let r = Range(m.range(at: i), in: s) { out.append(String(s[r])) } else { out.append("") }
        }
        return out
    }

    private func full(_ s: String) -> NSRange { NSRange(s.startIndex..<s.endIndex, in: s) }

    func first(_ s: String) -> [String]? {
        guard let m = re.firstMatch(in: s, range: full(s)) else { return nil }
        return caps(m, s)
    }

    func all(_ s: String) -> [[String]] {
        re.matches(in: s, range: full(s)).map { caps($0, s) }
    }

    /// 매치 전체가 차지한 자리까지 함께 준다. 여러 패턴을 같은 텍스트에 돌릴 때
    /// 앞선 패턴이 이미 삼킨 자리를 뒤 패턴이 다시 잡지 않게 하려면 범위가 필요하다.
    /// caps와 같은 이유로 Range(_:in:)를 거친다.
    func allWithRange(_ s: String) -> [(caps: [String], range: Range<String.Index>)] {
        re.matches(in: s, range: full(s)).compactMap { m in
            guard let r = Range(m.range, in: s) else { return nil }
            return (caps(m, s), r)
        }
    }

    func matches(_ s: String) -> Bool { re.firstMatch(in: s, range: full(s)) != nil }
}

// MARK: - JSON 쓰기

/// 삽입 순서를 그대로 쓰는 JSON writer.
/// JSONEncoder는 키를 뒤섞고 `"key" : value`로 띄운다. git 추적 산출물에는 쓸 수 없다.
indirect enum J {
    case s(String), i(Int), d(Double), b(Bool), null
    case a([J])
    case o([(String, J)])

    static func strs(_ xs: [String]) -> J { .a(xs.map { .s($0) }) }

    private static func esc(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                // 한글은 그대로 쓴다 (ensure_ascii=False와 같다). 제어 문자만 이스케이프.
                if ch.value < 0x20 { out += String(format: "\\u%04x", ch.value) }
                else { out.unicodeScalars.append(ch) }
            }
        }
        return out + "\""
    }

    private static func num(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 { return String(Int(v)) }
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    func write(_ indent: Int = 0) -> String {
        let pad = String(repeating: " ", count: indent)
        let pad2 = String(repeating: " ", count: indent + 2)
        switch self {
        case .s(let v): return J.esc(v)
        case .i(let v): return String(v)
        case .d(let v): return J.num(v)
        case .b(let v): return v ? "true" : "false"
        case .null: return "null"
        case .a(let xs):
            if xs.isEmpty { return "[]" }
            return "[\n" + xs.map { pad2 + $0.write(indent + 2) }.joined(separator: ",\n") + "\n" + pad + "]"
        case .o(let kvs):
            if kvs.isEmpty { return "{}" }
            return "{\n" + kvs.map { pad2 + J.esc($0.0) + ": " + $0.1.write(indent + 2) }
                .joined(separator: ",\n") + "\n" + pad + "}"
        }
    }
}

func writeJSON(_ j: J, to path: String) {
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let text = j.write() + "\n"
    do { try text.write(toFile: path, atomically: true, encoding: .utf8) }
    catch { die("쓰지 못했습니다: \(path) (\(error))") }
}

// MARK: - 프론트매터 파서

/// 프론트매터 값. 일반 YAML이 아니라 이 저장소가 실제로 쓰는 모양만 표현한다.
indirect enum FMValue {
    case scalar(String)
    case list([FMValue])
    case map(FMMap)

    var string: String? { if case .scalar(let s) = self { return s }; return nil }
    var stringList: [String] {
        if case .list(let xs) = self { return xs.compactMap { $0.string } }
        if case .scalar(let s) = self { return [s] }
        return []
    }
    var mapList: [FMMap] {
        if case .list(let xs) = self { return xs.compactMap { if case .map(let m) = $0 { return m }; return nil } }
        return []
    }
}

/// 키 순서를 보존하는 작은 맵. 순서가 곧 산출물의 순서라서 Dictionary를 쓰지 않는다.
struct FMMap {
    private(set) var keys: [String] = []
    private var storage: [String: FMValue] = [:]

    mutating func set(_ k: String, _ v: FMValue) {
        if storage[k] == nil { keys.append(k) }
        storage[k] = v
    }
    func value(_ k: String) -> FMValue? { storage[k] }
    func str(_ k: String) -> String? { storage[k]?.string }
    func strs(_ k: String) -> [String] { storage[k]?.stringList ?? [] }
    func maps(_ k: String) -> [FMMap] { storage[k]?.mapList ?? [] }
}

private let FM_TOP_RE = Rx("^([A-Za-z_][A-Za-z0-9_-]*):[ \t]*(.*)$")
private let FM_ITEM_RE = Rx("^-[ \t]+(.*)$")

/// 따옴표를 벗기고 주석을 떼어 낸다. 타입 변환은 하지 않는다.
///
/// 전부 문자열로 남긴다. PyYAML은 `version: 1.0`을 부동소수로 바꿔 버려서 원본 프로젝트가
/// 모든 버전에 손으로 따옴표를 쳐야 했다. 여기서는 그럴 필요가 없다.
func fmUnquote(_ raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespaces)
    if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
        s = String(s.dropFirst().dropLast())
        var out = "", esc = false
        for c in s {
            if esc { out.append(c == "\"" || c == "\\" ? c : c); esc = false }
            else if c == "\\" { esc = true }
            else { out.append(c) }
        }
        return out
    }
    if s.count >= 2, s.hasPrefix("'"), s.hasSuffix("'") {
        return String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
    }
    // 따옴표가 없을 때만 ` #` 뒤를 주석으로 본다.
    if let r = s.range(of: " #") { s = String(s[s.startIndex..<r.lowerBound]) }
    else if let r = s.range(of: "\t#") { s = String(s[s.startIndex..<r.lowerBound]) }
    return s.trimmingCharacters(in: .whitespaces)
}

/// `[a, b, "c, d"]`를 쪼갠다. 따옴표 안의 쉼표를 지켜야 해서 문자 단위로 훑는다.
func fmParseFlowList(_ raw: String) -> [FMValue] {
    var s = raw.trimmingCharacters(in: .whitespaces)
    guard s.hasPrefix("[") else { return [] }
    s = String(s.dropFirst())
    if s.hasSuffix("]") { s = String(s.dropLast()) }
    var out: [FMValue] = [], cur = "", inD = false, inS = false
    for c in s {
        if c == "\"" && !inS { inD.toggle(); cur.append(c) }
        else if c == "'" && !inD { inS.toggle(); cur.append(c) }
        else if c == "," && !inD && !inS {
            let t = cur.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { out.append(.scalar(fmUnquote(t))) }
            cur = ""
        } else { cur.append(c) }
    }
    let t = cur.trimmingCharacters(in: .whitespaces)
    if !t.isEmpty { out.append(.scalar(fmUnquote(t))) }
    return out
}

/// (프론트매터, 본문 시작 줄). 프론트매터가 없거나 망가졌으면 (nil, 1).
func parseFrontmatter(text: String, origin: String) -> (FMMap?, Int) {
    let lines = splitLines(text)
    guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
        return (nil, 1)
    }
    var close = -1
    for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
        close = i; break
    }
    guard close > 0 else {
        warn("\(origin): 프론트매터를 닫는 --- 가 없습니다. 이 문서를 건너뜁니다")
        return (nil, 1)
    }
    let body = Array(lines[1..<close])
    guard let m = parseFrontmatterLines(body, origin: origin, lineOffset: 2) else { return (nil, close + 2) }
    return (m, close + 2)
}

func parseFrontmatterLines(_ lines: [String], origin: String, lineOffset: Int = 1) -> FMMap? {
    var top = FMMap()
    var pendingKey: String? = nil          // 최상위 키가 컨테이너를 기다리는 중
    var listItems: [FMValue] = []
    var listDashIndent = -1
    var item: FMMap? = nil                 // 지금 채우고 있는 map 항목
    var itemKeyIndent = -1
    var itemPendingKey: String? = nil      // 항목 안의 키가 블록 리스트를 기다리는 중
    var itemList: [FMValue] = []

    func closeItemPending() {
        if let k = itemPendingKey {
            item?.set(k, .list(itemList))
            itemPendingKey = nil; itemList = []
        }
    }
    func closeItem() {
        closeItemPending()
        if let it = item { listItems.append(.map(it)); item = nil }
    }
    func closeTop() {
        closeItem()
        if let k = pendingKey {
            top.set(k, .list(listItems))
            pendingKey = nil; listItems = []; listDashIndent = -1; itemKeyIndent = -1
        }
    }

    for (i, raw) in lines.enumerated() {
        let lineNo = i + lineOffset
        if raw.hasPrefix("\t") || raw.hasPrefix(" \t") {
            warn("\(origin):\(lineNo): 프론트매터에 탭 들여쓰기가 있습니다. 스페이스만 씁니다. 이 문서를 건너뜁니다")
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        let indent = raw.prefix(while: { $0 == " " }).count

        if indent == 0 {
            closeTop()
            guard let c = FM_TOP_RE.first(raw) else {
                warn("\(origin):\(lineNo): 최상위 키를 읽지 못했습니다: \(trimmed). 이 문서를 건너뜁니다")
                return nil
            }
            let key = c[1], rest = c[2].trimmingCharacters(in: .whitespaces)
            if rest.isEmpty { pendingKey = key; listItems = []; listDashIndent = -1 }
            else if rest.hasPrefix("[") { top.set(key, .list(fmParseFlowList(rest))) }
            else { top.set(key, .scalar(fmUnquote(rest))) }
            continue
        }

        guard pendingKey != nil else {
            warn("\(origin):\(lineNo): 들여쓴 줄인데 열린 키가 없습니다: \(trimmed). 이 문서를 건너뜁니다")
            return nil
        }

        if let c = FM_ITEM_RE.first(trimmed) {
            let body = c[1].trimmingCharacters(in: .whitespaces)
            if listDashIndent < 0 { listDashIndent = indent }
            if indent > listDashIndent, itemPendingKey != nil {
                // 항목 안의 블록 리스트다. 예: entities[].code 아래의 - 경로
                itemList.append(.scalar(fmUnquote(body)))
                continue
            }
            closeItem()
            if let kc = FM_TOP_RE.first(body) {
                var m = FMMap()
                let k = kc[1], rest = kc[2].trimmingCharacters(in: .whitespaces)
                if rest.isEmpty { itemPendingKey = k; itemList = [] }
                else if rest.hasPrefix("[") { m.set(k, .list(fmParseFlowList(rest))) }
                else { m.set(k, .scalar(fmUnquote(rest))) }
                item = m
                itemKeyIndent = indent + 2
            } else if body.isEmpty {
                item = FMMap(); itemKeyIndent = indent + 2
            } else {
                listItems.append(.scalar(fmUnquote(body)))
            }
            continue
        }

        // 항목 안의 `키: 값`
        guard item != nil else {
            warn("\(origin):\(lineNo): 리스트 항목 밖의 들여쓴 키입니다: \(trimmed). 이 문서를 건너뜁니다")
            return nil
        }
        guard let kc = FM_TOP_RE.first(trimmed) else {
            warn("\(origin):\(lineNo): 항목 안의 키를 읽지 못했습니다: \(trimmed). 이 문서를 건너뜁니다")
            return nil
        }
        if indent < itemKeyIndent { closeItemPending() }
        closeItemPending()
        let k = kc[1], rest = kc[2].trimmingCharacters(in: .whitespaces)
        if rest.isEmpty { itemPendingKey = k; itemList = [] }
        else if rest.hasPrefix("[") { item?.set(k, .list(fmParseFlowList(rest))) }
        else { item?.set(k, .scalar(fmUnquote(rest))) }
    }
    closeTop()
    return top
}

// MARK: - 절 색인

struct Section {
    let id: String          // "requirements#12.4a", "acceptance-results#T13"
    let doc: String
    let path: String        // kb/wiki 기준 상대 경로
    let level: Int          // 2 또는 3
    let num: String?        // "12.4a" / "FR-1" / nil
    let heading: String
    let lineStart: Int      // 1부터, 제목 줄 포함
    let lineEnd: Int        // 포함
    var text: String = ""
    var declared: [String] = []
    var mentioned: [String] = []
}

private let HEADING_RE = Rx("^(#{2,3})[ \t]+(.*?)[ \t]*$")
private let NUMBERED_RE = Rx("^([0-9]+(?:\\.[0-9]+)*[a-z]?)\\.?[ \t]+(.*)$")
private let SYMHEAD_RE = Rx("^((?:FR|NFR|T)-?[0-9]{1,2}[a-z]?)[.:][ \t]+(.*)$")

/// 장 번호가 없는 제목의 절 id.
///
/// 한글을 지운 ascii 슬러그는 이 저장소에서 전부 빈 문자열이 되므로 한글을 남긴다.
/// 반드시 NFC로 정규화한다. 파일 맨 위 주석의 3번 항목을 보라.
func slugify(_ text: String, max: Int = 40) -> String {
    let normalized = text.precomposedStringWithCanonicalMapping.lowercased()
    var out = ""
    for ch in normalized {
        if ch == "`" { continue }
        if ch.isLetter || ch.isNumber { out.append(ch) }
        else if ch == " " || ch == "\t" || ch == "_" || ch == "-" { out.append("-") }
        // 나머지(⚠️, 괄호, 쉼표, 마침표)는 버린다
    }
    while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
    while out.hasPrefix("-") { out.removeFirst() }
    while out.hasSuffix("-") { out.removeLast() }
    if out.count > max { out = String(out.prefix(max)) }
    while out.hasSuffix("-") { out.removeLast() }
    return out.isEmpty ? "section" : out
}

/// 제목을 (level, num, heading)으로 가른다. 심볼 제목 → 번호 제목 → 슬러그 순으로 본다.
func splitHeading(_ hashes: String, _ raw: String) -> (Int, String?, String) {
    let level = hashes.count
    if let c = SYMHEAD_RE.first(raw) { return (level, c[1], c[2]) }
    if let c = NUMBERED_RE.first(raw) { return (level, c[1], c[2]) }
    return (level, nil, raw)
}

func parseSections(text: String, docId: String, path: String, bodyStart: Int) -> [Section] {
    let lines = splitLines(text)
    var heads: [(Int, Int, String?, String)] = []   // (줄번호, level, num, heading)
    var inFence = false
    var i = bodyStart - 1
    while i < lines.count {
        let line = lines[i]
        let lt = line.trimmingCharacters(in: .whitespaces)
        if lt.hasPrefix("```") || lt.hasPrefix("~~~") { inFence.toggle(); i += 1; continue }
        if !inFence, let c = HEADING_RE.first(line) {
            let (lv, num, h) = splitHeading(c[1], c[2])
            heads.append((i + 1, lv, num, h))
        }
        i += 1
    }
    var out: [Section] = []
    var used = Set<String>()
    for (k, h) in heads.enumerated() {
        // 다음 제목 **직전**까지가 이 절이다. 깊이를 따지지 않는 이유는, 상위 절이 하위 절
        // 본문을 삼키면 같은 단어가 두 번 세어져 점수가 부풀고, "이 줄부터 저 줄까지 읽어라"가
        // 113줄짜리 안내가 되기 때문이다. 이렇게 하면 문서의 모든 줄이 정확히 한 절에 속한다.
        let end = k + 1 < heads.count ? heads[k + 1].0 - 1 : lines.count
        var id = docId + "#" + (h.2 ?? slugify(h.3))
        if used.contains(id) { id += "-\(k)" }
        used.insert(id)
        let body = lines[(h.0 - 1)..<min(end, lines.count)].joined(separator: "\n")
        out.append(Section(id: id, doc: docId, path: path, level: h.1, num: h.2,
                           heading: h.3, lineStart: h.0, lineEnd: max(h.0, end), text: body))
    }
    return out
}

// MARK: - 심볼 선언·언급

// \b는 한글 옆에서 못 믿는다. 경계를 직접 적는다. 파일 맨 위 주석 1번 항목.
// FR-3은 하이픈이 있고 T1은 없다. 그래서 -? 다.
let SYMBOL_RE = Rx("(?<![A-Za-z0-9-])((?:FR|NFR|T)-?[0-9]{1,2}[a-z]?)(?![0-9A-Za-z-])")
/// "T1~T16" 같은 범위. 이 저장소에서 "전부"를 뜻하는 관용 표기다.
let RANGE_RE = Rx("(?<![A-Za-z0-9-])T([0-9]{1,2})[~\\-–]T?([0-9]{1,2})(?![0-9])")

let DECLARATION_SHAPES = [
    // ### FR-1. 폴더 감시 (필수)   /   ### T13: 로그인 시 자동 실행
    Rx("^[\\s>]*#{2,3}[ \t]+((?:FR|NFR|T)-?[0-9]{1,2}[a-z]?)[.:][ \t]"),
    // | T1 | 감시 폴더에 NFD 이름 파일 생성 | ...
    Rx("^[\\s>]*\\|\\s*\\*{0,2}\\s*((?:FR|NFR|T)-?[0-9]{1,2}[a-z]?)\\s*\\*{0,2}\\s*\\|"),
    // - **FR-1** ... / - T1: ...  (지금은 안 쓰지만 모양을 열어 둔다)
    Rx("^[\\s>]*[-*]\\s*\\*\\*\\s*((?:FR|NFR|T)-?[0-9]{1,2}[a-z]?)"),
    Rx("^[\\s>]*[-*]\\s*((?:FR|NFR|T)-?[0-9]{1,2}[a-z]?)\\s*[:：—-]"),
]

func symbolsIn(_ text: String) -> [String] {
    var out = SYMBOL_RE.all(text).map { $0[1] }
    for c in RANGE_RE.all(text) {
        guard let a = Int(c[1]), let b = Int(c[2]), a <= b, b - a <= 30 else { continue }
        for n in a...b { out.append("T\(n)") }
    }
    return orderedUnique(out)
}

func annotateSymbols(_ sections: inout [Section]) {
    for i in sections.indices {
        var declared: [String] = []
        for line in splitLines(sections[i].text) {
            for shape in DECLARATION_SHAPES {
                if let c = shape.first(line) { declared.append(c[1]); break }
            }
        }
        sections[i].declared = orderedUnique(declared)
        let all = symbolsIn(sections[i].text)
        let dset = Set(sections[i].declared)
        sections[i].mentioned = all.filter { !dset.contains($0) }
    }
}

// MARK: - 상호 참조

// 맨 N.N 은 이 저장소에서 소수(3.09초, 1.5초, 27.0)인 경우가 훨씬 많다.
// 그래서 원본의 BARE_SECTION_RE를 버리고 단서가 붙은 형태만 본다. 영어 번역본에서는
// 그 판단이 더 중요하다. macOS 13.4, Swift 6.3.3, v1.1이 전부 N.N 이기 때문이다.

/// 이름표 목록을 DOC_LABELS에서 만든다. 예전에는 표와 패턴에 같은 목록이 따로 있어서,
/// 문서를 하나 더 만들 때 한쪽만 고치면 그 문서로 가는 참조가 조용히 사라졌다.
/// 긴 이름을 먼저 놓는다. ICU의 | 는 최장 일치가 아니라 왼쪽 우선이라, "requirements"가
/// "requirements-v2"보다 앞서면 뒤엣것의 앞부분만 잘라 먹는다.
/// DOC_LABELS(68) 뒤에 와야 한다. 스크립트 최상위 let은 소스 순서대로 실행된다.
private let LABEL_REF_RE: Rx = {
    let alts = DOC_LABELS.map { $0.0 }.sorted { $0.count > $1.count }
        .map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
    return Rx("(?<![A-Za-z0-9-])(" + alts + ")[ \t]*§?[ \t]*([0-9]{1,2}(?:\\.[0-9]+)*[a-z]?)(?:장|절)?")
}()
private let CHAPTER_REF_RE = Rx("(?<![0-9.])([0-9]{1,2})장")
private let CUED_REF_RE = Rx("(?<![0-9.])([0-9]{1,2}(?:\\.[0-9]+)*[a-z]?)(?:절)?[ \t]*(?:참조|의[ \t])")
/// 영어 번역본의 절 표기. § 는 이 코퍼스에 한 번도 나온 적이 없어 단서로 삼기에 안전하다.
/// 영어 낱말 단서(see chapter 12)를 쓰지 않는 이유는 "see 12.1 seconds later" 같은 모양을
/// 만들어 내기 때문이다.
private let SIGIL_REF_RE = Rx("§[ \t]*([0-9]{1,2}(?:\\.[0-9]+)*[a-z]?)(?![0-9])")

struct SectionRef { let toDoc: String; let num: String; let labelled: Bool }

/// 이름표가 붙은 참조를 먼저 훑고, 그 자리를 나머지 패턴에서 뺀다.
/// 그러지 않으면 "acceptance-results 2장"이 올바른 참조와 selfDoc#2 참조를 동시에 만든다.
/// 없는 관계가 그래프에 들어가는 것이라, § 표기를 더하기 전에 반드시 고쳐야 했다.
func findSectionRefs(text: String, selfDoc: String) -> [SectionRef] {
    var out: [SectionRef] = []
    var claimed: [Range<String.Index>] = []
    for m in LABEL_REF_RE.allWithRange(text) {
        let doc = DOC_LABELS.first { $0.0 == m.caps[1] }?.1 ?? selfDoc
        out.append(SectionRef(toDoc: doc, num: m.caps[2], labelled: true))
        claimed.append(m.range)
    }
    func free(_ r: Range<String.Index>) -> Bool { !claimed.contains { $0.overlaps(r) } }
    // § 는 이름표만큼 명시적이므로 labelled로 둔다. 이 깃발의 뜻은 "산문이 아니라 지시이므로
    // 안 풀리면 결함"이고, cmdCheck가 그것을 오류로 올린다.
    for m in SIGIL_REF_RE.allWithRange(text) where free(m.range) {
        out.append(SectionRef(toDoc: selfDoc, num: m.caps[1], labelled: true))
        claimed.append(m.range)
    }
    for m in CHAPTER_REF_RE.allWithRange(text) where free(m.range) {
        out.append(SectionRef(toDoc: selfDoc, num: m.caps[1], labelled: false))
    }
    for m in CUED_REF_RE.allWithRange(text) where free(m.range) {
        out.append(SectionRef(toDoc: selfDoc, num: m.caps[1], labelled: false))
    }
    return out
}

// MARK: - 로드맵

struct Task {
    let id: String, status: String, milestone: String, module: String, title: String
    let date: String?, codePaths: [String], symbols: [String], sectionRefs: [(String, String)]
}

// 마일스톤이 곧 릴리스다. 요구사항 8장이 "v1.0.0 = 수용 기준 전부 통과"로 고정해 두었다.
let TASK_RE = Rx("^\\s*-\\s*\\[([ xX])\\]\\s*(V[0-9]+(?:\\.[0-9]+)?-[A-Z]{2,6}-[0-9]{2})\\s*:\\s*(.*)$")
// 루트가 대문자다(App/, CoreKit/). 한글이 단어 문자라 \b가 안 되므로 lookbehind를 쓴다.
let CODE_PATH_RE = Rx("(?<![A-Za-z0-9._/-])((?:App|CoreKit|scripts|docs|kb)/[A-Za-z0-9._/-]+\\.[A-Za-z0-9]+|README\\.md|project\\.yml)")
private let TASK_DATE_RE = Rx("\\(([0-9]{4}-[0-9]{2}-[0-9]{2})\\)")

func parseRoadmap(_ text: String) -> [Task] {
    var out: [Task] = []
    for line in splitLines(text) {
        guard let c = TASK_RE.first(line) else { continue }
        let id = c[2], title = c[3]
        // 앞의 두 하이픈까지만 쪼갠다. V1.1-KB-01 → V1.1 + KB
        let parts = id.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        let milestone = parts.count > 0 ? parts[0] : id
        let module = parts.count > 1 ? parts[1] : ""
        let refs = findSectionRefs(text: title, selfDoc: "requirements")
        out.append(Task(
            id: id,
            status: c[1].lowercased() == "x" ? "done" : "todo",
            milestone: milestone, module: module, title: title,
            date: TASK_DATE_RE.first(title)?[1],
            codePaths: orderedUnique(CODE_PATH_RE.all(title).map { $0[1] }),
            symbols: symbolsIn(title),
            sectionRefs: orderedUnique(refs.map { $0.toDoc + "\u{1}" + $0.num })
                .map { p in let a = p.split(separator: "\u{1}").map(String.init); return (a[0], a[1]) }
        ))
    }
    return out
}

// MARK: - 문서 읽기

struct Doc {
    let id: String, path: String, absPath: String
    let title: String, type: String, version: String, date: String
    let tags: [String]
    let parents: [FMMap], reviews: [FMMap], related: [FMMap], entities: [FMMap]
    let text: String, bodyStart: Int
    var sections: [Section] = []
}

/// 그래프가 색인할 파일을 고른다. 짝이 있으면 번역본을, 없으면 정본을 싣는다.
///
/// 클로드가 읽는 것이 번역본이므로 색인 대상도 번역본이어야 한다. 그런데 짝마다 하나만
/// 실어야 한다. 정본과 번역본이 같은 id를 갖는데 둘 다 실리면 buildGraph의
/// Dictionary(uniqueKeysWithValues:)에서 죽는다.
///
/// 폴백이 있는 이유는 이관을 점진적으로 만들기 위해서다. 번역본이 없는 문서는 정본이
/// 그대로 색인되므로 한 편씩 옮길 수 있다. 빠진 번역본은 cmdCheck가 크게 보고한다.
func indexedWikiFiles() -> [(abs: String, rel: String)] {
    var canonical: [String: String] = [:]      // wikiRel → abs
    var translated: Set<String> = []           // 짝이 있는 정본의 wikiRel
    var out: [(abs: String, rel: String)] = []
    for abs in walk(WIKI_DIR, ext: ".md") {
        let rel = relPath(abs, from: WIKI_DIR)
        switch classifyWiki(rel) {
        case .apparatus: continue
        case .canonical: canonical[rel] = abs
        case .translation:
            out.append((abs, rel))
            if let c = canonicalPath(ofTranslation: rel) { translated.insert(c) }
        }
    }
    for (rel, abs) in canonical where !translated.contains(rel) { out.append((abs, rel)) }
    return out.sorted { $0.rel < $1.rel }
}

/// 색인 대상 문서 전부.
func loadDocs() -> [Doc] {
    var out: [Doc] = []
    for (abs, rel) in indexedWikiFiles() {
        guard let text = readFile(abs) else { warn("읽지 못했습니다: \(rel)"); continue }
        let (fm, bodyStart) = parseFrontmatter(text: text, origin: "kb/wiki/" + rel)
        guard let fm else {
            warn("kb/wiki/\(rel): 프론트매터가 없습니다. `/wiki-frontmatter`로 만드세요. 건너뜁니다")
            continue
        }
        guard let id = fm.str("id"), !id.isEmpty else {
            warn("kb/wiki/\(rel): 프론트매터에 id가 없습니다. 건너뜁니다")
            continue
        }
        var d = Doc(id: id, path: rel, absPath: abs,
                    title: fm.str("title") ?? id,
                    type: fm.str("type") ?? "",
                    version: fm.str("version") ?? "",
                    date: fm.str("date") ?? "",
                    tags: fm.strs("tags"),
                    parents: fm.maps("parents"), reviews: fm.maps("reviews"),
                    related: fm.maps("related"), entities: fm.maps("entities"),
                    text: text, bodyStart: bodyStart)
        d.sections = parseSections(text: text, docId: id, path: rel, bodyStart: bodyStart)
        annotateSymbols(&d.sections)
        out.append(d)
    }
    return out.sorted { $0.id < $1.id }
}

// MARK: - 짝 대조

/// 정본 한 편과 그 번역본. Doc이 아닌 이유는 Doc의 모든 필드가 graph.json 노드의 속성이
/// 되는데 여기서 필요한 것은 대조뿐이기 때문이다. 고아 번역본은 canonical이 비어 있다.
struct WikiPair {
    let canonical: String            // kb/wiki 기준. 고아면 ""
    let translation: String          // kb/wiki 기준. 없으면 ""
    let canonicalFM: FMMap?
    let translationFM: FMMap?
    let canonicalNums: [String]
    let translationNums: [String]
}

private func readPairSide(_ wikiRel: String) -> (FMMap?, [String]) {
    let abs = WIKI_DIR + "/" + wikiRel
    guard let text = readFile(abs) else { return (nil, []) }
    let (fm, bodyStart) = parseFrontmatter(text: text, origin: "kb/wiki/" + wikiRel)
    let secs = parseSections(text: text, docId: "x", path: wikiRel, bodyStart: bodyStart)
    return (fm, secs.compactMap { $0.num })
}

/// kb/wiki의 정본과 번역본을 짝지어 준다. 장치(index.md·log.md)는 빼고,
/// 정본이 없는 번역본은 고아로 따로 담는다.
func loadWikiPairs() -> [WikiPair] {
    var canonicals: [String] = []
    var translations: Set<String> = []
    for abs in walk(WIKI_DIR, ext: ".md") {
        let rel = relPath(abs, from: WIKI_DIR)
        switch classifyWiki(rel) {
        case .apparatus: continue
        case .canonical: canonicals.append(rel)
        case .translation: translations.insert(rel)
        }
    }
    var out: [WikiPair] = []
    for c in canonicals.sorted() {
        let t = translationPath(ofCanonical: c)
        let has = translations.contains(t)
        if has { translations.remove(t) }
        let (cfm, cnums) = readPairSide(c)
        let (tfm, tnums) = has ? readPairSide(t) : (nil, [])
        out.append(WikiPair(canonical: c, translation: has ? t : "",
                            canonicalFM: cfm, translationFM: tfm,
                            canonicalNums: cnums, translationNums: tnums))
    }
    for orphan in translations.sorted() {
        let (tfm, tnums) = readPairSide(orphan)
        out.append(WikiPair(canonical: "", translation: orphan,
                            canonicalFM: nil, translationFM: tfm,
                            canonicalNums: [], translationNums: tnums))
    }
    return out
}

/// 번역이 정본을 따라잡았는가. cmdCheck가 -> Never 라 검사할 수 없어서 판정만 뺐다.
func translationStatus(sourceVersion: String, canonicalVersion: String) -> String {
    if sourceVersion.isEmpty || canonicalVersion.isEmpty { return "unknown" }
    return sourceVersion == canonicalVersion ? "ok" : "stale"
}

/// frontmatter의 구조 항목만 비교한다. title·note·definition은 언어가 달라 보지 않는다.
/// 이 항목들이 어긋나면 번역본이 그래프에 넣는 관계가 정본이 정한 것과 달라진다.
func frontmatterMismatches(canonical c: FMMap, translation t: FMMap) -> [String] {
    var out: [String] = []
    for key in ["id", "type", "date"] {
        let a = c.str(key) ?? "", b = t.str(key) ?? ""
        if a != b { out.append("\(key): 정본 \"\(a)\" ≠ 번역본 \"\(b)\"") }
    }
    func parentSig(_ m: FMMap) -> [String] {
        m.maps("parents").map { "\($0.str("id") ?? "")|\($0.str("version") ?? "")|\($0.strs("sections").joined(separator: "+"))" }
    }
    func entitySig(_ m: FMMap) -> [String] {
        m.maps("entities").map { "\($0.str("name") ?? "")|\($0.str("type") ?? "")|\($0.strs("code").joined(separator: "+"))" }
    }
    if parentSig(c) != parentSig(t) { out.append("parents가 다릅니다") }
    if entitySig(c) != entitySig(t) { out.append("entities가 다릅니다 (이름·타입·code는 복제해야 합니다)") }
    if c.strs("tags") != t.strs("tags") { out.append("tags가 다릅니다") }
    return out
}

// MARK: - 코드 훑기

/// 주석 줄인가. cites는 주석에서만 캔다. 식별자가 T10처럼 생겼을 수 있어서다.
private let COMMENT_RE = Rx("^\\s*(///?|\\*|//!)")

struct CodeCite { let path: String; let line: Int; let symbol: String }

/// 소스 주석이 인용한 요구사항 심볼. 이 저장소는 이미 이렇게 적고 있어서 채택 비용이 0이다.
///   /// 한 배치가 감당할 양을 넘었다. 일괄 변환으로 안내해야 한다 (FR-5, T10).
func scanCites() -> [CodeCite] {
    var out: [CodeCite] = []
    for root in CITE_ROOTS {
        let abs = PROJECT_ROOT + "/" + root
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: abs, isDirectory: &isDir), isDir.boolValue else { continue }
        for file in walk(abs, ext: ".swift") {
            guard let text = readFile(file) else { continue }
            let rel = relPath(file, from: PROJECT_ROOT)
            // 이 도구 자신은 제외한다. 주석과 자체 검사 문자열이 심볼을 잔뜩 인용하고 있어서
            // 넣어 두면 모든 심볼이 kb.swift를 가리키게 된다. 제품 코드가 아니다.
            if rel == "scripts/kb.swift" { continue }
            for (i, line) in splitLines(text).enumerated() {
                guard COMMENT_RE.matches(line) || line.contains("//") else { continue }
                // 코드 뒤에 붙은 주석이면 // 뒤만 본다.
                var scan = line
                if !COMMENT_RE.matches(line), let r = line.range(of: "//") { scan = String(line[r.lowerBound...]) }
                for sym in symbolsIn(scan) { out.append(CodeCite(path: rel, line: i + 1, symbol: sym)) }
            }
        }
    }
    return out
}

// MARK: - 그래프 만들기

func buildGraph(quiet: Bool = false) -> (docs: [Doc], graph: J, sections: J, tasks: J?) {
    let docs = loadDocs()
    let docIds = Set(docs.map { $0.id })

    // 노드: 문서
    var nodes: [J] = docs.map { d in
        .o([("id", .s(d.id)), ("type", .s("document")), ("doc_type", .s(d.type)),
            ("title", .s(d.title)), ("version", .s(d.version)), ("date", .s(d.date)),
            ("path", .s(d.path)), ("tags", J.strs(d.tags))])
    }

    // 노드: 엔티티. 여러 문서가 같은 이름을 쓰면 먼저 정의를 준 쪽이 이긴다.
    var entityOrder: [String] = []
    var entityType: [String: String] = [:], entityDef: [String: String] = [:]
    var entityCode: [String: [String]] = [:]
    var defines: [(String, String)] = []
    for d in docs {
        for e in d.entities {
            guard let name = e.str("name"), !name.isEmpty else {
                warn("kb/wiki/\(d.path): 이름 없는 엔티티가 있습니다"); continue
            }
            if entityType[name] == nil { entityOrder.append(name); entityType[name] = e.str("type") ?? "concept" }
            if let def = e.str("definition"), !def.isEmpty, entityDef[name] == nil { entityDef[name] = def }
            let code = e.strs("code")
            if !code.isEmpty { entityCode[name] = orderedUnique((entityCode[name] ?? []) + code) }
            defines.append((d.id, name))
        }
    }
    for name in entityOrder {
        var kv: [(String, J)] = [("id", .s(name)), ("type", .s("entity")),
                                 ("entity_type", .s(entityType[name] ?? "concept"))]
        if let def = entityDef[name] { kv.append(("definition", .s(def))) }
        nodes.append(.o(kv))
    }

    // 노드: 코드. frontmatter의 entities[].code가 진실이다. 소스에 마커를 심지 않는다.
    var codeEntities: [String: [String]] = [:]
    // entityOrder를 돈다. Dictionary 순회 순서는 실행마다 달라서, 그 위를 돌면 코드 노드의
    // entities 배열이 매번 뒤섞이고 graph.json이 아무 이유 없이 diff에 뜬다.
    for name in entityOrder {
        for p in entityCode[name] ?? [] {
            if !FileManager.default.fileExists(atPath: PROJECT_ROOT + "/" + p) {
                warn("엔티티 `\(name)`의 code 경로가 없습니다: \(p). 파일이 옮겨졌는지 보세요")
                continue
            }
            codeEntities[p] = orderedUnique((codeEntities[p] ?? []) + [name])
        }
    }
    for p in codeEntities.keys.sorted() {
        let lang = p.hasSuffix(".swift") ? "swift" : (p.hasSuffix(".yml") ? "yaml" : "other")
        nodes.append(.o([("id", .s(p)), ("type", .s("code")), ("lang", .s(lang)),
                         ("entities", J.strs(codeEntities[p]!))]))
    }

    // 엣지
    var edges: [J] = []
    func docEdges(_ key: String, _ relation: String, _ maps: (Doc) -> [FMMap]) {
        for d in docs {
            for m in maps(d) {
                guard let to = m.str("id"), !to.isEmpty else { continue }
                if !docIds.contains(to) {
                    warn("kb/wiki/\(d.path): \(key) 가 없는 문서를 가리킵니다: \(to)")
                    continue
                }
                var kv: [(String, J)] = [("from", .s(d.id)), ("to", .s(to)), ("relation", .s(relation))]
                if let v = m.str("version") { kv.append(("version", .s(v))) }
                let secs = m.strs("sections")
                if !secs.isEmpty { kv.append(("sections", J.strs(secs))) }
                if let n = m.str("note") { kv.append(("note", .s(n))) }
                edges.append(.o(kv))
            }
        }
    }
    docEdges("parents", "derives_from") { $0.parents }
    docEdges("reviews", "reviews") { $0.reviews }
    docEdges("related", "relates_to") { $0.related }

    for (doc, name) in defines {
        edges.append(.o([("from", .s(doc)), ("to", .s(name)), ("relation", .s("defines"))]))
    }
    for p in codeEntities.keys.sorted() {
        for name in codeEntities[p]! {
            edges.append(.o([("from", .s(p)), ("to", .s(name)), ("relation", .s("implements"))]))
        }
    }

    // derives_from_section: parents[].sections를 실제 절에 붙인다
    var sectionIds = Set<String>()
    for d in docs { for s in d.sections { sectionIds.insert(s.id) } }
    for d in docs {
        for m in d.parents {
            guard let to = m.str("id") else { continue }
            for num in m.strs("sections") {
                let sid = to + "#" + num
                if sectionIds.contains(sid) {
                    edges.append(.o([("from", .s(d.id)), ("to", .s(sid)),
                                     ("relation", .s("derives_from_section"))]))
                } else {
                    warn("kb/wiki/\(d.path): parents의 sections가 없는 절을 가리킵니다: \(sid)")
                }
            }
        }
    }

    // co_entity: 엔티티를 함께 가진 문서 쌍. 문서들 사이에서만 드러나는 의미가 여기서 나온다.
    var byDoc: [String: Set<String>] = [:]
    for (doc, name) in defines { byDoc[doc, default: []].insert(name) }
    let ids = docs.map { $0.id }
    for a in 0..<ids.count {
        for b in (a + 1)..<ids.count {
            let shared = (byDoc[ids[a]] ?? []).intersection(byDoc[ids[b]] ?? []).sorted()
            guard !shared.isEmpty else { continue }
            edges.append(.o([("from", .s(ids[a])), ("to", .s(ids[b])), ("relation", .s("co_entity")),
                             ("weight", .i(shared.count)), ("via", J.strs(shared))]))
        }
    }

    let graph = J.o([
        ("meta", .o([("generated_by", .s("scripts/kb.swift")), ("companion", .s("graph_sections.json"))])),
        ("stats", .o([("documents", .i(docs.count)), ("entities", .i(entityOrder.count)),
                      ("code", .i(codeEntities.count)), ("edges", .i(edges.count))])),
        ("nodes", .a(nodes)), ("edges", .a(edges)),
    ])

    // ---- 절과 심볼 (companion) ----
    var allSections: [Section] = []
    for d in docs { allSections.append(contentsOf: d.sections) }
    let typeOf = Dictionary(uniqueKeysWithValues: docs.map { ($0.id, $0.type) })

    // 심볼 소유권. 동점이면 (rank, lineStart, id) 전체로 가른다. Swift 정렬은 안정하지 않다.
    var declaredBy: [String: (rank: Int, line: Int, sid: String)] = [:]
    var mentionedIn: [String: [String]] = [:]
    var symbolOrder: [String] = []
    for s in allSections {
        for sym in s.declared {
            if declaredBy[sym] == nil && mentionedIn[sym] == nil { symbolOrder.append(sym) }
            let rank = DECLARING_TYPE_RANK[typeOf[s.doc] ?? ""] ?? DEFAULT_TYPE_RANK
            let cand = (rank: rank, line: s.lineStart, sid: s.id)
            if let cur = declaredBy[sym] {
                if (cand.rank, cand.line, cand.sid) < (cur.rank, cur.line, cur.sid) { declaredBy[sym] = cand }
            } else { declaredBy[sym] = cand }
        }
        for sym in s.mentioned {
            if declaredBy[sym] == nil && mentionedIn[sym] == nil { symbolOrder.append(sym) }
            mentionedIn[sym, default: []].append(s.id)
        }
    }
    // 선언 형태로 안 나온 심볼은 첫 언급을 선언으로 본다. 이건 코퍼스의 결함이므로 알린다.
    var danglingSymbols: [String] = []
    for sym in symbolOrder where declaredBy[sym] == nil {
        danglingSymbols.append(sym)
        if let firstSid = mentionedIn[sym]?.first {
            if !quiet { warn("심볼 \(sym): 선언된 곳이 없습니다. 첫 언급(\(firstSid))을 선언으로 봅니다") }
            declaredBy[sym] = (rank: DEFAULT_TYPE_RANK, line: 0, sid: firstSid)
        }
    }

    var citesBySymbol: [String: [CodeCite]] = [:]
    for c in scanCites() { citesBySymbol[c.symbol, default: []].append(c) }

    var sectionNodes: [J] = [], sectionEdges: [J] = []
    var numToId: [String: String] = [:]     // "requirements#12.1" 형태의 실재 확인용
    for s in allSections { if let n = s.num { numToId[s.doc + "#" + n] = s.id } }

    for s in allSections {
        var kv: [(String, J)] = [("id", .s(s.id)), ("doc", .s(s.doc)), ("path", .s(s.path)),
                                 ("level", .i(s.level))]
        if let n = s.num { kv.append(("num", .s(n))) }
        kv.append(("heading", .s(s.heading)))
        kv.append(("line_start", .i(s.lineStart)))
        kv.append(("line_end", .i(s.lineEnd)))
        kv.append(("symbols_declared", J.strs(s.declared)))
        kv.append(("symbols_mentioned", J.strs(s.mentioned)))
        sectionNodes.append(.o(kv))

        sectionEdges.append(.o([("from", .s(s.doc)), ("to", .s(s.id)), ("relation", .s("contains"))]))
        for sym in s.declared {
            sectionEdges.append(.o([("from", .s(s.id)), ("to", .s(sym)), ("relation", .s("declares"))]))
        }
        for sym in s.mentioned {
            sectionEdges.append(.o([("from", .s(s.id)), ("to", .s(sym)), ("relation", .s("mentions"))]))
        }
        // 상호 참조. 절 색인에 없으면 버린다. 라벨이 붙은 것만 경고한다.
        var seenRefs = Set<String>()
        for r in findSectionRefs(text: s.text, selfDoc: s.doc) {
            let key = r.toDoc + "#" + r.num
            guard let target = numToId[key], target != s.id, seenRefs.insert(target).inserted else {
                if r.labelled && numToId[key] == nil && !quiet {
                    warn("kb/wiki/\(s.path) \(s.id): 없는 절을 가리킵니다: \(key)")
                }
                continue
            }
            sectionEdges.append(.o([("from", .s(s.id)), ("to", .s(target)), ("relation", .s("references"))]))
        }
    }

    var symbolNodes: [J] = []
    for sym in symbolOrder.sorted(by: { a, b in
        let (ka, kb) = (a.prefix(while: { !$0.isNumber }), b.prefix(while: { !$0.isNumber }))
        if ka != kb { return ka < kb }
        let na = Int(a.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber })) ?? 0
        let nb = Int(b.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber })) ?? 0
        return na != nb ? na < nb : a < b
    }) {
        let d = declaredBy[sym]
        var kv: [(String, J)] = [
            ("id", .s(sym)),
            ("kind", .s(String(sym.prefix(while: { !$0.isNumber && $0 != "-" })))),
            ("proposed", .b(danglingSymbols.contains(sym))),
            ("declared_in", d.map { J.s($0.sid) } ?? .null),
            ("mentioned_in", J.strs(orderedUnique(mentionedIn[sym] ?? []))),
        ]
        let cites = citesBySymbol[sym] ?? []
        kv.append(("cited_by", .a(cites.map { .o([("path", .s($0.path)), ("line", .i($0.line))]) })))
        symbolNodes.append(.o(kv))
        for c in cites {
            sectionEdges.append(.o([("from", .s(c.path)), ("to", .s(sym)), ("relation", .s("cites"))]))
        }
    }

    let sectionsJSON = J.o([
        ("meta", .o([("generated_by", .s("scripts/kb.swift")), ("companion", .s("graph.json"))])),
        ("stats", .o([("sections", .i(allSections.count)), ("symbols", .i(symbolNodes.count)),
                      ("edges", .i(sectionEdges.count))])),
        ("sections", .a(sectionNodes)), ("symbols", .a(symbolNodes)), ("edges", .a(sectionEdges)),
    ])

    // ---- 로드맵 (gitignore 대상이라 따로 둔다) ----
    var tasksJSON: J? = nil
    if let rm = readFile(ROADMAP_PATH) {
        let tasks = parseRoadmap(rm)
        let done = tasks.filter { $0.status == "done" }.count
        tasksJSON = .o([
            ("meta", .o([("generated_by", .s("scripts/kb.swift")), ("source", .s("roadmap.md"))])),
            ("stats", .o([("tasks", .i(tasks.count)), ("done", .i(done)), ("todo", .i(tasks.count - done))])),
            ("tasks", .a(tasks.map { t in
                var kv: [(String, J)] = [("id", .s(t.id)), ("status", .s(t.status)),
                                         ("milestone", .s(t.milestone)), ("module", .s(t.module)),
                                         ("title", .s(t.title))]
                if let d = t.date { kv.append(("date", .s(d))) }
                kv.append(("code_paths", J.strs(t.codePaths)))
                kv.append(("symbols", J.strs(t.symbols)))
                kv.append(("section_refs", .a(t.sectionRefs.map { .a([.s($0.0), .s($0.1)]) })))
                return .o(kv)
            })),
        ])
    }
    return (docs, graph, sectionsJSON, tasksJSON)
}

func cmdBuild() {
    let r = buildGraph()
    writeJSON(r.graph, to: GRAPH_PATH)
    writeJSON(r.sections, to: SECTIONS_PATH)
    if let t = r.tasks { writeJSON(t, to: TASKS_PATH) }
    func stat(_ j: J, _ key: String) -> String {
        guard case .o(let kv) = j, let s = kv.first(where: { $0.0 == "stats" })?.1,
              case .o(let inner) = s else { return "?" }
        return inner.map { k, v in "\(k) \(v.write())" }.joined(separator: ", ")
    }
    print("graph.json          \(stat(r.graph, "stats"))")
    print("graph_sections.json \(stat(r.sections, "stats"))")
    if let t = r.tasks { print("graph_tasks.json    \(stat(t, "stats"))") }
    else { print("graph_tasks.json    로드맵이 없습니다 (/progress init 으로 만드세요)") }
}

// MARK: - 산출물 읽기

struct Graph {
    let nodes: [[String: Any]], edges: [[String: Any]]
    func nodes(ofType t: String) -> [[String: Any]] { nodes.filter { $0["type"] as? String == t } }
    func edges(_ relation: String) -> [[String: Any]] { edges.filter { $0["relation"] as? String == relation } }
}

func loadJSONObject(_ path: String) -> [String: Any]? {
    guard let d = FileManager.default.contents(atPath: path),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
    return o
}

func loadGraph() -> Graph {
    guard let o = loadJSONObject(GRAPH_PATH) else {
        die("graph.json이 없습니다. 먼저 `swift scripts/kb.swift build`를 실행하세요")
    }
    return Graph(nodes: o["nodes"] as? [[String: Any]] ?? [], edges: o["edges"] as? [[String: Any]] ?? [])
}

struct SectionIndex {
    let sections: [[String: Any]], symbols: [[String: Any]], edges: [[String: Any]]
    var byId: [String: [String: Any]] {
        Dictionary(sections.compactMap { s in (s["id"] as? String).map { ($0, s) } }, uniquingKeysWith: { a, _ in a })
    }
}

func loadSections() -> SectionIndex {
    guard let o = loadJSONObject(SECTIONS_PATH) else {
        die("graph_sections.json이 없습니다. 먼저 `swift scripts/kb.swift build`를 실행하세요")
    }
    return SectionIndex(sections: o["sections"] as? [[String: Any]] ?? [],
                        symbols: o["symbols"] as? [[String: Any]] ?? [],
                        edges: o["edges"] as? [[String: Any]] ?? [])
}

// MARK: - 질의: 토큰화

private let LATIN_RE = Rx("[a-z][a-z0-9_+-]{2,}")
private let HANGUL_RE = Rx("[가-힣]{2,}")
// 이 코퍼스는 2초·1.5초·3.09초·500개·30MB로 빽빽하다. 사람이 실제로 그렇게 묻는다.
private let UNIT_RE = Rx("[0-9]+(?:\\.[0-9]+)?(?:초|개|분|시간|MB|KB|ms|바이트)")

let STOPWORDS: Set<String> = [
    "그리고", "하지만", "그러나", "때문", "대해", "경우", "한다", "있다", "없다", "위해",
    "무슨", "어디", "언제", "정도", "그런", "이런", "저런", "무엇", "어떤", "어떻게",
    "the", "and", "for", "that", "this", "with", "から", "what", "how", "why", "does", "are", "was",
]
// 조사를 떼어 낸 변형도 함께 찾는다. 형태소 분석기 없이 질의 쪽만 손보는 방식이다.
let JOSA1: Set<Character> = ["은", "는", "이", "가", "을", "를", "의", "에", "와", "과", "로", "도", "만", "서"]
let JOSA2: Set<String> = ["으로", "에서", "에게", "부터", "까지", "마다", "보다", "처럼", "이나", "라는"]

struct Token { let text: String; let weight: Double }

func tokenize(_ text: String) -> [Token] {
    let lower = text.lowercased()
    var raw: [String] = []
    raw += LATIN_RE.all(lower).map { $0[0] }
    raw += HANGUL_RE.all(text).map { $0[0] }
    raw += UNIT_RE.all(text).map { $0[0] }
    var out: [Token] = [], seen = Set<String>()
    for t in raw where !STOPWORDS.contains(t) {
        if seen.insert(t).inserted { out.append(Token(text: t, weight: 1.0)) }
        // 조사를 뗀 변형. "변환으로" → "변환", "파일이" → "파일"
        guard t.count >= 3, HANGUL_RE.matches(t) else { continue }
        if t.count >= 4, JOSA2.contains(String(t.suffix(2))) {
            let s = String(t.dropLast(2))
            if s.count >= 2, !STOPWORDS.contains(s), seen.insert(s).inserted {
                out.append(Token(text: s, weight: 0.6))
            }
        }
        if let last = t.last, JOSA1.contains(last) {
            let s = String(t.dropLast())
            if s.count >= 2, !STOPWORDS.contains(s), seen.insert(s).inserted {
                out.append(Token(text: s, weight: 0.6))
            }
        }
    }
    return out
}

// MARK: - 질의: 점수

struct Hit { let id: String; var score: Double }

func runQuery(_ question: String, k: Int) -> (hits: [Hit], index: SectionIndex, graph: Graph, docText: [String: [String]]) {
    let index = loadSections()
    let graph = loadGraph()
    let byId = index.byId

    // 절 본문을 파일에서 잘라 온다. 색인은 줄 번호만 갖고 있다.
    var fileLines: [String: [String]] = [:]
    var bodyOf: [String: String] = [:]
    for s in index.sections {
        guard let id = s["id"] as? String, let path = s["path"] as? String,
              let a = s["line_start"] as? Int, let b = s["line_end"] as? Int else { continue }
        if fileLines[path] == nil { fileLines[path] = splitLines(readFile(WIKI_DIR + "/" + path) ?? "") }
        let ls = fileLines[path]!
        guard a >= 1, a <= ls.count else { continue }
        bodyOf[id] = ls[(a - 1)..<min(b, ls.count)].joined(separator: "\n")
    }

    let tokens = tokenize(question)
    let n = max(index.sections.count, 1)
    var scores: [String: Double] = [:]

    // 길이 정규화(BM25)를 쓴다. 안 쓰면 16행짜리 시나리오 표가 "exFAT은 왜 안 되나"의
    // 1위가 된다. 같은 단어를 여섯 번 담아서다. 짧고 정확한 절이 이겨야 한다.
    let lowered = bodyOf.mapValues { $0.lowercased() }
    let lengths = bodyOf.mapValues { Double($0.count) }
    let avgLen = max(lengths.values.reduce(0, +) / Double(max(lengths.count, 1)), 1)
    let k1 = 1.5, b = 0.6

    for t in tokens {
        var df = 0
        for (_, body) in lowered where body.contains(t.text) { df += 1 }
        guard df > 0 else { continue }
        let idf = log(1.0 + Double(n) / Double(df))
        for s in index.sections {
            guard let id = s["id"] as? String, let body = lowered[id] else { continue }
            let f = Double(occurrences(of: t.text, in: body))
            if f > 0 {
                let norm = 1 - b + b * ((lengths[id] ?? avgLen) / avgLen)
                scores[id, default: 0] += t.weight * idf * (f * (k1 + 1)) / (f + k1 * norm)
            }
            if let h = s["heading"] as? String, h.lowercased().contains(t.text) {
                scores[id, default: 0] += t.weight * 4.0 * idf
            }
        }
    }

    // 질의에 심볼이 있으면 선언 절을 크게 올린다.
    let qsyms = Set(symbolsIn(question.uppercased()))
    if !qsyms.isEmpty {
        for s in index.sections {
            guard let id = s["id"] as? String else { continue }
            let dec = Set(s["symbols_declared"] as? [String] ?? [])
            let men = Set(s["symbols_mentioned"] as? [String] ?? [])
            if !dec.intersection(qsyms).isEmpty { scores[id, default: 0] += 25 }
            else if !men.intersection(qsyms).isEmpty { scores[id, default: 0] += 6 }
        }
    }

    // 엔티티 이름·정의가 걸리면 그 이름을 담은 절을 올린다.
    let ql = question.lowercased()
    for e in graph.nodes(ofType: "entity") {
        guard let name = e["id"] as? String else { continue }
        let surfaces = orderedUnique([name.lowercased(), name.replacingOccurrences(of: "-", with: " ").lowercased()])
        var relevant = surfaces.contains { ql.contains($0) }
        if !relevant, let def = e["definition"] as? String {
            relevant = tokens.contains { $0.weight == 1.0 && def.lowercased().contains($0.text) }
        }
        guard relevant else { continue }
        for (id, body) in bodyOf where surfaces.contains(where: { body.lowercased().contains($0) }) {
            scores[id, default: 0] += 5
        }
    }

    // 한 홉 확장. 문서를 가로지르는 답이 여기서 나온다.
    var declaresSection: [String: String] = [:]
    for sym in index.symbols {
        if let id = sym["id"] as? String, let d = sym["declared_in"] as? String { declaresSection[id] = d }
    }
    var refsFrom: [String: [String]] = [:]
    for e in index.edges where e["relation"] as? String == "references" {
        if let f = e["from"] as? String, let t = e["to"] as? String { refsFrom[f, default: []].append(t) }
    }
    let seeds = scores.sorted { ($0.value, $0.key) > ($1.value, $1.key) }.prefix(12)
    var bonus: [String: Double] = [:]
    for (sid, sc) in seeds {
        guard let s = byId[sid] else { continue }
        // 씨앗 하나가 같은 대상에 여러 번 더하지 못하게 막는다. 안 그러면 T1~T16을 전부
        // 선언하는 시나리오 표가 T를 언급하는 모든 절에서 0.4배를 열여섯 번 받아,
        // 무슨 질문을 하든 1위가 된다.
        var targets: [String: Double] = [:]
        for sym in (s["symbols_mentioned"] as? [String] ?? []) {
            if let t = declaresSection[sym], t != sid { targets[t] = max(targets[t] ?? 0, sc * 0.4) }
        }
        for t in refsFrom[sid] ?? [] where t != sid { targets[t] = max(targets[t] ?? 0, sc * 0.35) }
        for (t, v) in targets { bonus[t, default: 0] += v }
    }
    for (id, b) in bonus { scores[id, default: 0] += b }

    // 제목만 있고 본문이 없는 절은 읽을 것이 없다. 하위 절을 거느린 상위 절이 여기 해당한다.
    let hasBody = Set(bodyOf.filter { _, body in
        splitLines(body).dropFirst().contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }.keys)

    let hits = scores.filter { $0.value > 0 && hasBody.contains($0.key) }
        .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        .prefix(k).map { Hit(id: $0.key, score: $0.value) }
    return (Array(hits), index, graph, fileLines)
}

func cmdQuery(_ args: [String]) {
    var question = "", k = 8, asJSON = false
    var i = 0
    while i < args.count {
        switch args[i] {
        case "-k", "--top": i += 1; k = i < args.count ? (Int(args[i]) ?? 8) : 8
        case "--json": asJSON = true
        default: if question.isEmpty { question = args[i] } else { question += " " + args[i] }
        }
        i += 1
    }
    guard !question.isEmpty else { die("사용법: swift scripts/kb.swift query \"질문\" [-k 8] [--json]", 2) }

    let (hits, index, graph, _) = runQuery(question, k: k)
    let byId = index.byId
    guard !hits.isEmpty else {
        print("# 걸리는 절이 없습니다. kb/wiki/index.md에서 직접 찾아보세요.")
        return
    }
    let docs = orderedUnique(hits.compactMap { byId[$0.id]?["doc"] as? String })

    if asJSON {
        let secs: [J] = hits.map { h in
            let s = byId[h.id] ?? [:]
            return .o([("id", .s(h.id)), ("doc", .s(s["doc"] as? String ?? "")),
                       ("path", .s(s["path"] as? String ?? "")),
                       ("line_start", .i(s["line_start"] as? Int ?? 0)),
                       ("line_end", .i(s["line_end"] as? Int ?? 0)),
                       ("heading", .s(s["heading"] as? String ?? "")),
                       ("score", .d(h.score))])
        }
        print(J.o([("question", .s(question)), ("sections", .a(secs))]).write())
        return
    }

    print("# \(hits.count)개 절, 문서 \(docs.count)개\n")
    for h in hits {
        guard let s = byId[h.id] else { continue }
        let path = s["path"] as? String ?? "", a = s["line_start"] as? Int ?? 0, b = s["line_end"] as? Int ?? 0
        print(String(format: "kb/wiki/%@:%d-%d  [%.1f]  %@", path, a, b, h.score, h.id))
        print("    " + (s["heading"] as? String ?? ""))
        let dec = s["symbols_declared"] as? [String] ?? []
        if !dec.isEmpty { print("    선언: " + dec.joined(separator: ", ")) }
    }

    // 연결 엣지: 관계가 곧 연결 논리다.
    var lines: [String] = []
    for e in graph.edges {
        guard let f = e["from"] as? String, let t = e["to"] as? String,
              let r = e["relation"] as? String, docs.contains(f), docs.contains(t) else { continue }
        guard ["derives_from", "relates_to", "co_entity", "reviews"].contains(r) else { continue }
        var s = "  \(f) --\(r)--> \(t)"
        if let note = e["note"] as? String { s += "\n      " + note }
        else if let via = e["via"] as? [String] { s += "\n      공유 엔티티: " + via.joined(separator: ", ") }
        lines.append(s)
    }
    if !lines.isEmpty { print("\n# 연결 엣지"); lines.forEach { print($0) } }

    // 이 심볼을 인용하는 코드. cites 엣지의 값이 여기서 나온다.
    var syms = orderedUnique(hits.flatMap { (byId[$0.id]?["symbols_declared"] as? [String] ?? []) })
    if syms.isEmpty { syms = orderedUnique(symbolsIn(question.uppercased())) }
    var codeLines: [String] = []
    for sym in index.symbols {
        guard let id = sym["id"] as? String, syms.contains(id) else { continue }
        let cites = (sym["cited_by"] as? [[String: Any]] ?? []).compactMap { c -> String? in
            guard let p = c["path"] as? String, let l = c["line"] as? Int else { return nil }
            return "\(p):\(l)"
        }
        if !cites.isEmpty { codeLines.append("  \(id)  " + cites.prefix(5).joined(separator: ", ")) }
    }
    if !codeLines.isEmpty { print("\n# 이 심볼을 인용하는 코드"); codeLines.forEach { print($0) } }

    // 범위 안의 엔티티 정의
    var defLines: [String] = []
    var definedByDoc: [String: [String]] = [:]
    for e in graph.edges("defines") {
        if let f = e["from"] as? String, let t = e["to"] as? String { definedByDoc[f, default: []].append(t) }
    }
    let inScope = Set(docs.flatMap { definedByDoc[$0] ?? [] })
    for e in graph.nodes(ofType: "entity") {
        guard let id = e["id"] as? String, inScope.contains(id),
              let def = e["definition"] as? String else { continue }
        if tokens(from: question).contains(where: { def.contains($0) || id.contains($0) }) || hits.count <= 3 {
            defLines.append("  \(id): \(def)")
        }
    }
    if !defLines.isEmpty { print("\n# 범위 안의 엔티티 정의"); defLines.prefix(6).forEach { print($0) } }
}

private func tokens(from q: String) -> [String] { tokenize(q).map { $0.text } }

// MARK: - 영향 분석

/// git diff를 한 번만 부른다. 원본 파이썬은 같은 diff를 두 번 불렀다.
func gitDiff(_ path: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["diff", "HEAD", "--", path]
    p.currentDirectoryURL = URL(fileURLWithPath: PROJECT_ROOT)
    let out = Pipe(), err = Pipe()
    p.standardOutput = out; p.standardError = err
    do { try p.run() } catch { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

private let DIFF_HEAD_RE = Rx("^[+-](#{1,3}[ \t]+.+)$")
private let HUNK_RE = Rx("^@@ -[0-9]+(?:,[0-9]+)? \\+([0-9]+)")
private let HEAD_NUM_RE = Rx("^#{1,3}[ \t]+([0-9]+(?:\\.[0-9]+)*[a-z]?)[.:]?[ \t]")
private let HEAD_SYM_RE = Rx("^#{1,3}[ \t]+((?:FR|NFR|T)-?[0-9]{1,2}[a-z]?)[.:]")

/// git diff 한 번을 훑어 바뀐 새-파일 줄 번호와 추가·삭제된 제목을 낸다.
/// cmdImpact와 cmdSync가 같은 답을 봐야 해서 함수로 뺐다. 둘이 각자 diff를 해석하면
/// "바뀐 절"과 "번역할 절"이 한쪽만 고쳤을 때 조용히 어긋난다.
struct DocDiff {
    let touchedLines: Set<Int>
    let addedHeads: Set<String>
    let removedHeads: Set<String>
    var isEmpty: Bool { touchedLines.isEmpty && addedHeads.isEmpty && removedHeads.isEmpty }
    /// 제목이 생기거나 사라졌는가. 절 단위 대응이 무너지는 경우다.
    var structural: Bool { !addedHeads.symmetricDifference(removedHeads).isEmpty }
}

func scanDocDiff(_ rel: String) -> DocDiff {
    var added = Set<String>(), removed = Set<String>()
    var touchedLines = Set<Int>()
    var newLine = 0
    for line in splitLines(gitDiff(rel)) {
        if let c = HUNK_RE.first(line) { newLine = Int(c[1]) ?? 0; continue }
        guard !line.hasPrefix("+++"), !line.hasPrefix("---") else { continue }
        if line.hasPrefix("+") {
            if let c = DIFF_HEAD_RE.first(line) { added.insert(c[1]) }
            touchedLines.insert(newLine)
            newLine += 1
        } else if line.hasPrefix("-") {
            if let c = DIFF_HEAD_RE.first(line) { removed.insert(c[1]) }
            // 지워진 줄은 새 파일에 없다. 그 자리를 바뀐 것으로 본다.
            touchedLines.insert(newLine)
        } else if newLine > 0 {
            newLine += 1
        }
    }
    return DocDiff(touchedLines: touchedLines, addedHeads: added, removedHeads: removed)
}

func cmdImpact(_ rawPath: String) {
    var rel = relPath(rawPath.hasPrefix("/") ? rawPath : PROJECT_ROOT + "/" + rawPath, from: PROJECT_ROOT)
    if rel.hasPrefix("./") { rel = String(rel.dropFirst(2)) }
    // 장치(index.md·log.md)는 문서가 아니다. 예전에는 문서 노드를 못 찾아 우연히 돌아갔을 뿐이다.
    guard let f = wikiFile(repoRel: rel), f.role != .apparatus else { return }

    let graph = loadGraph()
    let wikiRel = f.wikiRel
    guard let node = graph.nodes(ofType: "document").first(where: { ($0["path"] as? String) == wikiRel }),
          let docId = node["id"] as? String else { return }

    let dd = scanDocDiff(rel)
    let added = dd.addedHeads, removed = dd.removedHeads
    let touchedLines = dd.touchedLines
    let structural = dd.structural

    // 바뀐 줄이 어느 절에 떨어지는지 본다. 제목이 바뀐 것만 보면 본문만 고친 편집을 놓친다.
    let index = loadSections()
    var changedIds: [String] = [], changedNums = Set<String>(), changedSyms = Set<String>()
    for s in index.sections {
        guard let sid = s["id"] as? String, sid.hasPrefix(docId + "#"),
              let a = s["line_start"] as? Int, let b = s["line_end"] as? Int,
              touchedLines.contains(where: { $0 >= a && $0 <= b }) else { continue }
        changedIds.append(sid)
        if let n = s["num"] as? String { changedNums.insert(n) }
        changedSyms.formUnion(s["symbols_declared"] as? [String] ?? [])
    }
    // 제목 자체가 생기거나 사라졌으면 줄 매핑으로는 못 잡으므로 따로 더한다.
    for h in added.union(removed) {
        if let c = HEAD_SYM_RE.first(h) { changedSyms.insert(c[1]) }
        if let c = HEAD_NUM_RE.first(h) { changedNums.insert(c[1]) }
    }
    let changed = changedIds.sorted()

    // 하위 문서: 나를 parents로 가리키는 쪽
    var downstream: [J] = []
    for e in graph.edges("derives_from") where (e["to"] as? String) == docId {
        guard let from = e["from"] as? String else { continue }
        let path = graph.nodes(ofType: "document").first { ($0["id"] as? String) == from }?["path"] as? String ?? ""
        downstream.append(.o([("doc_id", .s(from)), ("path", .s(path)),
                              ("referenced_sections", J.strs(e["sections"] as? [String] ?? []))]))
    }

    // 코드: defines ⋈ implements. 단, 이 문서가 정의한 엔티티 중 **바뀐 절의 본문에
    // 실제로 등장하는** 것만 남긴다. 그러지 않으면 requirements를 한 글자만 고쳐도
    // 그것이 정의한 스무 개 엔티티의 구현 파일이 전부 나와서 아무 정보가 되지 못한다.
    var myEntities = Set<String>()
    for e in graph.edges("defines") where (e["from"] as? String) == docId {
        if let t = e["to"] as? String { myEntities.insert(t) }
    }
    var changedText = ""
    if let fileText = readFile(PROJECT_ROOT + "/" + rel) {
        let ls = splitLines(fileText)
        for n in touchedLines.sorted() where n >= 1 && n <= ls.count { changedText += ls[n - 1] + "\n" }
    }
    let changedLower = changedText.lowercased()
    var relevantEntities = Set<String>()
    for name in myEntities {
        let surfaces = [name.lowercased(), name.replacingOccurrences(of: "-", with: " ").lowercased()]
        if surfaces.contains(where: { changedLower.contains($0) }) { relevantEntities.insert(name) }
    }
    var codeImpacts: [J] = []
    for e in graph.edges("implements") {
        guard let ent = e["to"] as? String, relevantEntities.contains(ent),
              let p = e["from"] as? String else { continue }
        codeImpacts.append(.o([("path", .s(p)), ("entity", .s(ent))]))
    }

    // 심볼: 바뀐 절이 선언한 심볼과 그것을 인용하는 코드. 가장 실용적인 출력이다.
    var symbolImpacts: [J] = []
    for sym in index.symbols {
        guard let id = sym["id"] as? String, let dec = sym["declared_in"] as? String,
              dec.hasPrefix(docId + "#") else { continue }
        let num = String(dec.dropFirst(docId.count + 1))
        let touched = changedSyms.contains(id)
            || changedNums.contains(where: { num == $0 || num.hasPrefix($0 + ".") || $0.hasPrefix(num + ".") })
        guard touched else { continue }
        let cites = orderedUnique((sym["cited_by"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String })
        symbolImpacts.append(.o([("symbol", .s(id)), ("declared_in", .s(dec)), ("cited_by", J.strs(cites))]))
    }

    // 로드맵: 태스크가 인용한 절·심볼이 겹치는지. 공유 코드 경로만으로는 걸지 않는다.
    var roadmapImpacts: [J] = []
    if let o = loadJSONObject(TASKS_PATH), let tasks = o["tasks"] as? [[String: Any]] {
        for t in tasks {
            var refs: [String] = []
            for pair in (t["section_refs"] as? [[String]] ?? []) where pair.count == 2 && pair[0] == docId {
                if changedNums.contains(where: { pair[1] == $0 || pair[1].hasPrefix($0 + ".") || $0.hasPrefix(pair[1] + ".") }) {
                    refs.append(pair[1])
                }
            }
            for s in (t["symbols"] as? [String] ?? []) where changedSyms.contains(s) { refs.append(s) }
            guard !refs.isEmpty else { continue }
            roadmapImpacts.append(.o([("task_id", .s(t["id"] as? String ?? "")),
                                      ("references", J.strs(orderedUnique(refs))),
                                      ("code", J.strs(t["code_paths"] as? [String] ?? [])),
                                      ("status", .s((t["status"] as? String ?? "").uppercased()))]))
        }
    }

    writeJSON(.o([
        ("trigger_doc_id", .s(docId)), ("trigger_file", .s(rel)),
        ("changed_sections", J.strs(changed)), ("structural_change", .b(structural)),
        ("downstream_impacts", .a(downstream)), ("code_impacts", .a(codeImpacts)),
        ("symbol_impacts", .a(symbolImpacts)), ("roadmap_impacts", .a(roadmapImpacts)),
    ]), to: IMPACT_PATH)

    print("doc-impact: \(docId) → 하위 문서 \(downstream.count)개, 코드 \(codeImpacts.count)개, "
        + "심볼 \(symbolImpacts.count)개, 로드맵 \(roadmapImpacts.count)개")
}

// MARK: - 번역 지시서

/// 매니페스트를 조립한다. I/O와 떼어 놓아야 selftest가 모양을 고정할 수 있다.
func syncManifest(source: String, sourceVersion: String,
                  target: String, targetExists: Bool, targetVersion: String,
                  mode: String, structural: Bool,
                  preambleChanged: Bool, preambleLines: [Int],
                  sections: [(num: String, heading: String, start: Int, end: Int)]) -> J {
    .o([
        ("source", .s(source)), ("source_version", .s(sourceVersion)),
        ("target", .s(target)), ("target_exists", .b(targetExists)),
        ("target_version", .s(targetVersion)),
        ("mode", .s(mode)), ("structural_change", .b(structural)),
        ("preamble_changed", .b(preambleChanged)),
        ("preamble_lines", .a(preambleLines.map { J.i($0) })),
        ("changed_sections", .a(sections.map { s in
            J.o([("num", .s(s.num)), ("heading", .s(s.heading)),
                 ("source_lines", .a([.i(s.start), .i(s.end)]))])
        })),
    ])
}

/// 정본이 바뀌었을 때 무엇을 번역해야 하는지 적어 둔다.
///
/// 그래프를 읽지 않는다. 정본은 색인 대상이 아니므로 절의 줄 범위를 정본에서 직접 뜬다.
/// 대상 파일의 줄 번호는 넣지 않는다. 번역본은 정본과 줄이 어긋나 있고, 낡은 줄 번호를
/// 가리키는 것은 아무것도 안 가리키는 것보다 나쁘다. 대신 절 번호를 준다.
///
/// 시작할 때 기존 매니페스트를 무조건 지운다. 그래야 낡은 지시서로 엉뚱한 절을 번역하는
/// 사고가 원천적으로 없다. k_teacher는 이 삭제를 에이전트의 책임으로 뒀는데 미덥지 않다.
func cmdSync(_ rawPath: String) {
    try? FileManager.default.removeItem(atPath: SYNC_PATH)

    var rel = relPath(rawPath.hasPrefix("/") ? rawPath : PROJECT_ROOT + "/" + rawPath, from: PROJECT_ROOT)
    if rel.hasPrefix("./") { rel = String(rel.dropFirst(2)) }
    guard let f = wikiFile(repoRel: rel), f.role == .canonical else { return }

    let abs = PROJECT_ROOT + "/" + rel
    guard let text = readFile(abs) else { return }
    let (fm, bodyStart) = parseFrontmatter(text: text, origin: rel)
    let sourceVersion = fm?.str("version") ?? ""

    let targetWiki = translationPath(ofCanonical: f.wikiRel)
    let targetRel = "kb/wiki/" + targetWiki
    let targetAbs = WIKI_DIR + "/" + targetWiki
    let exists = FileManager.default.fileExists(atPath: targetAbs)
    var targetVersion = ""
    if exists, let t = readFile(targetAbs) {
        targetVersion = parseFrontmatter(text: t, origin: targetRel).0?.str("version") ?? ""
    }

    let secs = parseSections(text: text, docId: fm?.str("id") ?? "x", path: f.wikiRel, bodyStart: bodyStart)

    // 번역본이 없으면 전체를 번역해야 하므로 diff를 볼 것도 없다.
    if !exists {
        writeJSON(syncManifest(source: rel, sourceVersion: sourceVersion,
                               target: targetRel, targetExists: false, targetVersion: "",
                               mode: "create", structural: false,
                               preambleChanged: true, preambleLines: [],
                               sections: secs.compactMap { s in
                                   s.num.map { (num: $0, heading: s.heading, start: s.lineStart, end: s.lineEnd) }
                               }), to: SYNC_PATH)
        print("doc-sync: \(f.wikiRel) → 번역본을 새로 만들어야 합니다 (\(secs.count)개 절)")
        return
    }

    let dd = scanDocDiff(rel)
    guard !dd.isEmpty else { return }

    var changed: [(num: String, heading: String, start: Int, end: Int)] = []
    for s in secs {
        guard let n = s.num,
              dd.touchedLines.contains(where: { $0 >= s.lineStart && $0 <= s.lineEnd }) else { continue }
        changed.append((num: n, heading: s.heading, start: s.lineStart, end: s.lineEnd))
    }

    // parseSections는 bodyStart부터 첫 ## 까지의 머리말을 어느 절에도 넣지 않는다.
    // 그래서 머리말만 고치면 changed_sections가 비어 번역할 것이 없다고 나온다.
    let firstSectionLine = secs.first?.lineStart ?? Int.max
    let preambleTouched = dd.touchedLines.filter { $0 < firstSectionLine }.sorted()
    let preambleChanged = !preambleTouched.isEmpty

    guard !changed.isEmpty || preambleChanged || dd.structural else { return }

    // 구조가 바뀌면 절 단위 대응이 무너진다. 자동으로 진행하지 않고 사용자에게 묻는다.
    let mode = dd.structural ? "full" : "sections"
    writeJSON(syncManifest(source: rel, sourceVersion: sourceVersion,
                           target: targetRel, targetExists: true, targetVersion: targetVersion,
                           mode: mode, structural: dd.structural,
                           preambleChanged: preambleChanged,
                           preambleLines: preambleTouched.isEmpty ? [] : [preambleTouched.first!, preambleTouched.last!],
                           sections: changed), to: SYNC_PATH)
    print("doc-sync: \(f.wikiRel) → \(mode), 절 \(changed.count)개"
        + (preambleChanged ? ", 머리말 포함" : ""))
}

// MARK: - 검사

func cmdCheck() -> Never {
    let r = buildGraph(quiet: true)
    var problems: [String] = []
    let docIds = Set(r.docs.map { $0.id })
    guard !r.docs.isEmpty else { die("kb/wiki에 문서가 없습니다") }

    for d in r.docs {
        for m in d.parents where !(docIds.contains(m.str("id") ?? "")) {
            problems.append("kb/wiki/\(d.path): parents가 없는 문서를 가리킵니다: \(m.str("id") ?? "?")")
        }
        for e in d.entities {
            for p in e.strs("code") where !FileManager.default.fileExists(atPath: PROJECT_ROOT + "/" + p) {
                problems.append("kb/wiki/\(d.path): 엔티티 `\(e.str("name") ?? "?")`의 code 경로가 없습니다: \(p)")
            }
        }
        // 번호 없는 제목은 슬러그로 id가 만들어져 언어에 묶인다. 그러면 정본과 번역본을
        // 번호로 짝지을 수 없다. 매니페스트의 지목, 질의 붙이기, 구조 대조가 전부 번호에 걸려 있다.
        for s in d.sections where s.num == nil {
            problems.append("kb/wiki/\(d.path) \(s.id): 번호 없는 제목이라 짝을 지을 수 없습니다: \(s.heading)")
        }
    }

    // 선언된 곳이 없는 심볼. 첫 빌드에서 requirements의 FR-14가 걸린다.
    var declared = Set<String>(), mentioned: [String: String] = [:]
    var numToId = Set<String>()
    for d in r.docs {
        for s in d.sections {
            declared.formUnion(s.declared)
            for m in s.mentioned where mentioned[m] == nil { mentioned[m] = s.id }
            if let n = s.num { numToId.insert(d.id + "#" + n) }
        }
    }
    for (sym, where_) in mentioned.sorted(by: { $0.key < $1.key }) where !declared.contains(sym) {
        problems.append("심볼 \(sym): 선언된 곳이 없습니다 (\(where_)에서 언급)")
    }

    // 라벨이 붙은 상호 참조는 반드시 풀려야 한다.
    for d in r.docs {
        for s in d.sections {
            for ref in findSectionRefs(text: s.text, selfDoc: s.doc) where ref.labelled {
                let key = ref.toDoc + "#" + ref.num
                if !numToId.contains(key) {
                    problems.append("kb/wiki/\(d.path) \(s.id): 없는 절을 가리킵니다: \(key)")
                }
            }
        }
    }

    // 정본과 번역본의 짝. 클로드가 번역본을 읽으므로 번역이 밀리면 낡은 지식을 읽게 된다.
    // 그것을 알아채는 자리가 여기뿐이라 경고가 아니라 오류로 올린다.
    for p in loadWikiPairs() {
        if p.canonical.isEmpty {
            problems.append("kb/wiki/\(p.translation): 정본이 없는 번역본입니다")
            continue
        }
        guard !p.translation.isEmpty else {
            problems.append("kb/wiki/\(p.canonical): 영어 번역본이 없습니다 (\(translationPath(ofCanonical: p.canonical)))")
            continue
        }
        let cv = p.canonicalFM?.str("version") ?? ""
        let tv = p.translationFM?.str("version") ?? ""
        switch translationStatus(sourceVersion: tv, canonicalVersion: cv) {
        case "stale":
            problems.append("kb/wiki/\(p.translation): 번역이 v\(tv)에 머물러 있습니다. 정본은 v\(cv)입니다")
        case "unknown":
            problems.append("kb/wiki/\(p.translation): version을 읽을 수 없습니다 (정본 \"\(cv)\", 번역본 \"\(tv)\")")
        default: break
        }
        // 번호 집합이 어긋나면 번역 지시서의 절 지목과 질의 붙이기가 조용히 깨진다.
        let cs = Set(p.canonicalNums), ts = Set(p.translationNums)
        for n in cs.subtracting(ts).sorted() {
            problems.append("kb/wiki/\(p.translation): 번역본에 없는 절입니다: \(n)")
        }
        for n in ts.subtracting(cs).sorted() {
            problems.append("kb/wiki/\(p.translation): 정본에 없는 절입니다: \(n)")
        }
        if let c = p.canonicalFM, let t = p.translationFM {
            for m in frontmatterMismatches(canonical: c, translation: t) {
                problems.append("kb/wiki/\(p.translation): frontmatter가 정본과 다릅니다 — \(m)")
            }
        }
    }

    if problems.isEmpty { print("✅ 끊긴 참조 없음 (문서 \(r.docs.count)개)"); exit(0) }
    for p in orderedUnique(problems) { print("❌ " + p) }
    print("\n\(orderedUnique(problems).count)건")
    exit(1)
}

// MARK: - 버전 올리기

private let FM_VERSION_RE = Rx("^version:[ \t]*\"?([0-9]+)\\.([0-9]+)\"?[ \t]*$")

/// frontmatter의 version만 올린다. 본문에는 버전 줄이 없고, 만들지도 않는다.
/// parents[].version은 들여쓰여 있어서 열 0 앵커에 걸리지 않는다.
///
/// 정본에만 돈다. 버전의 주인은 정본 하나다. 번역본의 version은 번역할 때 정본의 값을
/// 베껴 적으므로, 번역이 밀리면 두 값이 어긋나고 그것이 cmdCheck의 신선도 판정 근거가 된다.
/// 번역본이 스스로 올리면 그 어긋남이 가려진다.
func cmdBump(_ rawPath: String) {
    var rel = relPath(rawPath.hasPrefix("/") ? rawPath : PROJECT_ROOT + "/" + rawPath, from: PROJECT_ROOT)
    if rel.hasPrefix("./") { rel = String(rel.dropFirst(2)) }
    guard wikiFile(repoRel: rel)?.role == .canonical else { return }
    let abs = PROJECT_ROOT + "/" + rel
    guard let text = readFile(abs) else { return }
    let (fm, bodyStart) = parseFrontmatter(text: text, origin: rel)
    guard fm != nil else { return }

    // 본문이 바뀌었을 때만 올린다. 그러지 않으면 이관만으로도 버전이 부풀어 오른다.
    let diff = gitDiff(rel)
    guard !diff.isEmpty else { return }
    var bodyChanged = false
    var hunkNew = 0, inHunk = false
    for line in splitLines(diff) {
        if line.hasPrefix("@@") {
            inHunk = true
            if let c = Rx("^@@ -[0-9]+(?:,[0-9]+)? \\+([0-9]+)").first(line) { hunkNew = Int(c[1]) ?? 0 }
            continue
        }
        guard inHunk else { continue }
        if line.hasPrefix("+") && !line.hasPrefix("+++") {
            if hunkNew >= bodyStart { bodyChanged = true; break }
            hunkNew += 1
        } else if line.hasPrefix("-") && !line.hasPrefix("---") {
            if hunkNew >= bodyStart { bodyChanged = true; break }
        } else { hunkNew += 1 }
    }
    guard bodyChanged else { return }

    var lines = splitLines(text)
    var bumped: String? = nil
    for i in lines.indices where i < bodyStart {
        if let c = FM_VERSION_RE.first(lines[i]), let minor = Int(c[2]) {
            let v = "\(c[1]).\(minor + 1)"
            lines[i] = "version: \"\(v)\""
            bumped = v
        } else if lines[i].hasPrefix("date:") {
            lines[i] = "date: \"\(TODAY)\""
        }
    }
    guard let v = bumped else { return }
    try? (lines.joined(separator: "\n") + "\n").write(toFile: abs, atomically: true, encoding: .utf8)
    print("doc-version: \(rel) → v\(v) (\(TODAY))")
}

// MARK: - 훅

/// 훅 payload를 stdin으로 받아 파일의 역할에 따라 갈라진다. jq는 쓰지 않는다.
///
/// 정본이 바뀌면 버전을 올리고 번역 지시서를 낸다. 그래프와 영향 분석은 건드리지 않는다.
/// 번역본이 바뀌면 그래프를 다시 만들고 영향을 분석한다. 버전은 건드리지 않는다.
///
/// 이 분기가 연쇄를 없앤다. 정본 편집은 영향 보고를 내지 않고, 그 뒤에 클로드가 번역본을
/// 고치면 그때 보고가 한 번만 나온다. k_teacher는 파생본이 그래프 문서라서 훅이 반드시 두 번
/// 돌고 두 번째를 휴리스틱으로 무시하는데, 여기서는 역할 하나로 그 문제가 사라진다.
///
/// 순서는 여전히 중요하다. 버전 범프는 그래프가 frontmatter를 읽기 전에 끝나야 하고,
/// 영향 분석은 다시 만들어진 그래프를 읽어야 한다.
func cmdHook() {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
    var path = ""
    if let ti = o["tool_input"] as? [String: Any], let p = ti["file_path"] as? String { path = p }
    if path.isEmpty, let tr = o["tool_response"] as? [String: Any], let p = tr["filePath"] as? String { path = p }
    guard !path.isEmpty else { return }

    var rel = relPath(path.hasPrefix("/") ? path : PROJECT_ROOT + "/" + path, from: PROJECT_ROOT)
    if rel.hasPrefix("./") { rel = String(rel.dropFirst(2)) }

    func rebuild() {
        let r = buildGraph(quiet: true)
        writeJSON(r.graph, to: GRAPH_PATH)
        writeJSON(r.sections, to: SECTIONS_PATH)
        if let t = r.tasks { writeJSON(t, to: TASKS_PATH) }
    }

    if let f = wikiFile(repoRel: rel) {
        switch f.role {
        case .apparatus:
            return
        case .canonical:
            cmdBump(rel)
            // bump 뒤여야 한다. 매니페스트의 source_version은 올라간 새 버전이어야 하고,
            // 클로드가 번역을 마치고 번역본에 그 값을 적으면 신선도가 맞아떨어진다.
            cmdSync(rel)
            // 번역본이 아직 없으면 이 정본이 색인 대상이다(loadDocs의 폴백). 그때는 예전처럼
            // 그래프와 영향을 여기서 돌려야 한다. 번역본이 생기면 그 일은 번역본 쪽으로 넘어간다.
            let tAbs = WIKI_DIR + "/" + translationPath(ofCanonical: f.wikiRel)
            if FileManager.default.fileExists(atPath: tAbs) { return }
            rebuild()
            cmdImpact(rel)
        case .translation:
            rebuild()
            cmdImpact(rel)
        }
        return
    }

    guard rel.hasSuffix(".swift"), CITE_ROOTS.contains(where: { rel.hasPrefix($0 + "/") }) else { return }
    rebuild()
}

// MARK: - 자체 검사

func cmdSelftest() -> Never {
    var pass = 0, fail = 0
    func check(_ name: String, _ got: String, _ want: String) {
        if got == want { pass += 1; print("✅ \(name)") }
        else { fail += 1; print("❌ \(name)\n     받음: \(got)\n     기대: \(want)") }
    }

    // 1. 프론트매터
    let fmSrc = """
    id: sample
    title: "제목: 쉼표, 있음"
    version: 1.0
    type: requirements
    parents:
      - id: other
        version: "2.1"
        sections: ["12.1", "FR-3"]
        note: "쉼표, 가 든 한국어"
    entities:
      - name: alpha
        type: component
        code:
          - App/A.swift
          - App/B.swift
      - name: beta
        type: concept
    tags: [a, b, c]
    trailing: bare value # 주석
    """
    let fm = parseFrontmatterLines(splitLines(fmSrc), origin: "selftest")
    check("프론트매터: 스칼라", fm?.str("id") ?? "nil", "sample")
    check("프론트매터: 따옴표 안 쉼표", fm?.str("title") ?? "nil", "제목: 쉼표, 있음")
    check("프론트매터: 숫자를 문자열로", fm?.str("version") ?? "nil", "1.0")
    check("프론트매터: flow 리스트", (fm?.strs("tags") ?? []).joined(separator: "|"), "a|b|c")
    check("프론트매터: 줄 끝 주석", fm?.str("trailing") ?? "nil", "bare value")
    let parents = fm?.maps("parents") ?? []
    check("프론트매터: parents 개수", String(parents.count), "1")
    check("프론트매터: parents.sections", (parents.first?.strs("sections") ?? []).joined(separator: "|"), "12.1|FR-3")
    check("프론트매터: parents.note", parents.first?.str("note") ?? "nil", "쉼표, 가 든 한국어")
    let ents = fm?.maps("entities") ?? []
    check("프론트매터: entities 개수", String(ents.count), "2")
    check("프론트매터: 항목 안 블록 리스트", (ents.first?.strs("code") ?? []).joined(separator: "|"), "App/A.swift|App/B.swift")
    check("프론트매터: 두 번째 항목", ents.count > 1 ? (ents[1].str("name") ?? "nil") : "없음", "beta")
    check("프론트매터: 탭은 거부", parseFrontmatterLines(["id: x", "\tbad: y"], origin: "selftest") == nil ? "nil" : "값", "nil")

    // 2. 제목 → 절 id
    func head(_ s: String) -> String {
        guard let c = HEADING_RE.first(s) else { return "매치 안 됨" }
        let (lv, num, h) = splitHeading(c[1], c[2])
        return "\(lv)|\(num ?? "-")|\(h)"
    }
    check("제목: FR 선언", head("### FR-1. 폴더 감시 (필수)"), "3|FR-1|폴더 감시 (필수)")
    check("제목: T 선언 콜론", head("### T13: 로그인 시 자동 실행"), "3|T13|로그인 시 자동 실행")
    check("제목: 번호+글자", head("### 12.4a T1의 \"2초 안에\"는 FR-2와 양립할 수 없다 ⚠️ 판단 필요"),
          "3|12.4a|T1의 \"2초 안에\"는 FR-2와 양립할 수 없다 ⚠️ 판단 필요")
    check("제목: 2단계 번호", head("## 12. 요구사항 대비 구현 차이 (구현 중 갱신)"), "2|12|요구사항 대비 구현 차이 (구현 중 갱신)")
    check("제목: 콜론 구분", head("### 2.2 HFS+: 변환 불가"), "3|2.2|HFS+: 변환 불가")
    check("제목: 번호 없음", head("### 전송 경로 검증 (README용, 앱 자체 기능 아님)"),
          "3|-|전송 경로 검증 (README용, 앱 자체 기능 아님)")

    // 3. 슬러그
    check("슬러그: 한글 유지", slugify("전송 경로 검증 (README용, 앱 자체 기능 아님)"), "전송-경로-검증-readme용-앱-자체-기능-아님")
    check("슬러그: 이모지 제거", slugify("Foundation을 어디까지 믿을 수 있는가 ⚠️"), "foundation을-어디까지-믿을-수-있는가")
    let nfd = "한글".decomposedStringWithCanonicalMapping
    check("슬러그: NFD와 NFC가 같은 id", String(slugify(nfd) == slugify("한글")), "true")

    // 4. 심볼 (\b 함정 회귀 고정)
    check("심볼: T16과 (한글 뒤)", symbolsIn("T16과 전송").joined(separator: ","), "T16")
    check("심볼: T10에", symbolsIn("T10에 걸림").joined(separator: ","), "T10")
    check("심볼: 괄호 안 나열", symbolsIn("(FR-5, T10)").joined(separator: ","), "FR-5,T10")
    check("심볼: 두 자리", symbolsIn("FR-14 기준").joined(separator: ","), "FR-14")
    check("심볼: 하이픈 뒤는 제외", symbolsIn("FR-3-x").joined(separator: ","), "")
    check("심볼: 접두사 있으면 제외", symbolsIn("aFR-3 NOTE-3").joined(separator: ","), "")
    check("심볼: 소수는 아님", symbolsIn("12.4a 참조").joined(separator: ","), "")
    check("심볼: 범위 확장", String(symbolsIn("요구사항 7장 T1~T16의 검증").count), "16")

    // 5. 선언 형태
    func declares(_ line: String) -> String {
        for shape in DECLARATION_SHAPES { if let c = shape.first(line) { return c[1] } }
        return "-"
    }
    check("선언: h3 마침표", declares("### FR-1. 폴더 감시 (필수)"), "FR-1")
    check("선언: h3 콜론", declares("### T13: 로그인 시 자동 실행"), "T13")
    check("선언: 표 첫 칸", declares("| T1 | 감시 폴더에 NFD 이름 파일 생성 | 4초 안에 NFC로 바뀜 |"), "T1")
    check("선언: 표 헤더는 제외", declares("| # | 시나리오 | 기대 결과 |"), "-")
    check("선언: 일반 표 행 제외", declares("| 지원 OS | macOS 13 Ventura 이상 |"), "-")
    check("선언: 본문 언급 제외", declares("FR-3의 전제는 성립한다"), "-")

    // 6. 로드맵
    let tasks = parseRoadmap("- [x] V1-CORE-03: 볼륨 능력 판별 (CoreKit/Sources/CoreKit/VolumeCapabilities.swift) (12.1b 참조) (2026-09-04)")
    if let t = tasks.first {
        check("로드맵: id", t.id, "V1-CORE-03")
        check("로드맵: 상태", t.status, "done")
        check("로드맵: 마일스톤/모듈", "\(t.milestone)/\(t.module)", "V1/CORE")
        check("로드맵: 날짜", t.date ?? "nil", "2026-09-04")
        check("로드맵: 코드 경로", t.codePaths.joined(separator: ","), "CoreKit/Sources/CoreKit/VolumeCapabilities.swift")
        check("로드맵: 절 참조", t.sectionRefs.map { "\($0.0)#\($0.1)" }.joined(separator: ","), "requirements#12.1b")
    } else { fail += 1; print("❌ 로드맵: 한 줄도 못 읽음") }
    let dotted = parseRoadmap("- [ ] V1.1-KB-01: 도구")
    check("로드맵: V1.1 쪼개기", dotted.first.map { "\($0.milestone)/\($0.module)" } ?? "nil", "V1.1/KB")

    // 7. 코드 경로 중복 제거 (마크다운 링크는 두 번 잡힌다)
    check("코드 경로: 링크 중복 제거",
          orderedUnique(CODE_PATH_RE.all("[docs/x.md](docs/x.md)").map { $0[1] }).joined(separator: ","), "docs/x.md")
    check("코드 경로: 한글 앞", orderedUnique(CODE_PATH_RE.all("측정은 scripts/probe-volume.swift로").map { $0[1] }).joined(separator: ","),
          "scripts/probe-volume.swift")
    check("코드 경로: 접두사 있으면 제외", CODE_PATH_RE.all("x/CoreKit/Sources/a.swift").count.description, "0")

    // 8. JSON writer
    check("JSON: 순서와 한글", J.o([("b", .i(1)), ("a", .s("한글"))]).write(), "{\n  \"b\": 1,\n  \"a\": \"한글\"\n}")
    check("JSON: 빈 배열", J.a([]).write(), "[]")

    // 9. 펜스 안의 제목은 절이 아니다
    let fenced = "# T\n\n## 진짜\n\n```\n## 가짜\n```\n\n## 진짜2\n"
    check("절: 펜스 안 제목 무시",
          parseSections(text: fenced, docId: "d", path: "d.md", bodyStart: 1).map { $0.heading }.joined(separator: ","),
          "진짜,진짜2")
    // 10. 줄 범위는 1부터 포함
    let ranged = "---\nid: x\n---\n\n# 제목\n\n## 가\n본문\n\n## 나\n끝\n"
    let secs = parseSections(text: ranged, docId: "x", path: "x.md", bodyStart: 4)
    check("절: 줄 범위", secs.map { "\($0.heading):\($0.lineStart)-\($0.lineEnd)" }.joined(separator: ","), "가:7-9,나:10-11")

    // 11. 정본·번역본·장치의 구분
    func role(_ p: String) -> String {
        switch classifyWiki(p) {
        case .canonical: return "canonical"
        case .translation: return "translation"
        case .apparatus: return "apparatus"
        }
    }
    check("역할: 정본", role("spec/requirements.md"), "canonical")
    check("역할: 번역본", role("spec/requirements.en.md"), "translation")
    check("역할: 최상위 index", role("index.md"), "apparatus")
    // 예전에는 loadDocs가 최상위만 걸러서 이것이 그래프 문서가 되는데 훅은 장치로 보고 건너뛰었다.
    check("역할: 하위 폴더 index", role("spec/index.md"), "apparatus")
    check("역할: 하위 폴더 log", role("spec/log.md"), "apparatus")
    check("역할: 뿌리 기준 경로", wikiFile(repoRel: "kb/wiki/spec/a.en.md").map { "\($0.wikiRel)|\(role($0.wikiRel))" } ?? "nil",
          "spec/a.en.md|translation")
    check("역할: wiki 밖", wikiFile(repoRel: "README.md") == nil ? "nil" : "있음", "nil")
    check("짝: 정본 → 번역본", translationPath(ofCanonical: "spec/requirements.md"), "spec/requirements.en.md")
    check("짝: 왕복", canonicalPath(ofTranslation: translationPath(ofCanonical: "research/x.md")) ?? "nil", "research/x.md")
    check("짝: 접미사 없으면 nil", canonicalPath(ofTranslation: "spec/x.md") ?? "nil", "nil")

    // 12. 상호 참조. 한국어 표기가 살아 있는지, § 가 걸리는지, 이중 계상이 없는지.
    func refs(_ t: String) -> String {
        findSectionRefs(text: t, selfDoc: "requirements")
            .map { "\($0.toDoc)#\($0.num)" }.joined(separator: ",")
    }
    check("참조: 이름표 + 장은 한 건", refs("acceptance-results 2장을 보라"), "acceptance-results#2")
    check("참조: 한국어 이름표", refs("(요구사항 12.4a)"), "requirements#12.4a")
    check("참조: 한국어 단서", refs("12.4a 참조"), "requirements#12.4a")
    check("참조: 한국어 장", refs("7장 표에 반영"), "requirements#7")
    check("참조: 시길", refs("see §12.4a"), "requirements#12.4a")
    check("참조: 이름표 + 시길은 한 건", refs("requirements §12.1"), "requirements#12.1")
    check("참조: 시길 두 개", refs("§12.1 and §12.1b"), "requirements#12.1,requirements#12.1b")
    // 578-579의 판단은 영어에서 더 중요하다. 버전 번호가 전부 N.N 이다.
    check("참조: 소수는 안 잡는다", refs("3.09 seconds"), "")
    check("참조: 버전은 안 잡는다", refs("macOS 13.4 or later"), "")
    check("참조: 시길은 labelled",
          findSectionRefs(text: "§99.9", selfDoc: "requirements").first.map { String($0.labelled) } ?? "nil", "true")

    // 13. 번역 신선도
    check("신선도: 따라잡음", translationStatus(sourceVersion: "1.1", canonicalVersion: "1.1"), "ok")
    check("신선도: 뒤처짐", translationStatus(sourceVersion: "1.0", canonicalVersion: "1.1"), "stale")
    check("신선도: 읽을 수 없음", translationStatus(sourceVersion: "", canonicalVersion: "1.1"), "unknown")

    // 14. frontmatter 대조. 산문은 언어가 다르므로 어긋나도 문제가 아니다.
    let fmKo = """
    id: requirements
    type: requirements
    date: "2026-09-06"
    title: "한국어 제목"
    parents:
      - id: plan
        version: "1.0"
        sections: ["7", "12.4a"]
        note: "한국어 설명"
    entities:
      - name: overflow-guard
        type: mechanism
        definition: "한국어 정의"
        code: [App/A.swift]
    tags: [a, b]
    """
    let fmEn = fmKo
        .replacingOccurrences(of: "한국어 제목", with: "English title")
        .replacingOccurrences(of: "한국어 설명", with: "English note")
        .replacingOccurrences(of: "한국어 정의", with: "English definition")
    let ko = parseFrontmatterLines(splitLines(fmKo), origin: "ko")!
    let en = parseFrontmatterLines(splitLines(fmEn), origin: "en")!
    check("frontmatter: 산문만 다르면 통과", frontmatterMismatches(canonical: ko, translation: en).count.description, "0")
    let enBad = parseFrontmatterLines(splitLines(fmEn.replacingOccurrences(of: "overflow-guard", with: "overflow-guard-2")), origin: "en")!
    check("frontmatter: 엔티티 이름이 다르면 걸린다",
          frontmatterMismatches(canonical: ko, translation: enBad).joined(separator: ";").contains("entities") ? "걸림" : "안 걸림", "걸림")
    let enBad2 = parseFrontmatterLines(splitLines(fmEn.replacingOccurrences(of: "\"12.4a\"", with: "\"12.4b\"")), origin: "en")!
    check("frontmatter: parents sections가 다르면 걸린다",
          frontmatterMismatches(canonical: ko, translation: enBad2).joined(separator: ";").contains("parents") ? "걸림" : "안 걸림", "걸림")

    // 15. 번역 지시서의 모양. 대상 파일의 줄 번호가 들어가면 안 된다.
    let manifest = syncManifest(source: "kb/wiki/spec/a.md", sourceVersion: "1.2",
                                target: "kb/wiki/spec/a.en.md", targetExists: true, targetVersion: "1.1",
                                mode: "sections", structural: false,
                                preambleChanged: false, preambleLines: [],
                                sections: [(num: "12.4a", heading: "제목", start: 507, end: 538)])
    check("지시서: 모양", manifest.write(), """
    {
      "source": "kb/wiki/spec/a.md",
      "source_version": "1.2",
      "target": "kb/wiki/spec/a.en.md",
      "target_exists": true,
      "target_version": "1.1",
      "mode": "sections",
      "structural_change": false,
      "preamble_changed": false,
      "preamble_lines": [],
      "changed_sections": [
        {
          "num": "12.4a",
          "heading": "제목",
          "source_lines": [
            507,
            538
          ]
        }
      ]
    }
    """)

    // 16. 제목이 생기거나 사라지면 구조 변경이다. 절 단위 대응이 무너진다.
    check("diff: 구조 변경 판정",
          String(DocDiff(touchedLines: [], addedHeads: ["## 새 절"], removedHeads: []).structural), "true")
    check("diff: 문구만 바뀌면 구조 변경 아님",
          String(DocDiff(touchedLines: [5], addedHeads: ["## 가"], removedHeads: ["## 가"]).structural), "false")

    print("\n\(pass + fail)건 중 \(pass) 통과, \(fail) 실패")
    exit(fail == 0 ? 0 : 1)
}

// MARK: - 진입점

let ARGS = Array(CommandLine.arguments.dropFirst())
let USAGE = """
사용법:
  swift scripts/kb.swift build                 그래프와 절 색인을 다시 만든다
  swift scripts/kb.swift query "질문" [-k 8] [--json]
  swift scripts/kb.swift impact <파일경로>      바뀐 문서의 파급 범위
  swift scripts/kb.swift check                 끊긴 참조가 있으면 exit 1
  swift scripts/kb.swift bump <파일경로>        프론트매터 버전 올리기
  swift scripts/kb.swift sync <정본경로>        번역할 절을 지시서로 남긴다
  swift scripts/kb.swift selftest              파서 자체 검사
  swift scripts/kb.swift hook                  훅 payload를 stdin으로
"""

switch ARGS.first {
case "build": cmdBuild()
case "query": cmdQuery(Array(ARGS.dropFirst()))
case "impact":
    guard ARGS.count > 1 else { die(USAGE, 2) }
    cmdImpact(ARGS[1])
case "bump":
    guard ARGS.count > 1 else { die(USAGE, 2) }
    cmdBump(ARGS[1])
case "sync":
    guard ARGS.count > 1 else { die(USAGE, 2) }
    cmdSync(ARGS[1])
case "check": cmdCheck()
case "selftest": cmdSelftest()
case "hook": cmdHook()
default: die(USAGE, 2)
}
