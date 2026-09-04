import AppKit
import SwiftUI

/// 보조 창(온보딩·폴더 관리·변환 내역)을 띄운다.
///
/// SwiftUI의 `Window` 장면 대신 `NSWindow`를 직접 쓴다. Dock 아이콘이 없는 앱
/// (`LSUIElement`)은 창을 띄울 때 스스로 앞으로 나와야 하고, 첫 실행 온보딩은
/// 메뉴를 열기 **전에** 떠야 하는데 `openWindow`는 뷰 안에서만 부를 수 있기 때문이다.
@MainActor
final class WindowPresenter {

    private var windows: [String: NSWindow] = [:]

    /// 같은 `id`로 다시 부르면 이미 떠 있는 창을 앞으로 가져온다.
    func show<Content: View>(id: String,
                             title: String,
                             size: CGSize,
                             @ViewBuilder content: () -> Content) {
        if let existing = windows[id] {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentViewController = NSHostingController(rootView: content())
        window.isReleasedWhenClosed = false
        window.center()

        // 창이 닫히면 참조를 놓아 준다. 안 그러면 계속 쌓인다.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.windows[id] = nil }
        }

        windows[id] = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close(id: String) {
        windows[id]?.close()
        windows[id] = nil
    }

    func isShowing(id: String) -> Bool { windows[id] != nil }
}
