# Documents

Solution design for the Luxury Presence RevTech case study — a custom CPQ on Salesforce.

| Document | File |
|---|---|
| **Solution Design** (submission copy) | [`Luxury Presence — Custom CPQ Solution Design.pdf`](Luxury%20Presence%20%E2%80%94%20Custom%20CPQ%20Solution%20Design.pdf) |
| Markdown source | [`01-solution-design.md`](01-solution-design.md) |

The PDF is the version to read: it carries the entity-relationship diagram, the design-decision
callouts and a table of contents. The Markdown holds the same content in a diff-friendly form.

`tools/` contains a Markdown-to-PDF build (`marked` + headless Chrome, no pandoc or LaTeX) used for
an earlier draft. It is kept because it renders the Mermaid ERD in `01-solution-design.md`:

```bash
./documents/tools/build-pdf.sh documents/01-solution-design.md
```
