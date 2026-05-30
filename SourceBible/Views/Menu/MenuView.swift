// MenuView.swift
// SourceBible

import SwiftUI

struct MenuView: View {
    @State private var fontSize: Double = 17
    @AppStorage("isDarkMode") private var isDark = false
    @Environment(\.locale) private var locale
    @AppStorage("appLanguage") private var appLanguage: String = "en"

    private var currentLanguageLabel: String {
        switch appLanguage {
        case "uk": return "Українська"
        default:   return "English"
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
            Form {
                Section("menu.section.reading") {
                    HStack {
                        Text("menu.font_size")
                        Spacer()
                        Text("\(Int(fontSize))").foregroundStyle(.secondary)
                    }
                    Slider(value: $fontSize, in: 13...24, step: 1)
                    Toggle("menu.dark_theme", isOn: $isDark)
                        .tint(.green)
                }
                Section("menu.section.translation") {
                    NavigationLink("menu.default_translation") {
                        Text("menu.choose_translation")
                    }
                }
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
            }
            .navigationTitle("tab.menu")
        }
        .id(locale.identifier)
    }
}

#Preview { MenuView() }
