// KeyboardPrewarm.swift
// SourceBible
//
// Pre-boots the system keyboard process at launch so the FIRST
// becomeFirstResponder() of the session (Note editor auto-focus,
// NoteEditorView.viewDidAppear) doesn't pay the keyboard spin-up cost
// (~0.3–1s on device, once per process). A zero-frame text field briefly
// becomes first responder and resigns on the next runloop tick — the keyboard
// process boots in the background, but no keyboard frame is ever drawn.
//
// ⚠️ The field must NOT be `isHidden` — UIKit refuses first-responder status
// to hidden views. A zero-size visible field renders nothing and is safe.

import UIKit

@MainActor
enum KeyboardPrewarm {

    private static var done = false

    /// Call once after the first window exists (hooked into the root `.task`
    /// in SourceBibleApp, slightly delayed to stay off the first-frame path).
    static func run() {
        guard !done else { return }
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first else { return }
        done = true

        let field = UITextField(frame: .zero)
        field.autocorrectionType = .no
        window.addSubview(field)
        field.becomeFirstResponder()

        // Resign on the next tick — enough for the keyboard process to start,
        // too early for any frame of the keyboard UI to appear.
        DispatchQueue.main.async {
            field.resignFirstResponder()
            field.removeFromSuperview()
        }
    }
}
