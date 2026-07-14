// NoteEditorView.swift
// SourceBible

import SwiftUI

struct NoteEditorView: View {

    @EnvironmentObject private var notesVM:   NotesViewModel
    @EnvironmentObject private var router:    AppNavigationRouter
    @EnvironmentObject private var readerVM:  ReaderViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorTheme) private var colorTheme

    @State private var noteWithBlocks: NoteWithBlocks
    @State private var textBody: String
    @State private var editorHeight: CGFloat = 44

    init(noteWithBlocks: NoteWithBlocks) {
        _noteWithBlocks = State(initialValue: noteWithBlocks)
        let body = noteWithBlocks.blocks
            .first(where: { $0.type == .text })
            .flatMap { try? JSONDecoder().decode(TextBlockContent.self,
                                                 from: Data($0.content.utf8)) }
            .map(\.body) ?? ""
        _textBody = State(initialValue: body)
    }

    var body: some View {
        // No NavigationStack — UINavigationController inside a sheet interferes
        // with the UITextView responder chain and can suppress keyboard on iOS 16+.
        VStack(spacing: 0) {

            // Manual navigation bar
            HStack {
                Button("action.cancel") { dismiss() }
                    .foregroundStyle(.primary)
                Spacer()
                Text(navigationTitle)
                    .font(.headline)
                Spacer()
                Button("note.editor.save") { saveAndDismiss() }
                    .bold()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {

                    // Verse context card(s) — tap to jump to that verse in the Reader
                    ForEach(verseBlocks, id: \.id) { block in
                        if let content = decodeVerseBlock(block) {
                            VerseContextCard(verseId: content.verseId, text: content.text)
                                .onTapGesture {
                                    dismiss()
                                    router.requestNavigation(to: content.verseId)
                                }
                        }
                    }

                    // Note text editor — plain, no background; auto-sizes to content
                    NoteTextEditor(text: $textBody, contentHeight: $editorHeight)
                        .frame(height: editorHeight)
                        .padding(.vertical, 4)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 16)
            }
        }
        // Applied HERE, not at the call sites: this editor is presented from both
        // NotesListView and VerseBottomSheetView, so a call-site fix would only
        // theme one of them. The inner UITextView is already .clear.
        .themedSheet(colorTheme)
    }

    // MARK: - Helpers

    private var verseBlocks: [NoteBlock] {
        noteWithBlocks.blocks.filter { $0.type == .verse }
    }

    private var navigationTitle: String {
        if let block = verseBlocks.first,
           let content = decodeVerseBlock(block) {
            return verseRef(from: content.verseId)
        }
        return NSLocalizedString("action.note", comment: "")
    }

    private func decodeVerseBlock(_ block: NoteBlock) -> VerseBlockContent? {
        try? JSONDecoder().decode(VerseBlockContent.self,
                                  from: Data(block.content.utf8))
    }

    private func verseRef(from verseId: String) -> String {
        let parts = verseId.split(separator: "|")
        guard parts.count == 3 else { return verseId }
        let short = readerVM.shortBookName(for: String(parts[0]))
        return "\(short) \(parts[1]):\(parts[2])"
    }

    private func saveAndDismiss() {
        var updatedBlocks = noteWithBlocks.blocks
        if let idx = updatedBlocks.firstIndex(where: { $0.type == .text }) {
            let encoded = (try? JSONEncoder().encode(TextBlockContent(body: textBody)))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"body\":\"\"}"
            updatedBlocks[idx].content   = encoded
            updatedBlocks[idx].updatedAt = Date()
        }
        var note = noteWithBlocks.note
        note.updatedAt = Date()
        note.isDirty   = true
        notesVM.save(note: note,
                     blocks: updatedBlocks,
                     verseIds: noteWithBlocks.verseIds)
        dismiss()
    }
}

// MARK: - UIKit text editor
// SwiftUI @FocusState is unreliable in nested sheets (sheet-on-sheet).
// UIViewControllerRepresentable is used so we can call becomeFirstResponder()
// inside viewDidAppear(_:), which fires after the sheet animation completes —
// the only reliable UIKit lifecycle hook for this purpose.
// (A fixed DispatchQueue delay was the previous approach but proved fragile
//  across iOS 16/17/18 where sheet animation timing changed.)

