// StudySheetDetent.swift
// SourceBible
//
// Custom presentation detent for the Study Mode sheet (spec-study-mode-redesign.md R3).
//
// WHY a custom detent and not .height(value):
// 1. The .sheet(item:) content closure in ReaderView is NOT re-evaluated when
//    the presenter's @State changes — any .height(x) passed from there froze
//    at presentation time.
// 2. Even with the detent declared inside the sheet content, replacing the
//    detents SET ([.height(old)] → [.height(new)]) proved unreliable for an
//    already-presented sheet on device.
// With a custom detent the SET never changes — it is always
// [.custom(StudySheetDetent.self)] — and the system re-RESOLVES height(in:)
// on presentation layout updates. The desired height is delivered through the
// SwiftUI environment (the documented dynamic channel for custom detents:
// `Context` exposes the environment, which is how e.g. dynamicTypeSize-aware
// detents update while the sheet is open).

import SwiftUI

extension EnvironmentValues {
    /// Desired Study Mode sheet height, computed by ReaderViewModel and
    /// injected by VerseBottomSheetView. Read by StudySheetDetent's resolver.
    @Entry var studySheetHeight: CGFloat = 400
}

struct StudySheetDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        min(context.studySheetHeight, context.maxDetentValue)
    }
}

// MARK: - Sheet detent calibration (bug-031)

/// UIKit лягає sheet із кастомним detent'ом ВИЩЕ, ніж `containerHeight − detentHeight`.
/// Ця різниця (Δ) не є універсальною константою: заміряно 2026-08-01 —
/// iOS 26.5 / iPhone 17 = **16.8**, iOS 18.0 / iPhone 16 Pro = **34.0**, тобто вдвічі
/// більше. У межах однієї платформи Δ стала (перевірено на detent'ах 680 і 614).
///
/// Замість того щоб плодити `#available`-гілки під кожну нову ОС і клас пристрою,
/// значення **вимірюється в рантаймі**: сид дає правильну геометрію з першого кадру,
/// а перше ж реальне вимірювання його підтверджує або виправляє. На незнайомій
/// комбінації ОС/пристрою система підлаштовується сама, без правок коду.
///
/// Корекція застосовується з НАСТУПНОЇ презентації sheet'а — свідомо, щоб не
/// пересмикувати вже відкриту картку під пальцем користувача.
@MainActor
enum SheetDetentCalibration {

    /// Сид: заміряні значення. Правильні для відомих конфігурацій, тож у типовому
    /// випадку калібрування нічого не змінює — воно страхує невідомі.
    private static var seeded: CGFloat = {
        if #available(iOS 26, *) { return 16 } else { return 34 }
    }()

    private static var measured: CGFloat?

    /// Замір із ПОПЕРЕДНЬОГО запуску. Без цього на пристрої, де реальна Δ
    /// відрізняється від сида (напр. iPhone SE), ПЕРШИЙ sheet кожного запуску
    /// малювався з хибною геометрією, а виправлявся лише з другого — помітно оку.
    /// Тепер хибним може бути щонайбільше найперший sheet після встановлення.
    ///
    /// Значення привʼязане до версії ОС: оновлення системи цілком може змінити
    /// лейаут sheet'а, і тоді старий замір треба відкинути, а не тягнути далі.
    private static var persisted: CGFloat? = {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: AppStorageKeys.sheetDetentTopOffsetOSBuild)
                == UIDevice.current.systemVersion,
              defaults.object(forKey: AppStorageKeys.sheetDetentTopOffset) != nil
        else { return nil }
        let value = CGFloat(defaults.double(forKey: AppStorageKeys.sheetDetentTopOffset))
        return (value >= 0 && value <= 120) ? value : nil
    }()

    /// Поправка, якою користується `ReaderViewModel.detentTopOffset`.
    /// Порядок: замір цієї сесії → замір минулого запуску → сид платформи.
    static var offset: CGFloat { measured ?? persisted ?? seeded }

    /// Записати заміряну Δ. Ігнорує сміття (від'ємні / абсурдно великі значення) і
    /// дрібні коливання ±1 pt, щоб не ганяти геометрію туди-сюди.
    static func record(_ delta: CGFloat) {
        guard delta.isFinite, delta >= 0, delta <= 120 else { return }
        // Порівнюємо з ЧИННИМ значенням (`offset`), а не з попереднім заміром.
        // Інакше перший же запис проходив би завжди — і на відомій конфігурації
        // зсував би геометрію на дрібницю без потреби (iOS 26: сид 16, замір 16.8).
        // Поріг 1 pt: нижче нього різниця невідчутна, а перекладати через неї
        // лейаут — гарантований мікро-джиттер.
        if abs(offset - delta) < 1 { return }
        measured = delta
        UserDefaults.standard.set(Double(delta), forKey: AppStorageKeys.sheetDetentTopOffset)
        UserDefaults.standard.set(UIDevice.current.systemVersion,
                                  forKey: AppStorageKeys.sheetDetentTopOffsetOSBuild)
    }
}

