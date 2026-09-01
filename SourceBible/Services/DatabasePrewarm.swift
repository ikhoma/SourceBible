// DatabasePrewarm.swift
// SourceBible
//
// bug-052: after a fresh (re)install, the OS page cache for the bundled 356 MB
// `sourcebible.db` is completely cold. Only `book`/`translation`/`verse` get touched
// by anything on the launch path (book list, current chapter's text) — `word`,
// `strongs` and `cross_reference` are read for the FIRST time in the process the
// moment the user taps a verse, and that first real disk I/O showed up as the sheet
// itself being slow to invoke.
//
// WHY the whole file, not "just the tables/rows Study Mode needs": a verse's
// cross-references (`DatabaseService.loadCrossReferences`) resolve through
// `verse_org` and then read verse TEXT for whichever book/chapter each reference
// happens to land in — effectively a random location anywhere in the Bible.
// There's no way to predict which pages a given tap will need, so warming only
// "the current chapter" would still leave the cross-reference TARGETS cold.
// A sequential read of the whole file is cheap on flash storage (well under a
// couple of seconds for ~350 MB) and guarantees every later random read — whichever
// table, whichever verse — hits a page the OS already has resident, regardless of
// which verse gets tapped first.
//
// WHY a raw file read, not a second SQLite connection running warm-up SELECTs:
// `DatabaseService`'s own handle is documented single-thread-only (opened with
// `SQLITE_OPEN_NOMUTEX` — see its class comment), so touching it from a background
// thread would race the main thread's own queries. A plain byte-for-byte read of the
// SAME file still populates the OS-level page cache that benefits every connection
// to it, including the shared one, without needing a second SQLite handle at all.
import Foundation

enum DatabasePrewarm {

    private static var started = false

    /// Reads `fileURL` sequentially on a background task, discarding the bytes —
    /// the read itself is the point, not the data. Idempotent and safe to call from
    /// any thread; call once, right after `DatabaseService` opens its own connection,
    /// so this starts as early as possible and has the best chance of finishing
    /// before the user's first tap.
    static func runInBackground(fileURL: URL) {
        guard !started else { return }
        started = true
        DebugTiming.mark("DatabasePrewarm scheduled")
        Task.detached(priority: .utility) {
            DebugTiming.mark("DatabasePrewarm STARTED")
            guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return }
            defer { try? handle.close() }
            // 4 MB chunks: large enough to amortize the read() syscall over a 350 MB
            // file, small enough that nothing is ever retained — each chunk is
            // dropped immediately, so this never holds more than ~4 MB in memory.
            let chunkSize = 4 * 1024 * 1024
            var totalBytes = 0
            while !Task.isCancelled,
                  let chunk = try? handle.read(upToCount: chunkSize),
                  !chunk.isEmpty {
                totalBytes += chunk.count
                // Intentionally empty otherwise: the read is the warm-up, there's
                // nothing to do with the bytes.
            }
            DebugTiming.mark("DatabasePrewarm FINISHED (\(totalBytes / 1_000_000) MB)")
        }
    }
}
