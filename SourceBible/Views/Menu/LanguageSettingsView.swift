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

    // Дефолт `@AppStorage` спрацьовує, поки ключа НЕМА — а він пишеться лише
    // коли людина відкриє пікер мови. Жорсткий "en" тут означав, що на
    // українському телефоні цей екран був англійським, хоч решта інтерфейсу
    // (через свізл бандла) — українська. `resolved` дає ту саму мову, що й свізл.
    @AppStorage(AppStorageKeys.appLanguage) private var appLanguage: String = AppLanguage.resolved
    @Environment(\.colorTheme) private var colorTheme

    private struct Language: Identifiable {
        let code: String
        let localName: String   // name in that language

        var id: String { code }
    }

    private let languages: [Language] = [
        Language(code: "en", localName: "English"),
        Language(code: "uk", localName: "Українська"),
    ]

    /// Language name in the CURRENT interface language («Ukrainian» / «Англійська»),
    /// from the system locale data — no strings to maintain per language. Returns nil
    /// when it would just repeat the row's own name (e.g. «English» under «English»).
    /// No flags: a flag marks a country, not a language (🇬🇧 for English excludes US/AU).
    private func interfaceName(for lang: Language) -> String? {
        let ui = Locale(identifier: appLanguage)
        guard let name = ui.localizedString(forLanguageCode: lang.code) else { return nil }
        // iOS returns Ukrainian names lowercase («англійська») — capitalize first letter.
        let cased = name.prefix(1).uppercased(with: ui) + name.dropFirst()
        return cased == lang.localName ? nil : cased
    }

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
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lang.localName)
                            .foregroundStyle(.primary)
                        if let subtitle = interfaceName(for: lang) {
                            Text(subtitle)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
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
