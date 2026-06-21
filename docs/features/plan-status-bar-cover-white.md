# План/Реф: Білий статус-бар на обкладинках книг

**Status:** Deferred — working algorithm preserved for a future iteration
**Date:** 2026-06-21
**Зв'язок:** реалізація ADR-023 (Option B). Цей файл = повний код + історія + єдина відкрита проблема. Код був реалізований і відкочений (revert) — НЕ в git, тільки тут.

---

## 1. Мета

У light mode на сторінці з обкладинкою (Reader, chapter 1) іконки статус-бара мають бути **білими**, поки обкладинка під статус-баром, і повертатись до theme-default коли обкладинка проскролилась вище. Обкладинка завжди темно-синя (Doré), тому білі іконки читабельні; default (чорні) — ні.

## 2. Чому це складно

- SwiftUI App lifecycle **не має API** для стилю статус-бара (тільки `.statusBarHidden`). Стиль контролює `UIViewController.preferredStatusBarStyle` системного `UIHostingController`, який ми не створюємо.
- Підміна root VC ламає `.preferredColorScheme` (dark mode) і lifecycle — див. ADR-023.
- **Навіть Apple Music має цю ваду**: на сторінці артиста з темним hero-фото статус-бар чорний-на-темному (нечитабельно) у стані спокою; адаптується до фону тільки на скрол. Тобто проблема фундаментальна, не «погана реалізація». Apple Music — UIKit з реальними per-screen VC, тому кожен екран нативно володіє своїм баром; у нас SwiftUI = один HC на таб зі спільним ObjC-класом, звідси вся складність (див. §5).

## 3. Робочий алгоритм (baseline — «works fine», окрім §5)

Підхід: **не** підміняти root. `UIHostingController` лишається коренем (нативний dark mode + lifecycle). Коли треба білий — у рантаймі йдемо `childForStatusBarStyle` від active root до terminal-VC, який система реально опитує, і **swizzl-имо його клас** `preferredStatusBarStyle`. Getter повертає `.lightContent` коли `useLightContent`, інакше `.default` (trait-resolved → правильно per theme).

Двовходова модель: `useLightContent = coverBehindStatusBar AND readerTabActive`. `coverBehind` пише ReaderView зі scroll-геометрії; `readerTabActive` — ContentView з `selectedTab` (синхронно, бо TabView віддає onAppear/onDisappear надто пізно).

### 3.1 `SourceBible/Services/StatusBarStyleState.swift`
```swift
import Foundation
import Combine

// iOS 26 SDK інферить ObservableObject як @MainActor → лишаємо @MainActor явно,
// тоді static let singleton не потребує nonisolated(unsafe).
@MainActor
final class StatusBarStyleState: ObservableObject {
    static let shared = StatusBarStyleState()
    private init() {}

    @Published private(set) var useLightContent = false

    private var coverBehindStatusBar = false
    private var readerTabActive = true

    func setCoverBehindStatusBar(_ value: Bool) {
        guard coverBehindStatusBar != value else { return }
        coverBehindStatusBar = value
        recompute()
    }
    func setReaderTabActive(_ value: Bool) {
        guard readerTabActive != value else { return }
        readerTabActive = value
        recompute()
    }
    private func recompute() {
        let next = coverBehindStatusBar && readerTabActive
        if useLightContent != next { useLightContent = next }
    }
}
```

