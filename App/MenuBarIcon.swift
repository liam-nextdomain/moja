import AppKit

/// 메뉴바에 올리는 모자 아이콘 (FR-7).
///
/// SF Symbols의 `hat.widebrim`은 macOS 15부터 있다. 배포 타깃이 13이라
/// 그 아래에서는 `graduationcap`으로 내려간다 — 둘 다 모자다.
///
/// 문제 상태는 오른쪽 아래 느낌표 배지로 알린다. 모자 계열 심볼에는
/// `textformat.abc.dottedunderline` 같은 짝이 없어서 직접 합성한다.
/// 배지가 붙어도 캔버스 크기는 그대로라 메뉴바 항목이 움직이지 않는다.
@MainActor
enum MenuBarIcon {
    /// 메뉴바 높이(22pt) 안에 여백이 남는 크기.
    private static let pointSize: CGFloat = 15
    /// 배지 지름 = 아이콘 높이 × 이 비율. 2x 화면에서 느낌표가 읽히는 최소값이다.
    private static let badgeRatio: CGFloat = 0.6
    /// 배지 둘레를 파낼 두께. 모자 선 위에 겹쳐도 배지가 떨어져 보인다.
    private static let badgeRing: CGFloat = 1

    /// 상태가 둘뿐이라 만든 그대로 들고 있는다. 메뉴바는 자주 다시 그린다.
    private static var cache: [Bool: NSImage] = [:]

    static func image(hasProblem: Bool) -> NSImage {
        if let cached = cache[hasProblem] { return cached }
        let made = compose(hasProblem: hasProblem)
        cache[hasProblem] = made
        return made
    }

    private static var hatSymbolName: String {
        if #available(macOS 15.0, *) { return "hat.widebrim" }
        return "graduationcap"
    }

    private static func compose(hasProblem: Bool) -> NSImage {
        guard let hat = symbol(hatSymbolName) ?? symbol("graduationcap") else { return NSImage() }
        guard hasProblem, let badge = symbol("exclamationmark.circle.fill", weight: .semibold) else {
            hat.isTemplate = true
            return hat
        }

        let canvas = hat.size
        let side = canvas.height * badgeRatio
        let box = NSRect(x: canvas.width - side, y: 0, width: side, height: side)

        let image = NSImage(size: canvas, flipped: false) { _ in
            hat.draw(in: NSRect(origin: .zero, size: canvas))
            guard let context = NSGraphicsContext.current else { return true }

            // 배지가 앉을 자리를 모자에서 파낸다. 템플릿 이미지라 색은 알파에만 쓰인다.
            context.compositingOperation = .destinationOut
            NSColor.black.setFill()
            NSBezierPath(ovalIn: box.insetBy(dx: -badgeRing, dy: -badgeRing)).fill()

            context.compositingOperation = .sourceOver
            badge.draw(in: aspectFit(badge.size, in: box))
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func symbol(_ name: String, weight: NSFont.Weight = .regular) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight))
    }

    /// 비율을 지키며 `box` 안에 맞춘다. 배지가 찌그러지지 않게.
    private static func aspectFit(_ size: NSSize, in box: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        let fitted = NSSize(width: size.width * scale, height: size.height * scale)
        return NSRect(x: box.midX - fitted.width / 2,
                      y: box.midY - fitted.height / 2,
                      width: fitted.width,
                      height: fitted.height)
    }
}
