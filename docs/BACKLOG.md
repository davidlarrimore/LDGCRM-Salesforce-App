# Migration backlog

Work that is agreed but not yet built, plus the decisions each item still needs. This is the
engineering-facing companion to the stakeholder report
([`migration-load-report-2026-08-13.html`](migration-load-report-2026-08-13.html)); per-object
build status lives in [`README.md`](README.md) and the field-level detail in
[`TRANSFORMATION-RULES.md`](TRANSFORMATION-RULES.md).

Ordered roughly by value, not by effort.

---

## 1. Assign record owners from Airtable, not the loading user

**Status: BUILT 2026-08-13, not yet loaded.** All four decisions below were answered by the
Partnerships lead on 2026-08-13 and are implemented in the existing `Build-*.ps1` transforms.
**Raised:** 2026-08-13 by the Partnerships lead.

### Decisions taken (2026-08-13)

1. **Fallback owner:** the loading/integration user.
2. **Applications** take their **Partner Account's** owner (*not* Airtable's `Account Owner`, which
   is a rollup from the parent Account).
3. **Contacts** inherit their **Account's** owner.
4. **Existing Accounts are left alone** — but the rules are baked into the core transforms rather
   than applied as a one-off backfill, because a **full wipe and reload** was planned for the same
   day. There is deliberately no `Build-OwnershipBackfill.ps1`.

### How it was implemented

One shared resolver, `Resolve-SalesforceOwnerIds` in `Common.DataMigration.ps1`, used by every
transform. The fallback is expressed as a **blank `OwnerId`**, not an explicit Id — Bulk API 2.0
reads empty as "not supplied", so inserts land on the loading user *and* re-runs don't revert manual
reassignments. Full rationale, the per-object source table, and the three silent
email-to-User resolution traps are in [`TRANSFORMATION-RULES.md`](TRANSFORMATION-RULES.md)'s
"Record ownership" section.

Coverage produced by the rebuilt transforms:

| Object | Owner resolved | Falls back |
| --- | --- | --- |
| Opportunity | 476 of 742 | 266 |
| `LDGCRM_application__c` | 511 of 688 | 177 |
| Contact | 1,116 of 1,943 | 827 |
| Meetings (when built) | 1,315 of 1,845 | 530 |

**⚠️ Contact ownership can't be verified in gsa-peo.** The 2026-08-13 rebuild seeded Accounts
Name-only, so 1,346 of 1,350 Accounts are owned by the loading user — Contacts inherit correctly, but
inherit *that*. The code is right; the sandbox just can't demonstrate it. Seeding Account `OwnerId`
in `Build-ProdAccountSeed.ps1` would fix that if a sandbox demonstration is wanted; it was built
Name-only on the basis that nothing read Account ownership, which is no longer true.

### Original analysis (kept for reference)

### The problem

Every record this migration creates is currently owned by whoever ran the load — in practice a single
person. Verified in gsa-peo:

| Object | Current owner |
| --- | --- |
| Contact (1,936) | all one user |
| Opportunity (742) | all one user |
| `LDGCRM_application__c` (688) | all one user |
| `LDGCRM_Impediment__c` (39) | all one user |
| Account (588) | mixed — these were *matched*, not created, so pre-existing owners survived |

That makes ownership-based reporting, sharing rules and "my records" views meaningless for everything
the migration created. Note the sharing model matters here: Account, Contact, Opportunity and the
three `LDGCRM_` objects all have org-wide-default-restricted sharing with owner-based sharing rules
(see `CLAUDE.md`), so owner is not cosmetic — it decides who can see the record.

### The agreed business rule

> If the Airtable owner has a matching Salesforce User, assign the record to them. If not, fall back
> to a single default owner (the migration/integration user).

Simple, and it degrades safely: no record is ever left unowned, and no owner is ever invented.

### What the source data supports

Owner emails resolved against **active** Salesforce Users. gsa-peo appends `.invalid` to every
sandbox user's email (standard sandbox behaviour), so matching must strip that suffix — this is
already handled in `Build-PartnerAccountLoad.ps1` and can be reused.

| Object | Airtable column | Distinct people | Resolve to a User | No User |
| --- | --- | --- | --- | --- |
| Opportunity | `Pod Opportunity Lead` | 15 | 11 → **541 opportunities** | 4 → **285 opportunities** |
| Partner Account | `Account Owner` | 7 | 5 → 62 rows | 2 → 25 rows |
| Application | `Account Owner` | 7 | 5 → 847 rows | 2 → 155 rows |
| Account | *(none found)* | — | — | — |
| Contact | *(none found)* | — | — | — |

So roughly **two-thirds of Opportunities would get their real owner immediately**, with the remainder
falling back cleanly.

The four unresolvable Opportunity leads are `elizabeth.mays@gsa.gov` (157 opportunities),
`gabriel.vorleto@gsa.gov` (105), `tony.parrilla@gsa.gov` (15) and `sierra.stewart@gsa.gov` (8). The
first two are **already on the data-quality list** from the Partner Account owner analysis — the same
people block ownership in two places, so provisioning or reassigning them fixes both.

### Things to get right when building this

- **`LDGCRM_Partner_Account__c` has no `OwnerId`.** It's a Master-Detail child of Account and inherits
  its parent's owner. Setting the Account owner correctly is what fixes Partner Account ownership —
  there is nothing to set on the child. It *does* have a separate custom `LDGCRM_Partner_Account_Owner__c`
  User lookup, which the migration already populates; that is a different field from record ownership
  and both may need to be right.
