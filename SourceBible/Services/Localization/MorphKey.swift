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

    static let sectionMorphology      = "morph.section.morphology"
    static let sectionLexical         = "morph.section.lexical"
    /// Interpolated: "Form in Gen 1:1" — use string(for:_:) with ref argument
    static let sectionFormInContext   = "morph.section.form_in_context"
    static let sectionGreekEquiv      = "morph.section.greek_equivalent"

    // MARK: - Row labels (InfoGroup)

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
    static let usageCount             = "word.usage.count"
    /// Interpolated: true total count — "6 512 випадків у Біблії"
    static let usageTotalCount        = "word.usage.total_count"
    /// Pluralized: "1 Occurrence in this Book" / "5 Occurrences in this Book"
    static let usageBookCount         = "word.usage.book_count"
}
