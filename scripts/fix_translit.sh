#!/usr/bin/env bash
#
# fix_translit.sh — run the Hebrew transliteration fix end to end.
#
# Fixes two defects in data/hebrew_translit.json:
#   BUG A  wrong verse in every chapter where Masoretic and English numbering
#          diverge (Ps 51:7 currently shows the words of Ps 51:9)
#   BUG B  1SA/2SA/1KI/2KI/1CH/2CH never fetched at all — 4,807 verses, caused
#          by "1-samuel" where BibleHub wants "1_samuel"
#
# The database is never touched. Only data/*.json and data/*.tsv are written,
# and the JSON is backed up before the first write.
#
# Stages, in order. Each one is a gate: the script stops on failure rather than
# carrying a bad map into a five-hour scrape.
#
#   0  preflight   inputs present, python works, scripts in place
#   1  audit       score the CURRENT json against Macula — quantifies the damage
#   2  derive      build the ORG->ENG map and self-check it
#   3  plan        show what would be fetched, no network
#   4  missing     fetch the six absent books        (~65 min)
#   5  shifted     re-fetch the shifted verses       (~45 min)
#   6  audit       score the RESULT — this is the proof the fix worked
#
# Usage:
#   ./fix_translit.sh              # run every stage, pausing before each fetch
#   ./fix_translit.sh --dry-run    # stages 0-3 only, never touches the network
#   ./fix_translit.sh --yes        # no prompts (for a long unattended run)
#   ./fix_translit.sh --from 4     # resume at a stage
#
# Requires: python3, and the repo at the path below.

set -o pipefail

REPO="${SOURCEBIBLE_REPO:-$HOME/Projects/SourceBible}"
PY="${PYTHON:-python3}"
DERIVE="scripts/derive_org_to_eng.py"
FETCH="scripts/fetch_biblehub_translit_hebrew_v2.py"
JSON="data/hebrew_translit.json"

DRY=0; YES=0; FROM=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --yes|-y)  YES=1 ;;
    --from)    FROM="$2"; shift ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

bold=$(printf '\033[1m'); dim=$(printf '\033[2m')
red=$(printf '\033[31m'); grn=$(printf '\033[32m'); ylw=$(printf '\033[33m')
rst=$(printf '\033[0m')

stage() { printf '\n%s══ stage %s — %s%s\n' "$bold" "$1" "$2" "$rst"; }
ok()    { printf '%s  ✓ %s%s\n' "$grn" "$1" "$rst"; }
warn()  { printf '%s  ! %s%s\n' "$ylw" "$1" "$rst"; }
die()   { printf '\n%s  ✗ %s%s\n\n' "$red" "$1" "$rst"; exit 1; }

confirm() {
  [ "$YES" = "1" ] && return 0
  printf '\n%s%s%s\n' "$bold" "$1" "$rst"
  printf 'continue? [y/N] '
  read -r a
  case "$a" in [yY]*) return 0 ;; *) echo "stopped."; exit 0 ;; esac
}

skip_before() { [ "$FROM" -gt "$1" ]; }

# ── 0. preflight ──────────────────────────────────────────────────────────────
stage 0 "preflight"

[ -d "$REPO" ] || die "repo not found: $REPO  (set SOURCEBIBLE_REPO)"
cd "$REPO" || die "cannot cd to $REPO"
ok "repo: $(pwd)"

command -v "$PY" >/dev/null 2>&1 || die "$PY not found"
ok "python: $($PY --version 2>&1)"

for f in "$DERIVE" "$FETCH"; do
  [ -f "$f" ] || die "missing $f — copy it into scripts/ first"
done
ok "scripts present"

for f in data/macula-hebrew-main.zip data/bsb_tables.tsv; do
  [ -f "$f" ] || die "missing input: $f"
done
ok "inputs present"

if [ -f "$JSON" ]; then
  BAK="${JSON}.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$JSON" "$BAK" || die "backup failed"
  ok "backed up $JSON -> $BAK"
else
  warn "$JSON does not exist yet — nothing to back up"
fi

