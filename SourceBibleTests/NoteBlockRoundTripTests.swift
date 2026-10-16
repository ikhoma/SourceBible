// NoteBlockRoundTripTests.swift
// SourceBibleTests
//
// Forward-compat guard for note blocks (commit 6b6f643, LOG 2026-10-16): a block type
// this build doesn't know must survive read → save → read with its raw type AND its
// content untouched. `saveNote` deletes + reinserts every block, so a regression here
// is permanent data loss for users on an older build.

import Foundation
import Testing
@testable import SourceBible

@MainActor
struct NoteBlockRoundTripTests {

    // MARK: Type mapping

    @Test func knownRawValuesMapToTheirCases() {
        #expect(NoteBlockType(rawValue: "text")  == .text)
        #expect(NoteBlockType(rawValue: "verse") == .verse)
        #expect(NoteBlockType(rawValue: "word")  == .word)
        #expect(NoteBlockType(rawValue: "quote") == .quote)
        #expect(NoteBlockType(rawValue: "ai")    == .ai)
    }

    @Test func unknownRawValueIsPreservedNotTurnedIntoText() {
        let t = NoteBlockType(rawValue: "heading")
        #expect(t == .unsupported("heading"))
        #expect(t?.rawValue == "heading")
    }

    // MARK: Codable — bare string, same as the DB column

    @Test func codableUsesTheBareRawString() throws {
        let data = try JSONEncoder().encode([NoteBlockType.text, .unsupported("checklist")])
        #expect(String(decoding: data, as: UTF8.self) == #"["text","checklist"]"#)
        let back = try JSONDecoder().decode([NoteBlockType].self, from: data)
        #expect(back == [.text, .unsupported("checklist")])
    }

    // MARK: Store round-trip (real GRDB, temp file)

    @Test func unsupportedBlockSurvivesSaveAndReload() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-roundtrip-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try GRDBUserDataStore(authService: LocalAuthService.shared, path: path)

        let now = Date()
        let noteId = UUID().uuidString
        let note = Note(id: noteId, userId: LocalAuthService.shared.userId, folderId: nil,
                        createdAt: now, updatedAt: now, deletedAt: nil, isDirty: true)
        let futureContent = #"{"level":2,"text":"From a newer version"}"#
        let blocks = [
            NoteBlock(id: UUID().uuidString, noteId: noteId, position: 0, type: .text,
                      verseId: nil, strongsId: nil, content: #"{"body":"hello"}"#,
                      createdAt: now, updatedAt: now),
            NoteBlock(id: UUID().uuidString, noteId: noteId, position: 1,
                      type: .unsupported("heading"),
                      verseId: nil, strongsId: nil, content: futureContent,
                      createdAt: now, updatedAt: now),
        ]

        store.saveNote(note, blocks: blocks, verseIds: [])
        // Second save of what was read back — what the editor does on «Save».
        let first = try #require(store.note(id: noteId))
        store.saveNote(first.note, blocks: first.blocks, verseIds: first.verseIds)

        let reloaded = try #require(store.note(id: noteId))
        let future = try #require(reloaded.blocks.first { $0.position == 1 })
        #expect(future.type == .unsupported("heading"))
        #expect(future.content == futureContent)
        #expect(reloaded.blocks.count == 2)
    }
}
