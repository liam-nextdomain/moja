// 앱 아이콘 원본(1024 × 1024 PNG)을 그린다. 설계 근거는 docs/app-icon-brief.md에 있다.
//
//   swift scripts/make-icon-art.swift [출력경로.png]
//
// 사람 디자이너가 만든 원본으로 교체할 때에는 이 스크립트를 쓰지 않고
// scripts/make-appicon.sh에 그 PNG를 직접 넘기면 된다.
import AppKit
import QuartzCore

let canvas = 1024
let shapeSide: CGFloat = 824              // 캔버스의 80.47%. 실제 시스템 아이콘에서 실측한 값이다.
let inset: CGFloat = (CGFloat(canvas) - shapeSide) / 2

/// 둥근 사각형의 모서리 반경. macOS 시스템 앱 아이콘(메모)의 알파 채널에서 모서리 프로파일을
/// 뽑아 CALayer의 연속 곡률과 맞춰 본 결과 이 값에서 오차가 가장 작았다 (RMS 2.5px).
/// 널리 인용되는 185.4보다 조금 작다.
let cornerRadius: CGFloat = 180

func srgb(_ hex: UInt32) -> CGColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1).cgColor
}

let bgTop = srgb(0x5B6FE0)
let bgBottom = srgb(0x2E3A8C)
let hatColor = srgb(0xF7F4EC)
let bandColor = srgb(0x2E3A8C)            // 배경 아래쪽 색을 재사용해 색 가짓수를 늘리지 않는다.

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func newContext() -> CGContext {
    CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
              bytesPerRow: canvas * 4, space: sRGB,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

// MARK: - 둥근 사각형

/// 연속 곡률 모서리는 직접 그리기 어려워서 CALayer가 그려 주는 것을 그대로 받아 쓴다.
/// anchorPoint와 position을 지정하지 않으면 render(in:)이 좌표를 다르게 잡는다.
func squircle() -> CGImage {
    let ctx = newContext()
    let layer = CALayer()
    layer.anchorPoint = .zero
    layer.position = CGPoint(x: inset, y: inset)
    layer.bounds = CGRect(x: 0, y: 0, width: shapeSide, height: shapeSide)
    layer.cornerRadius = cornerRadius
    layer.cornerCurve = .continuous
    layer.backgroundColor = NSColor.white.cgColor
    layer.render(in: ctx)
    return ctx.makeImage()!
}

// MARK: - 배경과 모자

/// 모자를 그리는 좌표는 좌상단이 원점이고 y가 아래로 증가한다.
func content() -> CGImage {
    let ctx = newContext()

    let gradient = CGGradient(colorsSpace: sRGB, colors: [bgTop, bgBottom] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: CGFloat(canvas) - inset),
                           end: CGPoint(x: 0, y: inset),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    ctx.translateBy(x: 0, y: CGFloat(canvas))
    ctx.scaleBy(x: 1, y: -1)

    // 크라운. 아래쪽은 챙에 가려지므로 실루엣에 드러나지 않는다.
    let crown = CGMutablePath()
    crown.move(to: CGPoint(x: 342, y: 595))
    crown.addCurve(to: CGPoint(x: 351, y: 432),
                   control1: CGPoint(x: 340, y: 528), control2: CGPoint(x: 344, y: 476))
    crown.addCurve(to: CGPoint(x: 512, y: 320),
                   control1: CGPoint(x: 363, y: 378), control2: CGPoint(x: 431, y: 320))
    crown.addCurve(to: CGPoint(x: 673, y: 432),
                   control1: CGPoint(x: 593, y: 320), control2: CGPoint(x: 661, y: 378))
    crown.addCurve(to: CGPoint(x: 682, y: 595),
                   control1: CGPoint(x: 680, y: 476), control2: CGPoint(x: 684, y: 528))
    crown.closeSubpath()

    // 챙. 살짝 위에서 내려다본 각도라 타원이 된다.
    let brim = CGPath(ellipseIn: CGRect(x: 177, y: 522, width: 670, height: 146), transform: nil)

    // 두 도형을 한 번에 채워서 하나의 실루엣으로 만든다.
    let hat = CGMutablePath()
    hat.addPath(crown)
    hat.addPath(brim)
    ctx.setFillColor(hatColor)
    ctx.addPath(hat)
    ctx.fillPath(using: .winding)

    // 밴드. 두꺼우면 32pt 이하에서 모자가 흰 막대 두 개로 쪼개져 보인다.
    // 크라운과 챙이 만나는 자리에 얇게만 넣는다.
    ctx.saveGState()
    ctx.addPath(crown)
    ctx.clip()
    ctx.setFillColor(bandColor)
    ctx.fill(CGRect(x: 280, y: 494, width: 464, height: 26))
    ctx.restoreGState()

    return ctx.makeImage()!
}

// MARK: - 합성

let full = CGRect(x: 0, y: 0, width: CGFloat(canvas), height: CGFloat(canvas))

// 둥근 사각형 모양으로 배경과 모자를 오려낸다.
let masked: CGImage = {
    let c = newContext()
    c.draw(squircle(), in: full)
    c.setBlendMode(.sourceIn)
    c.draw(content(), in: full)
    return c.makeImage()!
}()

// 그림자는 도형 바깥 100px 여백 안에 들어간다. 시스템 앱 아이콘과 비교해 맞춘 값이다.
let out = newContext()
out.setShadow(offset: CGSize(width: 0, height: -10), blur: 34,
              color: NSColor(white: 0, alpha: 0.20).cgColor)
out.draw(masked, in: full)

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "moja-icon-1024.png"
let rep = NSBitmapImageRep(cgImage: out.makeImage()!)
rep.size = NSSize(width: canvas, height: canvas)
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
print("생성: \(path) (\(canvas) × \(canvas))")
