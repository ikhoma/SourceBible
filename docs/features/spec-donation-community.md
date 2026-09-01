# Spec — Donation Community Prompt (implements ADR-038)

**Status:** Draft
**Date:** 2026-08-29
**Owner:** Ivan
**Implements:** ADR-038 (донат-банер: тригер, показ, rate-limit)
**Related:** `AboutView.swift` / `MenuView.swift` / `WordTabContent.swift` / `DonationView.swift` / `DonationService.swift` (наявні входи й кінцева точка CTA — див. ADR-038, таблицю входів у Контексті)

---

## 1. Розміщення в потоці

Тригер (локальний MSS-proxy, ADR-038 §1-2) → **одразу цей екран** як `.sheet`, без проміжного короткого нуджу → CTA «Приєднатися» штовхає наявний `DonationView` (сітка сум) → існуючий StoreKit-потік без змін.

Цей екран — **четвертий, окремий вхід**, не заміна й не редирект наявних трьох (Menu-пункт, About-кнопка, Word-tab CTA — ADR-038, таблиця входів). About і `CommunityView` змістовно дублюють один одного (обидва — загальний mission-пітч), але об'єднання свідомо відкладено (Іван, 2026-08-29) — не пріоритет зараз. Menu-пункт і Word-tab CTA цього не стосуються: вони вузькі й контекстні за задумом, не мають ставати цим екраном.

## 2. Мова

EN + UK inline у Swift (як `AboutView`), обрана через `appLanguage` / `AppLanguage.resolved`. **Не** через xcstrings — контент, не UI chrome (той самий прецедент, що About і тизери нотифікацій).

## 3. Текст — UK (джерело: надано Іваном, без правок)

```
# Спільнота SourceBible

## Приєднуйтесь до тих, хто допомагає будувати SourceBible

SourceBible — це проєкт, покликаний зробити глибоке дослідження Біблії простим, інтуїтивним і доступним.

Підтримуючи проєкт, ви допомагаєте нам розвивати не сам доступ до Біблії, а **інструменти для її глибшого дослідження**.

## Що ми будуємо разом

### 1. Контекст Писання

Історія, географія, персонажі, події, хронологія та карти — щоб бачити біблійний текст у його повному контексті.

### 2. Розумний пошук і ШІ-асистент

Знаходити потрібну інформацію природною мовою — від конкретного вірша чи слова до теми, події або біблійного персонажа.

ШІ-асистент допомагає взаємодіяти з біблійними знаннями та швидше знаходити потрібну інформацію, а не просто генерувати довільний контент.

### 3. Українські біблійні ресурси

Ми створюємо та адаптуємо ресурси, необхідні для глибокого дослідження Біблії українською:

- український глос;
- розмітка Strong's для перекладу Огієнка;
- переклад і адаптація словників;
- переклад коментарів;
- інші українські дослідницькі матеріали.

### 4. Інструменти для служіння

SourceBible має допомагати не лише досліджувати Писання, а й використовувати результати цього дослідження у служінні.

Ми розвиваємо інструменти для створення та збереження:

- власних коментарів;
- планів домашніх груп;
- конспектів;
- проповідей;
- навчальних матеріалів.

## Куди спрямовується підтримка

Внески спільноти допомагають фінансувати:

- розробку та підтримку SourceBible;
- створення українського біблійного контенту;
- дослідницькі та редакторські роботи;
- розробку нових інструментів для вивчення Писання;
- інфраструктуру, необхідну для роботи проєкту.

## Будуємо разом

SourceBible розвивається завдяки людям, які вірять у цю ідею та хочуть допомогти їй стати реальністю.

**Приєднуйтесь до спільноти SourceBible.**

Ваша підтримка допомагає нам створювати наступне покоління інструментів для дослідження Біблії.
```

## 4. Текст — EN (переклад, для затвердження)

```
# SourceBible Community

## Join those who are helping build SourceBible

SourceBible exists to make deep Bible study simple, intuitive, and accessible.

By supporting the project, you're not just helping expand access to the Bible — you're helping us build the tools for studying it more deeply.

## What we're building together

### 1. Context of Scripture

History, geography, people, events, timelines, and maps — so the biblical text can be seen in its full context.

### 2. Smart search and an AI assistant

Finding what you need in plain language — from a specific verse or word to a topic, event, or biblical figure.

The AI assistant helps you engage with biblical knowledge and find what you're looking for faster — not generate arbitrary content.

### 3. Bible study in more languages

SourceBible's depth — the original languages, Strong's, the lexicon, cross-references, centuries of commentary — has so far been built primarily in English. We're investing in bringing that same depth to other languages, not just translated interface labels.

**Ukrainian is the first we're bringing to completion** — an interlinear gloss, Strong's tagging for the Ohiienko translation, translated dictionaries and commentary. Spanish, Chinese, German, and French are among the languages we're considering next.

### 4. Tools for ministry

SourceBible should help not only with studying Scripture, but with putting that study to work in ministry.

We're building tools for creating and keeping:

- your own commentary notes;
- home group plans;
- study notes;
- sermons;
- teaching materials.

## Where your support goes

Community contributions help fund:

- developing and maintaining SourceBible;
- building out Bible study content in more languages;
- research and editorial work;
- building new tools for studying Scripture;
- the infrastructure the project runs on.

## Building this together

SourceBible grows because of people who believe in this and want to help make it real.

**Join the SourceBible community.**

Your support helps us build the next generation of Bible study tools.
```

