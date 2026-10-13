// LaunchGate.swift
// SourceBible
//
// Стан оверлея запуску (LaunchOverlay.swift). Лежить у ViewModels, бо це
// спільний стан, а не в'ю: ContentView передає сюди сигнал «перший розділ
// готовий» (ReaderViewModel.hasLoadedInitialChapter), AnalyticsConsentModifier
// чекає, поки оверлей зникне.

import Combine
import Foundation

/// Спільний стан оверлея: ContentView ховає його, AnalyticsConsentModifier
/// чекає на нього, щоб картка згоди з'явилась ПІСЛЯ оверлея, а не поверх лого.
@MainActor
final class LaunchGate: ObservableObject {
    @Published private(set) var isOverlayVisible = true

    /// Мінімальний час показу лого, рахуючи від СТАРТУ ПРОЦЕСУ (тобто разом
    /// із системним launch screen). Без нього на швидкому старті лого лише
    /// блимало на частку секунди. Якщо завантаження довше — зникає одразу,
    /// щойно розділ готовий, без додаткової паузи.
    static let minimumVisibleDuration: TimeInterval = 1.0

    private let processStart: Date = LaunchGate.processStartDate() ?? Date()
    private var dismissScheduled = false

    func dismissOverlay() {
        guard isOverlayVisible, !dismissScheduled else { return }
        dismissScheduled = true
        let remaining = Self.minimumVisibleDuration - Date().timeIntervalSince(processStart)
        guard remaining > 0 else {
            isOverlayVisible = false
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(remaining))
            isOverlayVisible = false
        }
    }

    /// Час старту процесу з ядра (`kinfo_proc.p_starttime`). Точніший за час
    /// `init` застосунку: враховує dyld і системний launch screen.
    private static func processStartDate() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }
}
