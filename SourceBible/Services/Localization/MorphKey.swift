// MorphKey.swift
// SourceBible
//
// Semantic keys for all morphology labels.
// MorphologyDecoder uses ONLY these constants — never string literals.
// Values resolve to translated strings via TranslationProvider.
//
// ADR-006: docs/architecture/ADR-006-localization-translation-provider.md

enum MorphKey {

    // MARK: - Parts of speech

    static let posVerb            = "morph.pos.verb"
    static let posNoun            = "morph.pos.noun"
    static let posAdjective       = "morph.pos.adjective"
    static let posPronoun         = "morph.pos.pronoun"
    static let posPreposition     = "morph.pos.preposition"
    static let posConjunction     = "morph.pos.conjunction"
    static let posAdverb          = "morph.pos.adverb"
    static let posParticle        = "morph.pos.particle"
    static let posInterjection    = "morph.pos.interjection"
    static let posPronSuffix      = "morph.pos.pronominal_suffix"
    static let posDirObjSuffix    = "morph.pos.direct_object_suffix"
    static let posSuffix          = "morph.pos.suffix"
    static let posArticle         = "morph.pos.article"
    static let posRelPronoun      = "morph.pos.relative_pronoun"
    static let posNegParticle     = "morph.pos.negative_particle"
    static let posInterrogative   = "morph.pos.interrogative"

    // MARK: - Скорочені підписи частин мови
    //
    // ⛔ ТІЛЬКИ для складу слова в рядку вкладки «Оригінал», де ширини мало.
    // У вкладці «Слово» лишаються повні назви: там місця вистачає, і саме там
    // людина розбирається, а не сканує список.
    //
    // EN «noun»/«verb» навмисно НЕ скорочені до «n.»/«v.» — вони й так короткі,
    // а односимвольні позначки читаються як нотація для тих, хто вже в темі.

    static let posShortVerb           = "morph.pos.short.verb"
    static let posShortNoun           = "morph.pos.short.noun"
    static let posShortAdjective      = "morph.pos.short.adjective"
    static let posShortPronoun        = "morph.pos.short.pronoun"
    static let posShortPreposition    = "morph.pos.short.preposition"
    static let posShortConjunction    = "morph.pos.short.conjunction"
    static let posShortAdverb         = "morph.pos.short.adverb"
    static let posShortParticle       = "morph.pos.short.particle"
    static let posShortInterjection   = "morph.pos.short.interjection"
    static let posShortPronSuffix     = "morph.pos.short.pronominal_suffix"
    static let posShortDirObjSuffix   = "morph.pos.short.direct_object_suffix"
    static let posShortSuffix         = "morph.pos.short.suffix"
    static let posShortArticle        = "morph.pos.short.article"
    static let posShortRelPronoun     = "morph.pos.short.relative_pronoun"
    static let posShortNegParticle    = "morph.pos.short.negative_particle"
    static let posShortInterrogative  = "morph.pos.short.interrogative"

    // MARK: - Hebrew verbal stems (Binyanim)
    // Stem names (Qal, Niphal…) are scholarly proper nouns — not translated.
    // Only the description after the dash is localized.

    static let stemQal            = "morph.stem.qal"
    static let stemNiphal         = "morph.stem.niphal"
    static let stemPiel           = "morph.stem.piel"
    static let stemPual           = "morph.stem.pual"
    static let stemHiphil         = "morph.stem.hiphil"
    static let stemHophal         = "morph.stem.hophal"
    static let stemHithpael       = "morph.stem.hithpael"
    static let stemPoel           = "morph.stem.poel"

    // MARK: - Hebrew verbal aspects / conjugation forms

    static let aspectPerfect          = "morph.aspect.perfect"
    static let aspectImperfect        = "morph.aspect.imperfect"
    static let aspectWayyiqtol        = "morph.aspect.wayyiqtol"
    static let aspectJussive          = "morph.aspect.jussive"
    static let aspectCohortative      = "morph.aspect.cohortative"
    static let aspectImperative       = "morph.aspect.imperative"
    static let aspectParticipleActive = "morph.aspect.participle_active"
    static let aspectParticiplePassive = "morph.aspect.participle_passive"
    static let aspectInfAbsolute      = "morph.aspect.infinitive_absolute"
    static let aspectInfConstruct     = "morph.aspect.infinitive_construct"

