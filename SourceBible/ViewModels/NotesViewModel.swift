// NotesViewModel.swift
// SourceBible

import Foundation
import Combine

@MainActor
final class NotesViewModel: ObservableObject {

    @Published var notes:   [NoteWithBlocks] = []
    @Published var folders: [NoteFolder]     = []

    // Editor sheet state
    @Published var isEditorPresented = false
    @Published var editingNote: NoteWithBlocks? = nil

    private let store:       UserDataStoreProtocol
    private let authService: AuthServiceProtocol

    // Analytics (Slice 3): injected via view .task — default noop so VM is
    // usable in previews and unit tests without an analytics service wired up.
    var analytics:      any AnalyticsService = NoopAnalytics.shared
    var sessionTracker: SessionTracker       = .noop

    init(store: UserDataStoreProtocol,
         authService: AuthServiceProtocol) {
        self.store       = store
        self.authService = authService
        refresh()
    }

    // MARK: - Data

    func refresh() {
        notes   = store.notes(folderId: nil)
        folders = store.folders()
    }

    // MARK: - Public accessors

    var authUserId: String { authService.userId }

    // MARK: - Editor

    /// Called from VerseBottomSheetView "Нотатка" button.
    /// Only sets editingNote — does NOT set isEditorPresented.
    /// VerseBottomSheetView owns its own sheet slot (activeEditor) and must
    /// present the editor itself. Setting isEditorPresented here would trigger
    /// NotesListView's sheet simultaneously, causing SwiftUI to collapse the
    /// bottom sheet.
    @discardableResult
    func openNewNote(attachedTo verse: BibleVerse, translation: String) -> NoteWithBlocks {
        let now    = Date()
        let noteId = UUID().uuidString

        let note = Note(
            id: noteId, userId: authService.userId, folderId: nil,
            createdAt: now, updatedAt: now, deletedAt: nil, isDirty: true)

        let verseContent = VerseBlockContent(
            verseId: verse.id, translationId: translation, text: verse.text)
        let verseJSON = (try? JSONEncoder().encode(verseContent))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        let verseBlock = NoteBlock(
            id: UUID().uuidString, noteId: noteId, position: 0,
            type: .verse, verseId: verse.id, strongsId: nil, content: verseJSON,
            createdAt: now, updatedAt: now)

        let textJSON = (try? JSONEncoder().encode(TextBlockContent(body: "")))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"body\":\"\"}"

        let textBlock = NoteBlock(
            id: UUID().uuidString, noteId: noteId, position: 1,
            type: .text, verseId: nil, strongsId: nil, content: textJSON,
            createdAt: now, updatedAt: now)

        let noteWithBlocks = NoteWithBlocks(note: note, blocks: [verseBlock, textBlock],
                                            verseIds: [verse.id])
        editingNote = noteWithBlocks
        return noteWithBlocks
    }

    func openNewNote() {
        let now    = Date()
        let noteId = UUID().uuidString
        let note   = Note(
            id: noteId, userId: authService.userId, folderId: nil,
            createdAt: now, updatedAt: now, deletedAt: nil, isDirty: true)
        let textJSON = (try? JSONEncoder().encode(TextBlockContent(body: "")))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"body\":\"\"}"
        let textBlock = NoteBlock(
            id: UUID().uuidString, noteId: noteId, position: 0,
            type: .text, verseId: nil, strongsId: nil, content: textJSON,
            createdAt: now, updatedAt: now)
        editingNote       = NoteWithBlocks(note: note, blocks: [textBlock], verseIds: [])
        isEditorPresented = true
    }

    func openEdit(note: NoteWithBlocks) {
        editingNote       = note
        isEditorPresented = true
    }

    // MARK: - CRUD

    func save(note: Note, blocks: [NoteBlock], verseIds: [String]) {
        // Detect new note BEFORE saving (the ID won't be in the current list yet).
        let isNew = !notes.contains(where: { $0.note.id == note.id })
        store.saveNote(note, blocks: blocks, verseIds: verseIds)
        refresh()
        // Analytics: discrete note_created + aggregate annotation counter (Slice 3 §C).
        if isNew {
            analytics.track(.noteCreated)
            sessionTracker.incAnnotation()
        }
    }

    func deleteNote(id: String) {
        store.deleteNote(id: id)
        refresh()
    }

    func saveFolder(_ folder: NoteFolder) {
        store.saveFolder(folder)
        refresh()
    }

    func deleteFolder(id: String) {
        store.deleteFolder(id: id)
        refresh()
    }
}
