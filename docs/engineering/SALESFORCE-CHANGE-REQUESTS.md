# Salesforce change requests

> **Who this is for:** whoever owns **Salesforce configuration** and builds change sets — not the
> Airtable data owners, and not the people running loads.
>
> The Airtable-side equivalent is
> [AIRTABLE-DATA-QUALITY-REQUESTS.md](../data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md). Items land
> here when the migration is blocked, or is producing wrong numbers, for a reason that **only a
> config change can fix** — nothing in the pipeline can route around them.

**Why this document exists at all:** metadata promotion in this project is **by change set only**
(see `CLAUDE.md`). From this repo a CLI deploy is sanctioned for exactly one purpose — *deleting*
incorrect metadata. Everything additive or modifying has to be made in Setup and promoted. So when a
load is blocked by a field setting, the pipeline's job is to describe precisely what needs changing
and stop, not to deploy it.

Same convention as the Airtable document: **items are marked resolved in place, never deleted**, and
each carries 🔴 Open / 🟡 Partially resolved / ✅ Resolved.

---

## CR-6 — Contact duplicate rule matched on NAME ONLY — ✅ FIXED AND VERIFIED IN DEV 2026-08-15, 🔴 NEEDS PROMOTING

> **✅ Resolved in Dev the same day it was raised.** The project owner added `Email` to
> `OTCRM_Contact_Matching_Rule`, so a duplicate now requires **FirstName AND LastName AND Email** to
> match, all `Exact`, all `NullNotAllowed`.
>
> **Verified by re-running the Contact step against Dev: 1,888 submitted, 1,888 loaded, 0 failures.**
> Contact went 1,721 → 1,888 — precisely the 167 rows the old rule had rejected. **This needs
> promoting by change set to QA, Full and Prod**, where the name-only rule is still live.
>
> The predicted side effect also occurred and is accepted: the six same-person-two-address pairs now
> exist as two Contacts each (`brian.v.cooke@cbp.dhs.gov` *and* `@associates.cbp.dhs.gov`, and five
> others). That is consistent with this migration's settled merge-on-email rule. **Net: fixed 167,
> created 6.**
>
> **The Airtable ask in the data-quality doc is NOT closed by this.** The rule change stopped 157
> Contacts being rejected; it did not make the data good. Salesforce now holds **175 Contacts all
> named "Help Desk"**, which is a search-and-usability problem rather than a load failure. See item 3
> there — downgraded from blocking, still open.
>
> **A stronger option was raised and not taken, recorded so it is a decision rather than an oversight:**
> matching on **Email alone** would fix the same 167 *and* catch the case the three-field rule now
> misses — same mailbox, name typed differently (`bob.smith@agency.gov` as both "Bob Smith" and
> "Robert Smith"). Every AND makes a matching rule catch *less*, so requiring an admittedly unreliable
> field to match propagates that unreliability. The rule is `Alert`, not `Block`, so a false positive
> costs one click and a false negative silently creates a duplicate — an asymmetry that favours the
> broader rule. The argument the other way is shared mailboxes: ~57 role inboxes exist, and Email-only
> would alert on two people recorded against one of them.

**Raised 2026-08-15 by the project owner**, whose framing is the whole case: *"There are 1,000 people
named Robert Smith in the world. Email should be unique; first and last name doesn't have to be."*

**The rule.** `OTCRM_Contact_Duplicate` ("OTCRM Contact Duplicate Rule") is the **only active** Contact
duplicate rule in the org. It uses `OTCRM_Contact_Matching_Rule`, whose entire definition is:

```xml
<matchingRuleItems><fieldName>FirstName</fieldName><matchingMethod>Exact</matchingMethod></matchingRuleItems>
<matchingRuleItems><fieldName>LastName</fieldName> <matchingMethod>Exact</matchingMethod></matchingRuleItems>
```

**`Email` does not appear in it.** Two unrelated people who share a name are, to this rule, the same
person. The other two Contact rules — `Standard_Rule_for_Contacts_with_Duplicate_Leads` and
`Contact_Duplicate_Rule` — are both inactive.

### Three things make this worse than a debatable config choice

