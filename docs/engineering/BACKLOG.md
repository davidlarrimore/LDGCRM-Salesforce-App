# Migration backlog

> **Who this is for:** engineers picking up the next piece of work, and anyone asking "is this
> already known?" Each item records the decisions it still needs, not just the task.

Work that is agreed but not yet built. This is the engineering-facing companion to the
[stakeholder report](../migration-load-report-2026-08-14.html); overall readiness for the
production load is tracked in [PRODUCTION-READINESS.md](../PRODUCTION-READINESS.md), per-object build status
lives in [ARCHITECTURE.md](ARCHITECTURE.md) and the field-level detail in
[TRANSFORMATION-RULES.md](TRANSFORMATION-RULES.md).

Ordered roughly by value, not by effort.

---

## 1. Assign record owners from Airtable, not the loading user

**Status: BUILT and LOADED 2026-08-13.** All four decisions below were answered by the Partnerships
lead on 2026-08-13, implemented in the existing `Build-*.ps1` transforms, and proven by a full
wipe-and-reload the same day. Measured results replace the predicted ones below.
**Raised:** 2026-08-13 by the Partnerships lead.

### Decisions taken (2026-08-13)

1. **Fallback owner:** `peter.marks@gsa.gov`. *(Revised from "the loading user" once it was confirmed
   GSA IT Operations runs the production load — see below.)*
2. **Applications** take their **Partner Account's** owner (*not* Airtable's `Account Owner`, which
   is a rollup from the parent Account).
3. **Contacts** inherit their **Account's** owner.
4. **Existing Accounts are left alone** — but the rules are baked into the core transforms rather
   than applied as a one-off backfill, because a **full wipe and reload** was planned for the same
   day. There is deliberately no `Build-OwnershipBackfill.ps1`.

### How it was implemented

Two shared resolvers in `Common.DataMigration.ps1`, used by every transform:
`Resolve-SalesforceOwnerIds` (email → active User, fixing three silent traps the hand-rolled version
had) and `Resolve-FallbackOwnerId`, which resolves `-FallbackOwnerEmail` at run time and **throws**
if it doesn't match an active User.

**The fallback is written explicitly, not left blank — this reversed the original design.** Blank
meant "whoever ran the load", which was fine while that was the intended owner and wrong the moment
GSA IT Operations took over the production run. Cost of the reversal: a re-run now re-asserts the
fallback owner, so a manual reassignment of a fallback-owned record gets reverted. Full rationale in
[`TRANSFORMATION-RULES.md`](TRANSFORMATION-RULES.md)'s "Record ownership" section.

**Status update 2026-08-13: LOADED and verified.** The full reload ran and ownership is now real data
in Dev, not a prediction. Measured coverage:

| Object | Own owner | Fallback | Predicted before loading |
| --- | --- | --- | --- |
| Opportunity | 471 | 271 | 471 / 271 ✅ |
| `LDGCRM_application__c` | **361** | **327** | 511 / 177 ❌ — see below |
| Contact | 1,548 | 0 | 1,553 / 0 — but see the warning |
| `LDGCRM_Impediment__c` | 0 | 39 | 0 / 39 ✅ |
| `LDGCRM_Application_Contact__c` | 0 | 1,878 | 0 / 1,880 ✅ |
| Meetings (when built) | 1,315 of 1,845 | 530 | *(not built — still a prediction)* |

**Two things only a real load could establish:**

1. **Application was 511/177 in prediction and is 361/327 in fact.** 150 Applications inherit an owner
   who is *active* but cannot own records — a Chatter Free user. Salesforce rejected them with
   `OP_WITH_INVALID_USER_TYPE_EXCEPTION`. Fixed by filtering owner resolution on
   `UserType = 'Standard'` in all four places a User Id becomes an `OwnerId`. Full detail in
   [`TRANSFORMATION-RULES.md`](TRANSFORMATION-RULES.md).
2. **Contact ownership is now demonstrable, and it confirms the D2 concern precisely.** Of 1,548
   Contacts, **1,426 (92%) are owned by `SystemUser DataLoader`** and 122 by the loading user. The
   analysis predicted ~92% under a service account or one person; the measurement is 92%. The rule
   works as designed and produces ownership data that carries almost no information. That is now
   evidence for revisiting D2, not an argument about it.

