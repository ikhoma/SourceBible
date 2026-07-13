// MenuView.swift
// SourceBible

import SwiftUI

struct MenuView: View {
    @EnvironmentObject var readerVM: ReaderViewModel
    @State private var brightness: Double = Double(UIScreen.main.brightness)
    @AppStorage(AppStorageKeys.appearanceMode) private var appearanceModeRaw = AppearanceMode.light.rawValue
    @AppStorage(AppStorageKeys.colorTheme) private var colorThemeRaw = ColorTheme.paper.rawValue
    @AppStorage(AppStorageKeys.titleFontStyle) private var titleFontStyleRaw = TitleFontStyle.modern.rawValue
    @AppStorage(AppStorageKeys.hideBookCovers) private var hideBookCovers = false
    @AppStorage(AppStorageKeys.redLetters) private var redLetters = false
    @AppStorage(AppStorageKeys.defaultTranslationId) private var defaultTranslationId: String = "KJV"
    @AppStorage(AppStorageKeys.analyticsEnabled) private var analyticsEnabled: Bool = true
    @Environment(\.locale) private var locale
    @AppStorage(AppStorageKeys.appLanguage) private var appLanguage: String = "en"
    @AppStorage(AppStorageKeys.launchBehavior) private var launchBehaviorRaw = LaunchBehavior.resume.rawValue

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
    private var appearanceMode: AppearanceMode { AppearanceMode(rawValue: appearanceModeRaw) ?? .light }

    private var launchBehaviorLabel: LocalizedStringKey {
        LaunchBehavior(rawValue: launchBehaviorRaw) == .lastBookmark
            ? "menu.launch.last_bookmark" : "menu.launch.resume"
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
                    // default menu-picker renders the selected Label (icon glued to
                    // text) in the primary color. Secondary + explicit spacing keeps
                    // the value column consistent with the LabeledContent rows below.
                    // Row = plain HStack, Menu wraps ONLY the trailing value cluster:
                    // • menu anchors at the trailing edge (not centered over the row),
                    // • the row title stays visible while the menu is up (iOS "lifts"
                    //   the menu source view — wrapping the whole row left it empty),
                    // • no LabeledContent → nothing clips "Match Device" on device.
                    // .font(.body) is explicit: a Menu label does not inherit the
                    // Form row text style and rendered smaller than sibling rows.
                    HStack {
                        Text("menu.appearance_mode")
                        Spacer()
                        Menu {
                            Picker("", selection: $appearanceModeRaw) {
                                ForEach(AppearanceMode.allCases) { mode in
                                    Label(mode.labelKey, systemImage: mode.systemImage)
                                        .tag(mode.rawValue)
                                }
                            }
                            .pickerStyle(.inline)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: appearanceMode.systemImage)
                                Text(appearanceMode.labelKey)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2)
                            }
                            .font(.body)
                            .foregroundStyle(.secondary)
                            // Menu proposes its label LESS than intrinsic width on
                            // device (larger Dynamic Type) and Text CLIPS without an
                            // ellipsis ("Модерний" → "одерний"). fixedSize makes the
                            // content dictate its own width. Values are short and
                            // known — the row cannot overflow.
                            .fixedSize()
                        }
                    }
                    HStack {
                        Text("menu.title_font")
                        Spacer()
                        Menu {
                            Picker("", selection: $titleFontStyleRaw) {
                                ForEach(TitleFontStyle.allCases) { style in
                                    Text(style.labelKey).tag(style.rawValue)
                                }
                            }
                            .pickerStyle(.inline)
                        } label: {
                            HStack(spacing: 5) {
                                Text(titleFontStyle.labelKey)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2)
                            }
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize() // see comment on the Mode row above
                        }
                    }
                    Toggle("menu.hide_book_covers", isOn: $hideBookCovers)
                        .tint(.appBlue)
                    Toggle("menu.red_letters", isOn: $redLetters)
                        .tint(.appBlue)
                }
                .listRowBackground(colorTheme.cardBackground)
                Section("menu.section.translation") {
                    NavigationLink {
                        DefaultTranslationPickerView(
                            translations: readerVM.availableTranslations,
                            selectedId: $defaultTranslationId
                        )
                    } label: {
                        LabeledContent("menu.default_translation",
                                       value: defaultTranslationId)
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
                    NavigationLink("menu.about") {
                        Text("Source Bible v1.0")
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
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(theme.appBackground)
                    Text(verbatim: "Aa")
                        .font(sampleFont)
                        .foregroundStyle(.primary)
                }
                .frame(height: 64)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.appBlue : Color(.separator).opacity(0.5),
                            lineWidth: isSelected ? 2 : 1
                        )
                }
                Text(theme.labelKey)
                    .font(.footnote.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.appBlue : Color.secondary)
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

// MARK: - LaunchBehaviorPickerView

struct LaunchBehaviorPickerView: View {
    @Binding var selectedRaw: String
    @Environment(\.dismiss) private var dismiss

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
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(opt.titleKey).font(.body)
                    Text(opt.subtitleKey)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if opt.behavior.rawValue == selectedRaw {
                    Image(systemName: "checkmark").foregroundStyle(.appBlue)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                selectedRaw = opt.behavior.rawValue
                dismiss()
            }
        }
        .navigationTitle("menu.launch_behavior")
        .navigationBarTitleDisplayMode(.inline)
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

    var body: some View {
        List(translations) { t in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.name).font(.body)
                    Text(languageLabel(for: t.language))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if t.id == selectedId {
                    Image(systemName: "checkmark").foregroundStyle(.appBlue)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                selectedId = t.id
                dismiss()
            }
        }
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
