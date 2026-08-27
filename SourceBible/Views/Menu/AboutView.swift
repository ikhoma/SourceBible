// AboutView.swift
// Source Bible
//
// In-app About screen (Menu → About). Long-form marketing/attribution copy, so
// the two languages are held inline and picked by `appLanguage` rather than
// routed through xcstrings (which is for UI labels). The "Support Source Bible"
// primary action pushes the existing DonationView (StoreKit 2, DonationService).

import SwiftUI

struct AboutView: View {
    @AppStorage(AppStorageKeys.colorTheme) private var colorThemeRaw = ColorTheme.paper.rawValue
    // Дефолт `@AppStorage` спрацьовує, поки ключа НЕМА — а він пишеться лише
    // коли людина відкриє пікер мови. Жорсткий "en" тут означав, що на
    // українському телефоні цей екран був англійським, хоч решта інтерфейсу
    // (через свізл бандла) — українська. `resolved` дає ту саму мову, що й свізл.
    @AppStorage(AppStorageKeys.appLanguage) private var appLanguage: String = AppLanguage.resolved

    private var colorTheme: ColorTheme { ColorTheme(rawValue: colorThemeRaw) ?? .paper }
    private var uk: Bool { appLanguage == "uk" }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "Source Bible v\(v)"
    }

    /// Support action WITHOUT its buttonStyle, so the surface can branch by OS
    /// (iOS 26 Liquid Glass `.glassProminent` vs iOS 18 fallback `.borderedProminent`).
    private var supportButton: some View {
        NavigationLink {
            DonationView()
        } label: {
            Text(uk ? "Підтримати Source Bible" : "Support Source Bible")
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .tint(.appBlue)
    }

    var body: some View {
        ZStack {
            colorTheme.appBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {

                    // ── Headline ──
                    Text(uk
                         ? "Ми прокладаємо міст між сучасним читачем і світом біблійного тексту."
                         : "We bridge the gap between modern readers and the world of the biblical text.")
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)

                    // ── Mission ──
                    Text(uk
                         ? "Наша місія — зробити глибоке вивчення Біблії простим, зрозумілим і доступним. Кожен вірш у Source Bible відкриває оригінальний єврейський і грецький текст, що стоїть за ним, — слово за словом, із морфологією, лексиконом Стронга, конкордансом, перехресними посиланнями і століттями коментарів на відстані одного дотику. Ми прагнемо зробити цю глибину доступною кожному, хто хоче придивитися ближче, — а не лише тим, хто має богословську освіту."
                         : "Our mission is to make deep Bible study simple, intuitive, and accessible. Every verse in Source Bible opens onto the original Hebrew and Greek behind it — word by word, with morphology, the Strong's lexicon, concordance, cross-references, and centuries of commentary a single tap away. Our hope is to make that depth approachable for anyone who wants to look closer — not only those with formal training.")
                        .fixedSize(horizontal: false, vertical: true)

                    // ── Manuscript basis ──
                    Text(uk
                         ? "Тексти мовами оригіналу взято з Ленінградського кодексу (Westminster Leningrad Codex) для єврейського Старого Заповіту та видання Nestle 1904 для грецького Нового Заповіту, з послівним аналізом від проєкту Macula."
                         : "The original-language texts are drawn from the Westminster Leningrad Codex for the Hebrew Old Testament and the Nestle 1904 edition of the Greek New Testament, with word-level analysis from the Macula project.")
                        .fixedSize(horizontal: false, vertical: true)

                    // ── Built by / for (credibility line) ──
                    Text(uk
                         ? "Створено дослідниками й викладачами Біблії — для дослідників і викладачів Біблії."
                         : "Built by Bible students and teachers, for Bible students and teachers.")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)

                    // ── Team / war ──
                    Text(uk
                         ? "Ми — команда незалежних розробників з України. Ми створюємо цей застосунок, поки в нашій країні триває війна. За таких обставин Слово Боже для нас не захоплення — це ґрунт, на якому ми стоїмо. Ми зберігаємо Source Bible безкоштовним для всіх завдяки тим, хто вирішує його підтримати."
                         : "We are a team of independent developers from Ukraine. We build this app while our country is at war. In these circumstances the word of God is not a hobby for us — it is the ground we stand on. We keep Source Bible free for everyone, with the help of those who choose to support it.")
                        .fixedSize(horizontal: false, vertical: true)

                    // ── Support (primary action → existing donation flow) ──
                    // iOS 26 Liquid Glass surface; iOS 18 fallback = borderedProminent.
                    Group {
                        if #available(iOS 26, *) {
                            supportButton.buttonStyle(.glassProminent)
                        } else {
                            supportButton.buttonStyle(.borderedProminent).legacyCapsuleButton()
                        }
                    }
                    .padding(.top, 4)

                    // ── Sources & licenses (plain section; title matches the intro style) ──
                    Text(uk ? "Джерела та ліцензії" : "Sources & licenses")
                        .font(.title3.weight(.semibold))
                        .padding(.top, 12)

                    Text(uk
                         ? "Ми вдячні всім, хто зробив ці матеріали вільно доступними."
                         : "We are grateful to everyone who made this scholarship freely available.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(licenseGroups) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.title)
                                .font(.subheadline.weight(.semibold))
                            ForEach(group.items, id: \.self) { item in
                                Text(item)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    // ── Version ──
                    Text(appVersion)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 8)
                }
                .padding(20)
            }
        }
        .navigationTitle("menu.about")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sources data

    private struct LicenseGroup: Identifiable {
        let id = UUID()
        let title: String
        let items: [String]
    }

    private var licenseGroups: [LicenseGroup] {
        if uk {
            return [
                LicenseGroup(title: "Тексти мовами оригіналу", items: [
                    "MACULA Hebrew і MACULA Greek Linguistic Datasets — © 2022–2024 Biblica, Inc. — CC BY 4.0",
                    "github.com/Clear-Bible/macula-hebrew · github.com/Clear-Bible/macula-greek",
                    "Іврит: Ленінградський кодекс (Tanach.us) · Грека: Nestle 1904",
                    "Westminster Hebrew Syntax — The J. Alan Groves Center — CC BY 4.0",
                    "OpenScriptures Hebrew Bible — CC BY 4.0",
                ]),
                LicenseGroup(title: "Глоси та транслітерація", items: [
                    "Cherith Glosses for the Hebrew Old Testament and the Greek New Testament, Andi Wu — © Cherith Analytics — CC BY 4.0",
                    "SILHA references marked \"SILHA\" are from SIL Hebrew-English Glosses and Annotations for the Westminster Leningrad Codex of the Hebrew Bible, Copyright 2020 SIL International®",
                    "Berean Interlinear Bible — транслітерації та грецькі глоси — суспільне надбання",
                ]),
                LicenseGroup(title: "Лексикони", items: [
                    "Словники Стронга (єврейський і грецький) — суспільне надбання",
                    "TBESH / TBESG — STEPBible.org, на основі праці Tyndale House Cambridge — CC BY 4.0",
                    "Glosses were created by Tyndale scholars",
                    "Hebrew meanings are based on the Abridged BDB by Online Bible, © Larry Pierce of OnlineBible.net",
                    "Greek meanings are based on Abbott-Smith, with Middle Liddell where Abbott-Smith lacks an entry",
                ]),
                LicenseGroup(title: "Переклади", items: [
                    "Біблія в перекладі Івана Огієнка (1988) — Українське Біблійне Товариство — CC BY-SA 4.0 · Вікіджерела",
                    "King James Version (KJV) — суспільне надбання. У Великій Британії права на Authorized Version належать Короні й адмініструються патентовласником Корони, Cambridge University Press",
                    "American Standard Version (ASV) — суспільне надбання",
                    "Синодальний переклад (RST) — суспільне надбання",
                ]),
                LicenseGroup(title: "Коментарі", items: [
                    "Жан Кальвін, Коментарі — суспільне надбання",
                    "Метью Генрі, Коментар на всю Біблію — суспільне надбання",
                    "Чарльз Сперджен, Скарбниця Давида — CC0 1.0",
                    "Джон Овен, Тлумачення Послання до Євреїв — суспільне надбання",
                ]),
                LicenseGroup(title: "Перехресні посилання", items: [
                    "OpenBible.info — CC BY 4.0",
                ]),
                LicenseGroup(title: "Версифікація", items: [
                    "Мапінги версифікації — Copenhagen Alliance — CC BY-SA 4.0",
                ]),
                LicenseGroup(title: "Ілюстрації", items: [
                    "Гюстав Доре, гравюри з La Sainte Bible (1866) — суспільне надбання",
                ]),
                LicenseGroup(title: "Шрифт", items: [
                    "Cormorant, Christian Thalmann / Catharsis Fonts — SIL Open Font License 1.1",
                ]),
                LicenseGroup(title: "Програмні компоненти", items: [
                    "GRDB.swift — ліцензія MIT",
                    "Mixpanel Swift SDK — ліцензія Apache 2.0",
                    "json-logic-swift — ліцензія MIT",
                ]),
            ]
        }
        return [
            LicenseGroup(title: "Original-language texts", items: [
                "MACULA Hebrew & MACULA Greek Linguistic Datasets — © 2022–2024 Biblica, Inc. — CC BY 4.0",
                "github.com/Clear-Bible/macula-hebrew · github.com/Clear-Bible/macula-greek",
                "Hebrew: Westminster Leningrad Codex (Tanach.us) · Greek: Nestle 1904",
                "Westminster Hebrew Syntax — The J. Alan Groves Center — CC BY 4.0",
                "OpenScriptures Hebrew Bible — CC BY 4.0",
            ]),
            LicenseGroup(title: "Glosses & transliteration", items: [
                "Cherith Glosses for the Hebrew Old Testament and the Greek New Testament, by Andi Wu — © Cherith Analytics — CC BY 4.0",
                "SILHA references marked \"SILHA\" are from SIL Hebrew-English Glosses and Annotations for the Westminster Leningrad Codex of the Hebrew Bible, Copyright 2020 SIL International®",
                "Berean Interlinear Bible — transliterations and Greek glosses — Public Domain",
            ]),
            LicenseGroup(title: "Lexicons", items: [
                "Strong's Hebrew & Greek Dictionaries — Public Domain",
                "TBESH / TBESG — STEPBible.org, based on work at Tyndale House Cambridge — CC BY 4.0",
                "Glosses were created by Tyndale scholars",
                "Hebrew meanings are based on the Abridged BDB by Online Bible, © Larry Pierce of OnlineBible.net",
                "Greek meanings are based on Abbott-Smith, with Middle Liddell where Abbott-Smith lacks an entry",
            ]),
            LicenseGroup(title: "Translations", items: [
                "Bible, Ivan Ohiienko Translation (1988) — Ukrainian Bible Society — CC BY-SA 4.0 · Wikisource",
                "King James Version (KJV) — Public Domain. In the United Kingdom, rights in the Authorized Version are vested in the Crown and administered by the Crown's patentee, Cambridge University Press",
                "American Standard Version (ASV) — Public Domain",
                "Russian Synodal Translation (RST) — Public Domain",
            ]),
            LicenseGroup(title: "Commentaries", items: [
                "John Calvin, Commentaries — Public Domain",
                "Matthew Henry, Commentary on the Whole Bible — Public Domain",
                "Charles H. Spurgeon, The Treasury of David — CC0 1.0",
                "John Owen, Exposition of the Epistle to the Hebrews — Public Domain",
            ]),
            LicenseGroup(title: "Cross-references", items: [
                "OpenBible.info Topic & Cross-Reference Data — CC BY 4.0",
            ]),
            LicenseGroup(title: "Versification", items: [
                "Versification mappings — Copenhagen Alliance — CC BY-SA 4.0",
            ]),
            LicenseGroup(title: "Illustrations", items: [
                "Gustave Doré, engravings from La Sainte Bible (1866) — Public Domain",
            ]),
            LicenseGroup(title: "Typeface", items: [
                "Cormorant, by Christian Thalmann / Catharsis Fonts — SIL Open Font License 1.1",
            ]),
            LicenseGroup(title: "Software", items: [
                "GRDB.swift — MIT License",
                "Mixpanel Swift SDK — Apache License 2.0",
                "json-logic-swift — MIT License",
            ]),
        ]
    }
}

#if DEBUG
#Preview {
    NavigationStack { AboutView() }
}
#endif