**1. It belongs to another application.** `OTCRM` is TTS OTCRM. Its filter is `RecordType equals
Federal`, which is exactly the record type this migration's partner-agency Contacts receive, so a rule
written for another app's data model governs ours. **The third instance of this pattern**, after
`priority_type__c` (another app's field with a matching label) and `GSA_FCIC_ContactTrigger` (another
app's trigger firing on our inserts). Contacts on the `GSA` record type are unaffected.

**2. It was never intended to block anything.** Its own description reads *"This is to soft check
duplicate contacts for Federal Record Type"*, and the configuration agrees:

```xml
<actionOnInsert>Allow</actionOnInsert>
<operationsOnInsert>Alert</operationsOnInsert>
```

**Allow + Alert** is a soft UI warning — a human sees "these look like duplicates, save anyway?" and
clicks through. On an API insert there is no human, so the row is **rejected**. Bypassing it requires
`DuplicateRuleHeader.allowSave=true`, which **Bulk API 2.0 does not expose** — and `sf data upsert
bulk` is Bulk 2.0. So a rule deliberately configured *not* to block is hard-blocking this pipeline,
and the pipeline has no header to set.

**3. It is currently costing 157 Contacts** and it halted the 2026-08-15 Dev load at step 5 of 12.
The immediate trigger was an Airtable bulk-rename (see the data-quality doc, item 3), but that only
exposed the rule — any 178 people sharing a name would do the same.

### What we are asking for

**Add `Email` to `OTCRM_Contact_Matching_Rule`, ideally as an exact match and the primary criterion.**
That is the actual identity key, and it makes the rule do what its description already claims.

**This is a TTS OTCRM-owned rule, so it is a cross-team request, not a unilateral change.** If they
will not change a rule their own app depends on, the fallback is to **scope its filter so it no longer
catches migration-created Contacts** — but note there is no clean discriminator today, because their
Federal Contacts and ours share a record type.

### One consequence to state up front, because it is not a free win

The name rule is currently *accidentally* catching the **6 genuine duplicates** — the same person under
two email addresses (`brian.v.cooke@associates.cbp.dhs.gov` vs `brian.v.cooke@cbp.dhs.gov`, and five
others; see the data-quality doc item 5). Match on email instead and **those 6 load as two Contacts
each.**

That is consistent with this migration's own settled rule — Contacts merge on **email**, so two
addresses already means two Contacts — but it should be a decision, not a surprise. Net effect:
**fixes 157, creates 6.**

The 157 load either way: they carry **140 distinct addresses, 139 of which appear nowhere else in
Salesforce**.

---

## CR-5 — `LDGCRM_Tehnical_Checklist_URL__c` renamed to `LDGCRM_Technical_Checklist_URL__c` — ✅ DONE IN DEV, 🔴 NEEDS PROMOTING

**Done in Dev 2026-08-14.** The API name was missing the second `c` while the **label read
"Technical Checklist URL" correctly** — so everything a human saw was spelled right, and the typo
looked like a bug in the transform rather than in the field. Both earlier spellings are now gone from
Dev: `LDGRM_Tehnical_…` (wrong prefix *and* body) and `LDGCRM_Tehnical_…` (body only).

Safe to do as a create-and-delete because **0 records held a value**. Anywhere that is not true, the
data has to be copied across before the old field is dropped.

### What to include in the change set

| Component | Type | Note |
| --- | --- | --- |
| `Opportunity.LDGCRM_Technical_Checklist_URL__c` | Custom Field | the new field |
| `Opportunity-Login.gov CRM` | Page Layout | places it |
| `LDGCRM_Partnership_Team_Member_CRE`, `LDGCRM_Partnership_Viewer_R`, `LDGCRM_Production_Support_CRED` | Permission Set | FLS |
| `GSA System Administrator`, `GSA Standard Basic User`, `GSA Standard Platform User`, `GSA Standard Salesforce User` | Profile | FLS |
| `LDGCRM_Login_gov_Market_Segments_with_Accounts_with_Opportunities`, `LDGCRM_Login_gov_Opportunities_with_Activity`, `LDGCRM_Login_gov_Opportunities_with_Impediments` | Report Type | column references |
| **`Federal_Opportunity_Record_Page`** | **Lightning Page** | ⚠️ **easy to miss — see below** |

> ### ⚠️ Two traps in promoting this one
>
> **1. `Federal_Opportunity_Record_Page` is not `LDGCRM_`-prefixed**, so it is not in
> `manifest/package.xml` and does not appear in this repo at all. It nonetheless displays this field,
> and in Dev it **blocked the delete** until it was repointed. If it is left out of the change set,
> the target org's page still points at the old field.
>
> **2. A change set cannot DELETE.** Promoting this **adds** the correctly-spelled field but leaves
> `LDGCRM_Tehnical_Checklist_URL__c` in place in the target org, so both will exist side by side.
> The old one has to be deleted by hand in Setup afterwards — and **check it holds no data first**,
> which is not guaranteed to still be true outside Dev.

---

## CR-4 — `LDGCRM_Level_of_Priority__c` picklist values — ✅ DONE IN DEV, 🔴 NEEDS PROMOTING

**This is the one to put in the next change set.** Made in Dev on 2026-08-14 at the project owner's
explicit request, so it can be picked up into an outbound change set. **QA, Full and Prod do not have
it**, and until they do, loading Opportunity there fails every row carrying a Priority Type — the
field is `restricted = true`.

### What to include in the change set

| Component | Type | Why |
| --- | --- | --- |
| `Opportunity.LDGCRM_Level_of_Priority__c` | Custom Field | carries the four new values |
| `Opportunity` → `Login_gov` | Record Type | **assigns** them — a value the record type omits is rejected even when the field defines it |

### What changed

**Added** (and assigned to `Login_gov`): `Strategic`, `High Volume`, `IdV Upgrade`,
`Leadership Escalation`.

**Retired**: `Low`, `Medium`, `High` — 0 Opportunities used any of them, verified before the change.

⚠️ **They are deactivated, not deleted.** A metadata deploy cannot delete a picklist value; all three
remain in the value set as `isActive = false`. **Only a Setup "Del" removes them** — worth doing while
usage is still zero, and note `sf sobject describe` will *not* show them, so the value-set page in
Setup is the only place they are visible.

**`N/A` was deliberately NOT added.** Airtable has it on 157 rows, but it means the field does not
apply; the transform maps it to blank. A priority literally called "N/A" reads as data while meaning
its absence.

### Two things to know before promoting

- ⚠️ **Do NOT put `TTS_OTCRM_Opportunity` in the change set.** It lost its assignment for this field
  in Dev as a side effect — it only exposed `High`, so deactivating that left the block empty and
  Salesforce removed it (33 → 32 picklist blocks on that record type). Harmless in Dev (0 records, and
  the field is `LDGCRM_`-owned — it sits on that record type only because the field was renamed into
  this app from an earlier life), but promoting that record type would make the same change to
  **another team's app** in the target org. Only `Login_gov` belongs in this change set.
- ✅ **The transform is already updated and proven against the load file** — 371 of 842 Opportunities
  carry a value (`Strategic` 249, `High Volume` 70, `IdV Upgrade` 38, `Leadership Escalation` 14), and
  every one was cross-checked against what the org accepts. Nothing further is needed on the pipeline
  side once the metadata lands.

---

## CR-1 — `Unique` must be turned off on the two Partner Portal Team fields — ✅ RESOLVED

**Resolved 2026-08-14.** Both fields are now `Unique = false`, and both were widened from Text(50)
to Text(255) at the same time — which also cleared the separate problem of six team names being too
long for the field.

**Verified the same day** by re-running the Application step: the transform took its unblocked path
("Partner-portal team columns will be written (both fields are non-unique)"), 1,026 Applications
loaded with 0 failures, and **681 now carry a partner-portal team name and UUID**. `DOI - FWS - ECOS`
holds 54 of them — the exact collision `Unique = true` would have rejected.

| Field | Was | Now |
| --- | --- | --- |
| `LDGCRM_P3_Partner_Portal_Team_Name__c` | Text(50), Unique = true | **Text(255), Unique = false** |
| `LDGCRM_P3_Team_UUID__c` | Text(50), Unique = true | **Text(255), Unique = false** |

The 9 Applications whose issuer strings name two different teams remain blank. **That is an accepted
outcome, not a defect** — the partner-portal team is optional (business rule, 2026-08-14).

<details><summary>Original analysis, kept for the record</summary>

**Why the current setting is wrong.** `Unique` enforces "this value may appear on at most one
record" — i.e. *each team belongs to exactly one Application*. The data says the opposite: **one
portal team runs many Applications.** `DOI - FWS - ECOS` (`5add6a5b-1ede-404d-b107-666d7eedb357`) is
the team for **54 distinct Applications**; `DOI - IBC - Quicktime` for 39; `Education ICAM Team` for
20.

The complementary statement — *each Application has one team* — **is** true, and the pipeline already
guarantees it: all 696 Applications that have a team resolve to exactly one, collapsed from their
child Issuer String records during data prep. That is not the constraint `Unique` enforces.

**Impact if left as-is.** `DUPLICATE_VALUE` is a **row-level** rejection: the whole Application
record fails, not just the field. Of the 696:

| | Applications |
| --- | --- |
| Would load with their team | 358 (51%) |
| **Would fail to load entirely** | **338 (49%)** |

…and which one "wins" per shared team is arbitrary — whichever row Bulk API processes first.

**What the pipeline does meanwhile.** `Build-ApplicationLoad.ps1` reads both fields' live definitions
at run time and **omits the two columns** while either is unique, so all 1,026 Applications load
normally with the team left empty. It prints a red `PARTNER PORTAL TEAM COLUMNS WITHHELD` block, and
`Invoke-FullMigrationLoad.ps1` reports it as `KNOWN INCOMPLETE` rather than a failure.

**After the change:** re-run `Build-ApplicationLoad.ps1` and load. The columns appear automatically —
no code change. Expect ~422 of the loaded Applications to carry a team.

**Neither field is an External ID and nothing matches records on them**, so nothing depended on the
setting.

</details>

---

## CR-2 — Retire `LDGCRM_PP_Issuer_Strings__c` — ✅ RESOLVED 2026-08-14

> ### The approach changed on 2026-08-14, and it is cheaper than what is specified below
>
> Rather than **removing** the ninth checklist item and moving the denominator 9 → 8, the item's
> **reference was swapped** to the successor field:
>
> ```
> - IF(ISBLANK(LDGCRM_PP_Issuer_Strings__c), 0, 1)
> + IF(ISBLANK(LDGCRM_P3_Team_UUID__c),      0, 1)
> ```
>
> **The denominator stays 9, so `LDGCRM_Launch_Checklist_Completion__c` needs no change at all** —
> steps 2a and 2b below are superseded. It hard-codes Level 1's item count as a weight (`*9`, `/16`,
> `/20`); leaving the count at 9 leaves all three alone.
>
> The checklist item also keeps its business meaning instead of disappearing: "the partner portal is
> set up" is still measured, just against the field that now holds that fact.
>
> **✅ Done and verified 2026-08-14:** ceiling moved 78 → 89, all 681 Applications with a Team UUID
> score the item, 0 without one can reach 100%.
>
> ### ✅ The field is deleted (2026-08-14)
>
> Deleted by CLI destructive deploy — the one sanctioned deploy from this repo. **Salesforce cascaded
> every remaining reference itself**, so none of the cleanup below needed doing by hand:
>
> | Reference | Count | Outcome |
> | --- | --- | --- |
> | Page layout `LDGCRM_application__c-Application Layout` | 1 | Removed automatically |
> | Permission sets — FLS | 3 | Removed automatically |
> | Report types | 4 | Column removed automatically |
> | The field itself | 1 | Deleted (`deleted=True`, 1 component, 0 errors) |
>
> Only a **formula** reference hard-blocks a field delete, and that had already been cleared by
> re-pointing the checklist item. Everything else Salesforce tidies up on its own — 78 lines removed
> across 8 files on the follow-up retrieve.
>
> Records holding data: **1**, a pre-existing test record. No migration data lost. Verified after:
> Level 1 ceiling still 89, still 681 Applications with a Team UUID.
>
> ⚠️ **One report type is still NAMED after the field** —
> `LDGCRM_Login_gov_Applications_with_Partner_Portal_Issuer_Strings`. Its column is gone but the name
> now misleads. Renaming is cosmetic and was left alone.
>
> #### ⚠️ `--metadata-dir` silently ignores a destructive manifest
>
> The first attempt used `sf project deploy start --metadata-dir <dir>` with
> `destructiveChangesPostDeploy.xml` beside `package.xml`. It reported **"Succeeded"** — and deployed
> **0 components**, deleting nothing. A success with nothing done, which is exactly the failure mode
> that looks fine in a transcript.
>
> Destructive changes need the explicit flags:
>
> ```
> sf project deploy start --manifest package.xml `
>     --post-destructive-changes destructiveChangesPostDeploy.xml `
>     --target-org <alias> --test-level NoTestRun
> ```
>
> **Check `numberComponentsDeployed` and `deleted=True` on the component, not just the status.**
> `sf project deploy report --job-id <id>` shows both. `sf sobject describe` also served a stale
> cached answer here — the Tooling API (`FieldDefinition`) gave the truthful one.

