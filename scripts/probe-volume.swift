// 볼륨의 정규화 성질을 측정한다. kb/wiki/research/rename-measurements.md의 표를 만든 스크립트.
//
//   swift scripts/probe-volume.swift <디렉터리> [<디렉터리> ...]
//
// 새 볼륨(SMB 공유, 클라우드 동기화 폴더, USB 등)을 만났을 때 같은 표를 다시 만들 수 있다.
// Foundation의 경로 변환을 일절 거치지 않는다 — fileSystemRepresentation이 NFD로
// 분해해 버리기 때문이다. 측정 대상 디렉터리는 비어 있어야 하며, 만든 파일은 지운다.

import Foundation

// MARK: - POSIX 유틸

/// String → UTF-8 C 문자열. `fileSystemRepresentation`과 달리 정규화하지 않는다.
func cpath(_ s: String) -> [CChar] { Array(s.utf8).map { CChar(bitPattern: $0) } + [0] }
func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
func errText(_ c: Int32) -> String { c == 0 ? "성공" : "\(String(cString: strerror(c))) (\(c))" }

/// readdir로 디렉터리 항목의 원시 바이트를 읽는다.
func entries(_ dir: String) -> [[UInt8]] {
    var out: [[UInt8]] = []
    guard let d = cpath(dir).withUnsafeBufferPointer({ opendir($0.baseAddress!) }) else { return out }
    defer { closedir(d) }
    while let e = readdir(d) {
        let ent = e.pointee
        var n = ent.d_name
        let b: [UInt8] = withUnsafeBytes(of: &n) { r in (0..<Int(ent.d_namlen)).map { r[$0] } }
        if b == Array(".".utf8) || b == Array("..".utf8) { continue }
        out.append(b)
    }
    return out
}

func fsType(_ p: String) -> String {
    var fs = statfs()
    guard cpath(p).withUnsafeBufferPointer({ statfs($0.baseAddress!, &fs) }) == 0 else { return "?" }
    return withUnsafeBytes(of: &fs.f_fstypename) {
        String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
    }
}

@discardableResult
func create(_ path: String) -> Int32 {
    let fd = cpath(path).withUnsafeBufferPointer { open($0.baseAddress!, O_CREAT | O_EXCL | O_WRONLY, 0o644) }
    if fd < 0 { return errno }
    close(fd)
    return 0
}

func canStat(_ path: String) -> Bool {
    var st = stat()
    return cpath(path).withUnsafeBufferPointer { lstat($0.baseAddress!, &st) } == 0
}

func posixRename(_ a: String, _ b: String) -> Int32 {
    cpath(a).withUnsafeBufferPointer { f in
        cpath(b).withUnsafeBufferPointer { t in rename(f.baseAddress!, t.baseAddress!) == 0 ? 0 : errno }
    }
}

let RENAME_EXCL_FLAG: UInt32 = 0x0000_0004

func renameExcl(_ a: String, _ b: String) -> Int32 {
    cpath(a).withUnsafeBufferPointer { f in
        cpath(b).withUnsafeBufferPointer { t in
            renamex_np(f.baseAddress!, t.baseAddress!, RENAME_EXCL_FLAG) == 0 ? 0 : errno
        }
    }
}

func wipe(_ dir: String) {
    for e in entries(dir) {
        let full = "\(dir)/\(String(decoding: e, as: UTF8.self))"
        _ = cpath(full).withUnsafeBufferPointer { unlink($0.baseAddress!) }
    }
}

// MARK: - 이름

let nfc = "한글.txt".precomposedStringWithCanonicalMapping
let nfd = nfc.decomposedStringWithCanonicalMapping
let nfcB = Array(nfc.utf8), nfdB = Array(nfd.utf8)
func form(_ b: [UInt8]) -> String { b == nfcB ? "NFC" : b == nfdB ? "NFD" : "기타(\(hex(b)))" }

// MARK: - 측정

func probe(_ dir: String) {
    print("\n" + String(repeating: "─", count: 72))
    print("  \(fsType(dir))   \(dir)")
    print(String(repeating: "─", count: 72))

    wipe(dir)
    guard entries(dir).isEmpty else {
        print("  ✗ 디렉터리가 비어 있지 않습니다. 빈 폴더를 지정하세요.")
        return
    }

    // H. NFC를 저장할 수 있는가  ★ 이 볼륨에서 변환이 가능한지 가르는 기준
    let rc = create("\(dir)/\(nfc)")
    let stored = entries(dir).first ?? []
    let canStoreNFC = stored == nfcB
    print("  NFC 이름으로 직접 생성   \(errText(rc)) → \(form(stored))")
    print("  ⇒ NFC 저장 \(canStoreNFC ? "가능 ✅" : "불가 ❌ (커널이 강제 변환)")")

    // B. 정규화 무시 여부
    let insensitive = canStat("\(dir)/\(nfd)")
    print("  정규화                   \(insensitive ? "무시 (insensitive)" : "구분 (SENSITIVE) ⚠️")")

    // E. 공존 가능성 — 덮어쓰기 사고의 전제
    let dup = create("\(dir)/\(nfd)")
    let coexist = entries(dir).count >= 2
    print("  NFD·NFC 공존             \(coexist ? "가능 ⚠️ (덮어쓰기 위험)" : "불가 (\(errText(dup)))")")

    // C/D. rename 동작
    wipe(dir)
    create("\(dir)/\(nfd)")
    let excl = renameExcl("\(dir)/\(nfd)", "\(dir)/\(nfc)")
    let afterExcl = entries(dir).first ?? []
    print("  renamex_np(RENAME_EXCL)  \(errText(excl)) → \(form(afterExcl))")

    if afterExcl != nfcB {
        let plain = posixRename("\(dir)/\(nfd)", "\(dir)/\(nfc)")
        print("  rename(2)                \(errText(plain)) → \(form(entries(dir).first ?? []))")
    }

    wipe(dir)
}

let dirs = Array(CommandLine.arguments.dropFirst())
guard !dirs.isEmpty else {
    FileHandle.standardError.write(
        "사용: swift scripts/probe-volume.swift <빈 디렉터리> [...]\n".data(using: .utf8)!)
    exit(2)
}
dirs.forEach(probe)
print()
