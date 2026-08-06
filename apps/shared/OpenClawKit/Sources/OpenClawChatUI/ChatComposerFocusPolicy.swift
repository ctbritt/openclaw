/// Focus policy shared by the composer's platform text editors.
///
/// Both editors are UIKit/AppKit views outside SwiftUI focus tracking, so any
/// mirrored focus value lags the real first responder by a render pass. Treating
/// that stale value as authority to resign pulls the keyboard away between the
/// user's tap and the focus round-trip, which is what broke iOS typing in
/// #116042. Disablement is the only reason to release focus; claiming it is a
/// one-shot request the editor consumes.
enum ChatComposerFocusAction: Equatable {
    case claimFocus
    case releaseFocus
    case none
}

enum ChatComposerFocusPolicy {
    static func action(
        focusRequested: Bool,
        isEnabled: Bool,
        holdsFocus: Bool) -> ChatComposerFocusAction
    {
        guard isEnabled else {
            return holdsFocus ? .releaseFocus : .none
        }
        return focusRequested && !holdsFocus ? .claimFocus : .none
    }
}
