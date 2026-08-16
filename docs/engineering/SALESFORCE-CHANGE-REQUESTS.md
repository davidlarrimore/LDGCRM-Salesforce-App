# Salesforce change requests

> **Who this is for:** whoever owns **Salesforce configuration** and builds change sets — not the
> Airtable data owners, and not the people running loads.
>
> The Airtable-side equivalent is
> [AIRTABLE-DATA-QUALITY-REQUESTS.md](../data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md).

---

## ✅ Nothing is open

**Verified against Dev (`peodv8dvn`) and QA (`peodv15dvn`) on 2026-08-15**, by querying the orgs
rather than reading the change-set record. Every config change that blocked a load has landed in
both.

⚠️ **This says nothing about Full or Prod.** Neither is authorized on this machine, and **no change
set has been promoted to either yet** — so the whole set of changes made in Dev still has to travel
there. That is tracked as gate 3 in
[PRODUCTION-READINESS.md](../PRODUCTION-READINESS.md), not as an item here.

---

## Why this document exists

Metadata promotion in this project is **by change set only** (see `CLAUDE.md`). From this repo a CLI
deploy is sanctioned for exactly one purpose — *deleting* incorrect metadata. Everything additive or
modifying has to be made in Setup and promoted.

So when a load is blocked by a field setting, the pipeline's job is to **describe precisely what needs
changing and stop**, not to deploy it. This file is where that description goes.

## What belongs here

An item earns a place only if **the migration is blocked, or is producing wrong numbers, for a reason
only a config change can fix.** The test: name the records that do not load, or the figure that is
wrong, because of it.

**Not here:** anything the pipeline can route around, and anything cosmetic that never leaves the org
it is in — a deactivated picklist value, a superseded field left behind by a change set that cannot
delete. Those are noise in a document whose value is that everything in it is blocking.

## What does NOT belong here

- **Airtable source data** → [AIRTABLE-DATA-QUALITY-REQUESTS.md](../data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md)
- **Settled business rules**, even ones a config change could have solved differently →
  [TRANSFORMATION-RULES.md](TRANSFORMATION-RULES.md)
- **Unbuilt pipeline work** → [BACKLOG.md](BACKLOG.md)

## Writing a new one

Include the org it was verified against and how. Field-level presence is **not** sufficient evidence
for a picklist change — record-type narrowing is enforced on load and is invisible to
`sf sobject describe`. See TRANSFORMATION-RULES.md, General Principle #6.

**This document lists only what is still open.** Resolved requests are deleted rather than archived —
if a change you made is no longer here, that is the confirmation it landed. Git carries the history.
