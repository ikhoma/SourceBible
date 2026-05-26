# Bible App — Network Map

## Overview
This document tracks developers and contributors involved in early discovery and technical validation of the Bible Study App.

Goal:
- Get expert input on architecture, AI, UX implementation
- Build a small circle of trusted contributors
- Avoid premature team formation

---

## Core Contacts

### Alona Ionova
- Role: AI + Full-stack (web)
- Current: Senior Software Engineer @ NiCE Cognigy (Düsseldorf, Germany) — Conversational AI / Agentic AI
- LinkedIn: https://www.linkedin.com/in/alona-ionova-a2a1b81b2/
- Priority: High (engage early)

**Why important:**
- Can shape AI direction (works on agentic / conversational AI at Cognigy)
- Can implement full-stack (web)
- Strong product thinking potential

**Ask about:**
- How to integrate AI into reading flow (not as chat)
- AI + UX interaction patterns
- Agent / LLM orchestration patterns from Cognigy

**Tech Stack:**
- Languages: JavaScript / TypeScript
- Frontend: React, Next.js
- Backend: Node.js, Express, Apollo GraphQL
- Data / Infra: Redis, AWS, Kubernetes
- AI: Conversational AI, Agentic AI (Cognigy platform)
- Testing: Cypress.io
- Note: LinkedIn does not show React Native experience — original "React Native" tag in this doc may be inaccurate. Worth verifying before assuming mobile fit.

---

### Alexander Khambir
- Role: Backend (Java) — Senior-level, 9+ yrs commercial
- Current: Software Engineer @ Wix.com (London, UK) — 7+ yrs
- Background: Java Coach @ Mate academy (3 yrs, taught Core Java / Spring / Hibernate / SQL); Java SWE @ GlobalLogic for Avaloq (digital banking, Core Payments — monolith → microservices on OpenShift, ISO 20022 XML payment engine); @ Luxoft for LuxTrust (national PKI / Digital Identity, Spring Boot, Hibernate, SOAP/REST, GlassFish/Payara, Oracle); @ Infopulse for BICS (telecom backend, Java 8, Spring, Hibernate, Oracle)
- LinkedIn: https://www.linkedin.com/in/akhambir/
- Priority: High (active advisor)

**Status:**
- Already had call
- Agreed to act as overseer (not owner)
- Waiting for BRD

**Ask about:**
- Data modeling (Bible + Strongs)
- API structure
- MVP architecture
- Postgres vs Elastic
- Event-driven design (Kafka experience at Wix — useful if AI features become async)

**Tech Stack:**
- Languages: Java (primary, 9+ yrs)
- Frameworks: Spring Boot, Spring Framework, Hibernate
- Architecture: Microservices, Event Driven, Low Latency, Scalability
- Messaging: Apache Kafka (5 roles)
- Infra / DevOps: Docker, Kubernetes, OpenShift, CI
- Databases: Oracle DB (deep), SQL
- Practices: Test-Driven Development, CI/CD
- API styles: REST, SOAP
- Domains: Payments / Fintech (Avaloq), Digital Identity / PKI (LuxTrust), Telecom (BICS), Web platform at scale (Wix)
- Note: Strong fit for backend architecture and data modeling. NOT a frontend or mobile resource. No visible AI/LLM or search-engine (Elastic) experience on profile — confirm in next sync.

---

### Daniel Yarmak
- Role: iOS Developer (note: LinkedIn shows iOS, not Frontend web)
- Current: iOS Developer @ Zoolatech (Kyiv, Ukraine)
- LinkedIn: https://www.linkedin.com/in/danielyarmak/
- Priority: High

**Why important:**
- Can help with complex UI logic on native iOS
- Strong in implementation details
- Relevant if app moves toward native iOS rather than React Native

**Ask about:**
- State management for:
  - verse selection
  - word selection
- Tap vs long-press interaction logic
- Component / view structure (SwiftUI vs UIKit trade-offs)

**Tech Stack:**
- Languages: Swift
- UI: SwiftUI, UIKit
- Architecture: Composable SwiftUI Architecture (Redux-style)
- Platform: iOS / Apple ecosystem
- Note: Original doc tagged him "Frontend / Full-stack" — actual specialization is iOS native. Re-confirm scope before assigning web tasks.

---

### Viacheslav Bilyi
- Role: Senior iOS Engineer / iOS Lead / Mentor
- Current: iOS Developer / Lead, iOS Consultant, Mentor (Ottawa, Canada)
- Background: Mobile Department Director @ Next League, iOS Tech Lead @ TEAM International, Mobile Team Lead @ Akvelon, Co-Founder of iOS Ukraine community, Swift/iOS Teacher @ Spalah IT-School
- LinkedIn: https://www.linkedin.com/in/viacheslavbilyi/
- Priority: Medium (mentor sessions)

