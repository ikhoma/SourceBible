// MenuView.swift
// SourceBible

import SwiftUI

struct MenuView: View {
    @EnvironmentObject var readerVM: ReaderViewModel
    @State private var brightness: Double = Double(UIScreen.main.brightness)
    @AppStorage(AppStorageKeys.isDarkMode) private var isDark = false
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
                Color("appBackground").ignoresSafeArea()
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
                    Toggle("menu.dark_theme", isOn: $isDark)
                        .tint(.appBlue)
                    Toggle("menu.hide_book_covers", isOn: $hideBookCovers)
                        .tint(.appBlue)
                    Toggle("menu.red_letters", isOn: $redLetters)
                        .tint(.appBlue)
                }
                .listRowBackground(Color("cardBackground"))
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
                .listRowBackground(Color("cardBackground"))
                Section("menu.section.reading") {
                    NavigationLink {
                        LaunchBehaviorPickerView(selectedRaw: $launchBehaviorRaw)
                    } label: {
                        LabeledContent("menu.launch_behavior") {
                            Text(launchBehaviorLabel)
                        }
                    }
                }
                .listRowBackground(Color("cardBackground"))
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
                .listRowBackground(Color("cardBackground"))
                Section {
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
                .listRowBackground(Color("cardBackground"))
                }
                .scrollContentBackground(.hidden)
                .navigationTitle("tab.menu")
            }
        }
        .id(locale.identifier)
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
        .navigationTitle("menu.default_translation")
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
