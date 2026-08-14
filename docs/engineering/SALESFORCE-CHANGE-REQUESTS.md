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

## CR-2 — Retire `LDGCRM_PP_Issuer_Strings__c` — 🟡 FORMULA DONE, references still to clear

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
> **Still to do before the field can be deleted** — Salesforce blocks the delete while any of these
> reference it:
>
> | Reference | Count | Owner |
> | --- | --- | --- |
> | Page layout `LDGCRM_application__c-Application Layout` | 1 | Config owner |
> | Permission sets — FLS (`..._Team_Member_CRE`, `..._Viewer_R`, `..._Production_Support_CRED`) | 3 | Config owner |
> | Report types — one is **named** `LDGCRM_Login_gov_Applications_with_Partner_Portal_Issuer_Strings`, so consider renaming rather than only dropping the column | 4 | Config owner |
> | Then: delete the field | — | **This repo may do this by CLI** — deletion is the one sanctioned deploy |
>
> Records holding data: **1**, a pre-existing test record. No migration data is lost.

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

## CR-3 — A blank Launch Level reports 100% launch-checklist completion — 🟡 MITIGATED FOR MIGRATED RECORDS

> **Status update 2026-08-13, later the same day.** The migration now **defaults a blank Launch Level
> to `1 - Very Low Impact`** (project owner's decision), so no migrated Application can fall through
> the `CASE` any more. Verified after reloading all 1,026: **records reporting 100% went 607 → 0**,
> and the maximum is now a real **90%**.
>
> **This does not close the item.** The formula is unchanged, so *any* Application created or edited
> later with a blank Launch Level still reports 100% complete. The data-side default protects the
> records this migration owns; it does not protect the org. The `else` value still needs fixing.

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
