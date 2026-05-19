// SyncEngine.swift
// SourceBible
//
// v1 + v1.5: NoOpSyncEngine — does nothing.
// v2:        Swap in SupabaseSyncEngine (dirty queue, 5-second batches, pull on launch).

import Foundation

// MARK: - Protocol

protocol SyncEngineProtocol: AnyObject {
    /// Start background sync (e.g. on app foreground).
    func start()
    /// Stop background sync (e.g. on app background).
    func stop()
    /// Trigger an immediate full sync cycle.
    func syncNow() async
}

// MARK: - v1 + v1.5 NoOp implementation

final class NoOpSyncEngine: SyncEngineProtocol {

    static let shared = NoOpSyncEngine()
    private init() {}

    func start() {}
    func stop() {}
    func syncNow() async {}
}
