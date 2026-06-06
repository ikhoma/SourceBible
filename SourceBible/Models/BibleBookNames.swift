// BibleBookNames.swift
// SourceBible
//
// Single source of truth for Bible book names and short abbreviations in all supported locales.
// Used by DatabaseService (book loading, concordance refs, cross-reference refs),
// NoteEditorView, and VerseContextCard.
//
// Locale is read from UserDefaults directly (not @AppStorage) so this can be called
// from non-View contexts such as DatabaseService and UIKit helpers.

import Foundation

enum BibleBookNames {

    // MARK: - Public API

    /// Locale-aware short abbreviation for a given OSIS book ID.
    /// e.g. "PSA" → "Ps" (EN) / "Пс" (UK)
    static func short(for bookId: String) -> String {
        isUkrainian ? (ukShort[bookId] ?? bookId) : (enShort[bookId] ?? bookId)
    }

    /// Locale-aware full book name for a given OSIS book ID.
    /// e.g. "PSA" → "Psalms" (EN) / "Псалми" (UK)
    static func full(for bookId: String) -> String {
        isUkrainian ? (ukFull[bookId] ?? bookId) : (enFull[bookId] ?? bookId)
    }


    /// Testament for a given OSIS book ID (language-independent).
    static func testament(for bookId: String) -> Testament {
        testamentMap[bookId] ?? .old
    }

    // MARK: - Locale helper

    private static var isUkrainian: Bool {
        UserDefaults.standard.string(forKey: "appLanguage") == "uk"
    }

    // MARK: - Testament map (66 books)

    static let testamentMap: [String: Testament] = {
        var m: [String: Testament] = [:]
        for id in oldTestamentIds { m[id] = .old }
        for id in newTestamentIds { m[id] = .new }
        return m
    }()

    private static let oldTestamentIds: [String] = [
        "GEN","EXO","LEV","NUM","DEU","JOS","JDG","RUT","1SA","2SA",
        "1KI","2KI","1CH","2CH","EZR","NEH","EST","JOB","PSA","PRO",
        "ECC","SNG","ISA","JER","LAM","EZK","DAN","HOS","JOL","AMO",
        "OBA","JON","MIC","NAM","HAB","ZEP","HAG","ZEC","MAL"
    ]
    private static let newTestamentIds: [String] = [
        "MAT","MRK","LUK","JHN","ACT","ROM","1CO","2CO","GAL","EPH",
        "PHP","COL","1TH","2TH","1TI","2TI","TIT","PHM","HEB","JAS",
        "1PE","2PE","1JN","2JN","3JN","JUD","REV"
    ]

    // MARK: - EN short abbreviations (SBL standard)

    static let enShort: [String: String] = [
        // Old Testament
        "GEN":"Gen",  "EXO":"Exod", "LEV":"Lev",  "NUM":"Num",  "DEU":"Deut",
        "JOS":"Josh", "JDG":"Judg", "RUT":"Ruth", "1SA":"1Sam", "2SA":"2Sam",
        "1KI":"1Kgs", "2KI":"2Kgs","1CH":"1Chr", "2CH":"2Chr", "EZR":"Ezra",
        "NEH":"Neh",  "EST":"Esth","JOB":"Job",  "PSA":"Ps",   "PRO":"Prov",
        "ECC":"Eccl", "SNG":"Song","ISA":"Isa",  "JER":"Jer",  "LAM":"Lam",
        "EZK":"Ezek", "DAN":"Dan", "HOS":"Hos",  "JOL":"Joel", "AMO":"Amos",
        "OBA":"Obad", "JON":"Jonah","MIC":"Mic", "NAM":"Nah",  "HAB":"Hab",
        "ZEP":"Zeph", "HAG":"Hag", "ZEC":"Zech","MAL":"Mal",
        // New Testament
        "MAT":"Matt", "MRK":"Mark","LUK":"Luke", "JHN":"John", "ACT":"Acts",
        "ROM":"Rom",  "1CO":"1Cor","2CO":"2Cor", "GAL":"Gal",  "EPH":"Eph",
        "PHP":"Phil", "COL":"Col", "1TH":"1Thes","2TH":"2Thes",
        "1TI":"1Tim", "2TI":"2Tim","TIT":"Titus","PHM":"Phlm", "HEB":"Heb",
        "JAS":"Jas",  "1PE":"1Pet","2PE":"2Pet", "1JN":"1John","2JN":"2John",
        "3JN":"3John","JUD":"Jude","REV":"Rev"
    ]

    // MARK: - EN full names

