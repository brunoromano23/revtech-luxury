# Documents

Deliverable for the RevTech Senior Salesforce Developer case study — a custom CPQ
solution on Salesforce for Luxury Presence.

| # | Document | Markdown | PDF |
|---|---|---|---|
| 01 | Solution Design | [`01-solution-design.md`](01-solution-design.md) | [`01-solution-design.pdf`](01-solution-design.pdf) |

Markdown is the source of truth. The PDF is generated from it — edit the `.md`,
then rebuild:

```bash
./documents/tools/build-pdf.sh documents/01-solution-design.md
```

The build uses `npx marked` for Markdown, [Mermaid](https://mermaid.js.org) for the
ERD and headless Google Chrome to print, so it adds nothing to `package.json` and
needs no pandoc/LaTeX toolchain. Print styling lives in
[`tools/template-head.html`](tools/template-head.html); the Mermaid bootstrap in
[`tools/template-foot.html`](tools/template-foot.html).