**⚠️ Contact ownership can't be verified in the sandbox, and may not be worth having in production.**
The Account bootstrap loads Name + hierarchy only, so nearly every sandbox Account is owned by the
loading user and Contacts inherit *that*. It cannot easily be fixed either: the production export
names Account owners by display name, not email. And in production, 92% of Accounts are owned by
`SystemUser DataLoader` or one individual — so inheritance would put 92% of Contacts under one of
those two. Confirmed as-is on 2026-08-13; revisit if ownership reporting proves misleading.

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

## 2. Meetings (1,845 Airtable rows, 0 loaded) — approach changed 2026-08-13

**Status: deferred by decision, and no longer a straight transform.** It now depends on an org
configuration change that sits outside this repo. **The reload should proceed without Meetings.**

### Why the original approach was rejected

Airtable records a meeting **date only** — no start time, no end time, no duration. Salesforce Events
require both. Every option for closing that gap invents data: a fixed 09:00 start would have had
1,604 meetings all claiming to begin at 9am, and even an all-day event asserts a shape the source
never recorded.

**The decision (2026-08-13): don't synthesize the time — get the real one.**

### The agreed approach

1. **Stand up Einstein Activity Capture (EAC)** so users' actual Google Calendar events sync into
   Salesforce and associate themselves with Salesforce records.
   *(Correct product name: **Einstein Activity Capture**. Searching for "Einstein Activity Monitor"
   finds nothing — worth knowing before anyone opens a ticket.)*
2. **Match each Airtable Meeting to the real calendar event** it describes, using fuzzy criteria
   across date, organizer, attendees and subject.
3. **Enrich the matched event** with what Airtable holds and a calendar entry doesn't — `Summary`,
   `Action Items`, `Agenda`, `Notes`, `Meeting Type` — rather than creating a duplicate meeting.

The real calendar supplies the times; Airtable supplies the meaning. Neither is fabricated.

---

### ⚠️ Prerequisite spike — do this before designing anything further

**One unknown determines whether the rest of this plan is buildable at all**, and it must be answered
against the actual org rather than from documentation:

> **Do EAC-captured events exist as standard `Event` records, or in Einstein Activity Capture's own
> data store?**

EAC has historically stored captured activity in a separate store surfaced through the Activity
Timeline, **not** as standard `Event` sObjects. If that holds here, the events are not reliably
queryable via SOQL, and the entire matching design below — which assumes we can query candidate
events — needs rethinking. If they do land as standard `Event` records, the design works as written.

Also confirm, in the same spike:

- **Retention window.** How far back does captured activity persist? This data spans
  **2024-02-05 → 2026-08-13**: 125 meetings in 2024, 931 in 2025, 548 in 2026. A 24-month window
  loses most of 2024; a 6-month window loses nearly everything.
- **Backfill vs forward-only.** Does connecting a calendar import history, or only capture from
  setup onward? If forward-only, **no historical meeting will ever match** and this approach only
  helps meetings held after go-live.
- **Licensing**, and which users are actually covered.

### ⚠️ A hard coverage ceiling that exists regardless of the spike

EAC syncs **per user, from that user's connected calendar**. A meeting can only be matched if its
organizer has an active Salesforce user with a connected calendar.

From the ownership analysis: **1,315 of 1,845 meetings have a Meeting Leader who resolves to an
active Salesforce User.** The remaining 530 are led by people who are deactivated or have no user at
all (`elizabeth.mays@gsa.gov` alone leads 182). **Those meetings can never sync**, because there is
no calendar to connect. That is a ceiling of roughly **71%**, before any matching accuracy is
considered — and it overlaps exactly with the missing-logins item in
[`AIRTABLE-DATA-QUALITY-REQUESTS.md`](../data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md), so provisioning those users
raises this ceiling as well as fixing record ownership.

---

### Matching design (proposed)

**Signals Airtable actually provides**, verified against the export:

| Signal | Coverage | Quality |
| --- | --- | --- |
| `Date` | 1,604 / 1,845 | Exact day. The natural blocking key. |
| `Meeting Leader` | 1,622 | **Structured** — collaborator object with a real email. Strongest signal; maps to the calendar organizer. |
| `Internal Attendees` | 1,279 | **Structured** — array of collaborator objects with emails. Excellent for attendee-overlap scoring. |
| `Topic` | 1,845 | Free text, always present. |
| `Meeting Name` | 1,633 | Free text, closest thing to a calendar subject. |
| `External Attendees` | 1,015 | **Inconsistent free text** — some rows are RFC-style `"Name" <email>` lists, others are bullet lists of bare names with no address at all. Parse opportunistically; treat as a weak signal only. |
| `Accounts Record ID` / `Opportunity Record ID` | 1,522 / 792 | Contextual confirmation against the event's `WhatId`. |

