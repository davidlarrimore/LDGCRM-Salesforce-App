# Documentation

## 🎯 Where is the project? → [PRODUCTION-READINESS.md](PRODUCTION-READINESS.md)

**The north star.** What still has to be true before the production load can run, as seven gates with
an owner each. Open it first when picking this project up after time away — it is the only page that
tracks the programme rather than a run, an object, or a script.

Individual loads write their own report to `scripts/logs/data-migration/<run>/SUMMARY.txt`, which is
gitignored and disposable. That tells you what happened once; this tells you where things stand.

---

**Then:** this page sends you to the right document for what you are doing.

The docs are split by **what you are trying to do**, because the audiences barely overlap. Someone
running a migration does not need the field-by-field mapping rules, and someone changing a transform
does not need the Airtable token setup.

---

## I need to *run* a migration → [`../scripts/`](../scripts/)

**These docs moved out of `docs/` on 2026-08-14.** They now live in
[`../scripts/docs/`](../scripts/docs/), beside the code they describe, because the GSA Salesforce
Operations team takes `scripts/` into their own repository and the runbooks have to travel with it.
Start at **[`../scripts/README.md`](../scripts/README.md)**, the bundle's own front door.

For anyone loading data into a Salesforce org — including people who have never seen this project.
Read in this order:

| Document | What it covers |
| --- | --- |
| **[../scripts/docs/SETUP.md](../scripts/docs/SETUP.md)** | **Start here.** What this project is, the tooling, connecting to a Salesforce org, getting an Airtable token, filling in `.env` |
| **[../scripts/docs/RUNNING-A-LOAD.md](../scripts/docs/RUNNING-A-LOAD.md)** | The main guide. Pull → transform → load, the step order and why it matters, approving a load, resuming a failure, verifying the result |
| [../scripts/docs/TROUBLESHOOTING.md](../scripts/docs/TROUBLESHOOTING.md) | Every failure this pipeline has actually produced, what the error really means, and how to read the logs |
| [../scripts/docs/ROLLBACK.md](../scripts/docs/ROLLBACK.md) | Undoing a load — and what it can never undo |
| [../scripts/docs/RELOAD-QA-CHECKLIST.md](../scripts/docs/RELOAD-QA-CHECKLIST.md) | Full wipe-and-reload of a sandbox, with verification at every stage |

> **One thing worth knowing before you touch anything.**
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
| [engineering/PRODUCTION-CHANGE-SET-INVENTORY.md](engineering/PRODUCTION-CHANGE-SET-INVENTORY.md) | **For the GSA IT Engineering team.** Every component in the production change set, to verify against a target org. A dated snapshot — regenerate it rather than editing it |

**Read `TRANSFORMATION-RULES.md`'s General Principles before writing any new transform.** They are
distilled from mistakes that reached a real org, and most of them describe a way Salesforce or
Airtable will mislead you — a field's declared type not matching what it accepts, a picklist that is
valid on the field but not the record type, a linked-record column that turns out to be a rollup.

---

## The source data is wrong → [`data-quality/`](data-quality/)

| Document | Audience | Holds |
| --- | --- | --- |
| [data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md](data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md) | The people who own the **Airtable base**, not engineers | Open asks that **unblock records** if fixed, ordered by how many |
| [data-quality/SALESFORCE-ACCOUNT-CLEANUP.md](data-quality/SALESFORCE-ACCOUNT-CLEANUP.md) | The **GSA Salesforce team** who own Account data in production | Duplicate and misfiled **Accounts in Salesforce**. To be worked **after** the production migration — nothing in it blocks the load |

**Three documents, three different owners — put an item with the one who can fix it:**

- **Airtable data** is wrong → the Airtable list.
- **Salesforce data** is wrong → the Account cleanup list. The migration reconciles onto Accounts it
  did not create, so a duplicate Account in the org is not something the pipeline can route around
  cleanly.
- A **Salesforce field setting** blocks a load →
  [engineering/SALESFORCE-CHANGE-REQUESTS.md](engineering/SALESFORCE-CHANGE-REQUESTS.md). Metadata
  moves by change set only, so the pipeline cannot fix it at all.

Every transform's review CSVs feed this list. Findings sitting unread in `scripts/logs/` are exactly
what it exists to prevent — see [../scripts/logs/README.md](../scripts/logs/README.md).

Keep it to things that unblock records. Zero-impact curiosities dilute it and make the real asks
easier to ignore.

---

## I want the status report → generate one

**There is no report in the repo, by design.** Reports are point-in-time snapshots and both Airtable
and the org stay in active use — counts have moved several times within a single day — so a report is
written when one is asked for and removed once it is superseded. For where the programme stands, use
**[PRODUCTION-READINESS.md](PRODUCTION-READINESS.md)**, which is maintained rather than snapshotted.

To produce one: write `migration-load-report-<date>.html` in this folder, aimed at the Partnerships
lead rather than at engineers, then render it:

```powershell
tools\Export-ReportPdf.ps1 -HtmlPath docs\migration-load-report-<date>.html
```

**Send the PDF, not the HTML.** Google Drive renders a standalone `.html` as raw markup.
`Export-ReportPdf.ps1` verifies the page count — a failed render still writes a valid-looking
one-page file, which is exactly the failure that makes an unverified PDF dangerous to send. The PDF
is gitignored; never edit an old report to refresh it.

---

## Elsewhere in the repo

| Path | |
| --- | --- |
| [`../README.md`](../README.md) | Repo front door — what this is, and the quick start |
| [`../CLAUDE.md`](../CLAUDE.md) | Conventions and architecture notes for AI coding assistants |
| [`../scripts/README.md`](../scripts/README.md) | **The Operations bundle's own front door** — start here to run a load |
| [`../scripts/logs/README.md`](../scripts/logs/README.md) | What every run leaves behind and how to read it |
| [`../scripts/data/README.md`](../scripts/data/README.md) | Airtable exports, the production Account export, and load-ready CSVs |
| `../tools/` | Engineering-only scripts — metadata sync, the report PDF, the bundle packager |
| `../sfdx/` | The Salesforce DX project — retrieved metadata |
