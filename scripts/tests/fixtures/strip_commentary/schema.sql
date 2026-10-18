CREATE TABLE comments(
            key                 TEXT PRIMARY KEY,
            source              TEXT NOT NULL,
            language            TEXT NOT NULL,
            book_id             TEXT NOT NULL,
            start_chapter       INTEGER NOT NULL,
            start_verse         INTEGER NOT NULL,
            end_chapter         INTEGER NOT NULL,
            end_verse           INTEGER NOT NULL,
            text                TEXT NOT NULL,
            origin              TEXT NOT NULL,
            translation_status  TEXT NOT NULL,
            reviewer            TEXT,
            reviewed_at         TEXT
        );

CREATE TABLE comment_verses(
            key      TEXT NOT NULL,
            book_id  TEXT NOT NULL,
            chapter  INTEGER NOT NULL,
            verse    INTEGER NOT NULL,
            PRIMARY KEY (key, book_id, chapter, verse)
        );

CREATE VIRTUAL TABLE comments_fts USING fts5(
            text,
            content='comments',
            content_rowid='rowid',
            tokenize='unicode61 remove_diacritics 2'
        );

CREATE TABLE module_info(name TEXT PRIMARY KEY, value TEXT);

CREATE INDEX idx_comment_verses_lookup ON comment_verses(book_id, chapter, verse);