- **Application's `Account Owner` is a rollup from the Account**, not the Application's own owner (it
  is excluded from the transform for exactly that reason — see `TRANSFORMATION-RULES.md`). Using it as
  the Application's owner is a judgement call that needs confirming, not an obvious mapping.
- **Account owners are not sourced from Airtable at all** and Accounts already carry real owners in
  Salesforce. The migration should almost certainly *not* touch Account ownership — confirm before
  building.
- **Contact has no owner column in Airtable.** Decide whether Contacts should inherit their Account's
  owner, or stay with the default.
- **Setting `OwnerId` on a Master-Detail parent cascades** to its children. Worth checking the record
  counts this touches before running it broadly.

### Open questions for the Partnerships lead

~~All four answered 2026-08-13 — see "Decisions taken" above.~~

---

## 2. Meetings (1,845 Airtable rows, 0 loaded)

**Status:** not started. **Blocked on three decisions, not one** — the source data was inspected on
2026-08-13 and the mapping is less clean than this entry originally assumed.

### 2a. `Meeting Type` doesn't fit the Salesforce field (the biggest of the three)

`LDGCRM_Meeting_Type__c` on Activity is a **single-value restricted picklist** with 10 values.
Airtable's `Meeting Type` is a **multi-select**, and its values largely don't match:

| Airtable value | Meetings | Salesforce picklist |
| --- | --- | --- |
| `General Follow Up` | 465 | **no match** — SF offers `BD Ad-hoc Follow Up` / `AM Ad-hoc Follow Up` |
| `Launch meeting` | 213 | `Launch Meeting` — differs by case |
| `Internal` | 37 | **no match** |
| `Contact Center` | 30 | **no match** |
| `Informal Sync` | 20 | **no match** |
| `Renewals` | 14 | **no match** |

`Intro Call`, `Technical Consultation`, `AM - Regular Sync`, `Exec Leadership`,
`Quarterly Business Review`, `Networking` and `Demo` all match exactly.

**566 meetings carry a value with no destination**, and **83 rows carry two or more types** against a
single-select field. This reads as a config gap rather than a data problem — the same shape as the
`Login_gov` record-type picklist gap and the Demographic Served expansion, both of which were fixed
by deploying values. **Not being guessed at:** splitting `General Follow Up` into SF's BD vs AM
variants is a human call, per the no-workarounds-for-bad-data rule.

**Needs:** (a) which values to add to the picklist, (b) what `General Follow Up` should become, and
(c) for the 83 multi-type rows — first value wins, or does the field need to become a multi-select?

### 2b. Start/end times (the original blocker)

Airtable records only a **date**, no time. Salesforce Events require both. Needs an agreed convention
(e.g. all-day event, or 09:00 for 60 minutes). Dates run 2024-02-05 → 2026-08-13.

### 2c. 241 meetings have no date at all

230 of them are marked `(Past)`. An Event can't be created without a date, so these are skipped
unless they should become dateless Tasks instead.

### Also worth knowing before building it

- **Link coverage:** 792 → Opportunity, 766 → Account only, and **287 link to neither** — those would
  be Events with no `WhatId` (legal, but floating).
- **`Meeting Leader` is a real owner source** — 1,315 of 1,845 resolve to an active User. This entry
  previously assumed Meetings had no owner column; it does. See item 1.
- Activity is a shared object with the unrelated FCIC and CTI apps (its field list includes
  `CTI_*` and `Template_*` columns), and `TriggerControls__c` has a record for **`Task`** — so
  **check the live org for Event/Task triggers before the first load**, per the standing rule.

---

## 3. Broker application relationships (second pass)

**Status:** not started. Small, self-contained.

`LDGCRM_Broker_App_Parent__c` links an Application to its parent Application. It is **deliberately not
written by the main Application load**: Bulk API does not resolve external-ID references between two
rows in the same batch, which was proven — 68 rows failed even though the parent was in the same file.
It needs a follow-up pass that re-upserts only the external ID and the parent reference, after every
Application exists. Roughly 68 relationships.

---

## 4. Notes (final chunk)

**Status:** not started, and **must be built last** — a note has to attach to a record that already
exists.

Freeform Airtable columns with no dedicated Salesforce field become `ContentNote` records attached to
their parent. Candidates identified so far: Partner Account `Account Description` and `Known Blockers`,
Application `Notes` / `Launch Notes` / `IdV Upgrade Notes`. Mechanically different from every other
chunk — `ContentNote.Content` is base64, and attaching is a second object (`ContentDocumentLink`).
Re-derive the candidate list per table when this is built; don't assume the current list is complete.

---

## 5. Re-run after Airtable cleanup

**Status:** ongoing, no engineering work required.

Every transform re-reads Airtable and re-queries Salesforce, so fixing the items in
[`AIRTABLE-DATA-QUALITY-REQUESTS.md`](AIRTABLE-DATA-QUALITY-REQUESTS.md) and re-running picks up the
newly-valid records automatically. The largest single lever remains the **169 unmatched Accounts**,
which cascade into Partner Accounts → Applications → Application-Contact links, and into Opportunities
→ Opportunity-Impediment links.

---

## 6. Report on automated-pipeline progress, not just record counts

**Status:** partially addressed in the 2026-08-13 report; keep current.

The stakeholder report should show how far the **automated loading process** has been built, not only
how many records exist — the goal is a repeatable pipeline the Operations team can run, not a
one-time data dump. The report now carries a pipeline-progress section covering pull → transform →
load → verify for each object. Keep it updated as chunks are built, and keep reporting what is
*automated* separately from what is *loaded*, since a chunk can be fully built yet mostly blocked by
source data (Application is exactly that: built and proven, 65% loaded).
