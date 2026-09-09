// design/app-icon.svg 한 장으로 AppIcon.appiconset을 채운다.
//
//   swift scripts/make-appicon.swift              # design/app-icon.svg를 쓴다
//   swift scripts/make-appicon.swift 다른원본.svg  # 원본을 직접 지정한다
//
// 자산 카탈로그의 AppIcon 슬롯은 벡터를 직접 받지 못하므로 PNG가 필요하다. 큰 PNG를 한 장
// 만들어 축소하지 않고, 열 개 슬롯마다 벡터에서 그 픽셀 크기로 직접 그린다. 16pt처럼 작은
// 크기에서 형태가 뭉개지지 않게 하려는 것이다.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let setDir = root.appendingPathComponent("App/Resources/Assets.xcassets/AppIcon.appiconset")

let source: URL = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : root.appendingPathComponent("design/app-icon.svg")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

guard FileManager.default.fileExists(atPath: source.path) else {
    fail("'\(source.path)'를 찾을 수 없습니다.")
}
guard let artwork = NSImage(contentsOf: source) else {
    fail("'\(source.path)'를 이미지로 읽지 못했습니다.")
}
guard artwork.size.width == artwork.size.height, artwork.size.width > 0 else {
    fail("원본은 정사각형이어야 합니다. 지금은 \(Int(artwork.size.width)) × \(Int(artwork.size.height))입니다.")
}

// 자산 카탈로그가 요구하는 열 개 슬롯이다. (논리 크기, 배율, 실제 픽셀) 순서로 적었다.
let slots: [(size: String, scale: String, pixels: Int)] = [
    ("16x16", "1x", 16),
    ("16x16", "2x", 32),
    ("32x32", "1x", 32),
    ("32x32", "2x", 64),
    ("128x128", "1x", 128),
    ("128x128", "2x", 256),
    ("256x256", "1x", 256),
    ("256x256", "2x", 512),
    ("512x512", "1x", 512),
    ("512x512", "2x", 1024),
]

func render(_ pixels: Int, to output: URL) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let bitmap = CGContext(data: nil, width: pixels, height: pixels,
                                 bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fail("\(pixels)px 비트맵 컨텍스트를 만들지 못했습니다.")
    }

    let context = NSGraphicsContext(cgContext: bitmap, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    artwork.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
                 from: .zero, operation: .copy, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()

    guard let image = bitmap.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
              output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("\(output.lastPathComponent)를 쓰지 못했습니다.")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fail("\(output.lastPathComponent)를 쓰지 못했습니다.")
    }
}

print("==> \(source.path) → \(setDir.lastPathComponent)")

// 이전에 만들어 둔 PNG는 먼저 지운다. 슬롯 구성을 바꿨을 때 옛 파일이 남지 않게 하려는 것이다.
let existing = (try? FileManager.default.contentsOfDirectory(at: setDir, includingPropertiesForKeys: nil)) ?? []
for file in existing where file.pathExtension == "png" {
    try? FileManager.default.removeItem(at: file)
}

var entries: [String] = []
for slot in slots {
    let name = slot.scale == "1x" ? "icon_\(slot.size).png" : "icon_\(slot.size)@2x.png"
    render(slot.pixels, to: setDir.appendingPathComponent(name))
    entries.append("""
        { "idiom" : "mac", "scale" : "\(slot.scale)", "size" : "\(slot.size)", "filename" : "\(name)" }
    """.trimmingCharacters(in: .whitespaces))
    let padded = name.padding(toLength: max(name.count, 18), withPad: " ", startingAt: 0)
    print("    \(padded) \(slot.pixels)px")
}

let contents = """
{
  "images" : [
    \(entries.joined(separator: ",\n    "))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try! contents.write(to: setDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

print()
print("==> Contents.json을 다시 썼습니다")
print("    다음: ./scripts/build.sh 로 확인하세요")
