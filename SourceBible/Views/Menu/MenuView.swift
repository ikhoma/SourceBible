// MenuView.swift
// SourceBible

import SwiftUI

struct MenuView: View {
    @State private var fontSize: Double = 17
    @State private var isDark = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Читання") {
                    HStack {
                        Text("Розмір шрифту")
                        Spacer()
                        Text("\(Int(fontSize))").foregroundStyle(.secondary)
                    }
                    Slider(value: $fontSize, in: 13...24, step: 1)
                    Toggle("Темна тема", isOn: $isDark)
                }
                Section("Переклад") {
                    NavigationLink("Переклад за замовчуванням") { Text("Вибір перекладу") }
                }
                Section("Застосунок") {
                    NavigationLink("Мова інтерфейсу") { Text("Вибір мови") }
                    NavigationLink("Про застосунок")  { Text("Source Bible v1.0") }
                }
            }
            .navigationTitle("Меню")
        }
    }
}

#Preview { MenuView() }
