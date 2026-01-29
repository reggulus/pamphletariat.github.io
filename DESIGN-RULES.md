# Site Rules for the Pamphletariat.org Website

This document defines the structural and visual rules that govern the
HTML and CSS for the site. It is the authoritative description of what
the site is allowed to do visually.

---

## Orientation

- The site is an archive for pamphlets: reasoned arguments published pseudonymously.
- It is statically hosted on GitHub Pages.
- Readers come first.
- Content comes second.
- Navigation comes third.

---

## Look and Feel

- The site supports automated light/dark themes based on browser preference. The dark them has white text on a black background. The light theme is black text on a white background and is the default.
- It echoes the look of 1790s print in a modern website.
- The palette is largely black and white.
- Headings use the WarblerDeck font.
- The first H1 heading on all pages except pamphlet pages are centered.
- Body text uses Atkinson Hyperlegible Next.
- All numbers are rendered in WarblerDeck.
- Links are underlined.
- Unvisited links use normal text color.
- Visited links use a muted purple.

---

## Header

- Pages other than the home page have a standard header.
- “Pamphletariat” is a left-aligned Warbler logotype linking to `/`. It never uses a visited color.
- “caveat lector” is right-aligned, italic, faded, and small.

---

## Navigation

- nav.site-nav needs to be centered


## Footer

- Present on all pages.
- The footer begins with an `<hr>`.
- Below the rule is a single line of links separated by dots.

---

## Pages

A general page consists of:

- Header
- Body
- Footer


## Pamphlet Pages

Each pamphlet is a single page with a permanent location.

A pamphlet page consists of:

- Header
- Metadata block
- Pamphlet body
- Footer


### Metadata block

- Metadata appears at the top of the pamphlet page.
- Metadata is displayed quietly and compactly.
- Metadata is not interpreted, explained, or editorialized.
- Any metadata field may be present or absent.
- Metadata ordering is stable but semantic meaning is not encoded in layout.

The metadata block contains, in order:

- Title
- Author · Date
- One or more additional metadata lines (e.g. domain, subject, audience,
  geography, reader warnings, source notes), displayed verbatim if present
- A horizontal rule separating metadata from pamphlet prose

---

## Home Page

- The home page is the primary entry point into the archive.
- It emphasizes discovery over navigation.
- section.home-masthead content should be centered
- h2.home-subtitle should be in WarblerDeck italic

---

## Index Pages

- Index pages list pamphlets or authors.
- They serve as navigational aids, not editorial content.

---

## Normal Pages

- Normal pages live in `/content/pages/`.