**Strategy:**
- Approach via mentorship, not collaboration
- Ask for validation, not execution

**Ask about:**
- Overall architecture direction (especially mobile)
- Whether approach makes sense
- Trade-offs in early decisions
- Native iOS vs cross-platform reality check

**Tech Stack:**
- Languages: Swift, Objective-C
- UI: SwiftUI, UIKit
- Platform: iOS / Apple ecosystem (deep expertise, 10+ yrs)
- Process: Agile / Scrum (Scrum Mastery cert)
- Strength: mobile architecture, team leadership, mentoring

---

### Danylo Omelchenko
- Role: Backend / Infrastructure
- Current: Software Engineer @ Google (London, UK) — Software Infrastructure
- Background: Software Engineer @ BreezoMeter (Kubernetes / GKE), @ Wix.com (GCP / Python), Python Developer @ DataArt (Python / AWS), Python back-end @ DIGITALOUTLOOKS (Flask)
- LinkedIn: https://www.linkedin.com/in/danylo-omelchenko/
- Priority: Later stage

**Why important:**
- High-level system design at hyperscaler scale
- Scalability thinking
- Cloud / infra depth

**Ask about:**
- Search architecture (Elastic vs Postgres)
- Scaling data and queries
- System design decisions
- Cloud cost / infra trade-offs for an indie MVP

**Tech Stack:**
- Languages: Python, C++, TypeScript
- Cloud: Google Cloud Platform (GCP), AWS
- Infra: Kubernetes, GKE, Software Infrastructure (at Google scale)
- Frameworks: Flask
- Experience: Wix scale → Google scale

---

## QA

### Dmytro Lukianchuk
- Role: QA Leadership / Strategy (much more senior than just "QA")
- Current: Head of Quality Engineering @ Wix (Payments) (Cracow, Poland)
- Background: 15 yrs in IT, 8 yrs in leadership, 6 yrs in fintech. Leads 10-engineer QA org across 8 squads, influences 50+ engineers. Mentor on Mentor.sh.
- LinkedIn: https://www.linkedin.com/in/dmytro-lukianchuk-74ba3b26/

**Tech Stack:**
- Languages: JavaScript (basics)
- QA strategy: API / UI / contract automation, CI/CD quality gates, BDD (Given/When/Then)
- AI in QA: AI-powered test generation, triage bots, investigation acceleration
- Domains: Fintech / Payments — Stripe, Adyen, PayPal integrations
- Leadership: scaling QA orgs, hiring, mentoring, shift-left adoption
- Note: Better suited for QA *strategy* and process review than hands-on test writing.

### Yevhen Ternikov
- Role: Senior Manual QA Engineer
- Current: Senior Manual QA Engineer @ DataArt (Kyiv, Ukraine) — 5+ yrs
- LinkedIn: https://www.linkedin.com/in/yevhen-ternikov-%F0%9F%87%BA%F0%9F%87%A6-1316341b8/

**Tech Stack:**
- Testing: manual (web / mobile / data), functional, exploratory, smoke, regression, e2e, cross-platform / cross-browser
- Mobile: Android Studio, Xcode, BrowserStack, iMazing, TestFlight (real devices, iOS / Android)
- API: Postman, Swagger, SoapUI
- Databases / SQL: PostgreSQL, MySQL, Microsoft SQL Server
- Performance: JMeter (basic)
- Debugging proxies: Charles, Fiddler
- Test management: Jira, Confluence, Zephyr, TestRail, Allure, Azure DevOps, Trello, Aha!, QA Sphere, TestLink, Mantis
- CI/CD & VCS: Octopus Deploy, Git, GitHub, GitLab
- Data / analytics testing: Power BI, ETL flows
- AI tools: ChatGPT, Claude, Copilot, Gemini, TestCraft
- Languages: Python (basics, 2026), HTML/CSS understanding
- Certs: ICAgile ICP-ATF, ISTQB CTFL, Anthropic AI Fluency, Claude Code in Action

**How to engage:**
- Do NOT ask for formal testing
- Ask to "break the logic"

**Ask about:**
- Edge cases
- Confusing UX
- Broken states

Examples:
- What happens when switching quickly between words?
- Is it clear what is selected: verse or word?
- Can interaction logic be broken?

---

## Engagement Principles

### 1. Always provide context
- Short intro
- One specific problem
- Then link

### 2. Never ask:
- “What do you think?”
- “Can you review everything?”

### 3. Always ask:
- “How would you approach this?”
- “Does this direction make sense?”

---

## Current Focus

- Finalizing BRD
- Defining data model
- Deciding search approach
- Clarifying interaction model

---

## Next Steps

1. Finish BRD
2. Send to Akhambir
3. Discuss AI direction with Alona
4. Validate UX logic with Daniel
5. Run QA exploratory testing