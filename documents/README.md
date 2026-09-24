# Documents

Solution design for the Luxury Presence RevTech case study — a custom CPQ on Salesforce.

| Document | Audience | File |
|---|---|---|
| **Solution Design** (submission copy) | Engineering | [`Luxury Presence — Custom CPQ Solution Design.pdf`](Luxury%20Presence%20%E2%80%94%20Custom%20CPQ%20Solution%20Design.pdf) |
| Markdown source | | [`01-solution-design.md`](01-solution-design.md) |
| **Business Briefing** | Operations and Business | [`Luxury Presence — CPQ Business Briefing.pdf`](Luxury%20Presence%20%E2%80%94%20CPQ%20Business%20Briefing.pdf) |
| Markdown source | | [`02-business-briefing.md`](02-business-briefing.md) |

Both PDFs are **generated from the Markdown**, so the two cannot drift. Regenerate them with:

```bash
./documents/tools/build-pdf.sh documents/01-solution-design.md \
  "documents/Luxury Presence — Custom CPQ Solution Design.pdf"

TEMPLATE=documents/tools/template-head-briefing.html \
  ./documents/tools/build-pdf.sh documents/02-business-briefing.md \
  "documents/Luxury Presence — CPQ Business Briefing.pdf"
```

The two documents share `assemble.py` and differ only in their stylesheet, which carries the
running header and footer. `TEMPLATE` selects it; it defaults to the solution design's.

## How the build works

`marked` renders the Markdown; `assemble.py` inlines the SVG diagrams and builds the document
structure — cover, contents, numbered section openers, design-decision callouts, figure captions,
and binding each figure to the heading that introduces it; `template-head.html` carries the house
style; **WeasyPrint** prints it.

Set up once:

```bash
brew install pango gdk-pixbuf libffi
pip3 install weasyprint beautifulsoup4
```

**Why WeasyPrint and not headless Chrome.** Chrome applies a single page size to the entire
document, so the landscape page the ERD needs is impossible there. The alternatives were both bad:
inline at portrait width the diagram scales to 0.43 and cannot be read, and rotating it onto a
portrait page leaves the caption running vertically while the running header and footer stay
horizontal. WeasyPrint supports named pages with their own size (`@page erd { size: A4 landscape }`),
resolves `target-counter` for the contents page numbers natively, and honours `counter(pages)` in
the footer.

It also runs no JavaScript, which is why every structural transform lives in `assemble.py`. That is
the better place for it: the intermediate HTML is a real file you can open when a layout goes wrong,
rather than a DOM that only ever existed inside a browser.

Two things worth knowing before editing the CSS. WeasyPrint's flexbox is incomplete — a flex-based
contents page leaves stray leader fragments floating in the empty half of the page, so the contents
is a table. And `target-counter(attr(href url), page)` returns 0 for every entry; the untyped
`attr(href)` is what resolves.

The Markdown opens with a style specification in an HTML comment. It is instruction for whatever
renders the document, and it is deliberately precise enough that a different tool — or a person —
could reproduce the same house style from the source alone.
