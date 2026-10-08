# Minimal Tap-to-Study Onboarding — Spec

**Status:** Draft
**Date:** 2026-09-16
**Type:** Feature spec (UI-only — no ADR: нема нової архітектури, БД-логіки чи структурного рішення)
**Related:** `ADR-035-guided-first-study-onboarding.md` (ширший задум, свідомо НЕ будується зараз — 1.1), `ADR-026-reader-chapter-paging-tabview.md` (UIPageViewController, не TabView — важливо для §5), `spec-study-mode-redesign.md` (механізм, на який вказуємо), `docs/ux/known-design-friction.md`, `docs/ux/feature-requests.md` (ux-005, ux-016)

---

## 1. Проблема

Застосунок не має онбордингу взагалі. Уся цінність продукту сидить за одним нерозказаним жестом — тапом по вірші (`ReaderViewModel.tapVerse(_:)` → Study Mode). Неформальні спостереження Івана (n≈9, самодобірні тестери, НЕ холодна установка — пам'ять проєкту `tester-research-status`) показують, що приблизно **1/3 має тертя саме з цим жестом**; ~2 людини прямо просили якийсь onboarding.

`ADR-035` (guided-first-study, hesed/Вих 34:6) відповідає на ширше питання — «чи розуміє користувач *глибину* інструментів» — і свідомо відкладений до 1.1: серед іншого він блокований невиправленими дефектами даних (омонім H2617, ASV mistag), а доказова база під нього ще не існує (потрібні холодні cold-install інтерв'ю, яких поки не було).

**Звужений бар для релізу 20.09 (рішення Івана, 2026-09-15):** новий користувач розуміє, що вірш тапається. Не більше.

## 2. Рішення

**Один системний `Tip` (TipKit), не кастомний екран.**

- **Тригер:** одразу на першому запуску.
- **Якір:** вірш Бут. 1:1 — реальна дефолтна ціль першого запуску (`target = ("GEN", 1, nil)` вже в `ReaderViewModel`, нічого нового не вигадуємо).
- **Форма:** `popoverTip` (callout зі стрілкою) на рядку вірша, іконка `hand.tap.fill`.
- **Показ рівно один раз:** `MaxDisplayCount(1)`.
- **Ховається назавжди при тапі БУДЬ-ЯКОГО вірша** (не лише Бут. 1:1) — через `Tip.Parameter` + `Rule`, донатиться одним рядком усередині вже наявного `tapVerse(_:)`.
- Liquid Glass на бульбашці — автоматично від системи (iOS 26), вручну не чіпаємо.

## 3. Не-цілі (свідомо звужено — рішення Івана в цій сесії)

- **Жодного контенту ADR-035** (hesed, Вих 34:6, funnel через Original→lexicon→concordance) — лишається недоторканим під 1.1.
- **Жодного другого тултіпа в 20.09.** Обговорено і відкладено:
  - тултіп на лонгтап (word-level jump, `VerseTextView.swift`) — нуль доказів потреби, сиквенс технічно незручний (перший тултіп інвалідується тапом, що ховає рядок під Study Mode Sheet — другому нема де з'явитись без розриву).
  - тултіп на toolbar-шеврони `<>` (verse/word nav у Study Mode) — технічно лягає гладко в `TipGroup(.ordered)` одразу услід за першим (шеврони з'являються в той самий момент, коли перший інвалідується), але так само нуль доказів потреби. **Рішення Івана:** почати з одного тултіпа, дивитись на статистику (§6), додати другим кроком, якщо буде видно потребу. Код лишити розширюваним (одинарний `Tip`, не `TipGroup` — переходити на `TipGroup` тільки коли з'явиться другий тіп, щоб не тягнути зараз зайву абстракцію).
- **Жодного нового custom view.** Тільки штатний `Tip`.
- **Відкрите питання, не вирішую сам:** пункт «Показати підказку знову» в Меню — не додаю. TipKit типово не розрахований на ручний ре-тригер після донації; якщо потрібно — окрема маленька вимога.

## 4. Копірайт

**Фінальна версія (2026-09-16, після ревізії з реального пристрою):**

**EN:** **"Tap any verse"** / "Explore original text, word meanings, commentary, and more."
**UK:** **«Торкніться будь-якого вірша»** / «Дослідіть оригінал, значення слів, коментарі та інше.»

Правки проти першої версії ("Tap a verse" / "Every verse opens up — original text, word meanings, commentary."):
- `a` → `any` (`будь-якого`): знімає двозначність — тултіп заякорений на Бут. 1:1, і "a verse" можна було прочитати як "тапни САМЕ ЦЕЙ вірш", а не "будь-який".
- "Every verse opens up —" → "Explore" (imperative): пряміший, запрошувальний тон; присвійник "its" по дорозі прибрали — без нього коротше й не менш зрозуміло під заголовком "Tap any verse".
- Список закінчили відкрито — "and more" / "та інше" (в UK "інше" саме по собі граматично завершене, на відміну від першого чорнового "and other" без іменника). Свідомо: Study Mode реально має більше, ніж ці три пункти (cross-references), тож це не порожній хайп.

(Проміжна ітерація копірайту з "подив, не інструкція" варіантом, а також закритий варіант без "and more" — обговорювались і відхилені, див. історію спеку.)

## 5. Технічний дизайн

```swift
struct TapVerseTip: Tip {
    @Parameter
    static var hasTappedAnyVerse: Bool = false

    var title: Text { Text("tip.tapVerse.title", ...) }      // localized, xcstrings
    var message: Text? { Text("tip.tapVerse.message", ...) }
    var image: Image? { Image(systemName: "hand.tap.fill") }

    var rules: [Rule] {
        #Rule(Self.$hasTappedAnyVerse) { $0 == false }
    }
    var options: [Option] { [MaxDisplayCount(1)] }
}
```

- Якір: `.popoverTip(TapVerseTip())` на рядку вірша Бут. 1:1 при першому запуску (`VerseRowView`, умовно на `verse.id == firstLaunchTarget`).
- Донація: один рядок у вже наявному `tapVerse(_:)` (`ReaderViewModel.swift:1072`) — `TapVerseTip.hasTappedAnyVerse = true`. Той самий choke-point, куди й так стікається кожен тап; нічого поруч не переписуємо.
- **iOS-версія:** TipKit доступний з iOS 17+ — вище нашого min target (18.0), без `#available`-гілки для самого факту використання Tip.
- **`#Rule` синтаксис уточнено проти офіційної докʼі (developer.apple.com) перед кодом, як велить CLAUDE.md:** правильна форма — `#Rule(Self.$hasTappedAnyVerse) { $0 == false }` (проєкція `@Parameter`, НЕ голе значення `Bool`). Перша спроба без `$` не скомпілювалась (`macro 'Rule' requires that 'Bool' conform to 'Tips.RuleInput'`) — виправлено й зафіксовано білдом (Debug+Release, iOS 18.0 sim).
- **⚠️ Відомий регрес iOS 26:** `popoverTip` повторно спливає при перемиканні `TabView`-вкладок ([Apple Developer Forums, FB20904972](https://developer.apple.com/forums/thread/805796)). Наш рідер гортає глави через `UIPageViewController` (ADR-026), не `TabView` — імовірно не зачіпає, але **не перевірено на нашому UI**. `MaxDisplayCount(1)` — подвійний запобіжник у будь-якому разі. Перевірити емпірично в §7.

## 6. Аналітика

`onboarding_tap_hint_shown`, `onboarding_tap_hint_dismissed { reason }` — легкі події за патерном ADR-022/035, щоб коли підуть справжні cold-install інтерв'ю (ще не проведені — пам'ять проєкту), було чим перевірити гіпотезу, і щоб було на що дивитись перед рішенням про другий тултіп (§3).

**Правки після code-review (opus, 2026-09-16) — до злиття:**
- `onboarding_tap_hint_shown` мав вогонь без обмежень: `shouldDisplayUpdates` віддає ЕЛІГІБЕЛЬНІСТЬ, не «показано один раз», а `ChapterScrollContent` (і його UIPageViewController-сторінка, ADR-026) перебудовується на кожну навігацію/свайп — подія могла спрацювати повторно на кожну перебудову, поки тултіп лишався елігібельним. Додано другий `@Parameter static var hasShownTapHint` — той самий патерн, що й `hasTappedAnyVerse`, гарантує рівно один show-івент за інсталяцію.
- Той самий `.task` читав `vm.analytics`, який `ReaderView` виставляє власним окремим `.task { vm.analytics = analytics }` — порядок виконання між двома `.task` не гарантований, подія могла тихо піти в `NoopAnalytics`. Замінено на `@Environment(\.analytics)` напряму (той самий патерн, що й `SearchView.swift`/`ContentView.swift`) — обходить проблему порядку повністю, без зміни DI-конструкції.
- `Tips.configure()` викликався всередині post-first-render `.task` у `SourceBibleApp.swift` — теоретично міг програти гонку з першим рендером `ReaderView` на холодному старті. Перенесено в `init()`, туди ж, де вже стоїть `LocalizedBundle.install(...)` за тим самим правилом «до побудови сцени».
- Лонгтап (`tapWord(_:VerseSegment,in:)`, `VerseTextView`) — теж легітимний ПЕРШИЙ жест відкриття Study Mode, який раніше не скидав `hasTappedAnyVerse`. Додано той самий guarded-донейт, що й у `tapVerse(_:)`, з `reason: "word_long_pressed"`.

**Правки після реального пристрою (2026-09-16) — до злиття:**
- **Баг А (виправлено):** на холодному старті `TapVerseTip` і перший показ `AnalyticsConsentModifier` (наявний first-launch consent sheet, `AnalyticsConsentCard.swift`) конкурували за екран одночасно — репорт з реального пристрою, два скриншоти, тап на "Share Statistics" гасив тултіп. Причина: `analyticsConsentShown` (AppStorage) стає `true` в той самий тік, коли `presentIfReady()` вирішує показати шіт — НЕ коли його закрито — тож гейтити тултіп на цей ключ не рятувало б. Додано окремий сигнал `EnvironmentValues.consentFlowPending` (`AnalyticsConsentCard.swift`, `ConsentFlowPendingEnvironmentKey`): `true` за замовчуванням, `false` — коли `onAppear` бачить, що шіт для цього запуску не потрібен (не перший запуск), або коли спрацював `onDismiss` шіта. `ChapterScrollContent` (`ReaderView.swift`) читає це значення через `@Environment(\.consentFlowPending)`, гейтить `.popoverTip` (`nil` поки `consentFlowPending == true`) і перезапускає `.task` через `.task(id: consentFlowPending)`, щоб shown-подія не могла зафіксуватись, поки тултіп візуально не показаний. `AnalyticsConsentCard.swift` (висото-гонка, `heightProbe`, `presentIfReady`) не займали — торкнуто лише `onAppear`/`onDismiss` двома рядками.
- **Баг B (НЕ виправлено, свідомо відкладено):** сам consent sheet має «подвійну анімацію» — шіт виїжджає з сідовою висотою (300), потім детент стрибає на заміряну (задокументовано в самому файлі як відомий, раніше вже баганий шлях). Це pre-existing race у `AnalyticsConsentCard.swift`, ймовірно не спричинений цією фічею. Рішення Івана: не займатись зараз, завести окремим тікетом, розберемось з реальною статистикою запусків.

## 7. Тест-план

- Sim QA через launch-args: скинути TipKit datastore + прапорець «перший запуск» → перевірити показ рівно один раз на Бут. 1:1.
- Тап по БУДЬ-ЯКОМУ іншому вірші (не Бут. 1:1) до появи тултіпа — тултіп не повинен зʼявитись при наступному відкритті рідера.
- Тап по Бут. 1:1 напряму — тултіп ховається, Study Mode відкривається штатно.
- Перезапуск застосунку після дисміса — тултіп не повертається.
- iOS 18 (мінімум) і iOS 26 (SDK) — обидві гілки; окремо перевірити §5 регрес емпірично на нашому UIPageViewController-рідері.
- Build Debug + Archive (не лише Debug — CLAUDE.md правило про `#Preview`/Release різницю не тут, але звичка перевіряти обидві конфігурації лишається).

## 8. Work Order

1. `TapVerseTip` struct + рядки в `Localizable.xcstrings` (UK/EN).
2. Один рядок донації в `ReaderViewModel.tapVerse(_:)`.
3. `.popoverTip` на верхньому рівні рядка вірша при `verse.id == firstLaunchTarget`.
4. Дві аналітичні події (§6).
5. Sim QA за §7 → Archive build.

## Відкриті питання

- «Показати ще раз» у Меню — не будується, чекає окремого запиту.
- `ChevronNavTip` (toolbar-навігація Study Mode) — свідомо відкладено, ревізит після статистики §6 з цього релізу.
