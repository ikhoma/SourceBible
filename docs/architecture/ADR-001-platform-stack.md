# ADR-001: Platform Stack — SwiftUI Native, iOS 18+, Swift 6

**Status:** Accepted  
**Date:** 2026-05  
**Amended:** 2026-05-26 — iOS 18 minimum target decided; iOS 26 features behind `#available` guards  
**Deciders:** Ivan Khoma  
**Supersedes:** ADR-013-ios-minimum-target.md (deleted — described a React Native prototype that was not built)

---

## Context

The initial BRD (2026, pre-development) specified React Native + Expo as the tech stack. Before development began, the decision was made to build a fully native iOS app instead. This ADR records the platform choices that are now in effect across the codebase.

---

## Decisions

### 1. Native iOS (SwiftUI) — not React Native

The app is a pure SwiftUI app with no cross-platform framework. All UI is built with SwiftUI views. Low-level text rendering (verse display, highlighted attributed strings) uses `UIViewRepresentable` bridging to UIKit where SwiftUI's capabilities are insufficient.

**Why native over React Native:**
- The core reader experience requires tight control over text rendering — attributed strings, tap targets on individual words, custom layout for morphology chips. React Native bridges for this level of UIKit control add significant complexity.
- The data layer (`sourcebible.db` SQLite bundle, GRDB writable store) integrates naturally with Swift and the iOS file system. No JS bridge overhead on the hot read path.
- Single-platform target means no cross-platform tradeoffs. The entire budget of complexity goes to iOS quality.

### 2. iOS 18 minimum deployment target, iOS 26 features progressive

**Intended target:** `IPHONEOS_DEPLOYMENT_TARGET = 18.0`  
**Current state:** still set to `26.4` in `project.pbxproj` — the compatibility pass is deferred until after outstanding features are complete.

**Why iOS 18:**
- iPhone X (A11) received iOS 16 as its last update; iPhone XS (A12) receives iOS 18.
- iOS 18 is the last version available on a meaningful segment of older-but-capable hardware.
- Dropping to iOS 18 minimum keeps the app accessible to users who cannot upgrade devices.

**Strategy — progressive enhancement:**
- iOS 26-exclusive APIs are wrapped in `#available(iOS 26, *)` guards with an iOS 18 fallback.
- The app is fully functional on iOS 18; iOS 26 users get the enhanced experience where the API allows it.
- Swift 6 strict concurrency is a compiler setting — it is independent of deployment target and stays on.

**Known iOS 26-only APIs currently used without guards (to be audited in the compatibility sprint):**
- `Bundle` `@MainActor` — `LocalizedBundle` pattern; iOS 18 SDK does not mark `Bundle` as `@MainActor`, so `nonisolated` overrides and `nonisolated(unsafe)` file-scope globals may simplify under iOS 18 target.
- `TabView` value-based tab selection — needs `#available` guard or backport.
- Any other iOS 26 SDK additions used freely in the current codebase.

**Deferred to compatibility sprint** (after highlights/notes/bookmarks, word lookup, VersificationService features are complete):
1. Change `IPHONEOS_DEPLOYMENT_TARGET` to `18.0` in `project.pbxproj`
2. Fix every compiler error the target change surfaces
3. Document non-obvious `#available` patterns in CLAUDE.md

### 3. Swift 6 strict concurrency

The project compiles with `SWIFT_STRICT_CONCURRENCY = complete`. All code must satisfy Swift 6's actor isolation rules. The most important consequences are documented in CLAUDE.md under "Swift 6 / iOS 26 SDK — mandatory rules":

- `Bundle` subclasses inherit `@MainActor` — override methods must be `nonisolated`
- `@escaping` closures require explicit `self.` for instance methods
- Property visibility must not exceed type visibility

### 4. No third-party UI frameworks

The only third-party dependency is **GRDB** (SQLite wrapper for the writable user data store). Everything else is Swift stdlib + Apple frameworks. No Combine (SwiftUI's native observation is used), no third-party networking.

---

## Consequences

**What this enables:**
- iOS 26 bells and whistles available to users on current hardware
- iOS 18 minimum reaches users on iPhone XS (A12) and newer — a meaningful audience
- Swift 6 concurrency catches data races at compile time regardless of deployment target
- Simple dependency graph — GRDB is the only non-Apple SPM package

**What this constrains:**
- iOS-only. Android, web, or desktop would require a full rewrite or a separate codebase.
- iOS 26-exclusive APIs require `#available(iOS 26, *)` guards — every such usage needs an iOS 18 fallback.
- Any contributor must know SwiftUI and be aware of Swift 6 actor isolation rules (see CLAUDE.md).
- **Do not add iOS 26-only APIs without a `#available` guard** until the compatibility sprint changes the deployment target and the compiler enforces it automatically.

---

## Notes on the BRD

`docs/BRD/03-brd.md` still specifies React Native + Expo. The BRD reflects the pre-development prototype phase and has not been updated. The technical sections of the BRD are outdated; the product/feature requirements sections remain useful context. **The BRD should be rewritten before release** to reflect the actual stack and current feature set.
