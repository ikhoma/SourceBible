// AnalyticsConsentCard.swift
// SourceBible
//
// One-time bottom sheet shown on first launch asking the user to share
// anonymous usage data.
//
// Persistence:
//   - "analyticsConsentShown"  (Bool) — true after shown once, never show again
//   - "analyticsEnabled"       (Bool) — user's live choice; дефолт регіональний
//
// ⚠️ ЗГОДА МУСИТЬ БУТИ ЯВНОЮ (перероблено 2026-08-03).
//
// Було дві нечесності, обидві виправлені тут:
//
// 1. Кнопка казала «Не зараз», але `analyticsConsentShown` виставляється в
//    момент ПОКАЗУ, тож екран більше ніколи не зʼявлявся. «Не зараз» де-факто
//    означало «ніколи». Тепер текст = поведінці: «Не ділитися», питаємо один
//    раз, шлях назад — перемикач у Меню.
//
// 2. Свайп вниз не чіпав `analyticsEnabled`, тобто закрити не читаючи
//    означало лишити дефолт — а дефолт міг бути ON. Мовчазної згоди бути не
//    може, тож `onDismiss` тепер пише значення ЗАВЖДИ.
//
// ⚠️ ЩО САМЕ пише — залежить від регіону (PDR D6, `AnalyticsConsentPolicy`):
//    ЄЕЗ/GB → `false` (немає affirmative action — немає згоди).
//    Решта світу → `true` (картка там ПОВІДОМЛЯЄ, а не питає; закрити ≠ відмовити,
//    відмова живе на кнопці «Не ділитися» і в Меню).
//
// ⛔ І в жодному разі не «лишити як є, нічого не писати». Ключ мусить існувати
//    після картки в ОБОХ гілках, інакше дефолт переобчислюється на кожному
//    запуску, і згода тихо перемкнеться, щойно людина змінить Region у Settings.
//    Написане один раз — залипає, і це навмисно.
//
// ⛔ Не прибирати `onDismiss` і не покладатись на дефолт у цьому шляху —
// це поверне пункт 2.

import SwiftUI

// MARK: - Consent Card

struct AnalyticsConsentCard: View {
    @Binding var isPresented: Bool
    /// Ставиться лише явним тапом. Усе решта (свайп, тап поза шітом) — відмова.
    @Binding var decisionMade: Bool
    @AppStorage(AppStorageKeys.analyticsEnabled) private var analyticsEnabled: Bool = AnalyticsConsentPolicy.defaultConsent