<details><summary>Original specification (superseded — kept for the record)</summary>

**Confirmed by the project owner (2026-08-13): the field is deprecated and this data is not being
migrated.** It cannot simply be deleted — a formula depends on it, and removing it changes two
reported metrics.

**Object:** `LDGCRM_application__c`. **Field:** `LDGCRM_PP_Issuer_Strings__c`, Text(40), Unique.

### Why it can't be deleted on its own

| Reference | Count | Action needed |
| --- | --- | --- |
| `LDGCRM_Level_1_Complete_Pct__c` formula | 1 | **Edit first** — Salesforce blocks deleting a field a formula uses |
| `LDGCRM_Launch_Checklist_Completion__c` formula | 1 | Edit — it hard-codes Level 1's *item count* as a weight |
| Report types | 4 | Remove the column. One is named `LDGCRM_Login_gov_Applications_with_Partner_Portal_Issuer_Strings` |
| Permission sets | 3 | Remove FLS entries (`..._Team_Member_CRE`, `..._Viewer_R`, `..._Production_Support_CRED`) |
| Page layout | 1 | `LDGCRM_application__c-Application Layout` |
| Records holding data (Dev) | 1 | A pre-existing test record — no migration data is lost |

### Step 2a — `LDGCRM_Level_1_Complete_Pct__c`

