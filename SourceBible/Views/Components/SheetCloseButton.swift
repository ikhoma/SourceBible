// SheetCloseButton.swift
// SourceBible
//
// Єдина кнопка закриття для всіх sheet-хедерів (консистентність, 2026-07).
// iOS 26: системна Button(role: .close) у toolbar автоматично рендериться
// стандартною круглою X-кнопкою з правильним glass-стилем — без кастомного
// label (див. developer.apple.com/documentation/swiftui/buttonrole/close).
// iOS 18 fallback: звичайна toolbar-кнопка з іконкою xmark.
//
// Використання:
//   ToolbarItem(placement: .cancellationAction) {
//       SheetCloseButton { dismiss() }
//   }

import SwiftUI

struct SheetCloseButton: View {
    let action: () -> Void

    var body: some View {
        if #available(iOS 26, *) {
            Button(role: .close, action: action)
        } else {
            Button(action: action) {
                Image(systemName: "xmark")
            }
            .accessibilityLabel(Text("action.close"))
        }
    }
}