    // MARK: - Person

    static let person1                = "morph.person.1"
    static let person2                = "morph.person.2"
    static let person3                = "morph.person.3"

    // MARK: - Gender

    static let genderMasculine        = "morph.gender.masculine"
    static let genderFeminine         = "morph.gender.feminine"
    static let genderCommon           = "morph.gender.common"

    // MARK: - Number

    static let numberSingular         = "morph.number.singular"
    static let numberPlural           = "morph.number.plural"
    static let numberDual             = "morph.number.dual"

    // MARK: - State (Hebrew nouns)

    static let stateAbsolute          = "morph.state.absolute"
    static let stateConstruct         = "morph.state.construct"
    static let stateDetermined        = "morph.state.determined"

    // MARK: - Section labels (WordMeaningView)

    static let sectionLemma           = "morph.section.lemma"
    static let sectionMorphology      = "morph.section.morphology"
    static let sectionLexical         = "morph.section.lexical"
    /// Interpolated: "Form in Gen 1:1" — use string(for:_:) with ref argument
    static let sectionFormInContext   = "morph.section.form_in_context"
    static let sectionGreekEquiv      = "morph.section.greek_equivalent"
    /// Позначка біля породи, що збігається з розібраною формою (ADR-033).
    static let stemFormInVerse        = "morph.stem.form_in_verse"

    // MARK: - Row labels (InfoGroup)

    /// Склад складеного слова: «артикль + іменник».
    static let rowComposition         = "morph.row.composition"
    static let rowPartOfSpeech        = "morph.row.part_of_speech"
    static let rowStem                = "morph.row.stem"
    static let rowAspect              = "morph.row.aspect"
    static let rowGrammaticalForm     = "morph.row.grammatical_form"
    static let rowSyntaxRole          = "morph.row.syntax_role"
    static let rowWord                = "morph.row.word"
    static let rowTransliteration     = "morph.row.transliteration"
    static let rowStrongs             = "morph.row.strongs"

    // MARK: - Syntax roles

    static let syntaxPredicate        = "morph.syntax.predicate"
    static let syntaxPredicateNominal = "morph.syntax.predicate_nominal"
    static let syntaxSubject          = "morph.syntax.subject"
    static let syntaxObject           = "morph.syntax.object"
    static let syntaxCircumstance     = "morph.syntax.circumstance"
    static let syntaxAdverb           = "morph.syntax.adverb_role"

    // MARK: - Word tab

    static let tabMeaning             = "word.tab.meaning"
    static let tabUsage               = "word.tab.usage"
    static let emptyNoData            = "word.empty.no_data"
    static let emptyTapHint           = "word.empty.tap_hint"
    /// Interpolated: "42 occurrences in the Bible" — legacy key, kept for reference
    /// Interpolated: true total count — "6 512 випадків у Біблії"
    static let usageTotalCount        = "word.usage.total_count"
    /// Pluralized: "1 Occurrence in this Book" / "5 Occurrences in this Book"
    static let usageBookCount         = "word.usage.book_count"

    // MARK: - ADR-040: new morphology categories (source-field columns)

    // MARK: - Row labels

    static let rowCase                   = "morph.row.case"
    static let rowTense                  = "morph.row.tense"
    static let rowVoice                  = "morph.row.voice"
    static let rowMood                   = "morph.row.mood"
    static let rowDegree                 = "morph.row.degree"
    static let rowNonFiniteForm          = "morph.row.non_finite_form"

    // MARK: - Case (Greek)

    static let caseNominative            = "morph.case.nominative"
    static let caseGenitive              = "morph.case.genitive"
    static let caseDative                = "morph.case.dative"
    static let caseAccusative            = "morph.case.accusative"
    static let caseVocative              = "morph.case.vocative"

    // MARK: - Tense (Greek)