**Proposed algorithm:**

1. **Block on date** — candidate events on the same calendar day (allow ±1 day for timezone drift).
   This alone reduces the search space enormously and is cheap.
2. **Require organizer agreement** — Airtable `Meeting Leader` email = the event's organizer/owner.
   Treat this as a near-hard gate rather than a score component; two different people's meetings on
   the same day are not the same meeting.
3. **Score the remainder**, weighted:
   - internal-attendee email overlap (Jaccard) — the highest-signal fuzzy component, since both
     sides are structured emails;
   - subject similarity (`Meeting Name` / `Topic` vs event subject), normalized and token-based;
   - `WhatId` agreement with Airtable's Account / Opportunity;
   - parsed external-attendee overlap where addresses exist.
4. **Auto-link only unambiguous, high-confidence matches.** One candidate clearly above threshold →
   link. Two plausible candidates → **review CSV, not a guess.** This follows the rule the rest of
   this pipeline already runs on: load what is genuinely clean, report the rest.
5. **Idempotency** — stamp the matched event with the Airtable `Meeting Record ID` in
   `LDGCRM_External_ID__c` so re-runs match rather than duplicate.

**Thresholds must be tuned against real synced data, not guessed in advance.** Expect the first pass
to be run in report-only mode and the weights adjusted from its output.

### Open question: what happens to meetings that never match

Likely the majority, given the coverage ceiling and retention limits. Needs a decision — this is the
main thing to settle once the spike reports back:

- **(a) Don't migrate them.** Cleanest, loses ~2 years of meeting summaries and action items.
- **(b) Attach them as Notes** to their Account or Opportunity. Preserves `Summary` / `Action Items`
  / `Agenda` verbatim without pretending a calendar event existed. Fits naturally with the Notes
  chunk (item 4) and needs no invented times — **currently the most attractive option.**
- **(c) Create an all-day Event as a fallback.** Returns to the fabrication this decision rejected,
  but only for records that would otherwise be lost.

### Decisions still inherited from the original design

These do not go away — they apply to whatever record ultimately carries the meeting:

- **`Meeting Type` doesn't fit the field.** `LDGCRM_Meeting_Type__c` is a **single-value restricted
  picklist**; Airtable's is a **multi-select** whose values largely don't match. 566 meetings carry a
  value with no valid target (`General Follow Up` 465, `Internal` 37, `Contact Center` 30,
  `Informal Sync` 20, `Renewals` 14) and `Launch meeting` differs from `Launch Meeting` only by case.
  83 rows carry two or more types. Reads as a config gap — the same shape as the `Login_gov`
  record-type fix — but splitting `General Follow Up` between Salesforce's `BD Ad-hoc Follow Up` and
  `AM Ad-hoc Follow Up` is a human call, not a guess.
- **241 meetings have no date at all** (230 marked `(Past)`). These cannot be matched by date and
  cannot become an Event; they are the strongest candidates for option (b) above.
- **287 link to neither an Opportunity nor an Account.**

### Also worth knowing before building it

Activity is shared with the unrelated FCIC and CTI apps (its field list carries `CTI_*` and
`Template_*` columns) and `TriggerControls__c` has a record for **`Task`** — so **check the live org
for Event/Task triggers before the first load**, per the standing rule that burned the Contact load.

---

## 3. Broker application relationships (second pass)

**Status: BUILT and LOADED 2026-08-13 — 63/63, 0 failures.** The ordering held: no
`Foreign key external ID ... not found` errors, confirming the second pass resolves correctly once
the main Application file is in the org.

`LDGCRM_Broker_App_Parent__c` links an Application to its parent Application. It cannot go in the main
upsert file: Bulk API does not resolve external-ID references between two rows of the same batch,
proven when 68 rows failed with the parent sitting in the same file.

