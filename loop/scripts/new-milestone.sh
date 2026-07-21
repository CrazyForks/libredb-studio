#!/usr/bin/env bash
# ==============================================================================
# Open a new maintainer-loop milestone.
#
# Seeds (fresh) or resets (subsequent) the loop's LIVE working state under
# .loop/ from the tracked templates in loop/. .loop/ is gitignored, so loop
# bookkeeping never leaks into a feature/contributor PR; loop/*.template are the
# single source of truth for a pristine milestone.
#
# Source (tracked)                  ->  Live (gitignored, seeded here)
#   loop/PROGRESS.md.template            .loop/PROGRESS.md
#   loop/TRIAGE.md.template              .loop/TRIAGE.md
#   loop/ACCEPTANCE.md.template          .loop/ACCEPTANCE.md
#   loop/IMPLEMENTATION_PLAN.md.template .loop/IMPLEMENTATION_PLAN.md
#   loop/HANDOFF.md.template             .loop/HANDOFF.md   (seeded fresh only)
#   loop/config/loop.env.example         .loop/config/loop.env
#
# On a RESET (a prior .loop/ exists), the previous milestone's working set is
# first archived, then re-seeded from the templates:
#   .loop/archive/<prev>/{PROGRESS,TRIAGE,ACCEPTANCE,IMPLEMENTATION_PLAN}.md
# Two things carry across a reset rather than reverting to template:
#   - TRIAGE.md's "## Not for the loop" section (the anti-re-triage memory)
#   - .loop/HANDOFF.md (planning mode owns it; not reseeded on reset)
# .loop/COMPLETE is removed. Templates use {{MILESTONE}}/{{SENTINEL}} placeholders.
#
# Mutates files only - review the diff and commit; this script never commits
# and never touches git state.
#
# Usage: new-milestone.sh <milestone-name> [root-dir]
#   milestone-name: kebab-case, e.g. sweep-3
#   root-dir: repo root override (used by the unit tests; defaults to the
#             repository this script lives in)
# ==============================================================================

set -euo pipefail

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "Usage: $0 <milestone-name> [root-dir]" >&2
  exit 1
fi

NAME=$1
ROOT="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
TPL_DIR="$ROOT/loop"          # tracked scaffold + templates (source of truth)
LIVE_DIR="$ROOT/.loop"        # gitignored live working state (seeded here)
LIVE_ENV="$LIVE_DIR/config/loop.env"
ENV_EXAMPLE="$TPL_DIR/config/loop.env.example"

if ! printf '%s' "$NAME" | grep -Eq '^[a-z0-9][a-z0-9-]*$'; then
  echo "Milestone name must be kebab-case (got: '$NAME')" >&2
  exit 1
fi

for t in PROGRESS TRIAGE ACCEPTANCE IMPLEMENTATION_PLAN HANDOFF; do
  if [ ! -f "$TPL_DIR/$t.md.template" ]; then
    echo "Missing template: $TPL_DIR/$t.md.template" >&2
    exit 1
  fi
done
if [ ! -f "$ENV_EXAMPLE" ]; then
  echo "Missing template: $ENV_EXAMPLE" >&2
  exit 1
fi

DATE=$(date -u +%Y-%m-%d)
SENTINEL="LIBREDB-STUDIO-$(printf '%s' "$NAME" | tr '[:lower:]' '[:upper:]')-DONE"

# seed <template> <dest> — copy a template, substituting milestone placeholders.
seed() {
  sed -e "s|{{MILESTONE}}|$NAME|g" -e "s|{{SENTINEL}}|$SENTINEL|g" "$1" > "$2"
}

mkdir -p "$LIVE_DIR/config"

if [ ! -f "$LIVE_ENV" ]; then
  # ---- FRESH: no prior live state to archive ----------------------------------
  PREV=""
  seed "$TPL_DIR/HANDOFF.md.template" "$LIVE_DIR/HANDOFF.md"
