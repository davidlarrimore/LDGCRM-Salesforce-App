# Documentation

**Start here.** This page does one thing: sends you to the right document.

The docs are split by **what you are trying to do**, because the audiences barely overlap. Someone
running a migration does not need the field-by-field mapping rules, and someone changing a transform
does not need the Airtable token setup.

---

## I need to *run* a migration → [`operations/`](operations/)

For anyone loading data into a Salesforce org — including people who have never seen this project.
Read in this order:

| Document | What it covers |
| --- | --- |
| **[operations/SETUP.md](operations/SETUP.md)** | **Start here.** What this project is, the tooling, connecting to a Salesforce org, getting an Airtable token, filling in `.env` |
| **[operations/RUNNING-A-LOAD.md](operations/RUNNING-A-LOAD.md)** | The main guide. Pull → transform → load, the step order and why it matters, approving a load, resuming a failure, verifying the result |
| [operations/TROUBLESHOOTING.md](operations/TROUBLESHOOTING.md) | Every failure this pipeline has actually produced, what the error really means, and how to read the logs |
| [operations/ROLLBACK.md](operations/ROLLBACK.md) | Undoing a load — and what it can never undo |
| [operations/RELOAD-QA-CHECKLIST.md](operations/RELOAD-QA-CHECKLIST.md) | Full wipe-and-reload of a sandbox, with verification at every stage |

> **Two things worth knowing before you touch anything.**
>
> `gsa-peo` means **production**. It used to mean the Dev sandbox, and older notes still say so — any
> command you find using it is a silent retarget to production.
>
> **Nothing writes to Salesforce except the load step.** Every `Build-*.ps1` transform is read-only,
> so you can always see exactly what *would* be written before anything is.

---

## I need to *change* how the migration works → [`engineering/`](engineering/)

For anyone modifying the transforms, adding an object, or working out why something maps the way it
does.

| Document | What it covers |
| --- | --- |
| [engineering/ARCHITECTURE.md](engineering/ARCHITECTURE.md) | How the pipeline is built, per-script status, conventions, load order, environments |
| [engineering/TRANSFORMATION-RULES.md](engineering/TRANSFORMATION-RULES.md) | The authority on field-by-field mapping — every rule and every gotcha, per object |
| [engineering/BACKLOG.md](engineering/BACKLOG.md) | Agreed but unbuilt work, and the decisions each item still needs |
| [engineering/SALESFORCE-CHANGE-REQUESTS.md](engineering/SALESFORCE-CHANGE-REQUESTS.md) | **For the Salesforce config owner.** Things only a change set can fix — field settings blocking a load, and formulas producing wrong numbers |

**Read `TRANSFORMATION-RULES.md`'s General Principles before writing any new transform.** They are
distilled from mistakes that reached a real org, and most of them describe a way Salesforce or
Airtable will mislead you — a field's declared type not matching what it accepts, a picklist that is
valid on the field but not the record type, a linked-record column that turns out to be a rollup.

---

## The source data is wrong → [`data-quality/`](data-quality/)

[data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md](data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md) —
written for the people who own the Airtable base, not for engineers. Every item is something that
**unblocks records** if fixed, ordered by how many.

> **The Salesforce-side equivalent is
> [engineering/SALESFORCE-CHANGE-REQUESTS.md](engineering/SALESFORCE-CHANGE-REQUESTS.md).** When a
> load is blocked by a *field setting* rather than by the data, it belongs there — the pipeline
> cannot route around it, because metadata moves by change set only.

Every transform's review CSVs feed this list. Findings sitting unread in `logs/` are exactly what it
exists to prevent — see [logs/README.md](../logs/README.md).

Keep it to things that unblock records. Zero-impact curiosities dilute it and make the real asks
easier to ignore.

---

## I want the status report → the dated reports in this folder

| File | |
| --- | --- |
| **[migration-load-report-2026-08-13-post-reload.pdf](migration-load-report-2026-08-13-post-reload.pdf)** | **Current.** Written for the Partnerships lead, not for engineers |
| [migration-load-report-2026-08-13.pdf](migration-load-report-2026-08-13.pdf) | Superseded — kept only as the record of what was true when it was sent |

**Send the PDF, not the HTML.** Google Drive renders a standalone `.html` as raw markup. Regenerate
with `scripts/data-migration/Export-ReportPdf.ps1`, which verifies the page count — a failed render
still writes a valid-looking one-page file.

These are **point-in-time snapshots, deliberately dated in the filename.** Both Airtable and the org
stay in active use and the counts have moved several times within a single day. Never edit an old
report to refresh it; generate a new dated one and leave the old as the record.

---

## Elsewhere in the repo

| Path | |
| --- | --- |
| [`../README.md`](../README.md) | Repo front door — what this is, and the quick start |
| [`../CLAUDE.md`](../CLAUDE.md) | Conventions and architecture notes for AI coding assistants |
| [`../logs/README.md`](../logs/README.md) | What every run leaves behind and how to read it |
| [`../data/README.md`](../data/README.md) | Airtable exports and load-ready CSVs |
| `../scripts/` | The automation itself, organised by purpose |
| `../sfdx/` | The Salesforce DX project — retrieved metadata |