    var body: some View {
        VStack(spacing: 16) {
            // Образ замість стіни тексту: за пів секунди видно, про що мова,
            // ще до читання.
            //
            // 48 pt + `.quaternary` — навмисно ті самі значення, що в empty-state'ах
            // (`NotesListView` / `BookmarksListView` / `CrossRefsView`), щоб великі
            // символи в застосунку виглядали як один прийом, а не як три різні.
            //
            // padding(.bottom, 8) + spacing 16 = 24 знизу, рівно стільки ж, скільки
            // дає верхній `.padding(24)` картки. Зазори навколо іконки симетричні.
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)
                .padding(.bottom, 8)
                .accessibilityHidden(true)   // суто декоративний

            Text("analytics.consent.title")
                .font(.title2)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            // Лінк на політику вшитий у речення (markdown у LocalizedStringKey),
            // а не окремим рядком: окремо він читався як третя кнопка й тягнув
            // увагу на себе. `.tint` задає колір лінка — `.foregroundStyle`
            // фарбує лише звичайний текст.
            Text("analytics.consent.body")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .tint(.appBlue)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            // Ієрархія дій: залита кнопка + текстова, а не дві однакові.
            // Раніше обидві мали підкладку, і з першого погляду не читалось,
            // яка з них основна.
            VStack(spacing: 4) {
                if #available(iOS 26, *) {
                    acceptButton.buttonStyle(.glassProminent)
                } else {
                    acceptButton.buttonStyle(.borderedProminent).legacyCapsuleButton()
                }
                declineButton
            }
            .padding(.top, 4)
        }
        .padding(24)
        .padding(.bottom, 8)
        // Запобіжник: забороняє тексту стискатись у «…», якщо детент раптом
        // виявиться меншим за потрібну висоту (довший переклад, більший шрифт
        // Dynamic Type). Краще, щоб картка чесно вилізла за межі й це побачили,
        // ніж щоб половина пояснення тихо зникла в трьох крапках.
        .fixedSize(horizontal: false, vertical: true)
    }

    // Accept action WITHOUT its buttonStyle, so the surface can branch by OS.
    // .foregroundStyle(.white): the system auto-contrast on .appBlue (#3085CF)
    // picks a black label in dark mode; the correct color on an accent capsule
    // is white, matching the system's own prominent buttons.
    private var acceptButton: some View {
        Button {
            analyticsEnabled = true
            decisionMade = true
            isPresented = false
        } label: {
            Text("analytics.consent.accept")
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .tint(.appBlue)
    }

    // Тиха текстова дія без підкладки — щоб основна кнопка читалась основною.
    // Повна ширина збережена заради зони дотику, не заради ваги.
    private var declineButton: some View {
        Button {
            analyticsEnabled = false
            decisionMade = true
            isPresented = false
        } label: {
            Text("analytics.consent.decline")
                .font(.body)
                .foregroundStyle(.appBlue)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Consent Modifier
//
// Usage: attach .analyticsConsentIfNeeded() to the root ContentView.
// Shows the sheet once; never again after that.
//
// Sheet sizing: детент рахується з прихованої копії картки поза шітом.
// Деталі й граблі — у доккоментарі `heightProbe` нижче.
//
// `.presentationSizing(.fitted)` (iOS 18+) тут не підходить: на iPhone він
// розтягує шіт майже на весь екран замість обгортання вмісту (перевірено).
//
// Corner radius: not set — iOS 26 floating partial sheets automatically
// use the device's rounded-corner radius. Explicit values looked "off".

struct AnalyticsConsentModifier: ViewModifier {
    @AppStorage(AppStorageKeys.analyticsConsentShown) private var consentShown: Bool = false
    // Reaches this modifier even though .analyticsConsentIfNeeded() is applied before
    // .environment(\.colorTheme) in SourceBibleApp: the later modifier wraps the chain,
    // so it is an ancestor and the value flows down.
    @Environment(\.colorTheme) private var colorTheme
    @AppStorage(AppStorageKeys.analyticsEnabled) private var analyticsEnabled: Bool = AnalyticsConsentPolicy.defaultConsent
    @State private var showSheet = false
    @State private var sheetHeight: CGFloat = 300
    @State private var decisionMade = false

    /// Згода потрібна, але шіт ще не показано — чекаємо на замір висоти.
    @State private var consentPending = false
    /// Проба вже відпрацювала хоч раз, тобто `sheetHeight` — справжній, а не сід.
    @State private var heightMeasured = false

    /// Невидимий дублікат картки — єдине джерело висоти детента.
    ///
    /// Лежить у `.background` кореневого в'ю, де висота нічим не обмежена, тож
    /// картка повідомляє свою ІДЕАЛЬНУ висоту. Детент правильний уже на першій
    /// появі: без стрибка й без підбору стартового значення.
    ///
    /// ⛔ Не міряти картку, що вже в шіті — це дедлок:
    ///   детент 300 → контент затиснуто до 300 → замір дає 300 → детент 300…
    /// Заміряне значення не може перерости стартове, тож щойно вміст став вищим
    /// за 300, іконку зрізало верхнім краєм шіта.
    ///
    /// ⛔ І не через `PreferenceKey`: преференси з вмісту `.background`/`.overlay`
    /// не піднімаються до батьківського в'ю, тож значення просто не доходило.
    /// `onGeometryChange` (iOS 16.4+, у нас таргет 18) пише прямо в `@State`
    /// і цієї ізоляції не має.
    ///
    /// Патерн: fatbobman «SwiftUI Sheet Auto-Sizing» + Daniel Saidi «size to fit».
    ///
    /// ⛔ Замір сам по собі гонку не вирішує — показ шіта мусить його ДОЧЕКАТИСЬ.
    /// Див. `presentIfReady()`.
    private var heightProbe: some View {
        AnalyticsConsentCard(isPresented: .constant(false),
                             decisionMade: .constant(false))
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                guard height > 0 else { return }
                // ⛔ ПІСЛЯ показу висоту НЕ чіпаємо. Проба живе в корені й може
                // переміряти пізніше (перекладка при завантаженні рідера, осідання
                // скляних кнопок на iOS 26, зміна Dynamic Type). Кожен такий апдейт
                // після показу = зміна детента у відкритого шіта, тобто рівно той
                // стрибок, який ми ловимо. Детент фіксується один раз — перед показом.
                guard !showSheet else { return }
                sheetHeight = height
                heightMeasured = true
                presentIfReady()
            }
            .hidden()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Шіт показуємо ЛИШЕ коли висота вже заміряна.
    ///
    /// ⛔ ГОНКА, через яку шіт підстрибував. `onAppear` кореневого в'ю і
    /// `onGeometryChange` проби — дві незалежні події, порядок між ними не
    /// гарантований. Виграє проба — детент одразу правильний; виграє `onAppear` —
    /// шіт презентується з сідовими 300, потім детент стрибає на заміряні 388,
    /// а контент, що був затиснутий у 300, переїжджає вдруге.
    ///
    /// Саме тому баг «то є, то немає»: у симуляторі проба зазвичай встигає перша
    /// (заміряно `probe=388 | present@388`), а на холодному старті пристрою —
    /// не завжди.
    private func presentIfReady() {
        guard consentPending, heightMeasured else { return }
        consentPending = false
        consentShown = true
        // ⛔ Показ ВІДКЛАДАЄМО на наступний тік.
        //
        // `presentIfReady()` викликається з `onGeometryChange`, тобто ПІД ЧАС
        // розкладки. Виставити `showSheet` прямо там означає почати презентацію
        // в тому самому проході, у якому щойно змінився `sheetHeight`: UIKit
        // забирає детент до того, як зміна докотилась, тож перший кадр шіта
        // виїжджає зі старою висотою й одразу підганяється під нову.
        //
        // Саме тому замір показував ідеальні числа (`p388 SHOW@388`, `inner: 388`),
        // а на екрані стрибало: у трейсі — намір, на екрані — те, що UIKit устиг
        // прочитати. Один тік затримки прибирає розбіжність.
        Task { @MainActor in showSheet = true }
    }

    func body(content: Content) -> some View {
        content
            .background(alignment: .top) { heightProbe }
            .onAppear {
                guard !consentShown else { return }
                consentPending = true
                presentIfReady()
            }
            // Страхувальна сітка: якщо заміру так і не сталося, показуємо шіт із
            // сідовою висотою. Стрибок неприємний, але мовчки НЕ спитати згоду —
            // гірше: `analyticsConsentShown` виставляється лише разом із показом,
            // тож без цієї гілки користувача не спитали б ніколи.
            .task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if consentPending {
                    heightMeasured = true
                    presentIfReady()
                }
            }
            // onDismiss ловить свайп вниз і тап поза шітом. Пишемо регіональний
            // дефолт ЯВНО — не лишаємо ключ порожнім. Див. пункт 2 у шапці файлу.
            .sheet(isPresented: $showSheet, onDismiss: {
                if !decisionMade { analyticsEnabled = AnalyticsConsentPolicy.defaultConsent }
            }) {
                AnalyticsConsentCard(isPresented: $showSheet, decisionMade: $decisionMade)
                    .presentationDetents([.height(sheetHeight)])
                    .presentationDragIndicator(.visible)
                    .themedSheet(colorTheme)
            }
    }
}

extension View {
    func analyticsConsentIfNeeded() -> some View {
        modifier(AnalyticsConsentModifier())
    }
}