It counts **nine** checklist items, and the ninth is this field. Because the migration never populates
it, **every migrated Application forfeits that item by construction** — a hard ceiling of 8/9 = 89%.
Observed maximum across 1,026 migrated Applications is **78%** (7 of 9).

Replace with (item removed, denominator 9 → **8**):

```
(
    IF(LDGCRM_Launch_Tested__c, 1, 0) +
    IF(LDGCRM_Finalized_Application_Details__c, 1, 0) +
    IF(LDGCRM_Agreement_Finalization_Email_Sent__c, 1, 0) +
    IF(LDGCRM_Account_Manager_Approved__c, 1, 0) +
    IF(LDGCRM_Sent_Integration_Approval_Request__c, 1, 0) +
    IF(LDGCRM_Production_Launch_Completed__c, 1, 0) +
    IF(LDGCRM_Launch_Activities_Confirmed__c, 1, 0) +
    IF(LDGCRM_Launch_Activities_Completed__c, 1, 0)
) / 8
```

Effect: the same records that read 78% (7 of 9) will read **88%** (7 of 8). Nothing is lost — an item
that could never be satisfied stops dragging the score down.

### Step 2b — `LDGCRM_Launch_Checklist_Completion__c`

This is why the change can't stop at Level 1: the total **weights each level by its item count**, and
those counts are hard-coded. Level 1 going 9 → 8 items changes the weight *and* both denominators
(16 = 9+7, 20 = 9+7+4).

