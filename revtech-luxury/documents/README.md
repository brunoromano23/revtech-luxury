# Documents

Deliverables for the RevTech Senior Salesforce Developer case study — a custom CPQ
solution on Salesforce for Luxury Presence.

| # | Document | Markdown | PDF | Status |
|---|---|---|---|---|
| 01 | Business Requirements Document | [`01-business-requirements.md`](01-business-requirements.md) | [`01-business-requirements.pdf`](01-business-requirements.pdf) | v1.0 — for review |
| 02 | Solution Design (data model, ERD, API contract, security, logging) | `02-solution-design.md` | `02-solution-design.pdf` | not started |

Markdown is the source of truth. The PDF is generated from it — edit the `.md`,
then rebuild:

```bash
./documents/tools/build-pdf.sh documents/01-business-requirements.md
```

The build uses `npx marked` for Markdown and headless Google Chrome for the PDF,
so it adds no dependencies to `package.json` and no pandoc/LaTeX toolchain to the
machine. Print styling lives in [`tools/template-head.html`](tools/template-head.html).
