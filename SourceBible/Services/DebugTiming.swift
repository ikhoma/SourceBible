// DebugTiming.swift
// SourceBible
//
// TEMPORARY — bug-052 diagnosis. Pinpoints exactly where the first-tap delay goes
// (tapVerse → sheet vs. loadCrossReferences internals). Safe to delete once the
// investigation is closed; DEBUG-only, no cost in Release.
//
// Round 4 additions (after hypotheses 1–3 were disproven on device):
//   • `tick` / `time` — aggregated counters+durations for events far too frequent
//     to print one line each (per-verse body evaluations, per-verse TextKit
//     measurement). Flushed at the interesting boundaries only.
//   • `installRunLoopProbe` — two CFRunLoopObservers (one BEFORE CoreAnimation's
//     commit observer, one AFTER it) that report any main-run-loop phase lasting
//     >150 ms. This is what names the phase that CONTAINS the freeze: a stall
//     inside `beforeWaiting/early → beforeWaiting/late` is inside the CATransaction
//     commit (SwiftUI view-graph update + layout); a stall inside
//     `beforeSources → beforeWaiting/early` is inside the touch/gesture delivery.

import Foundation

#if DEBUG
enum DebugTiming: Sendable {
    // nonisolated: called from the deferred main-actor Task work AND from
    // DatabasePrewarm's Task.detached background work — needs to be callable
    // from any thread, and this project defaults unmarked types to @MainActor.
    nonisolated private static let start = CFAbsoluteTimeGetCurrent()

    // @autoclosure: every call site interpolates a string ("...\(x)...") built
    // from live state. Without this, that interpolation is constructed by the
    // CALLER before `mark` is even entered, in every build configuration — the
    // Release stub below never gets a chance to skip it. With @autoclosure the
    // closure is only invoked (and the string only built) here, inside the
    // DEBUG-only body — the Release stub's unused parameter costs nothing.
    nonisolated static func mark(_ label: @autoclosure () -> String) {
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print(String(format: "⏱️ bug-052 [%8.1fms] %@", elapsed, label()))
    }

    // MARK: - Aggregated counters
    //
    // Main-actor isolated on purpose: every call site (SwiftUI bodies,
    // UIViewRepresentable callbacks, UIView.layoutSubviews) is already on the
    // main actor, and that isolation is what makes the shared dictionary safe.

    @MainActor private static var counters: [String: (count: Int, total: Double)] = [:]

    /// Count one occurrence of `key`.
    @MainActor static func tick(_ key: @autoclosure () -> String) {
        let key = key()
        var entry = counters[key] ?? (0, 0)
        entry.count += 1
        counters[key] = entry
    }

    /// Count one occurrence of `key` AND accumulate how long `body` took.
    @MainActor static func time<T>(_ key: @autoclosure () -> String, _ body: () -> T) -> T {
        let t0 = CFAbsoluteTimeGetCurrent()
        let result = body()
        let key = key()
        var entry = counters[key] ?? (0, 0)
        entry.count += 1
        entry.total += CFAbsoluteTimeGetCurrent() - t0
        counters[key] = entry
        return result
    }

    /// Print and RESET every counter. Call at the boundaries that matter, so each
    /// dump covers exactly the window since the previous dump.
    @MainActor static func flushTicks(_ label: @autoclosure () -> String) {
        guard !counters.isEmpty else { return }
        let dump = counters
            .sorted { $0.key < $1.key }
            .map { key, value in
                value.total > 0
                    ? String(format: "%@ ×%d (%.1fms)", key, value.count, value.total * 1000)
                    : "\(key) ×\(value.count)"
            }
            .joined(separator: ", ")
        counters.removeAll()
        let label = label()
        mark("TICKS @ \(label) → \(dump)")
    }

    // MARK: - Main run-loop stall probe

    @MainActor private static var lastPhase = "—"
    @MainActor private static var lastPhaseAt: CFAbsoluteTime = 0
    @MainActor private static var probeInstalled = false

    /// Install once, as early as possible. Reports any >150 ms gap between two
    /// consecutive run-loop observer callbacks, naming the phase it happened in.
    @MainActor static func installRunLoopProbe() {
        guard !probeInstalled else { return }
        probeInstalled = true
        lastPhaseAt = CFAbsoluteTimeGetCurrent()
        // CoreAnimation's commit observer sits at BeforeWaiting order 2_000_000.
        // Bracketing it is what separates "SwiftUI/UIKit commit" from everything else.
        addObserver(order: -2_000_000, tag: "early")
        addObserver(order: 3_000_000, tag: "late")
    }

    @MainActor private static func addObserver(order: CFIndex, tag: String) {
        guard let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.allActivities.rawValue,
            true,
            order,
            { _, activity in
                MainActor.assumeIsolated {
                    note(phase: "\(phaseName(activity))/\(tag)")
                }
            }
        ) else { return }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    @MainActor private static func note(phase: String) {
        let now = CFAbsoluteTimeGetCurrent()
        let gap = (now - lastPhaseAt) * 1000
        let previous = lastPhase
        lastPhase = phase
        lastPhaseAt = now
        // After `beforeWaiting/late` the run loop SLEEPS — a long gap there is an
        // idle app, not a stall. Everything else is real main-thread occupancy.
        guard gap > 150, previous != "beforeWaiting/late" else { return }
        mark(String(format: "RUNLOOP STALL %.1fms — inside [%@], resumed at [%@]",
                    gap, previous, phase))
    }

    nonisolated private static func phaseName(_ activity: CFRunLoopActivity) -> String {
        switch activity {
        case .entry:         return "entry"
        case .beforeTimers:  return "beforeTimers"
        case .beforeSources: return "beforeSources"
        case .beforeWaiting: return "beforeWaiting"
        case .afterWaiting:  return "afterWaiting"
        case .exit:          return "exit"
        default:             return "activity(\(activity.rawValue))"
        }
    }
}
#else
enum DebugTiming: Sendable {
    // @autoclosure here is the actual fix: the caller's string interpolation
    // ("...\(x)...") is never built at all in Release, because the closure
    // that would build it is simply never invoked.
    nonisolated static func mark(_ label: @autoclosure () -> String) {}
    nonisolated static func tick(_ key: @autoclosure () -> String) {}
    nonisolated static func time<T>(_ key: @autoclosure () -> String, _ body: () -> T) -> T { body() }
    nonisolated static func flushTicks(_ label: @autoclosure () -> String) {}
    nonisolated static func installRunLoopProbe() {}
}
#endif