Replace `*9` with `*8`, `/16` with `/15`, and `/20` with `/19`:

```
CASE(
    TEXT(LDGCRM_Launch_Level__c),
    "1 - Very Low Impact", LDGCRM_Level_1_Complete_Pct__c,
    "2 - Low Impact", LDGCRM_Level_1_Complete_Pct__c,
    "3 - Moderate Impact",
        (
            ((LDGCRM_Level_1_Complete_Pct__c)*8) +
            ((LDGCRM_Level_3_Complete_Pct__c)*7)
        ) / 15,

    "4 - High Impact",
        (
            ((LDGCRM_Level_1_Complete_Pct__c)*8) +
            ((LDGCRM_Level_3_Complete_Pct__c)*7) +
            ((LDGCRM_Level_4_Complete_Pct__c)*4)
        ) / 19,

    "5 - Very High Impact",
        (
            ((LDGCRM_Level_1_Complete_Pct__c)*8) +
            ((LDGCRM_Level_3_Complete_Pct__c)*7) +
            ((LDGCRM_Level_4_Complete_Pct__c)*4)
        ) / 19,

    LDGCRM_Level_1_Complete_Pct__c
)
```

> ⚠️ Note the **last line changed too** — that is CR-3 below, and it is a separate decision. If you
> want to keep the current behaviour, leave that line as `1`.

