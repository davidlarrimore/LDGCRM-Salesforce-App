# Documentation

An index. Everything here routes somewhere else — this file holds no content of
its own, so that there is exactly one place to change when something moves.

Sprint 1 shipped to production on **2026-09-08**. These documents describe the
app as it is **now**; they are not a record of the migration that built it.

## By audience

| Path | Audience | Contents |
| --- | --- | --- |
| [engineering/ARCHITECTURE.md](engineering/ARCHITECTURE.md) | People **changing** the app or its tooling | How the dev/QA loading tools fit together, and what each one does |
| [engineering/TRANSFORMATION-RULES.md](engineering/TRANSFORMATION-RULES.md) | People **changing** the app | Field-by-field mapping rules and the settled business rules. **Rules stay here after they are implemented** |
| [engineering/BACKLOG.md](engineering/BACKLOG.md) | People **changing** the app | Work agreed but **not yet built**. A built item is deleted, not marked done |
| [engineering/PRODUCTION-CHANGE-SET-INVENTORY.md](engineering/PRODUCTION-CHANGE-SET-INVENTORY.md) | GSA IT Engineering | What shipped, component by component. **Generated — never hand-edit** |
| [data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md](data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md) | The **Airtable data owners** | Currently-open asks that cost records on a load |
| [data-quality/SALESFORCE-ACCOUNT-CLEANUP.md](data-quality/SALESFORCE-ACCOUNT-CLEANUP.md) | The **GSA Salesforce team** | Duplicate and misfiled Accounts still present in production |

For conventions aimed at AI coding assistants — PowerShell traps, record-type
scoping, org gotchas — see [CLAUDE.md](../CLAUDE.md) at the repository root.

## Sprint 1

The operator runbooks that shipped with the migration — `SETUP.md`,
`RUNNING-A-LOAD.md`, `DEPLOYMENT-GUIDE.md`, `TROUBLESHOOTING.md`, `ROLLBACK.md`,
`OVERVIEW.md`, `RELOAD-QA-CHECKLIST.md` — are archived, along with the
programme's readiness gates and the project deliverables:

- `archive/sprint_1_scripts.zip` — the operations bundle's code and its runbooks
- `archive/sprint_1_docs.zip` — these docs as they stood at go-live

They describe a pipeline that ran against UAT, a full sandbox and production.
**None of that applies to the tools in `tools/data-loading/`**, which are Dev/QA
only and cannot reach those orgs. Read the archive as history, not instructions.

## ⚠️ EVERY document records what is TRUE NOW

Standing convention. Completed work, resolved items and superseded status are
**deleted** — not struck through, not archived in a "Resolved log", not marked ✅.
Git carries the history; per-run detail lives in that run's `SUMMARY.txt`.

The reason is the one that forced the original reversal: closed items outnumber
open ones within days, and a reader then has to work out which is which. A
1,100-line data-quality document and a 630-line backlog of built work are what
this rule exists to prevent.

Re-measure the survivors in the same change, so every number describes today.

**The one exception is a RULE.** A business or transformation rule stays after it
is implemented, because it describes how the system must behave rather than what
happened. Deleting one as "completed" invites it being re-litigated as an open
question.
