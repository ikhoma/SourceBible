# Product Decision — Trust-First Authentication Strategy for Bible App

## Status
Accepted

---

# Context

The app is designed as a deeply personal Bible reading and study experience.

Users may store:
- personal reflections
- prayers
- emotional notes
- theological insights
- meaningful highlights
- bookmarks tied to spiritual growth

Because of this, the product should avoid:
- aggressive onboarding
- forced sign-up walls
- SaaS-style friction before value
- growth-first dark patterns

The core product philosophy:

> Love for users is a product value.

The app should respect:
- the user's attention
- the reading experience
- emotional context
- privacy and ownership of thoughts

---

# Product Principle

## Deliver value before asking for commitment

Authentication should happen only after the user experiences meaningful value.

The app should NOT ask users to:
- create an account
- sign in
- configure sync

before they:
- read Scripture
- create a note
- save meaningful content
- emotionally invest into the app

---

# Product Strategy

## Anonymous-first architecture

The app uses a trust-first onboarding strategy:

```text
No forced signup
↓
User reads and explores freely
↓
User creates meaningful content
↓
App offers backup + sync as value
```

This reduces friction while preserving a future path for:
- cloud sync
- multi-device usage
- backup and recovery
- long-term retention

---

# Why this strategy fits a Bible App

Bible reading is reflective and personal.

Users do not want:
- enterprise onboarding flows
- account walls before reading
- interruption before spiritual engagement

Instead, users value:
- simplicity
- calm experience
- safety of personal notes
- continuity across devices

The app should feel:
- trustworthy
- quiet
- respectful
- emotionally safe

---

# Emotional Investment Model

Not all user actions have equal emotional weight.

## Highlights

- low emotional investment
- often temporary
- exploratory interaction

## Bookmarks

- medium emotional investment
- indicates intent to return

## Notes

- high emotional investment
- personal thoughts and reflections
- strongest retention signal

Because of this, authentication prompts should NOT appear too early.

---

# Recommended Trigger Points

## Preferred trigger

### After the first meaningful note

This is the strongest moment because the user has:
- reflected
- written something personal
- invested attention and emotion

At this moment, backup and sync become naturally valuable.

---

## Secondary trigger options

Authentication prompt may also appear after:

- 3 highlights
- multiple bookmarks
- repeated reading sessions
- returning users

However, note creation remains the strongest contextual trigger.

---

# UX Principle

## Never block the user immediately after save

Avoid:
- aggressive modals
- forced account walls
- interruption during reading flow

Prefer:
- subtle banners
- inline cards
- lightweight bottom sheets
- dismissible prompts

---

# Recommended Copy Direction

Avoid technical language.

## Bad

- "Create an account"
- "Enable synchronization"
- "Sign in to continue"

These phrases feel transactional and SaaS-like.

---

## Better

- "Save your notes across devices"
- "Don’t lose your reflections"
- "Restore your notes anytime"
- "Keep your study safe"

These phrases communicate:
- care
- continuity
- protection
- value

---

# Recommended Authentication Flow

## Stage 1 — Local-first MVP

Architecture:

```text
SwiftUI
↓
GRDB (SQLite)
```

Features:
- offline-first
- local notes
- highlights
- bookmarks
- no visible account system

Goal:
- validate reading + study UX
- reduce implementation complexity
- maximize product iteration speed

---

## Stage 1.5 — Silent Anonymous Auth

Add:
- Supabase Anonymous Auth
- stable cloud user_id
- optional silent cloud backup

User perspective:
- still no signup friction
- app simply works

Engineering benefits:
- future sync-ready identity
- avoids migration problems later
- allows gradual cloud rollout

---

## Stage 2 — Explicit Sign-In

Offer:
- Apple Sign In
- Google Sign In
- Email login

Only after meaningful engagement.

Primary value proposition:

```text
Access your notes on all your devices.
```

Secondary value proposition:

```text
Protect your notes and restore them anytime.
```

---

# Retention Insight

In a Bible app:

> Notes and reflections are emotional assets.

The more meaningful content a user creates:
- the stronger the attachment
- the higher the retention
- the greater the desire for backup and continuity

Because of this:

> Sync and backup are not merely technical features.
>
> They are retention mechanics built on trust.

---

# Architectural Consequence

Even before cloud sync is enabled publicly, the app should:

- use UUID-based entities
- store timestamps
- maintain sync-ready schema
- separate UI state from persistence models

This preserves flexibility while keeping the MVP lightweight.

---

# Final Product Philosophy

> The app should help users engage more deeply with Scripture,
> not distract them with product friction.

And:

> Love for users should be visible in product decisions.

