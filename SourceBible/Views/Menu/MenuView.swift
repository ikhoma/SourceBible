// MenuView.swift
// SourceBible

import SwiftUI

struct MenuView: View {
    @EnvironmentObject var readerVM: ReaderViewModel
    @State private var brightness: Double = Double(UIScreen.main.brightness)
    @AppStorage(AppStorageKeys.appearanceMode) private var appearanceModeRaw = AppearanceMode.matchDevice.rawValue
    @AppStorage(AppStorageKeys.colorTheme) private var colorThemeRaw = ColorTheme.paper.rawValue
    @AppStorage(AppStorageKeys.titleFontStyle) private var titleFontStyleRaw = TitleFontStyle.modern.rawValue
    @AppStorage(AppStorageKeys.hideBookCovers) private var hideBookCovers = false
    @AppStorage(AppStorageKeys.redLetters) private var redLetters = false
    @AppStorage(AppStorageKeys.defaultTranslationId) private var defaultTranslationId: String = AppLanguage.defaultTranslationId
    @AppStorage(AppStorageKeys.analyticsEnabled) private var analyticsEnabled: Bool = true
    @Environment(\.locale) private var locale
    // Дефолт `@AppStorage` спрацьовує, поки ключа НЕМА — а він пишеться лише
    // коли людина відкриє пікер мови. Жорсткий "en" тут означав, що на
    // українському телефоні цей екран був англійським, хоч решта інтерфейсу
    // (через свізл бандла) — українська. `resolved` дає ту саму мову, що й свізл.
    @AppStorage(AppStorageKeys.appLanguage) private var appLanguage: String = AppLanguage.resolved
    @AppStorage(AppStorageKeys.launchBehavior) private var launchBehaviorRaw = LaunchBehavior.resume.rawValue
    @AppStorage(AppStorageKeys.translationLaunchBehavior) private var translationLaunchRaw = TranslationLaunchBehavior.lastUsed.rawValue

    private var currentLanguageLabel: String {
        switch appLanguage {
        case "uk": return "Українська"
        default:   return "English"
        }
    }

    // Typed views over the raw @AppStorage values (single source of truth stays
    // in UserDefaults; the environment re-injects from SourceBibleApp).
    private var colorTheme: ColorTheme { ColorTheme(rawValue: colorThemeRaw) ?? .paper }
    private var titleFontStyle: TitleFontStyle { TitleFontStyle(rawValue: titleFontStyleRaw) ?? .modern }
    private var appearanceMode: AppearanceMode { AppearanceMode(rawValue: appearanceModeRaw) ?? .matchDevice }

    private var launchBehaviorLabel: LocalizedStringKey {
        LaunchBehavior(rawValue: launchBehaviorRaw) == .lastBookmark
            ? "menu.launch.last_bookmark" : "menu.launch.resume"
    }

    private var translationLaunchBehavior: TranslationLaunchBehavior {
        TranslationLaunchBehavior(rawValue: translationLaunchRaw) ?? .lastUsed
    }

    /// Значення в рядку: або «Останній відкритий», або id конкретного перекладу.
    @ViewBuilder
    private var translationLaunchValueLabel: some View {
        if translationLaunchBehavior == .lastUsed {
            Text("menu.translation_launch.last_used")
        } else {
            Text(defaultTranslationId)
        }
    }