### 3.2 `SourceBible/Services/StatusBarStyleController.swift`
```swift
import UIKit
import Combine

@MainActor
enum StatusBarStyleController {
    private static var cancellable: AnyCancellable?
    private static var swizzledClasses: Set<ObjectIdentifier> = []

    static func start() {
        guard cancellable == nil else { return }
        cancellable = StatusBarStyleState.shared.$useLightContent
            .removeDuplicates()
            .receive(on: DispatchQueue.main)           // RunLoop.main лагало — НЕ використовувати
            .sink { _ in MainActor.assumeIsolated { apply() } }
    }

    private static func apply() {
        guard let root = activeRootViewController() else { return }
        var terminal = root
        var hops = 0
        while let child = terminal.childForStatusBarStyle, hops < 20 { terminal = child; hops += 1 }
        if let cls = object_getClass(terminal) { swizzleIfNeeded(cls) }
        root.setNeedsStatusBarAppearanceUpdate()
    }

    private static func activeRootViewController() -> UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .keyWindow?.rootViewController
    }

    private static func swizzleIfNeeded(_ cls: AnyClass) {
        let id = ObjectIdentifier(cls)
        guard !swizzledClasses.contains(id) else { return }
        let sel = #selector(getter: UIViewController.preferredStatusBarStyle)
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let types = method_getTypeEncoding(method)
        // UIKit опитує статус-бар на main → assumeIsolated безпечний.
        let block: @convention(block) (UIViewController) -> UIStatusBarStyle = { _ in
            MainActor.assumeIsolated {
                StatusBarStyleState.shared.useLightContent ? .lightContent : .default
            }
        }
        let imp = imp_implementationWithBlock(block)
        // class_addMethod ПЕРШИМ — щоб не зачепити успадкований (спільний) метод.
        if !class_addMethod(cls, sel, imp, types) {
            if let own = class_getInstanceMethod(cls, sel) { method_setImplementation(own, imp) }
        }
        swizzledClasses.insert(id)
    }
}
```

### 3.3 `SourceBible/AppDelegate.swift`
```swift
import UIKit

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        StatusBarStyleController.start()
        return true
    }
}
```

### 3.4 `SourceBibleApp.swift` — хуки
```swift
@UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate   // вгорі struct
// у body, на ContentView — лишити НАТИВНИЙ:
.preferredColorScheme(isDarkMode ? .dark : .light)
```

### 3.5 `ContentView.swift` — драйвер табу
```swift
.task { StatusBarStyleState.shared.setReaderTabActive(selectedTab == .bible) }   // seed
.onChange(of: selectedTab) { _, tab in
    StatusBarStyleState.shared.setReaderTabActive(tab == .bible)
}
```

### 3.6 `ReaderView.swift` — драйвер обкладинки
```swift
@State private var topSafeInset: CGFloat = 0   // поряд з ін. @State

// у ZStack (повноекранний reader для status-bar лінії):
GeometryReader { geo in
    Color.clear
        .onAppear { topSafeInset = geo.safeAreaInsets.top }
        .onChange(of: geo.safeAreaInsets.top) { _, v in topSafeInset = v }
}
.ignoresSafeArea()
.allowsHitTesting(false)

// на BookCoverView(...), ПЕРЕД .padding-ами — Bool-tracked, не per-frame:
.onGeometryChange(for: Bool.self, of: { [topSafeInset] proxy in
    proxy.frame(in: .global).maxY > topSafeInset
}) { behind in
    StatusBarStyleState.shared.setCoverBehindStatusBar(behind)
}

// на ScrollView, біля .id(...):
.onChange(of: showsBookCover) { _, shows in
    if !shows { StatusBarStyleState.shared.setCoverBehindStatusBar(false) }
}
```

## 4. Варіанти і результати

| Підхід | Результат |
|---|---|
| **A. Window-root container** (підміна `window.rootViewController`, контейнер володіє баром+appearance) | ⛔ Зламав `.preferredColorScheme` (dark mode мертвий, freeze). Відкинуто. |
| **B. Class swizzle `preferredStatusBarStyle`** (§3, getter → global `useLightContent ? .lightContent : .default`) + двовходова модель | ✅ «works fine». Єдина вада — §5 (миттєвий tab-switch). **Рекомендований baseline.** |
| B+ `.frame(in: .named("readerScroll"))` замість `.global` | Не виправило stale-on-return; теорія (tab-slide корупція global-frame) не підтвердилась на практиці. |
| **C. Per-instance** (associated object на terminal, getter читає свій тег) | ⛔ Стало гірше: білий протікав на інші таби (walk знаходив **спільний** terminal/клас). Відкинуто. |
| **D. Design-level scrim** (без override бару взагалі) | Не реалізовано. Найнадійніший fallback — див. §5. |