else
  # ---- RESET: derive previous milestone, archive its working set --------------
  PREV=$(sed -n 's/^LOOP_COMPLETION_SENTINEL="LIBREDB-STUDIO-\(.*\)-DONE"$/\1/p' "$LIVE_ENV" |
    tr '[:upper:]' '[:lower:]')
  PREV="${PREV:-previous}"

  if [ "$PREV" = "$NAME" ]; then
    echo "Milestone '$NAME' is already the current one (sentinel matches) - pick a new name" >&2
    exit 1
  fi

  ARCHIVE="$LIVE_DIR/archive/$PREV"
  if [ -e "$ARCHIVE" ]; then
    echo "Archive already exists: $ARCHIVE - refusing to overwrite history" >&2
    exit 1
  fi
  mkdir -p "$ARCHIVE"

  # PROGRESS: archive everything from "## Log" on.
  awk '/^## Log$/{found=1} found{print}' "$LIVE_DIR/PROGRESS.md" > "$ARCHIVE/PROGRESS.md"
  # TRIAGE: archive the Queue section (stop before "Not for the loop").
  awk '/^## Queue$/{found=1} found && /^## Not for the loop$/{exit} found{print}' \
    "$LIVE_DIR/TRIAGE.md" > "$ARCHIVE/TRIAGE.md"
  # ACCEPTANCE / IMPLEMENTATION_PLAN: archive whole.
  cp "$LIVE_DIR/ACCEPTANCE.md" "$ARCHIVE/ACCEPTANCE.md"
  cp "$LIVE_DIR/IMPLEMENTATION_PLAN.md" "$ARCHIVE/IMPLEMENTATION_PLAN.md"

  # Preserve the live "Not for the loop" section (anti-re-triage memory).
  awk '/^## Not for the loop$/{found=1} found{print}' "$LIVE_DIR/TRIAGE.md" > "$LIVE_DIR/.notforloop.tmp"
fi

# ---- (re)seed the live working set from the templates -------------------------
seed "$TPL_DIR/PROGRESS.md.template" "$LIVE_DIR/PROGRESS.md"
seed "$TPL_DIR/ACCEPTANCE.md.template" "$LIVE_DIR/ACCEPTANCE.md"
seed "$TPL_DIR/IMPLEMENTATION_PLAN.md.template" "$LIVE_DIR/IMPLEMENTATION_PLAN.md"

# TRIAGE: template up to "## Not for the loop"; then the preserved live section
# on a reset, or the template's own section on a fresh seed.
awk '/^## Not for the loop$/{exit} {print}' "$TPL_DIR/TRIAGE.md.template" > "$LIVE_DIR/TRIAGE.md.tmp"
if [ -f "$LIVE_DIR/.notforloop.tmp" ]; then
  cat "$LIVE_DIR/.notforloop.tmp" >> "$LIVE_DIR/TRIAGE.md.tmp"
  rm -f "$LIVE_DIR/.notforloop.tmp"
else
  awk '/^## Not for the loop$/{found=1} found{print}' "$TPL_DIR/TRIAGE.md.template" >> "$LIVE_DIR/TRIAGE.md.tmp"
fi
mv "$LIVE_DIR/TRIAGE.md.tmp" "$LIVE_DIR/TRIAGE.md"

# Append the milestone-opened entry to the fresh PROGRESS log.
{
  printf '\n### %s — Milestone %s opened (human)\n\n' "$DATE" "$NAME"
  if [ -n "$PREV" ]; then
    printf -- '- State reset by `loop/scripts/new-milestone.sh %s`; previous milestone (%s) archived to `.loop/archive/%s/`.\n' "$NAME" "$PREV" "$PREV"
  else
    printf -- '- State seeded by `loop/scripts/new-milestone.sh %s` (fresh; no previous milestone to archive).\n' "$NAME"
  fi
  printf -- '- Next: triage mode over the untriaged open issues.\n'
} >> "$LIVE_DIR/PROGRESS.md"

# loop.env: seed from the example (fresh) or keep the live one (reset), then
# rotate the sentinel and set TRIAGE mode (tmp+mv, portable across GNU/BSD sed).
if [ ! -f "$LIVE_ENV" ]; then
  cp "$ENV_EXAMPLE" "$LIVE_ENV"
fi
sed \
  -e "s|^LOOP_COMPLETION_SENTINEL=.*|LOOP_COMPLETION_SENTINEL=\"$SENTINEL\"|" \
  -e "s|^LOOP_PROMPT_FILE=.*|LOOP_PROMPT_FILE=\"loop/PROMPT-TRIAGE.md\"|" \
  "$LIVE_ENV" > "$LIVE_ENV.tmp"
mv "$LIVE_ENV.tmp" "$LIVE_ENV"

rm -f "$LIVE_DIR/COMPLETE"

if [ -n "$PREV" ]; then
  echo "Milestone '$NAME' opened (previous: '$PREV', archived to .loop/archive/$PREV/)."
else
  echo "Milestone '$NAME' opened (fresh seed; no previous milestone)."
fi
cat << EOF
Sentinel: $SENTINEL | mode: TRIAGE | live state under .loop/ (gitignored).

Next steps:
  1. Review the diff (loop/ scaffold only; .loop/ is gitignored) and commit if anything changed.
  2. Run the full pipeline unattended:  ./loop/scripts/pipeline.sh
  3. When it finishes: review the branch, push, open the PR (always human).
EOF
