import AppKit

/// 메뉴바에 올리는 모자 아이콘 (FR-7).
///
/// 두 가지 모습이 있다. 평상시에는 윤곽선만 남긴 모자이고, 이름을 바꾸고 있는 동안에는
/// 속을 채운 모자다. 두 이미지는 캔버스 크기가 같으므로 서로 바뀌어도 메뉴바 항목이
/// 옆으로 움직이지 않는다.
///
/// 애셋은 `scripts/make-menubar-icon.swift`가 `design/app-icon.svg`의 #cap 벡터에서
/// 굽는다. 앱 아이콘과 원본이 같아서 두 아이콘의 모양이 어긋날 일이 없다.
///
/// 문제 상태는 오른쪽 아래 느낌표 배지로 알린다. 모자에는 `textformat.abc.dottedunderline`
/// 같은 짝이 되는 심볼이 없어서 직접 합성한다. 배지가 붙어도 캔버스 크기는 그대로라
/// 메뉴바 항목이 움직이지 않는다.
@MainActor
enum MenuBarIcon {

    /// 아이콘이 취할 수 있는 모습. 캐시 열쇠로도 쓴다.
    struct Appearance: Hashable {
        /// 폴더 가운데 하나라도 문제가 있다. 느낌표 배지를 붙인다.
        var hasProblem: Bool
        /// 지금 이름을 바꾸고 있다. 속을 채운 모자로 바꾼다.
        var isConverting: Bool
    }

    /// 배지 지름 = 아이콘 높이 × 이 비율. 2x 화면에서 느낌표가 읽히는 최소값이다.
    private static let badgeRatio: CGFloat = 0.6
    /// 배지 둘레를 파낼 두께. 모자 선 위에 겹쳐도 배지가 떨어져 보인다.
    private static let badgeRing: CGFloat = 1
    /// 메뉴바 높이(22pt) 안에 여백이 남는 크기. 배지와 대체 심볼이 이 크기를 따른다.
    private static let pointSize: CGFloat = 15

    /// 경우의 수가 넷뿐이라 만든 그대로 들고 있는다. 메뉴바는 자주 다시 그린다.
    private static var cache: [Appearance: NSImage] = [:]

    static func image(hasProblem: Bool, isConverting: Bool) -> NSImage {
        let appearance = Appearance(hasProblem: hasProblem, isConverting: isConverting)
        if let cached = cache[appearance] { return cached }
        let made = compose(appearance)
        cache[appearance] = made
        return made
    }

    private static func compose(_ appearance: Appearance) -> NSImage {
        // 애셋 카탈로그가 돌려주는 인스턴스는 앱 전체가 함께 쓴다. 여기서 isTemplate을
        // 건드리게 되므로 사본을 뜬다.
        guard let cap = cap(filled: appearance.isConverting)?.copy() as? NSImage else {
            return NSImage()
        }
        guard appearance.hasProblem,
              let badge = symbol("exclamationmark.circle.fill", weight: .semibold) else {
            cap.isTemplate = true
            return cap
        }

        let canvas = cap.size
        let side = canvas.height * badgeRatio
        let box = NSRect(x: canvas.width - side, y: 0, width: side, height: side)

        let image = NSImage(size: canvas, flipped: false) { _ in
            cap.draw(in: NSRect(origin: .zero, size: canvas))
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

    /// 구워 둔 애셋을 가져온다.
    ///
    /// 애셋이 빠진 빌드에서도 메뉴바에 아무것도 없는 상태로 두지는 않는다. SF Symbols의
    /// `hat.widebrim`은 macOS 15부터라 그 아래에서는 `graduationcap`으로 내려간다 —
    /// 둘 다 모자다. 다만 채움과 선을 구분해 주지는 못한다.
    private static func cap(filled: Bool) -> NSImage? {
        if let asset = NSImage(named: filled ? "MenuBarCapFilled" : "MenuBarCap") {
            return asset
        }
        if #available(macOS 15.0, *), let hat = symbol("hat.widebrim") { return hat }
        return symbol("graduationcap")
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
