#!/usr/bin/env node
// Fill the news page template from SELECTED.md.
//
// Usage: node fill_template.mjs --selected <SELECTED.md> --date 2026-10-13 --out <file.html>
//          [--template <news-template.html>] [--force]
//
// The template holds one marker per section and two date placeholders. Each story is
// escaped to ASCII. The script refuses to overwrite --out unless --force is given.

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

const here = dirname(fileURLToPath(import.meta.url));
const { values } = parseArgs({
  options: {
    selected: { type: "string" },
    date: { type: "string" },
    out: { type: "string" },
    template: { type: "string", default: join(here, "..", "template", "news-template.html") },
    force: { type: "boolean", default: false },
  },
});
for (const key of ["selected", "date", "out"]) {
  if (!values[key]) throw new Error(`--${key} is required`);
}
if (!/^\d{4}-\d{2}-\d{2}$/.test(values.date)) throw new Error(`--date must be YYYY-MM-DD, got ${values.date}`);
if (existsSync(values.out) && !values.force) throw new Error(`refusing to overwrite ${values.out} (use --force)`);

// ---- parse SELECTED.md --------------------------------------------------
const raw = readFileSync(values.selected, "utf8");
const REQUIRED = ["Section", "Rank", "Source", "Title", "Published", "Link", "Image", "Summary"];
const stories = [];
for (const [, id, body] of raw.matchAll(/^## (\d+)\s*\r?\n([\s\S]*?)(?=^## \d+\s*$|(?![\s\S]))/gm)) {
  const fields = {};
  for (const line of body.split(/\r?\n/)) {
    const m = /^([A-Z][A-Za-z ]*):\s*(.*)$/.exec(line);
    if (m) fields[m[1].trim()] = m[2].trim();
  }
  const missing = REQUIRED.filter((f) => !fields[f]);
  if (missing.length) throw new Error(`story ${id} is missing ${missing.join(", ")}`);
  stories.push({ id: Number(id), ...fields });
}
if (stories.length < 2) throw new Error(`need at least 2 stories, parsed ${stories.length}`);

// Dashes are not allowed anywhere in the visible text, literal or as entities.
if (/[–—]|&(ndash|mdash|#8211|#8212|#x2013|#x2014);/.test(raw)) {
  throw new Error("SELECTED.md contains an en or em dash; replace it with a hyphen first");
}

// ---- escaping -----------------------------------------------------------
function esc(value) {
  let out = "";
  for (const ch of value) {
    const code = ch.codePointAt(0);
    out += code < 0x80 ? ch : `&#${code};`;
  }
  return out;
}

// Bare ampersands are legal in text but unsafe in attribute values.
function escAttr(value) {
  return esc(value).replace(/&(?![a-zA-Z][a-zA-Z0-9]*;|#\d+;|#x[0-9a-fA-F]+;)/g, "&amp;");
}

// ---- components ---------------------------------------------------------
function figure(story, role) {
  const url = story.Image;
  if (url === "none" || url === "unverified") return null;
  return [
    `<figure class="fig fig-${role}">`,
    `<img src="${escAttr(url)}" alt="${escAttr(story.Title)}" loading="lazy" referrerpolicy="no-referrer">`,
    `</figure>`,
  ].join("\n");
}

function text(story) {
  const rows = [
    `<p class="eyebrow">${esc(story.Source)}</p>`,
    `<h3 class="headline"><a href="${escAttr(story.Link)}">${esc(story.Title)}</a></h3>`,
    `<p class="summary">${esc(story.Summary)}</p>`,
    `<p class="meta">${esc(story.Published)}</p>`,
  ];
  if (story["Also covered by"]) {
    const m = /^(.*?)\s+(https?:\/\/\S+)$/.exec(story["Also covered by"]);
    if (!m) throw new Error(`cannot parse Also covered by for story ${story.id}`);
    rows.push(`<p class="also">Also covered by: <a href="${escAttr(m[2])}">${esc(m[1])}</a></p>`);
  }
  return rows.join("\n");
}

function article(story, role, extraClass) {
  const cls = ["card", role === "lead" ? "lead" : null, extraClass].filter(Boolean).join(" ");
  const img = figure(story, role);
  // The lead photo sits below its text; card photos sit above it.
  const inner = role === "lead"
    ? [text(story), img].filter(Boolean).join("\n")
    : [img, text(story)].filter(Boolean).join("\n");
  return [`<article class="${cls}">`, inner, `</article>`].join("\n");
}

function sectionHtml(name, id, list) {
  if (list.length < 2) throw new Error(`${name} needs at least 2 stories, has ${list.length}`);
  const [lead, ...cards] = list;
  // The grid is three columns. The last card spans the columns that would otherwise be empty:
  // lead (2) + singles + last card (span) must be a multiple of 3.
  const n = list.length;
  const span = (3 - (n % 3)) % 3 || 3;
  const cardHtml = cards.map((s, i) => {
    const isLast = i === cards.length - 1;
    return article(s, "card", isLast && span > 1 ? `span${span}` : "");
  });
  return [
    `<section class="section" id="${id}">`,
    `<h2 class="section-name">${name}</h2>`,
    `<div class="grid">`,
    article(lead, "lead", ""),
    cardHtml.join("\n"),
    `</div>`,
    `</section>`,
  ].join("\n");
}

// ---- assemble -----------------------------------------------------------
// The template's SECTION markers name the sections, in page order. A story's Section must match one.
let page = readFileSync(values.template, "utf8");
const sections = [...page.matchAll(/<!-- SECTION:([a-z-]+) -->/g)].map((m) => ({
  id: m[1],
  name: stories.find((s) => s.Section.toLowerCase() === m[1])?.Section ?? m[1],
  marker: m[0],
}));
const unknown = [...new Set(stories.map((s) => s.Section))].filter(
  (name) => !sections.some((s) => s.id === name.toLowerCase()),
);
if (unknown.length) throw new Error(`no SECTION marker in the template for: ${unknown.join(", ")}`);

const bySection = (name) =>
  stories.filter((s) => s.Section.toLowerCase() === name).sort((a, b) => Number(a.Rank) - Number(b.Rank));
const DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August",
  "September", "October", "November", "December"];
const d = new Date(`${values.date}T00:00:00Z`);
const dateLong = `${DAYS[d.getUTCDay()]}, ${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]} ${d.getUTCFullYear()}`;

const replacements = [
  ["{{DATE_ISO}}", values.date],
  ["{{DATE_LONG}}", dateLong],
  ...sections.map((s) => [s.marker, sectionHtml(s.name, s.id, bySection(s.id))]),
];

for (const [marker, html] of replacements) {
  if (!page.includes(marker)) throw new Error(`template is missing ${marker}`);
  // A function replacement keeps "$" in story text from being read as a pattern.
  page = page.replace(marker, () => html);
}
if (/\{\{[A-Z_]+\}\}/.test(page)) throw new Error("an unfilled placeholder is left in the page");
if (/[^\x00-\x7F]/.test(page)) throw new Error("the page is not ASCII");

writeFileSync(values.out, page, { encoding: "ascii" });
const counts = sections.map((s) => `${s.name} ${bySection(s.id).length}`).join(", ");
console.log(`wrote ${values.out} (${stories.length} stories: ${counts})`);