# The DB is read-only from this script's point of view. Say so out loud, because
# CLAUDE.md forbids writing to it from anywhere but the Mac.
ok "sourcebible.db is NOT touched by any stage"

# ── 1. audit the current state ────────────────────────────────────────────────
if ! skip_before 1; then
  stage 1 "audit the CURRENT json — how bad is it right now"
  if [ -f "$JSON" ]; then
    "$PY" "$FETCH" --verify
    rc=$?
    if [ $rc -ne 0 ]; then
      warn "audit failed, which is expected before the fix — this is the baseline"
    else
      ok "current json already passes; the fix may be unnecessary"
    fi
  else
    warn "no json yet, skipping baseline audit"
  fi
fi

# ── 2. derive the ORG->ENG map ────────────────────────────────────────────────
if ! skip_before 2; then
  stage 2 "derive the ORG->ENG map and self-check it"
  "$PY" "$DERIVE" || die "map self-check FAILED — do not scrape against this map.
  Read data/org_to_eng_review.tsv, then re-run just this stage:
      $PY $DERIVE
  If an anchor disagrees, check the verse in a Hebrew and an English Bible
  before changing any code — the anchor may be the thing that is wrong."
  ok "map written and verified: data/org_to_eng.tsv"
fi

# ── 3. plan ───────────────────────────────────────────────────────────────────
if ! skip_before 3; then
  stage 3 "plan — what would be fetched (no network)"
  "$PY" "$FETCH" --plan || die "planning failed"
fi

if [ "$DRY" = "1" ]; then
  printf '\n%s--dry-run: stopping before any network access.%s\n\n' "$dim" "$rst"
  exit 0
fi

# ── 4. the six missing books ──────────────────────────────────────────────────
if ! skip_before 4; then
  stage 4 "fetch the six books that were never scraped (BUG B)"
  confirm "About to fetch ~4,807 pages from biblehub.com at 0.8s each — roughly 65 minutes.
Progress is saved every 200 pages, so this is safe to interrupt and resume with --from 4."
  "$PY" "$FETCH" --missing-only || die "fetch failed; re-run with --from 4 to resume"
  ok "missing books done"
fi

# ── 5. the shifted verses ─────────────────────────────────────────────────────
if ! skip_before 5; then
  stage 5 "re-fetch every verse whose page is not simply its own (BUG A)"
  confirm "This OVERWRITES existing entries — that is the point, the current values
belong to another verse. Selection is NOT the shifted flag alone: it also covers
merged verses (a psalm superscription keeps its verse number but owns only part
of the page) and verses split across two pages. The stage 0 backup is your way back."
  "$PY" "$FETCH" --fix-only --replace-shifted || die "fetch failed; re-run with --from 5"
  ok "shifted, merged and split verses done"
fi

# ── 6. prove it ───────────────────────────────────────────────────────────────
stage 6 "audit the RESULT"
if "$PY" "$FETCH" --verify; then
  printf '\n%s════════════════════════════════════════════════════%s\n' "$grn" "$rst"
  printf '%s  DONE — every stored verse now agrees with Macula.%s\n' "$grn" "$rst"
  printf '%s════════════════════════════════════════════════════%s\n\n' "$grn" "$rst"
  echo "Next, on the Mac only (sourcebible.db is an APFS sparse file):"
  echo "    $PY scripts/build_db.py        # repopulate word.xlit_slot"
  echo
  echo "Then open Ps 50:7 in the app. The transliteration under הֵן should read"
  echo "hen, not tə-ḥaṭ-ṭə-'ê-nî."
  exit 0
else
  printf '\n%s  The audit still reports problems.%s\n' "$ylw" "$rst"
  echo "  Look at data/hebrew_translit_audit.tsv — the verdict column separates"
  echo "  CORRUPT (wrong verse) from SUSPECT (borderline agreement)."
  echo "  Rejected pages, if any, are in data/hebrew_translit_rejected.tsv."
  echo
  echo "  To roll back completely:"
  echo "      cp ${BAK:-<backup>} $JSON"
  exit 1
fi
