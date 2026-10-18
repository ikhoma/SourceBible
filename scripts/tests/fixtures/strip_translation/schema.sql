CREATE TABLE translation (
    id       TEXT PRIMARY KEY,
    name     TEXT,
    language TEXT
);

CREATE TABLE book (
    id        TEXT PRIMARY KEY,
    num       INTEGER UNIQUE,
    testament TEXT,
    name_en   TEXT,
    chapters  INTEGER
);

CREATE TABLE book_name (
    book_id        TEXT NOT NULL,
    translation_id TEXT NOT NULL,
    long_name      TEXT NOT NULL,
    short_name     TEXT NOT NULL,
    sort_order     INTEGER NOT NULL,
    PRIMARY KEY (book_id, translation_id),
    FOREIGN KEY (book_id)        REFERENCES book(id),
    FOREIGN KEY (translation_id) REFERENCES translation(id)
);

CREATE TABLE verse (
    id          TEXT PRIMARY KEY,   -- 'KJV|GEN|1|1'
    translation TEXT NOT NULL,
    book_id     TEXT NOT NULL,
    chapter     INTEGER NOT NULL,
    verse       INTEGER NOT NULL,
    text        TEXT NOT NULL,
    -- Display-ready copy of `text` with ALL inline markup removed (bug-035).
    -- `text` keeps <S>1234</S>/<J>/<i> for the app parser; the FTS5 index reads
    -- THIS column instead, because unicode61 tokenizes <S>6757</S> into the tokens
    -- S | 6757 | S and those break phrase adjacency ("смертной тени" → 0 hits).
    -- INVARIANT: `text` = parser source, `text_clean` = the only thing FTS indexes.
    text_clean  TEXT NOT NULL,
    FOREIGN KEY (translation) REFERENCES translation(id),
    FOREIGN KEY (book_id)     REFERENCES book(id)
);

CREATE TABLE verse_org (
            translation TEXT NOT NULL,
            book_id     TEXT NOT NULL,
            chapter     INTEGER NOT NULL,
            verse       INTEGER NOT NULL,
            org_book_id TEXT,
            org_chapter INTEGER,
            org_verse   INTEGER,
            scheme      TEXT NOT NULL,   -- яка .vrs-схема застосована (або 'empirical'/'override')
            source      TEXT NOT NULL,   -- identity | ubs | empirical | override | none
            verified    INTEGER NOT NULL,
            overlap     INTEGER,
            PRIMARY KEY (translation, book_id, chapter, verse, org_chapter, org_verse)
        );

CREATE TABLE search_terms (
            term TEXT NOT NULL,
            lang TEXT NOT NULL,
            freq INTEGER NOT NULL DEFAULT 1,
            PRIMARY KEY (term, lang)
        ) WITHOUT ROWID;

CREATE TABLE footnote (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    translation  TEXT NOT NULL,
    book_id      TEXT NOT NULL,
    chapter_from INTEGER NOT NULL,
    verse_from   INTEGER NOT NULL,
    chapter_to   INTEGER NOT NULL,
    verse_to     INTEGER NOT NULL,
    marker       TEXT,              -- '[1]', '[2]', … — matches <f> anchor in text
    text         TEXT NOT NULL,
    FOREIGN KEY (translation) REFERENCES translation(id),
    FOREIGN KEY (book_id)     REFERENCES book(id)
);

CREATE VIRTUAL TABLE verse_fts USING fts5(
            text_clean,
            content='verse',
            content_rowid='rowid',
            tokenize='unicode61 remove_diacritics 2'
        );

CREATE INDEX idx_book_name_tid ON book_name(translation_id);

CREATE INDEX idx_verse_loc    ON verse(translation, book_id, chapter, verse);

CREATE INDEX idx_footnote_loc ON footnote(translation, book_id, chapter_from, verse_from);

CREATE INDEX idx_verse_org_rev ON verse_org(translation, org_book_id, org_chapter, org_verse);
