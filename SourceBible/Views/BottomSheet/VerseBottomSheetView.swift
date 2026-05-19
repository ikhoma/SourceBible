// VerseBottomSheetView.swift
// SourceBible
//
// Контейнер bottom sheet: шапка, mode tabs, pills row, action bar.
// Вміст вкладок — у VerseTabContent.swift та WordTabContent.swift.

import SwiftUI

struct VerseBottomSheetView: View {

    /// Kept only as a fallback for Xcode Previews.
    /// At runtime the view always reads vm.selectedVerse so navigation updates propagate correctly.
    private let fallbackVerse: BibleVerse
    @EnvironmentObject var vm: ReaderViewModel

    /// Lifted here so the selected pill survives switching to/from word mode.
    @State private var versePill: VersePill = .crossRefs
    @State private var wordSubTab: WordSubTab = .meaning

    init(verse: BibleVerse) {
        self.fallbackVerse = verse
    }

    private var verse: BibleVerse {
        vm.selectedVerse ?? fallbackVerse
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            modeTabs
            pillsRow        // fixed — does not scroll vertically
            Divider()
            ScrollView {   // only content scrolls
                if vm.bottomSheetMode == .verse {
                    VerseTabView(verse: verse, pill: versePill).environmentObject(vm)
                } else {
                    WordTabView(subTab: wordSubTab).environmentObject(vm)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                actionBar
            }
            .background(Color(UIColor.systemBackground))
        }
        .background(Color(UIColor.systemBackground))
    }

    // MARK: - Header

    private var sheetHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if vm.bottomSheetMode == .word {
                    let wordText = vm.selectedWordDisplayText ?? "Слово"
                    Text(wordText).font(.title2).bold()
                } else {
                    Text("\(vm.currentBook.nameShort) \(verse.chapter):\(verse.number)")
                        .font(.title2).bold()
                }
            }

            Spacer()

            HStack(spacing: 0) {
                Button {
                    if vm.bottomSheetMode == .verse { vm.navigateToPreviousVerse() }
                    else { vm.navigateToPreviousWord() }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 40, height: 34)
                }
                .disabled(isPrevDisabled)

                Button {
                    if vm.bottomSheetMode == .verse { vm.navigateToNextVerse() }
                    else { vm.navigateToNextWord() }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 40, height: 34)
                }
                .disabled(isNextDisabled)
            }
            .modifier(CapsuleNavGroupStyle())
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var isPrevDisabled: Bool {
        if vm.bottomSheetMode == .verse {
            return vm.verses.first?.id == verse.id
        } else {
            guard let w = vm.selectedWord else { return true }
            return vm.verseWordsWithStrongs.first?.id == w.id
        }
    }

    private var isNextDisabled: Bool {
        if vm.bottomSheetMode == .verse {
            return vm.verses.last?.id == verse.id
        } else {
            guard let w = vm.selectedWord else { return true }
            return vm.verseWordsWithStrongs.last?.id == w.id
        }
    }

    // MARK: - Mode Tabs

    private var modeTabs: some View {
        Picker("", selection: $vm.bottomSheetMode) {
            Text("Вірш").tag(BottomSheetMode.verse)
            Text("Слово").tag(BottomSheetMode.word)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 20).padding(.vertical, 8)
        .onChange(of: vm.bottomSheetMode) { _, newMode in
            guard newMode == .word else { return }
            vm.autoSelectFirstWordIfNeeded()
        }
    }

    // MARK: - Pills Row

    private var pillsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if vm.bottomSheetMode == .verse {
                    ForEach(VersePill.allCases, id: \.self) { p in
                        pillBtn(p.label, isActive: versePill == p) {
                            withAnimation { versePill = p }
                        }
                    }
                } else {
                    ForEach(WordSubTab.allCases, id: \.self) { t in
                        pillBtn(t.label, isActive: wordSubTab == t) {
                            withAnimation { wordSubTab = t }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.top, 10).padding(.bottom, 12)
    }

    private func pillBtn(_ label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.footnote)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(isActive ? Color(UIColor.label) : Color(UIColor.tertiarySystemFill))
                .foregroundStyle(isActive ? Color(UIColor.systemBackground) : Color(UIColor.label))
                .clipShape(Capsule())
        }
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: 0) {
            actionBtn(icon: "highlighter", label: "Відмітити",
                      isActive: vm.isCurrentVerseHighlighted, color: .green) {
                vm.toggleHighlight(for: verse)
            }
            Divider().frame(height: 32)
            actionBtn(icon: "note.text", label: "Нотатка", isActive: false, color: .blue) {}
            Divider().frame(height: 32)
            actionBtn(icon: "square.and.arrow.up", label: "Поділитись", isActive: false, color: .blue) {}
        }
        .padding(.horizontal, 8).padding(.vertical, 10)
    }

    private func actionBtn(icon: String, label: String, isActive: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 20))
                    .foregroundStyle(isActive ? color : .secondary)
                Text(label).font(.caption2)
                    .foregroundStyle(isActive ? color : .secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 6)
        }
    }
}

#Preview {
    VerseBottomSheetView(verse: BibleVerse.sampleVerses[0])
        .environmentObject(ReaderViewModel())
}