> ⚠️ **EN-переклад — машинний, не носійський.** Чекає термінологічного рев'ю перед тим, як цей текст піде в реалізацію UI (див. §7). Секція 3 (EN) — переписана, не переклад UK-варіанту: UK-версія лишається специфічною до української (§3 там), EN — узагальнена до місійності «інвестуємо в мовний контент», з українською як приклад-флагман (перша, що добудовується) і згадкою Іспанська/Китайська/Німецька/Французька як наступних у дорожній карті.
>
> ⚠️ **Розбіжність зі наявними ADR-документами.** `spec-localization-i18n.md`/`plan-localization-i18n.md` (P2.3 / Phase 4) називають наступними мовами **російську, іспанську, німецьку, польську** — без китайської й французької, з російською замість них. Список у цьому попапі (іспанська/китайська/німецька/французька) від Івана новіший і, судячи з усього, актуальніший продуктовий намір, але формально розходиться з тим, що записано в i18n-специ. Це маркетинговий текст, не архітектурне зобов'язання (§5 нижче), тож синхронізувати не обов'язково негайно — але якщо мовний ряд справді змінився, варто оновити `spec-localization-i18n.md`/`plan-localization-i18n.md` окремим проходом, щоб документи не розходились мовчки.

## 5. Продуктовий нюанс — контент випереджає реалізацію

Текст явно описує **ще не збудовані** фічі: контекст Писання (мапи/хронологія), ШІ-асистент, розширені українські ресурси, інструменти для служіння (проповіді/конспекти/плани груп). Це нормально для «roadmap-пітчу» спільноти (Patreon-подібна модель: платиш за напрямок, не за вже готове), але:

- **Не породжує нових ADR автоматично.** Ці пункти — маркетинговий опис напрямку, не архітектурне зобов'язання; коли/якщо кожен дійде до розробки — отримає власний ADR/spec тоді.
- **Розбіжність тексту з реальністю застосунку зростатиме з часом**, якщо пункти не оновлювати в міру реалізації (симетрична проблема до `about-page.md`, яка вже є source of truth для About-копірайту й синхронізується вручну). Рекомендація: той самий режим — контент курується вручну, без окремого механізму синхронізації.
- **Мовний список і порядок у §4 (EN) — не затверджено (Іван, 2026-08-29).** Тому копірайт свідомо м'який («among the languages we're considering next», не «next on the roadmap» — жодної обіцянки послідовності).
  - **Іспанська, ймовірно, піде першою** після української: європейська і водночас найпоширеніша мова світу — найширший охоплюваний загал на одну мову.
  - **Російська — свідомо відсутня в списку, і це не помилка.** Технічно це буде найлегша мова: Синодальний переклад (RST) уже в ядрі `sourcebible.db` (`about-page.md` license list), інфраструктура під неї фактично готова. Відсутність — суто ціннісне рішення: **чекаємо закінчення війни**, узгоджується з рамкою «Ми будуємо цей застосунок, поки в нашій країні триває війна» (About, розділ «Team / war»). **Не додавати Russian у цей попап** без окремого підтвердження Івана, навіть коли комусь здасться, що технічна готовність — достатня причина.

## 6. UI-структура (орієнтовно, за зразком AboutView)

- `ScrollView` + секції як у наведеному тексті (headline → місія → 4 нумеровані підрозділи → «Куди спрямовується підтримка» → заклик).
- Primary CTA внизу (у дусі `supportButton` з `AboutView`): iOS 26 `.glassProminent` / iOS 18 `.borderedProminent` fallback, штовхає `DonationView`.
- Другорядна дія — системний dismiss sheet'а (свайп/×) → рахується як «показано», rate-limit-прапорці ADR-038 записуються.

## 7. Відкриті питання

- Чи потрібні візуальні акценти (іконки на 4 підрозділи, як About має license-групи) чи чистий текст досить?
- Термінологічна звірка EN-перекладу перед фіналізацією (§4 warning).

~~Чи дублювати текст в About~~ — **не пріоритет зараз** (Іван, 2026-08-29). Цей екран — окремий, четвертий вхід у `DonationView`, поруч із Menu-пунктом, About-кнопкою і Word-tab CTA (ADR-038, таблиця входів у Контексті). Об'єднання з About відкладено як revisit-тригер, не питання цього проходу.
