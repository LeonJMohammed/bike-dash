import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Calls `onTouch` for every touch anywhere in the window (the ride screen,
/// sheets, everything) without getting in the way of buttons, scrolling or
/// other gestures. Put it in a background.
struct WindowTouchHook: UIViewRepresentable {
    let onTouch: @MainActor () -> Void

    func makeUIView(context: Context) -> HookView {
        HookView(onTouch: onTouch)
    }

    func updateUIView(_ view: HookView, context: Context) {
        view.onTouch = onTouch
    }

    /// An empty view that hangs a touch watcher on whatever window it lands in.
    final class HookView: UIView {
        var onTouch: @MainActor () -> Void
        private let watcher = TouchWatcher(target: nil, action: nil)

        init(onTouch: @escaping @MainActor () -> Void) {
            self.onTouch = onTouch
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            watcher.onTouch = { [weak self] in self?.onTouch() }
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            watcher.view?.removeGestureRecognizer(watcher)
            window?.addGestureRecognizer(watcher)
        }
    }
}

/// Notices a touch beginning, then fails at once, so every other gesture and
/// control gets the touch as if it weren't there.
final class TouchWatcher: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onTouch: (() -> Void)?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouch?()
        state = .failed
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
