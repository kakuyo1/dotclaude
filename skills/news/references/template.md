# The page template

`template/news-template.html` is the approved page with its story content removed. Stage 3
fills it from SELECTED.md, so no page is written from scratch.

## What the template holds

- The full stylesheet from the approved 2026-10-13 page: the cream canvas, the 1200px container,
  the three-column grid, the 1px rules, the 8px image radius, and the 390px breakpoint.
- The masthead with `{{DATE_LONG}}` (the date as in "Tuesday, 13 October 2026").
- The nav row linking to `#international` and `#technology`.
- Two section markers, `<!-- SECTION:international -->` and `<!-- SECTION:technology -->`. The
  filler replaces each with the section's markup.
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
- fails on any dash in SELECTED.md, any unfilled placeholder, or any non-ASCII byte in the output
- refuses to overwrite an existing file unless `--force` is given

Then screenshot and check it:

```bash
node ~/.claude/skills/news/scripts/shoot_page.mjs \
  --page "$WORKTREE/news-2026-10-13.html" --out "$HANDOVER"
```

Exit 0 means no horizontal overflow at 390px and no image box changed size when its image
loaded. Read the two PNGs with the Read tool before writing REVIEW.md.

## Checking the template still matches the approved page

The regression check refills the template from the approved selection of the 2026-10-13 run, kept at `.orca/team/news-html/` (that run predates the dated run folders), and compares it to the
approved page. The only expected difference is the `span3` CSS rule, which the template added
for sections with a multiple of three stories.

```bash
node ~/.claude/skills/news/scripts/fill_template.mjs \
  --selected ~/news/.orca/team/news-html/SELECTED.md --date 2026-10-13 --out "$TEMP/regress.html" --force
diff ~/news/news-2026-10-13-1633.html "$TEMP/regress.html"
```

Run this after any change to the template or to `fill_template.mjs`.

## Changing the design

Edit `template/news-template.html`, not the generated page. Keep the markers and the two
placeholders. Then run the regression check: an unexpected diff means the template and the
filler disagree.

DESIGN.md is the reference for the design. Where the approved 2026-10-13 page departs from it,
the departures were deliberate choices recorded in that run's IMPLEMENTATION.md, not defects:
cards and the lead sit on white, and the lead photo sits below its text. Keep them unless the
user decides otherwise.