## 5. ⚠️ Єдина відкрита проблема: миттєвий перехід між табами

**Симптом:** при швидкому Reader→інший таб є невелика затримка перш ніж бар стане чорним; при поверненні бар короткочасно «застряглий білий» до скролу.

**Діагноз (root cause):** SwiftUI хостить кожен таб у `UIHostingController`, і вони **ділять один ObjC-клас**. Тому swizzle класу впливає на ВСІ таби — всі читають один глобальний `useLightContent`. `readerTabActive` намагається це гейтити, але робить це через **async Combine hop** (`receive(on:)`), а `UITabBarController` опитує статус-бар **синхронно** в момент перемикання. Ця гонка = затримка/застрягання. Per-instance (варіант C) мав це вирішити, але walk знаходив спільний terminal — білий протікав.

**Чому Apple Music це робить добре:** вони UIKit з реальними per-screen `UIViewController` — кожен екран нативно й синхронно володіє своїм баром, без спільного прапора. Наш SwiftUI single-HC-per-tab — інша модель.

**Кандидати на фікс (для майбутньої ітерації):**
1. **Синхронний шлях.** Прибрати async-залежність: гарантувати, що `useLightContent` оновлюється і `setNeedsStatusBarAppearanceUpdate` викликається **синхронно** у тій самій транзакції, що й перемикання табу (напр. driver з ContentView без `receive(on:)`), щоб синхронний опит `UITabBarController` читав свіже значення.
2. **Per-instance, але з правильним таргетом.** Тегувати асоційованим обʼєктом саме той VC, який `UITabBarController` опитує для Reader-табу — перевірити рантайм-ланцюг (`childForStatusBarStyle` дерево) на реальному пристрої, переконатись що це НЕ спільний контейнер, перш ніж тегувати. Варіант C провалився бо тегував спільний вузол.
3. **Scroll-driven як Apple Music** — приймати недосконалість hero-стану (як вони).
4. **Design-level scrim (рекомендовано як safe-win):** взагалі НЕ чіпати бар; додати слабкий темний градієнт у верхній ~status-bar зоні обкладинки (дзеркало наявного нижнього градієнта у `BookCoverView`), щоб default (чорні) гліфи лишались читабельними. Нуль swizzling, нуль гонок, працює на всіх табах і пристроях. Програє «білому» естетично, але надійно.

**Перед будь-якою реалізацією:** інструментувати на пристрої (sim cold-launch таймаутить tooling) — залогувати `object_getClass(terminal)` для кожного табу, щоб підтвердити спільність класу і знайти правильний per-instance таргет.

## 6. Swift 6 / concurrency нотатки

- iOS 26 SDK інферить `ObservableObject` як `@MainActor` → клас стану позначити `@MainActor`, тоді `static let shared` без `nonisolated(unsafe)`.
- Swizzled getter читає main-actor стан → обгорнути в `MainActor.assumeIsolated` (UIKit опитує бар на main).
- `.onGeometryChange` `of:`-closure — `@Sendable`; захоплювати `topSafeInset` через capture list `[topSafeInset]`, не напряму.
- Трекати **Bool**, не `CGFloat`, в `onGeometryChange` — інакше per-frame запис у @State = лаги скролу.
- `.receive(on: DispatchQueue.main)`, НЕ `RunLoop.main` (останній лагає).

## 7. Як відновити

1. Створити §3.1–3.3 файли (Xcode 16 buildable folders підхопить автоматично).
2. Додати хуки §3.4–3.6.
3. Build (iOS 26 SDK, Swift 6) — має бути 0 errors.
4. **Зайнятись §5 пунктом 1 або 2** (це те, що лишилось) АБО прийняти §5.4 scrim.
5. Тест на пристрої: обкладинка (біла), скрол-past (default), dark mode toggle (нативний), **tab-switch туди-назад** (головний кейс для §5).