    static let enFull: [String: String] = [
        // Old Testament
        "GEN":"Genesis",        "EXO":"Exodus",          "LEV":"Leviticus",
        "NUM":"Numbers",        "DEU":"Deuteronomy",     "JOS":"Joshua",
        "JDG":"Judges",         "RUT":"Ruth",            "1SA":"1 Samuel",
        "2SA":"2 Samuel",       "1KI":"1 Kings",         "2KI":"2 Kings",
        "1CH":"1 Chronicles",   "2CH":"2 Chronicles",    "EZR":"Ezra",
        "NEH":"Nehemiah",       "EST":"Esther",          "JOB":"Job",
        "PSA":"Psalms",         "PRO":"Proverbs",        "ECC":"Ecclesiastes",
        "SNG":"Song of Solomon","ISA":"Isaiah",          "JER":"Jeremiah",
        "LAM":"Lamentations",   "EZK":"Ezekiel",         "DAN":"Daniel",
        "HOS":"Hosea",          "JOL":"Joel",            "AMO":"Amos",
        "OBA":"Obadiah",        "JON":"Jonah",           "MIC":"Micah",
        "NAM":"Nahum",          "HAB":"Habakkuk",        "ZEP":"Zephaniah",
        "HAG":"Haggai",         "ZEC":"Zechariah",       "MAL":"Malachi",
        // New Testament
        "MAT":"Matthew",        "MRK":"Mark",            "LUK":"Luke",
        "JHN":"John",           "ACT":"Acts",            "ROM":"Romans",
        "1CO":"1 Corinthians",  "2CO":"2 Corinthians",   "GAL":"Galatians",
        "EPH":"Ephesians",      "PHP":"Philippians",     "COL":"Colossians",
        "1TH":"1 Thessalonians","2TH":"2 Thessalonians", "1TI":"1 Timothy",
        "2TI":"2 Timothy",      "TIT":"Titus",           "PHM":"Philemon",
        "HEB":"Hebrews",        "JAS":"James",           "1PE":"1 Peter",
        "2PE":"2 Peter",        "1JN":"1 John",          "2JN":"2 John",
        "3JN":"3 John",         "JUD":"Jude",            "REV":"Revelation"
    ]

    // MARK: - UK short abbreviations

    static let ukShort: [String: String] = [
        // Old Testament
        "GEN":"Бут",  "EXO":"Вих",  "LEV":"Лев",  "NUM":"Чис",  "DEU":"Втор",
        "JOS":"Нав",  "JDG":"Суд",  "RUT":"Рут",  "1SA":"1Сам", "2SA":"2Сам",
        "1KI":"1Цар", "2KI":"2Цар","1CH":"1Хр",  "2CH":"2Хр",  "EZR":"Езд",
        "NEH":"Неєм", "EST":"Ест",  "JOB":"Йов",  "PSA":"Пс",   "PRO":"Пр",
        "ECC":"Еккл", "SNG":"Піс",  "ISA":"Іс",   "JER":"Єр",   "LAM":"Плач",
        "EZK":"Єз",   "DAN":"Дан",  "HOS":"Ос",   "JOL":"Йоїл", "AMO":"Ам",
        "OBA":"Авд",  "JON":"Йон",  "MIC":"Мих",  "NAM":"Наум", "HAB":"Авак",
        "ZEP":"Соф",  "HAG":"Ог",   "ZEC":"Зах",  "MAL":"Мал",
        // New Testament
        "MAT":"Мт",   "MRK":"Мр",   "LUK":"Лк",   "JHN":"Ів",   "ACT":"Дії",
        "ROM":"Рим",  "1CO":"1Кор", "2CO":"2Кор", "GAL":"Гал",  "EPH":"Еф",
        "PHP":"Флп",  "COL":"Кол",  "1TH":"1Сол", "2TH":"2Сол",
        "1TI":"1Тим", "2TI":"2Тим","TIT":"Тит",  "PHM":"Флм",  "HEB":"Євр",
        "JAS":"Як",   "1PE":"1Пет", "2PE":"2Пет", "1JN":"1Ів",  "2JN":"2Ів",
        "3JN":"3Ів",  "JUD":"Юд",   "REV":"Одкр"
    ]

    // MARK: - UK full names

    static let ukFull: [String: String] = [
        // Old Testament
        "GEN":"Буття",              "EXO":"Вихід",             "LEV":"Левит",
        "NUM":"Числа",              "DEU":"Второзаконня",      "JOS":"Ісуса Навина",
        "JDG":"Суддів",             "RUT":"Рут",               "1SA":"1-а Самуїлова",
        "2SA":"2-а Самуїлова",      "1KI":"1-а Царів",         "2KI":"2-а Царів",
        "1CH":"1-а Хронік",         "2CH":"2-а Хронік",        "EZR":"Ездра",
        "NEH":"Неємія",             "EST":"Естер",             "JOB":"Йов",
        "PSA":"Псалми",             "PRO":"Приповісті",        "ECC":"Екклезіяст",
        "SNG":"Пісня пісень",       "ISA":"Ісая",              "JER":"Єремія",
        "LAM":"Плач Єремії",        "EZK":"Єзекіїль",          "DAN":"Даниїл",
        "HOS":"Осія",               "JOL":"Йоїл",              "AMO":"Амос",
        "OBA":"Авдій",              "JON":"Йона",              "MIC":"Михей",
        "NAM":"Наум",               "HAB":"Авакум",            "ZEP":"Софонія",
        "HAG":"Огій",               "ZEC":"Захарія",           "MAL":"Малахія",
        // New Testament
        "MAT":"Матвія",             "MRK":"Марка",             "LUK":"Луки",
        "JHN":"Івана",              "ACT":"Дії",               "ROM":"Римлян",
        "1CO":"1-а Коринтян",       "2CO":"2-а Коринтян",      "GAL":"Галатян",
        "EPH":"Ефесян",             "PHP":"Филип'ян",          "COL":"Колосян",
        "1TH":"1-а Солунян",        "2TH":"2-а Солунян",       "1TI":"1-а Тимофія",
        "2TI":"2-а Тимофія",        "TIT":"Тита",              "PHM":"Филимона",
        "HEB":"Євреїв",             "JAS":"Якова",             "1PE":"1-а Петра",
        "2PE":"2-а Петра",          "1JN":"1-а Івана",         "2JN":"2-а Івана",
        "3JN":"3-я Івана",          "JUD":"Юди",               "REV":"Об'явлення"
    ]

}
