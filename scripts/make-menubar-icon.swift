// design/app-icon.svg의 #cap 벡터 하나로 메뉴바 아이콘 두 벌을 굽는다.
//
//   swift scripts/make-menubar-icon.swift
//
// 메뉴바는 두 가지 모습을 쓴다 (FR-7).
//
//   MenuBarCap        평상시. 윤곽선만 남긴 모자
//   MenuBarCapFilled  변환하는 동안. 속을 채운 모자
//
// 채움은 모자 전체를 통으로 칠하는 것이 아니라, 칠한 뒤 원본의 검은 선을 도로 파낸다.
// 통으로 칠하면 챙과 크라운이 한 덩어리로 뭉쳐서 16pt에서는 모자로 보이지 않는다.
//
// 앱 아이콘과 같은 벡터에서 나오므로 두 아이콘의 모양이 어긋날 일이 없다. 또 목표 크기마다
// 벡터를 그 크기로 직접 그리기 때문에, 큰 비트맵을 축소할 때처럼 선이 흐려지지 않는다.
// make-appicon.swift와 같은 방식이다.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let sourceSVG = root.appendingPathComponent("design/app-icon.svg")
let catalog = root.appendingPathComponent("App/Resources/Assets.xcassets")
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// #cap이 놓인 좌표계의 한 변. app-icon.svg가 `scale(0.39082)`로 800pt에 맞춰 넣고 있다.
let capCoordinateSpace = 2048
/// 메뉴바에서 쓸 논리 높이. 지금까지 쓰던 `hat.widebrim` 15pt가 16pt 높이였다.
let logicalHeight = 16

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

// MARK: - #cap에서 path 뽑기

guard let svgText = try? String(contentsOf: sourceSVG, encoding: .utf8) else {
    fail("'\(sourceSVG.path)'를 읽지 못했습니다.")
}
guard let capOpen = svgText.range(of: "<g id=\"cap\">"),
      let capClose = svgText.range(of: "</g>", range: capOpen.upperBound..<svgText.endIndex) else {
    fail("app-icon.svg에서 <g id=\"cap\"> 그룹을 찾지 못했습니다. 아트워크 구조가 바뀌었습니다.")
}

var paths: [String] = []
var cursor = capOpen.upperBound
while let open = svgText.range(of: "<path", range: cursor..<capClose.lowerBound),
      let close = svgText.range(of: "/>", range: open.upperBound..<capClose.lowerBound) {
    paths.append(String(svgText[open.lowerBound..<close.upperBound]))
    cursor = close.upperBound
}
guard !paths.isEmpty else { fail("#cap 안에 <path>가 없습니다.") }

/// 검은 선을 그리는 path. 나머지는 그 위에 얹히는 색면이다.
let linePaths = paths.filter { $0.contains("fill=\"#000000\"") }
guard !linePaths.isEmpty else {
    fail("#cap에서 검은 윤곽선 path를 찾지 못했습니다. 아트워크의 색이 바뀌었습니다.")
}

/// path 몇 개를 그대로 담은 SVG 한 장을 만든다.
///
/// 색은 원본 그대로 둔다. 아래에서 알파 채널만 꺼내 쓰기 때문에 어떤 색으로 칠해져 있든
/// 결과가 같다.
func svgDocument(_ body: [String]) -> Data {
    let side = capCoordinateSpace
    return Data("""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(side) \(side)" width="\(side)" height="\(side)">
    \(body.joined(separator: "\n"))
    </svg>
    """.utf8)
}

guard let lineArt = NSImage(data: svgDocument(linePaths)),
      let solidArt = NSImage(data: svgDocument(paths)) else {
    fail("#cap을 이미지로 그리지 못했습니다.")
}

// MARK: - 벡터 그리기

/// 벡터를 정사각형 캔버스에 그린 뒤 알파만 뽑는다.
func alphaMask(_ art: NSImage, width: Int, height: Int, draw: (NSImage) -> Void) -> [UInt8] {
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: width * 4, space: sRGB,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fail("\(width)×\(height) 비트맵을 만들지 못했습니다.")
    }
    let context = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    draw(art)
    NSGraphicsContext.restoreGraphicsState()

    guard let image = ctx.makeImage() else { fail("비트맵을 이미지로 굳히지 못했습니다.") }
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    buffer.withUnsafeMutableBytes { raw in
        CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: sRGB,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
            .draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return (0..<(width * height)).map { buffer[$0 * 4 + 3] }
}