// MARK: - UIKit detent applier

/// Drives the sheet height at the UIKit level, bypassing SwiftUI's detent
/// plumbing entirely. On device, neither replacing a SwiftUI .height set nor
/// invalidateDetents()-driven re-resolution of a custom detent resized the
/// open sheet — so this zero-size representable finds the hosting
/// UISheetPresentationController via the responder chain and SETS
/// `sheet.detents` directly to a UIKit custom detent with the desired height,
/// animated via animateChanges. The only dependency left is the verse
/// measurement itself.
struct StudySheetDetentApplier: UIViewRepresentable {
    let height: CGFloat

    func makeUIView(context: Context) -> ApplierView {
        DebugTiming.mark("StudySheetDetentApplier.makeUIView")
        let v = ApplierView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ uiView: ApplierView, context: Context) {
        uiView.desiredHeight = height
    }

    @MainActor
    final class ApplierView: UIView {
        var desiredHeight: CGFloat = 0 {
            didSet {
                guard abs(desiredHeight - oldValue) > 0.5 else { return }
                apply(animated: true)
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            DebugTiming.mark("ApplierView.didMoveToWindow (window=\(window != nil))")
            // First moment the responder chain reaches the presented VC.
            apply(animated: false)
        }

        /// Identifier of the detent this applier installs. Also the value written to
        /// `largestUndimmedDetentIdentifier` — see `apply(animated:)`.
        private static let detentID = UISheetPresentationController.Detent.Identifier("studySheet")

        private func apply(animated: Bool) {
            DebugTiming.mark("apply(animated: \(animated)) ENTRY")
            guard desiredHeight > 0, let sheet = sheetController() else {
                DebugTiming.mark("apply EARLY RETURN (no sheetController / height<=0)")
                return
            }
            let h = desiredHeight
            let id = Self.detentID
            // NOTE: the resolver captures ONLY `h` — never `sheet`. Capturing the
            // UISheetPresentationController here would form a retain cycle
            // (sheet → detents → resolver → sheet), because this closure is stored
            // on `sheet.detents` below. Keep it that way.
            let detent = UISheetPresentationController.Detent.custom(identifier: id) { context in
                min(h, context.maximumDetentValue)
            }
            // ⛔ bug-030 — BOTH assignments must stay together, in this order.
            //
            // `largestUndimmedDetentIdentifier` is what actually makes the sheet
            // non-modal: undimmed background + touches passed through to the
            // presenter + no tap-outside-to-dismiss. UIKit honours it ONLY when the
            // identifier names a detent that is present in `sheet.detents`.
            //
            // SwiftUI's `.presentationBackgroundInteraction(.enabled)` in ReaderView
            // sets it to ITS OWN detent id (`.custom(StudySheetDetent.self)`). The
            // line below then replaces the whole set with `id` — orphaning SwiftUI's
            // identifier, so UIKit silently ignored it. Result on iOS 18: dimming
            // stayed (over the pinned verse) and a tap on the toolbar chevrons was
            // read as "outside the sheet" and dismissed it instead of navigating
            // verses. Re-asserting the id here is what closes that gap.
            let applyChanges = {
                sheet.detents = [detent]
                sheet.largestUndimmedDetentIdentifier = id
            }
            if animated {
                sheet.animateChanges(applyChanges)
            } else {
                applyChanges()
            }
            DebugTiming.mark("apply(animated: \(animated)) DID SET sheet.detents")
            // Калібрування (bug-031): після того як лейаут осів, зміряти РЕАЛЬНИЙ
            // top sheet'а і зберегти різницю з розрахунковим. Наступна презентація
            // використає заміряне значення. Нічого не малює й не рухає зараз.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                self.calibrate()
            }
        }

        /// Вимірює Δ = computedTop − realTop і віддає її `SheetDetentCalibration`.
        private func calibrate() {
            guard desiredHeight > 0,
                  let sheet = sheetController(),
                  let container = sheet.containerView,
                  let presented = sheet.presentedView else { return }
            let realTop = container.convert(presented.bounds, from: presented).origin.y
            let computedTop = container.bounds.height - desiredHeight
            SheetDetentCalibration.record(computedTop - realTop)
        }

        private func sheetController() -> UISheetPresentationController? {
            var responder: UIResponder? = self
            while let r = responder {
                if let vc = r as? UIViewController {
                    return vc.sheetPresentationController
                }
                responder = r.next
            }
            return nil
        }
    }
}
