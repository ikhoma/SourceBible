# Bug: AnalyticsConfiguration.swift генерується з `\"token\"` замість `"token"`

**Severity:** Build failure  
**File:** `SourceBible.xcodeproj/project.pbxproj` → `PBXShellScriptBuildPhase` "Generate Analytics Token"  
**Symptom:** Swift-компілятор видає "Unterminated string literal" на `static let mixpanelToken`

---

## Контекст: чому взагалі з'явився Run Script

### Попередній підхід (провалився): `INFOPLIST_KEY_MIXPANEL_TOKEN`

Перша спроба інжектувати токен через build settings:

```
// target Debug config у pbxproj
INFOPLIST_KEY_MIXPANEL_TOKEN = "$(MIXPANEL_DEV_TOKEN)";
```

і в `MixpanelAnalytics.init()`:
```swift
Bundle.main.object(forInfoDictionaryKey: "MIXPANEL_TOKEN") as? String
```

**Чому не спрацювало:** проект використовує `GENERATE_INFOPLIST_FILE = YES` — Xcode генерує Info.plist автоматично з build settings, але обробляє **тільки Apple-defined** `INFOPLIST_KEY_*` ключі (NSPhotoLibraryUsageDescription тощо). Кастомні ключі (`INFOPLIST_KEY_MIXPANEL_TOKEN`) він **мовчки ігнорує** і до згенерованого Info.plist не додає. Підтверджено через PlistBuddy: `Entry, "MIXPANEL_TOKEN", Does Not Exist`.

---

### Поточна імплементація (частково правильна): Run Script → Generated Swift file

**Підхід:** стандартний iOS-патерн (підтверджений NSHipster, STRV, Kodeco). Run Script build phase зчитує токен з env-змінних (які xcconfig виставляє автоматично) і генерує Swift-файл до компіляції.

**Що додано в проект:**

1. `PBXShellScriptBuildPhase` з UUID `888733C02FE5700000EDC19D` ("Generate Analytics Token") — першим у `buildPhases` мети, до Sources.
   - `inputPaths`: `$(SRCROOT)/Config/Secrets.xcconfig`  
   - `outputPaths`: `$(SRCROOT)/SourceBible/Generated/AnalyticsConfiguration.swift`

2. `SourceBible/Generated/AnalyticsConfiguration.swift` — placeholder файл (порожній токен), щоб перший білд скомпілювався навіть до того як скрипт відпрацює; `PBXFileSystemSynchronizedRootGroup` сканує директорію при відкритті проекту, тому файл має існувати заздалегідь.

3. `.gitignore` — додано `SourceBible/Generated/AnalyticsConfiguration.swift` (не комітити реальний токен).

4. `MixpanelAnalytics.swift` — прибрано `tokenFromBundle()`, замінено на:
   ```swift
   let token = AnalyticsConfiguration.mixpanelToken
   guard !token.isEmpty else { ... }
   ```

5. Прибрано нерабочий `INFOPLIST_KEY_MIXPANEL_TOKEN` з обох build configs у pbxproj.

**Скрипт (як він зараз виглядає в pbxproj, shellScript поле):**

```bash
#!/bin/bash
set -e

DIR="${SRCROOT}/SourceBible/Generated"
mkdir -p "${DIR}"

if [ "${CONFIGURATION}" = "Debug" ]; then
  TOKEN="${MIXPANEL_DEV_TOKEN:-}"
else
  TOKEN="${MIXPANEL_TOKEN:-}"
fi

cat > "${DIR}/AnalyticsConfiguration.swift" << EOF
// AnalyticsConfiguration.swift -- Auto-generated. DO NOT EDIT.
// Built from Config/Secrets.xcconfig by the \"Generate Analytics Token\" build phase.
enum AnalyticsConfiguration {
    static let mixpanelToken = \"${TOKEN}\"
}
EOF
```

Скрипт **відпрацьовує** (файл генерується, токен підставляється) — але виводить `\"token\"` замість `"token"`.

---

## Що відбувається

Згенерований файл `SourceBible/Generated/AnalyticsConfiguration.swift` містить:

```swift
static let mixpanelToken = \"b01f0469e86095167812f117d97e03db\"
```

замість:

```swift
static let mixpanelToken = "b01f0469e86095167812f117d97e03db"
```

Swift не вміє парсити `\"` всередині файлу — це буквальний backslash + quote, не string escape.

---

## Root cause

В `shellScript` рядку pbxproj лапки навколо `${TOKEN}` в heredoc закодовані як `\\\"`:

```
static let mixpanelToken = \\\"${TOKEN}\\\"
```

Ланцюжок декодування:
1. pbxproj рядок `\\\"` → shell script `\"`  
2. Shell heredoc (`<< EOF`, **unquoted**) — **не інтерпретує** `\"` як escape, виводить буквально `\"`  
3. Swift-файл отримує `\"token\"` → compile error "Unterminated string literal"

---

## Fix

В `shellScript` у pbxproj замінити `\\\"${TOKEN}\\\"` → `\"${TOKEN}\"`:

**До (неправильно):**
```
    static let mixpanelToken = \\\"${TOKEN}\\\"\n
```

**Після (правильно):**
```
    static let mixpanelToken = \"${TOKEN}\"\n
```

Декодування правильного варіанту:
1. pbxproj `\"${TOKEN}\"` → shell script `"${TOKEN}"`
2. heredoc виводить `"token"` (без backslash)
3. Swift файл компілюється ✓

Та ж зайва проблема в рядку коментаря (`\\\"Generate Analytics Token\\\"`) — теж backslash в коментарі, але це тільки косметика, не ламає білд.

---

## Де міняти

`SourceBible.xcodeproj/project.pbxproj`, об'єкт `888733C02FE5700000EDC19D`, поле `shellScript`.

Поточний фрагмент:
```
...static let mixpanelToken = \\\"${TOKEN}\\\"\n}\nEOF\n
```

Має стати:
```
...static let mixpanelToken = \"${TOKEN}\"\n}\nEOF\n
```

Після виправлення — **⇧⌘K (Clean Build Folder)**, потім білд.
