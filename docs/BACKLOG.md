# Migration backlog

Work that is agreed but not yet built, plus the decisions each item still needs. This is the
engineering-facing companion to the stakeholder report
([`migration-load-report-2026-08-13.html`](migration-load-report-2026-08-13.html)); per-object
build status lives in [`README.md`](README.md) and the field-level detail in
[`TRANSFORMATION-RULES.md`](TRANSFORMATION-RULES.md).

Ordered roughly by value, not by effort.

---

## 1. Assign record owners from Airtable, not the loading user

**Status:** not started. **Raised:** 2026-08-13 by the Partnerships lead.

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

1. Confirm the fallback owner (the migration user, or a named person / queue?).
2. Should Applications take their Account's owner, given Airtable has no Application-specific owner?
3. Should Contacts take their Account's owner, or the default?
4. Should the migration change ownership of **existing** Accounts, or leave those alone?

---

## 2. Meetings (1,845 Airtable rows, 0 loaded)

**Status:** not started. Blocked on one decision.

Airtable's Meetings table records only a **date** — no start or end time. Salesforce calendar events
require both. A default duration and start time have to be agreed before this can load (e.g. "all-day
event", or "09:00 for 60 minutes"). Everything else about the mapping is understood:
`Meeting Type` → `LDGCRM_Meeting_Type__c`, and the meeting attaches to its Opportunity when there is
one, otherwise to its Account.

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
