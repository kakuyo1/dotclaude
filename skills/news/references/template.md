# The page template

`template/news-template.html` is the approved page with its story content removed. Stage 3
fills it from SELECTED.md, so no page is written from scratch.

## What the template holds

- The full stylesheet from the approved 2026-10-13 page: the cream canvas, the 1200px container,
  the three-column grid, the 1px rules, the 8px image radius, and the 390px breakpoint.
- The masthead with `{{DATE_LONG}}` (the date as in "Tuesday, 13 October 2026").
- The nav row linking to `#international`, `#china`, and `#technology`.
- Three section markers in page order: `<!-- SECTION:international -->`, `<!-- SECTION:china -->`,
  and `<!-- SECTION:technology -->`. The filler replaces each with the markup of the stories whose
  Section matches the marker's name.
- `{{DATE_ISO}}` in the page title.

The template has no story content, no script, and no external resource. It is ASCII.

## Filling it

```bash
node ~/.claude/skills/news/scripts/fill_template.mjs \
  --selected "$HANDOVER/SELECTED.md" \
  --date 2026-10-13 \
  --out "$WORKTREE/news-2026-10-13.html"
```

The filler:

- parses every `## N` block of SELECTED.md, and fails if a block lacks a required field
- sorts each section by Rank, lead first
- escapes story text to ASCII entities and attribute values to `&amp;`
- sets the last card's span so each section's grid has no empty cell
- fails if a story's Section has no marker in the template, or a section has fewer than 2 stories
- fails on any dash in SELECTED.md, any unfilled placeholder, or any non-ASCII byte in the output
- refuses to overwrite an existing file unless `--force` is given

Then screenshot and check it:

```bash
node ~/.claude/skills/news/scripts/shoot_page.mjs \
  --page "$WORKTREE/news-2026-10-13.html" --out "$HANDOVER"
```

Exit 0 means no horizontal overflow at 390px and no image box changed size when its image
loaded. Read the two PNGs with the Read tool before writing REVIEW.md.

## Checking the page structure

Run this after any change to the template or to `fill_template.mjs`, and on each filled page:

```bash
F=<project>/news-<YYYY-MM-DD>-<HHMM>.html
grep -c '<article' "$F"                              # equals the number of selected stories
grep -n 'class="section" id=' "$F"                   # international, china, technology, in that order
grep -n 'href="#' "$F"                               # the nav links, one per section
grep -c -e '<script' -e '<link' -e '@font-face' "$F" # 0
```

The approved 2026-10-13 page has two sections and no China stories, so the template now refuses its
selection. The structure check replaces the diff against that page, which no longer applies.

## Changing the design

Edit `template/news-template.html`, not the generated page. Keep the section markers and the two
placeholders. Then run the structure check above: a failure means the template and the filler
disagree.

DESIGN.md is the reference for the design. Where the approved 2026-10-13 page departs from it,
the departures were deliberate choices recorded in that run's IMPLEMENTATION.md, not defects:
cards and the lead sit on white, and the lead photo sits below its text. Keep them unless the
user decides otherwise.