### Step 2c — remove the remaining references, then delete

Layout → 3 permission sets → 4 report types → then delete the field. Deleting the field is the one
step this repo may do by CLI deploy; everything above it is change-set work.

</details>

---

## CR-3 — A blank Launch Level reports 100% launch-checklist completion — ✅ CLOSED, ACCEPTED AS-IS

> **Closed 2026-08-14 by the project owner: accepted, not fixed.** The reasoning — it does not break
> anything, and once the app is live the field is ignored. No change set needed; the formula stays as
> it is.
>
> **What protects the data is the migration-side default, not the formula.** The transform writes
> `1 - Very Low Impact` when Airtable has no Launch Level, so no migrated Application falls through
> the `CASE`. Verified in both orgs on 2026-08-14: **1 Application with a blank Launch Level in each,
> and 0 of them migrated** — the record reporting 100% is pre-existing test data.
>
> ### ⚠️ The dependency this creates, which must not be lost
>
> `Build-ApplicationLoad.ps1`'s Launch Level default is now **load-bearing for reporting**, not a
> convenience. Removing it as redundant tidy-up would silently return **607 of 1,026 Applications to
> reporting 100% launch-complete** — that is what the figure was before the default existed.
>
> If that default is ever revisited, this item comes back with it.

**Found 2026-08-13 while working CR-2. This one is a live reporting defect, independent of the
migration.**

`LDGCRM_Launch_Checklist_Completion__c` is a `CASE` on Launch Level whose **else value is `1`** —
i.e. 100%. Any Application with **no Launch Level** matches none of the five cases and falls through
to *fully complete*.

Measured on the 1,026 migrated Applications:

| Launch Level | Applications | Reported checklist completion |
| --- | --- | --- |
| **Blank** | **607** (59%) | **100%, every one of them** |
| Set (levels 1–5) | 419 | max 90% |

Those 607 were demonstrably not complete — their own `Level 1 Complete %` maxed out at 78%. So
**59% of Applications reported as fully launch-complete because a field was empty.** (Those specific
records are now fixed by the migration-side default above; the formula behaviour is not.)

**What we need — a decision, then a formula edit.** The `1` should become something that isn't
"finished". Two sensible options:

- **(a) Fall back to Level 1** — `LDGCRM_Level_1_Complete_Pct__c`, as written in CR-2 above.
  Consistent with levels 1 and 2, which already map to Level 1 alone. **Recommended:** an
  unclassified application is most likely low-impact, and this reports real progress rather than a
  placeholder.
- **(b) Report `0`** — unambiguous, but tells you nothing about actual progress and will read as a
  regression on dashboards.

This is a config-owner decision because it changes a number people already look at.

---

## Resolved log

| Date | Item | What changed | Who | Effect |
| --- | --- | --- | --- | --- |
| | *(nothing closed yet)* | | | |