**`Build-ApplicationLoad.ps1` now writes the second-pass file automatically**
(`LDGCRM_application__c-broker-parent-upsert.csv`) — deliberately not a separate transform script,
since a pass you have to remember to run is one you eventually forget. Only the *load* is separate,
and it must come **after** the main Application load; the transform prints the exact command.

A row is emitted only when both sides will exist once the main load finishes (planned set ∪ what's
already in the org), so a re-run picks up newly-resolvable links with no code change.

Of 70 Airtable rows carrying a Broker App Parent: **63 ready**, 6 waiting on an Application withheld
by the Account data-quality issue, and **1 dropped as a self-reference** (`ACF Login.gov
ACF-ockta-oidc` lists itself as its own parent). The self-reference is handled entirely in code and
**not raised with the data owners**: it costs one optional lookup on one record that otherwise
migrates fine, so it fails the "does this unblock anything?" test the data-quality list exists to
meet. No longer cycles exist, and the deepest chain is 1, so no multi-pass hierarchy walk is needed
(unlike the Account bootstrap, which goes four levels deep).

---

## 4. Notes (final chunk)

**Status: BUILT and LOADED 2026-08-13 — 537 created, 537 attached, 0 failures, 537 verified in the
org.** Sharing landed as `ShareType=I` / `Visibility=InternalUsers` as decided. 200 notes remain
withheld pending the Airtable Account fixes, and 59 placeholder values (`None`/`N/A`) are skipped by
design.

**It failed on the first attempt in a way worth recording, because the failure mode is specific to
this chunk.** `Invoke-SalesforceRestJson` piped `ConvertFrom-Json` straight out of the function, and
PowerShell 5.1 emits a deserialized JSON array as a **single** pipeline item — so a 100-record
response measured as `Count = 1`. The loader's own guard ("positional correlation is unsafe")
correctly refused to match results to sources and aborted — but by then 100 notes existed in
Salesforce, and the throw preceded the write of `created-note-ids.csv`, so the only handle on them
was gone. They were identified by being the only `SNOTE` documents linked exclusively to a `User`,
and hard-deleted before the retry.

Two durable lessons: **assign `ConvertFrom-Json` output to a variable before returning it** (the
`@()` caller convention cannot repair a collapse that happens upstream of it), and **write the
created-id file before anything that can throw**, not after.

Freeform Airtable columns with no dedicated Salesforce field become `ContentNote` records attached to
their parent. Candidates identified so far: Partner Account `Account Description` and `Known Blockers`,
Application `Notes` / `Launch Notes` / `IdV Upgrade Notes`. Mechanically different from every other
chunk — `ContentNote.Content` is base64, and attaching is a second object (`ContentDocumentLink`).
Re-derive the candidate list per table when this is built; don't assume the current list is complete.

**This chunk may have to absorb Meetings.** Option (b) in item 2 — attaching unmatched meetings to
their Account or Opportunity as Notes, preserving `Summary` / `Action Items` / `Agenda` without
inventing a calendar event — is currently the most attractive answer for the meetings EAC can never
recover (the 241 with no date, plus everything outside the retention window or led by someone with no
Salesforce user). If that option is chosen, the volume here grows by up to ~1,800 records and Notes
stops being a small final chunk. Settle item 2's spike before sizing this one.

---

## 4a. Rollback — BUILT 2026-08-13

**Status: built** — `scripts/powershell-scripts/Invoke-MigrationRollback.ps1`. The design below is what
it implements; read it before running the script, particularly "What it will never be able to do".

**One gap had to close first, and it was invisible until someone tried to use the restore point.**
`Save-RestorePoint` captured baseline *counts* but not the *set* of external IDs already present per
object — and a count cannot answer the only question a rollback must get right: did this run create
this record, or was it already here? It now writes `external-ids/<Object>.csv` per object. That cost
no extra queries: the tagged-count query was already reading exactly those rows and discarding
everything but the row count.

**Any run directory written before 2026-08-13 lacks that folder, and the script refuses to run
against one** rather than assuming nothing was tagged beforehand. Missing data reads as unknown, and
unknown must not authorise a delete.

### The asymmetry that defines the whole problem

**Undoing an insert is easy. Undoing an update is not.**

Most of this migration *creates* records — delete them by external ID and the org is back where it
started. That is what `Invoke-SandboxFactoryReset.ps1` already does.

But the pipeline also **updates records it does not own**:

| What | Overwrites | Recoverable by deleting? |
| --- | --- | --- |
| `Build-AccountReconciliation.ps1` | `LDGCRM_External_ID__c`, `Type`, Market Segment on **pre-existing** Accounts | **No** |
| Ownership pass | `OwnerId` on Opportunity/Application/Contact | Only if the record is deleted entirely |
| `Invoke-AccountBootstrap.ps1` | `ParentId` on Accounts that had none | **No** |

Deleting a migrated record does not restore an updated one. Once those fields are overwritten the
previous values are gone unless something wrote them down first — and until 2026-08-13 nothing did.
`Invoke-FullMigrationLoad.ps1` now captures a **pre-image of every Account** plus baseline counts into
`scripts/logs/data-migration/Invoke-FullMigrationLoad-<ts>/` before it writes anything. That file is the only thing that
makes an Account rollback possible at all.

### Why the factory reset is not the answer for production

It deletes **everything carrying an external ID**, which in a sandbox is the same set the migration
created. In production it is not: a second migration run would delete the *first* run's records too.
A production rollback has to be **scoped to one run**, not to the external-ID filter. And the factory
reset is deliberately blocked from production anyway.

### What a rollback script should do

1. Take a **run directory** (`Invoke-FullMigrationLoad-<ts>/`), not a set of objects — so it undoes exactly one run.
2. **Delete only what that run created** — external IDs tagged in the org *now* and *absent* from the
   pre-run baseline. Records that already existed are updated back, never deleted.
   **Built against the org rather than the load CSVs, which was a change from this design.** The load
   CSVs say what was *planned*: they can be overwritten by any later transform run, and they cannot
   distinguish a row that was inserted from one that already existed and was merely updated. The set
   difference above is measured on both sides.
3. **Restore the Account pre-image** for the fields the migration overwrote.
4. Delete notes from the run's `created-note-ids.csv` — `ContentNote` has no external ID, so that
   file is the only handle on them.
5. Reverse order: children and junctions before parents, same as the factory reset.
6. Its own typed token (`-Confirmation "ROLLBACK"`), and the separate production token on top.

**One safeguard added during the build that this design missed.** The rollback is scoped by a
*baseline*, not by a run id — so if another load ran *after* the one being rolled back, that load's
records are newer than this baseline too and would be deleted as though this run had created them.
The script therefore compares the org's current totals against the run's own `post-load-counts.csv`
and **stops if they disagree**, on the grounds that the operator is about to undo more than they
think. `-IgnoreDrift` overrides it, deliberately awkwardly.

```powershell
# Always dry-run first - writes the full plan, changes nothing
powershell scripts/powershell-scripts/Invoke-MigrationRollback.ps1 `
    -Environment Dev -RunDirectory scripts/logs/data-migration/Invoke-FullMigrationLoad-<ts> -PlanOnly

powershell scripts/powershell-scripts/Invoke-MigrationRollback.ps1 `
    -Environment Dev -RunDirectory scripts/logs/data-migration/Invoke-FullMigrationLoad-<ts> -Confirmation "ROLLBACK"
```

### What it will never be able to do — state this before anyone relies on it

- **Hard deletes are irreversible.** Rollback deletes; it cannot resurrect. Anything the factory
  reset removed is gone short of Salesforce's paid Data Recovery service.
- **It clobbers post-load human edits.** Restoring the Account pre-image overwrites whatever anyone
  changed since. **Rollback has a shelf life** — it is safe in the minutes after a load and
  increasingly destructive after users touch the data. That window, not the script, is the real
  constraint.
- **Cascades delete more than the run created.** Removing an Account takes its Master-Detail Partner
  Accounts and their children with it, including any that pre-dated the run.
- **Flows, triggers and roll-ups fire on the way back out**, and the FCIC and PureCloud automation is
  outside this repo's control.

### The honest recommendation for production

A script-level rollback is a **best-effort tidy-up, not a safety net**. The actual safety net for a
production migration is a backup taken immediately before the run and a rehearsed restore path —
plus loading in stages small enough that "stop and fix forward" beats "undo". Build the script, but
do not let its existence justify skipping the backup.

---

## 5. Re-run after Airtable cleanup

**Status:** ongoing, no engineering work required.

Every transform re-reads Airtable and re-queries Salesforce, so fixing the items in
[`AIRTABLE-DATA-QUALITY-REQUESTS.md`](../data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md) and re-running picks up the
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
