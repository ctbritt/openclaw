import Testing
@testable import OpenClawChatUI

@Suite
struct ChatComposerFocusPolicyTests {
    /// The regression guard for #116042: the mirrored focus value lags the real
    /// responder, so "not requested" must never mean "resign". Before this policy
    /// existed the iOS editor resigned here and the keyboard was pulled away
    /// between the tap and the focus state round-trip.
    @Test func idleEditorKeepsFocusWithoutAnOutstandingRequest() {
        #expect(
            ChatComposerFocusPolicy.action(
                focusRequested: false,
                isEnabled: true,
                holdsFocus: true) == .none)
    }

    @Test func disablementIsTheOnlyReasonToReleaseFocus() {
        #expect(
            ChatComposerFocusPolicy.action(
                focusRequested: false,
                isEnabled: false,
                holdsFocus: true) == .releaseFocus)
        #expect(
            ChatComposerFocusPolicy.action(
                focusRequested: true,
                isEnabled: false,
                holdsFocus: true) == .releaseFocus)
    }

    @Test func aDisabledEditorWithoutFocusHasNothingToRelease() {
        #expect(
            ChatComposerFocusPolicy.action(
                focusRequested: false,
                isEnabled: false,
                holdsFocus: false) == .none)
    }

    @Test func anOutstandingRequestClaimsFocusOnlyWhenTheEditorLacksIt() {
        #expect(
            ChatComposerFocusPolicy.action(
                focusRequested: true,
                isEnabled: true,
                holdsFocus: false) == .claimFocus)
        #expect(
            ChatComposerFocusPolicy.action(
                focusRequested: true,
                isEnabled: true,
                holdsFocus: true) == .none)
    }

    @Test func anIdleUnfocusedEditorStaysUnfocused() {
        #expect(
            ChatComposerFocusPolicy.action(
                focusRequested: false,
                isEnabled: true,
                holdsFocus: false) == .none)
    }
}