    static let tenseAorist               = "morph.tense.aorist"
    static let tensePresent              = "morph.tense.present"
    static let tenseImperfect            = "morph.tense.imperfect"
    static let tenseFuture               = "morph.tense.future"
    static let tensePerfect              = "morph.tense.perfect"
    static let tensePluperfect           = "morph.tense.pluperfect"

    // MARK: - Voice (Greek)

    static let voiceActive               = "morph.voice.active"
    static let voiceMiddle               = "morph.voice.middle"
    static let voicePassive              = "morph.voice.passive"
    static let voiceMiddlePassive        = "morph.voice.middlepassive"

    // MARK: - Mood (Greek) — 4 real moods only; participle/infinitive are a non-finite form, not a mood

    static let moodIndicative            = "morph.mood.indicative"
    static let moodImperative            = "morph.mood.imperative"
    static let moodSubjunctive           = "morph.mood.subjunctive"
    static let moodOptative              = "morph.mood.optative"

    // MARK: - Degree (Greek) — positive/default is not shown

    static let degreeComparative         = "morph.degree.comparative"
    static let degreeSuperlative         = "morph.degree.superlative"

    // MARK: - Non-finite form (Greek) — participle/infinitive, split out of `mood`

    static let nonFiniteParticiple       = "morph.non_finite_form.participle"
    static let nonFiniteInfinitive       = "morph.non_finite_form.infinitive"

    // MARK: - Gender — Greek adds neuter

    static let genderNeuter              = "morph.gender.neuter"

    // MARK: - Aramaic/Hebrew verbal stems — ADR-040 (34 total; 8 already above)

    static let stemPeal                  = "morph.stem.peal"
    static let stemPeil                  = "morph.stem.peil"
    static let stemPael                  = "morph.stem.pael"
    static let stemHaphel                = "morph.stem.haphel"
    static let stemAphel                 = "morph.stem.aphel"
    static let stemShaphel               = "morph.stem.shaphel"
    static let stemSaphel                = "morph.stem.saphel"
    static let stemHithpaal              = "morph.stem.hithpaal"
    static let stemIthpaal               = "morph.stem.ithpaal"
    static let stemHithpeel              = "morph.stem.hithpeel"
    static let stemIthpeel               = "morph.stem.ithpeel"
    static let stemIthpoel               = "morph.stem.ithpoel"
    static let stemHishtaphel            = "morph.stem.hishtaphel"
    static let stemNithpael              = "morph.stem.nithpael"
    static let stemHithpolel             = "morph.stem.hithpolel"
    static let stemPolel                 = "morph.stem.polel"
    static let stemPolal                 = "morph.stem.polal"
    static let stemPolpal                = "morph.stem.polpal"
    static let stemPilpel                = "morph.stem.pilpel"
    static let stemPilel                 = "morph.stem.pilel"
    static let stemPalel                 = "morph.stem.palel"
    static let stemPealal                = "morph.stem.pealal"
    static let stemPoal                  = "morph.stem.poal"
    static let stemPulal                 = "morph.stem.pulal"
    static let stemQalPassive            = "morph.stem.qal_passive"
    static let stemHithpalpel             = "morph.stem.hithpalpel"

    // MARK: - Hebrew aspect — weqatal (11th verb-relevant `morph_type` value)

    static let aspectWeqatal             = "morph.aspect.weqatal"

    // MARK: - Greek POS from morph-code prefix (bug-053)

    static let posPersonalPronoun        = "morph.pos.personal_pronoun"
    static let posDemonstrativePronoun   = "morph.pos.demonstrative_pronoun"
    static let posInterrogativePronoun   = "morph.pos.interrogative_pronoun"
    static let posIndefinitePronoun      = "morph.pos.indefinite_pronoun"
    static let posReflexivePronoun       = "morph.pos.reflexive_pronoun"
    static let posPossessivePronoun      = "morph.pos.possessive_pronoun"
    static let posCorrelativePronoun     = "morph.pos.correlative_pronoun"
    static let posReciprocalPronoun      = "morph.pos.reciprocal_pronoun"
    static let posHebrewTerm             = "morph.pos.hebrew_term"
    static let posAramaicTerm            = "morph.pos.aramaic_term"
}