private struct NoteTextEditor: UIViewControllerRepresentable {
    @Binding var text: String
    @Binding var contentHeight: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, contentHeight: $contentHeight) }

    func makeUIViewController(context: Context) -> NoteEditorHostController {
        let vc = NoteEditorHostController()
        vc.coordinator       = context.coordinator
        vc.initialText       = text
        vc.onLayoutCallback  = context.coordinator.updateHeight
        return vc
    }

    func updateUIViewController(_ vc: NoteEditorHostController, context: Context) {
        guard !context.coordinator.isEditing else { return }
        if let tv = vc.textView,
           tv.textColor == .label && tv.text != text {
            tv.text = text
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String
        @Binding var contentHeight: CGFloat
        var isEditing = false

        init(text: Binding<String>, contentHeight: Binding<CGFloat>) {
            _text          = text
            _contentHeight = contentHeight
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            isEditing = true
            if textView.textColor == .tertiaryLabel {
                textView.text      = ""
                textView.textColor = .label
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            isEditing = false
            if textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                textView.text      = NSLocalizedString("notes.editor.placeholder", comment: "")
                textView.textColor = .tertiaryLabel
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.textColor == .tertiaryLabel ? "" : textView.text
            updateHeight(textView)
        }

        func updateHeight(_ textView: UITextView) {
            let size = textView.sizeThatFits(
                CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude))
            let newHeight = max(44, size.height)
            if abs(newHeight - contentHeight) > 0.5 {
                DispatchQueue.main.async { self.contentHeight = newHeight }
            }
        }
    }
}

// MARK: - Host controller for NoteTextEditor

private final class NoteEditorHostController: UIViewController {
    weak var textView: UITextView?
    // Typed as the protocol rather than the private Coordinator nested type,
    // so NoteEditorHostController can be private without a visibility conflict.
    var coordinator: (any UITextViewDelegate)?
    var initialText: String = ""
    /// Called after layout so the Coordinator can report initial height to SwiftUI.
    var onLayoutCallback: ((UITextView) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        let tv = UITextView()
        tv.font              = .preferredFont(forTextStyle: .body)
        tv.backgroundColor   = .clear
        tv.textColor         = .label
        tv.isScrollEnabled   = false   // lets SwiftUI control height via sizeThatFits
        tv.delegate          = coordinator
        tv.translatesAutoresizingMaskIntoConstraints = false

        if initialText.isEmpty {
            tv.text      = NSLocalizedString("notes.editor.placeholder", comment: "")
            tv.textColor = .tertiaryLabel
        } else {
            tv.text = initialText
        }

        view.addSubview(tv)
        NSLayoutConstraint.activate([
            tv.topAnchor.constraint(equalTo: view.topAnchor),
            tv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.textView = tv
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let tv = textView { onLayoutCallback?(tv) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // viewDidAppear fires after the sheet animation completes —
        // this is the correct and reliable moment to claim first responder.
        textView?.becomeFirstResponder()
    }
}

// MARK: - Verse Context Card
// Matches NoteCardView styling exactly: white card, ref label, gray bar, verse text.

private struct VerseContextCard: View {
    let verseId: String
    let text: String

    @EnvironmentObject private var readerVM: ReaderViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ReferenceLabel(refLabel)

            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color(.separator))
                    .frame(width: 4)
                    .padding(.vertical, 2)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.primary)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var refLabel: String {
        let parts = verseId.split(separator: "|")
        guard parts.count == 3 else { return verseId }
        let short = readerVM.shortBookName(for: String(parts[0]))
        return "\(short) \(parts[1]):\(parts[2])"
    }
}

#Preview {
    NoteEditorView(noteWithBlocks: NoteWithBlocks(
        note: Note(id: "1", userId: "u", folderId: nil,
                   createdAt: .now, updatedAt: .now, deletedAt: nil, isDirty: false),
        blocks: [],
        verseIds: []
    ))
    .environmentObject(NotesViewModel(store: InMemoryUserDataStore(),
                                      authService: LocalAuthService.shared))
    .environmentObject(AppNavigationRouter())
    .environmentObject(ReaderViewModel(store: InMemoryUserDataStore()))
}