    var body: some View {
        // .id on NavigationStack (not Form) forces the entire UINavigationController —
        // including UINavigationBar and its cached title — to be torn down and rebuilt
        // when locale changes. Putting .id on the inner Form only reconstructs the
        // UITableView content; UIKit's navigation bar title is resolved from a
        // preference-key emission that arrives ONE RENDER CYCLE AFTER the Form identity
        // change, causing a persistent one-step-behind swap of locale values.
        // MenuView has no deep navigation state to preserve (LanguageSettingsView is
        // the only pushed destination and is where language changes originate), so
        // full NavigationStack reconstruction is safe.
        NavigationStack {
            ZStack {
                colorTheme.appBackground.ignoresSafeArea()
                Form {
                Section("menu.section.appearance") {
                    VStack(spacing: 8) {
                        HStack {
                            Text("menu.brightness")
                            Spacer()
                            Text("\(Int(brightness * 100))%").foregroundStyle(.secondary)
                        }
                        Slider(value: $brightness, in: 0...1)
                            .onChange(of: brightness) { _, newValue in
                                UIScreen.main.brightness = newValue
                            }
                    }
                    // Color theme cards (Apple Books style). The Aa preview renders
                    // in the CURRENT title font style, so switching Modern/Antique
                    // below updates the cards live.
                    HStack(spacing: 12) {
                        ForEach(ColorTheme.allCases) { theme in
                            ThemeCardButton(
                                theme: theme,
                                isSelected: theme == colorTheme,
                                titleFontStyle: titleFontStyle
                            ) {
                                colorThemeRaw = theme.rawValue
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    // Full-width row separator: without this the system aligns the
                    // separator to the first text inside the row (card captions),
                    // producing a short indented divider.
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    // Menu + custom collapsed label instead of a bare Picker: the
                    // Pushed sub-pages (same pattern as Default translation /
                    // Launch behavior): the in-row Menu approach clipped its label
                    // on device no matter how it was hosted — NavigationLink +
                    // LabeledContent is the reliable native rendering.
                    NavigationLink {
                        AppearanceModePickerView(selectedRaw: $appearanceModeRaw)
                    } label: {
                        LabeledContent("menu.appearance_mode") {
                            HStack(spacing: 5) {
                                Image(systemName: appearanceMode.systemImage)
                                Text(appearanceMode.labelKey)
                            }
                        }
                    }
                    NavigationLink {
                        TitleFontPickerView(selectedRaw: $titleFontStyleRaw)
                    } label: {
                        LabeledContent("menu.title_font") {
                            Text(titleFontStyle.labelKey)
                        }
                    }
                    Toggle("menu.hide_book_covers", isOn: $hideBookCovers)
                        .tint(.appBlue)
                    Toggle("menu.red_letters", isOn: $redLetters)
                        .tint(.appBlue)
                }
                .listRowBackground(colorTheme.cardBackground)
                // Режим і конкретний переклад — ОДИН рядок і один список.
                // Раніше це були дві настройки (режим + значення), і рядок значення
                // доводилось ховати в режимі .lastUsed, бо він переставав керувати.
                // «Останній відкритий» — просто ще один пункт того самого списку.
                Section("menu.section.translation") {
                    NavigationLink {
                        TranslationLaunchPickerView(
                            translations: readerVM.availableTranslations,
                            behaviorRaw: $translationLaunchRaw,
                            fixedId: $defaultTranslationId
                        )
                    } label: {
                        LabeledContent("menu.translation_launch") {
                            translationLaunchValueLabel
                        }
                    }
                }
                .listRowBackground(colorTheme.cardBackground)
                Section("menu.section.reading") {
                    NavigationLink {
                        LaunchBehaviorPickerView(selectedRaw: $launchBehaviorRaw)
                    } label: {
                        LabeledContent("menu.launch_behavior") {
                            Text(launchBehaviorLabel)
                        }
                    }
                }
                .listRowBackground(colorTheme.cardBackground)
                Section("menu.section.app") {
                    NavigationLink {
                        LanguageSettingsView()
                    } label: {
                        LabeledContent("menu.language", value: currentLanguageLabel)
                    }
                    // About — real copy in AboutView (EN/UK, sources & licenses,
                    // Support primary action → DonationView). Closes bug-022/bug-023.
                    NavigationLink("menu.about") {
                        AboutView()
                    }
                }
                .listRowBackground(colorTheme.cardBackground)
                Section("menu.section.support") {
                    NavigationLink {
                        DonationView()
                    } label: {
                        Label("menu.donation", systemImage: "heart")
                    }
                }
                .listRowBackground(colorTheme.cardBackground)
                Section("menu.section.statistics") {
                    Toggle(isOn: $analyticsEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("menu.analytics.toggle_title")
                            Text("menu.analytics.toggle_subtitle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(.appBlue)

                    NavigationLink("menu.privacy") {
                        PrivacyPolicyView()
                    }
                }
                .listRowBackground(colorTheme.cardBackground)
                }
                .scrollContentBackground(.hidden)
                .navigationTitle("tab.menu")
            }
        }
        .id(locale.identifier)
    }
}

// MARK: - ThemeCardButton

/// Apple Books-style theme preview card: a swatch of the theme's reader
/// background with an "Aa" sample rendered in the active title font style.
private struct ThemeCardButton: View {
    let theme: ColorTheme
    let isSelected: Bool
    let titleFontStyle: TitleFontStyle
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppCornerRadius.tile, style: .continuous)
                        .fill(theme.appBackground)
                    Text(verbatim: "Aa")
                        .font(sampleFont)
                        .foregroundStyle(.primary)
                }
                .frame(height: 64)
                .overlay {
                    RoundedRectangle(cornerRadius: AppCornerRadius.tile, style: .continuous)
                        .strokeBorder(
                            // Selection indicator follows the primary label colour
                            // (black in light, white in dark) rather than the brand
                            // blue: the blue read as a third accent competing with
                            // the theme swatches themselves.
                            isSelected ? Color.primary : Color(.separator).opacity(0.5),
                            lineWidth: isSelected ? 2 : 1
                        )
                }
                Text(theme.labelKey)
                    // Same weight in both states — selection is carried by the border
                    // and label colour alone. A weight change also shifted the caption
                    // width between states.
                    .font(.footnote)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }

    private var sampleFont: Font {
        switch titleFontStyle {
        case .modern:  return .system(size: 26, weight: .bold)
        case .antique: return .custom(TitleFontStyle.antiqueFontName, fixedSize: 28)
        }
    }
}

// MARK: - AppearanceModePickerView

struct AppearanceModePickerView: View {
    @Binding var selectedRaw: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorTheme) private var colorTheme

    var body: some View {
        List(AppearanceMode.allCases) { mode in
            // Button (not onTapGesture) → the ENTIRE row is tappable, including
            // the inset margins, with the native highlight — standard iOS feel.
            Button {
                selectedRaw = mode.rawValue
                dismiss()
            } label: {
                HStack {
                    Label(mode.labelKey, systemImage: mode.systemImage)
                        .foregroundStyle(.primary)
                    Spacer()
                    if mode.rawValue == selectedRaw {
                        Image(systemName: "checkmark").foregroundStyle(.appBlue)
                    }
                }
            }
            .themedRow(colorTheme)
        }
        .themedList(colorTheme)
        .navigationTitle("menu.appearance_mode")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - TitleFontPickerView

struct TitleFontPickerView: View {
    @Binding var selectedRaw: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorTheme) private var colorTheme

    var body: some View {
        List(TitleFontStyle.allCases) { style in
            Button {
                selectedRaw = style.rawValue
                dismiss()
            } label: {
                HStack {
                    Text(style.labelKey)
                        .foregroundStyle(.primary)
                    Spacer()
                    if style.rawValue == selectedRaw {
                        Image(systemName: "checkmark").foregroundStyle(.appBlue)
                    }
                }
            }
            .themedRow(colorTheme)
        }
        .themedList(colorTheme)
        .navigationTitle("menu.title_font")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - LaunchBehaviorPickerView

struct LaunchBehaviorPickerView: View {
    @Binding var selectedRaw: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorTheme) private var colorTheme

    private struct Option: Identifiable {
        let behavior: LaunchBehavior
        let titleKey: LocalizedStringKey
        let subtitleKey: LocalizedStringKey
        var id: String { behavior.rawValue }
    }

    private let options: [Option] = [
        Option(behavior: .resume,
               titleKey: "menu.launch.resume",
               subtitleKey: "menu.launch.resume.subtitle"),
        Option(behavior: .lastBookmark,
               titleKey: "menu.launch.last_bookmark",
               subtitleKey: "menu.launch.last_bookmark.subtitle"),
    ]

    var body: some View {
        List(options) { opt in
            Button {
                selectedRaw = opt.behavior.rawValue
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(opt.titleKey).font(.body)
                            .foregroundStyle(.primary)
                        Text(opt.subtitleKey)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if opt.behavior.rawValue == selectedRaw {
                        Image(systemName: "checkmark").foregroundStyle(.appBlue)
                    }
                }
            }
            .themedRow(colorTheme)
        }
        .themedList(colorTheme)
        .navigationTitle("menu.launch_behavior")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - TranslationLaunchPickerView

/// Обʼєднаний вибір «з чим відкривати рідер»: «Останній відкритий» стоїть у списку
/// нарівні з конкретними перекладами.
///
/// Під капотом і далі ДВА ключі (ADR-025): `translationLaunchBehavior` — режим,
/// `defaultTranslationId` — явний вибір. Розділення навмисне й лишається: явний
/// вибір належить до preference і переживає «очистити історію читання», а слід
/// останнього перекладу ефемерний і чиститься разом із позицією. Тому вибір
/// конкретного перекладу пише ОБИДВА ключі — і режим, і значення.
///
/// ⛔ Не плутати з `DefaultTranslationPickerView` — той лишається чистим списком
/// перекладів без «Останнього відкритого», бо його перевикористовує фільтр пошуку.
struct TranslationLaunchPickerView: View {
    let translations: [Translation]
    @Binding var behaviorRaw: String
    @Binding var fixedId: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorTheme) private var colorTheme

    private var behavior: TranslationLaunchBehavior {
        TranslationLaunchBehavior(rawValue: behaviorRaw) ?? .lastUsed
    }

    var body: some View {
        List {
            Section {
                Button {
                    behaviorRaw = TranslationLaunchBehavior.lastUsed.rawValue
                    dismiss()
                } label: {
                    row(title: Text("menu.translation_launch.last_used"),
                        subtitle: Text("menu.translation_launch.last_used.subtitle"),
                        isSelected: behavior == .lastUsed)
                }
                .themedRow(colorTheme)
            }
            Section {
                ForEach(translations) { t in
                    Button {
                        // Порядок важливий лише для читабельності: обидва ключі
                        // пишуться в одному оновленні, гонки тут немає.
                        fixedId = t.id
                        behaviorRaw = TranslationLaunchBehavior.fixed.rawValue
                        dismiss()
                    } label: {
                        row(title: Text(t.name),
                            subtitle: Text(languageLabel(for: t.language)),
                            isSelected: behavior == .fixed && fixedId == t.id)
                    }
                    .themedRow(colorTheme)
                }
            }
        }
        .themedList(colorTheme)
        .navigationTitle("menu.translation_launch")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(title: Text, subtitle: Text, isSelected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                title.font(.body).foregroundStyle(.primary)
                subtitle.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark").foregroundStyle(.appBlue)
            }
        }
    }

    private func languageLabel(for code: String) -> LocalizedStringKey {
        switch code {
        case "uk": return "lang.ukrainian"
        case "ru": return "lang.russian"
        default:   return "lang.english"
        }
    }
}

// MARK: - DefaultTranslationPickerView

struct DefaultTranslationPickerView: View {
    let translations: [Translation]
    @Binding var selectedId: String
    /// Navigation title — default fits the Settings entry point; the search
    /// Translation filter passes its own key when reusing this picker in a sheet.
    var titleKey: LocalizedStringKey = "menu.default_translation"
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorTheme) private var colorTheme

    var body: some View {
        List(translations) { t in
            Button {
                selectedId = t.id
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.name).font(.body)
                            .foregroundStyle(.primary)
                        Text(languageLabel(for: t.language))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if t.id == selectedId {
                        Image(systemName: "checkmark").foregroundStyle(.appBlue)
                    }
                }
            }
            .themedRow(colorTheme)
        }
        .themedList(colorTheme)
        .navigationTitle(titleKey)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func languageLabel(for code: String) -> LocalizedStringKey {
        switch code {
        case "uk": return "lang.ukrainian"
        case "ru": return "lang.russian"
        default:   return "lang.english"
        }
    }
}

#Preview {
    @MainActor in
    MenuView().environmentObject(ReaderViewModel(store: InMemoryUserDataStore()))
}
