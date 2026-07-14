// LanguageSettingsView.swift
// SourceBible
//
// Language picker — persists selection to @AppStorage("appLanguage").
// SourceBibleApp.swift injects .environment(\.locale) on ContentView so all
// LocalizedStringKey Text views re-render immediately when appLanguage changes.
// LocalizedBundle is activated HERE before the AppStorage write so the bundle
// swizzle is ready before SwiftUI re-evaluates any String(localized:) calls.
// ADR-006: docs/architecture/ADR-006-localization-translation-provider.md

import SwiftUI

struct LanguageSettingsView: View {

    @AppStorage(AppStorageKeys.appLanguage) private var appLanguage: String = "en"
    @Environment(\.colorTheme) private var colorTheme

    private struct Language: Identifiable {
        let code: String
        let localName: String   // name in that language
        let flag: String

        var id: String { code }
    }

    private let languages: [Language] = [
        Language(code: "en", localName: "English",    flag: "🇬🇧"),
        Language(code: "uk", localName: "Українська", flag: "🇺🇦"),
    ]

    var body: some View {
        List(languages) { lang in
            Button {
                // Activate the bundle BEFORE writing to @AppStorage.
                // When appLanguage changes, .environment(\.locale) on ContentView
                // triggers SwiftUI to re-evaluate all LocalizedStringKey Text views.
                // Pre-activating ensures String(localized:) also returns the new
                // language in any view body re-evaluated during that render pass.
                LocalizedBundle.activate(language: lang.code)
                appLanguage = lang.code
            } label: {
                HStack(spacing: 14) {
                    Text(lang.flag).font(.title2)
                    Text(lang.localName)
                        .foregroundStyle(.primary)
                    Spacer()
                    if appLanguage == lang.code {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.appBlue)
                            .fontWeight(.semibold)
                    }
                }
            }
            .buttonStyle(.plain)
            .themedRow(colorTheme)
        }
        .themedList(colorTheme)
        .navigationTitle("menu.language")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        LanguageSettingsView()
    }
}