/// 모자가 실제로 차지하는 사각형. 벡터 좌표계 기준이다.
///
/// #cap은 2048 정사각형 안에 위아래 여백을 두고 놓여 있다. 그 여백째로 메뉴바에 올리면
/// 모자가 실제 높이의 70%로 쪼그라든다.
let capBounds: CGRect = {
    let probe = 1024
    let mask = alphaMask(solidArt, width: probe, height: probe) { art in
        art.draw(in: NSRect(x: 0, y: 0, width: probe, height: probe),
                 from: .zero, operation: .copy, fraction: 1)
    }
    var minX = probe, maxX = -1, minY = probe, maxY = -1
    for y in 0..<probe {
        for x in 0..<probe where mask[y * probe + x] > 8 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX >= minX else { fail("#cap을 그렸는데 아무것도 칠해지지 않았습니다.") }
    let unit = Double(capCoordinateSpace) / Double(probe)
    return CGRect(x: Double(minX) * unit, y: Double(minY) * unit,
                  width: Double(maxX - minX + 1) * unit, height: Double(maxY - minY + 1) * unit)
}()

let logicalWidth = Int((Double(logicalHeight) * capBounds.width / capBounds.height).rounded())

/// 모자를 캔버스 높이에 꽉 채워 가운데에 그린 알파 마스크.
func mask(_ art: NSImage, scale: Int) -> [UInt8] {
    let width = logicalWidth * scale, height = logicalHeight * scale
    return alphaMask(art, width: width, height: height) { art in
        let factor = Double(height) / capBounds.height
        let inset = (Double(width) - capBounds.width * factor) / 2
        art.draw(in: NSRect(x: -capBounds.minX * factor + inset, y: -capBounds.minY * factor,
                            width: Double(capCoordinateSpace) * factor,
                            height: Double(capCoordinateSpace) * factor),
                 from: .zero, operation: .sourceOver, fraction: 1)
    }
}

/// 알파 마스크를 검은 template PNG로 굳혀 쓴다.
func writePNG(_ mask: [UInt8], scale: Int, to output: URL) {
    let width = logicalWidth * scale, height = logicalHeight * scale
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    // premultiplied 검정이라 RGB는 0으로 두고 알파만 채운다.
    for i in 0..<(width * height) { rgba[i * 4 + 3] = mask[i] }

    let image: CGImage = rgba.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4, space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let made = ctx.makeImage() else { fail("\(output.lastPathComponent)를 굳히지 못했습니다.") }
        return made
    }
    guard let destination = CGImageDestinationCreateWithURL(
        output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("\(output.lastPathComponent)를 쓰지 못했습니다.")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fail("\(output.lastPathComponent)를 쓰지 못했습니다.")
    }
}

// MARK: - imageset 두 벌 쓰기

/// 한 벌을 통째로 만든다. 이전 PNG는 지우고 Contents.json도 다시 쓴다.
func writeImageSet(named name: String, base: String, makeMask: (Int) -> [UInt8]) {
    let directory = catalog.appendingPathComponent("\(name).imageset")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for stale in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    where stale.pathExtension == "png" {
        try? FileManager.default.removeItem(at: stale)
    }

    var entries: [String] = []
    for scale in [1, 2] {
        let file = scale == 1 ? "\(base).png" : "\(base)@2x.png"
        writePNG(makeMask(scale), scale: scale, to: directory.appendingPathComponent(file))
        entries.append("""
        { "idiom" : "mac", "scale" : "\(scale)x", "filename" : "\(file)" }
        """.trimmingCharacters(in: .whitespaces))
        print("    \(file.padding(toLength: max(file.count, 22), withPad: " ", startingAt: 0)) \(logicalWidth * scale)×\(logicalHeight * scale)px")
    }

    // template-rendering-intent를 지정해야 메뉴바가 밝은 배경에서는 검게, 어두운 배경에서는
    // 희게 칠해 준다. 이 한 줄이 빠지면 어느 쪽에서도 원본 색 그대로 나온다.
    let contents = """
    {
      "images" : [
        \(entries.joined(separator: ",\n    "))
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      },
      "properties" : {
        "template-rendering-intent" : "template"
      }
    }

    """
    do {
        try contents.write(to: directory.appendingPathComponent("Contents.json"),
                           atomically: true, encoding: .utf8)
    } catch {
        fail("\(name)의 Contents.json을 쓰지 못했습니다: \(error.localizedDescription)")
    }
}

print("==> \(sourceSVG.lastPathComponent) #cap → 메뉴바 아이콘 (\(logicalWidth)×\(logicalHeight)pt)")

print("  MenuBarCap (평상시 · 선만)")
writeImageSet(named: "MenuBarCap", base: "menubar-cap") { mask(lineArt, scale: $0) }

print("  MenuBarCapFilled (변환 중 · 채움)")
writeImageSet(named: "MenuBarCapFilled", base: "menubar-cap-filled") { scale in
    let solid = mask(solidArt, scale: scale)
    let line = mask(lineArt, scale: scale)
    // 채운 모양에서 선을 빼면 챙과 크라운 사이가 틈으로 남는다.
    return (0..<solid.count).map { UInt8(max(0, Int(solid[$0]) - Int(line[$0]))) }
}

print()
print("==> 두 벌을 다시 썼습니다")
print("    다음: ./scripts/build.sh 로 확인하세요")
