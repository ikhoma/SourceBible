// DebugTiming.swift
// SourceBible
//
// TEMPORARY — bug-052 diagnosis. Pinpoints exactly where the first-tap delay goes
// (tapVerse → sheet vs. loadCrossReferences internals). Safe to delete once the
// investigation is closed; DEBUG-only, no cost in Release.

import Foundation

#if DEBUG
enum DebugTiming: Sendable {
    // nonisolated: called from the deferred main-actor Task work AND from
    // DatabasePrewarm's Task.detached background work — needs to be callable
    // from any thread, and this project defaults unmarked types to @MainActor.
    nonisolated private static let start = CFAbsoluteTimeGetCurrent()

    nonisolated static func mark(_ label: String) {
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print(String(format: "⏱️ bug-052 [%8.1fms] %@", elapsed, label))
    }
}
#else
enum DebugTiming: Sendable {
    nonisolated static func mark(_ label: String) {}
}
#endif
