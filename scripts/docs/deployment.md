# Sprint 2 — deployment notes

> **Who this is for:** whoever builds the Sprint 2 change set and whoever receives
> it. It records the things a change set **cannot carry**, which therefore have to
> be done by hand in every target org and are the easiest things to miss.
>
> Metadata moves between orgs by **change set only** — see [CLAUDE.md](../../CLAUDE.md).
> This document is not a substitute for that rule; it is the list of exceptions
> where a change set is structurally incapable of doing the job.

Sprint 1's full deployment guide is archived in `archive/sprint_1_scripts.zip`
(`docs/DEPLOYMENT-GUIDE.md`). It still describes the metadata/permission-set/layout
sequence accurately; what follows is what Sprint 1 learned *after* it was written.

---

## 1. ⚠️ `OpportunityContactRole.Role` — two values must be REACTIVATED by hand

**This is the one that will silently corrupt a load if it is missed.**

### What is wrong

The migration relies on two Role values, `Day-to-Day POC` and `Senior POC`. In the
refreshed **Dev** sandbox they are **present but DEACTIVATED**. In **QA** they are
active.

They are not missing. Nothing needs creating. They need **activating**.

### Why you cannot put it in a change set

Three separate obstacles, and each one alone is enough:

1. **It is not a field you can pick.** Picklist values on a *standard* field do not
   travel as the field. They travel as the **value set** behind it.
2. **It is not called `Role`.** The component is the Standard Value Set named
   **`ContactRole`** — not `Role`, not `OpportunityContactRole`, and not
   `Role__c` (there is no such custom field; `Role` is standard, with no suffix).
   Searching the change set for any of those finds nothing, which reads like the
   component is missing rather than misnamed.
3. **Salesforce does not offer Standard Value Sets in change sets at all.** There
   is no such component type in the outbound change set UI. Confirmed 2026-09-09.
   They are Metadata API only.

So there is no change set that can carry this. It is a manual step, in **every**
org, forever — or GSA IT Engineering adds
`sfdx/force-app/main/default/standardValueSets/ContactRole.standardValueSet-meta.xml`
to their CLI deployment separately from the change-set-derived component set.

### The fix — do this in each target org

*Setup → Object Manager → **Opportunity Contact Role** → Fields & Relationships →
**Role** → Values*

Find `Day-to-Day POC` and `Senior POC` in the **inactive** list and click
**Activate** on each. Do not create new ones — duplicates on a standard value set
are worse than the original problem.

Alternatively: *Setup → Picklist Value Sets → **Contact Role***, which is the same
value set seen from the global page.

### ⚠️ How to verify — and why every quick check lies

**A deactivated picklist value is invisible to every API surface we use.** Both of
these return only ACTIVE values, so a deactivated value looks exactly like a value
that was never there:

```powershell
# Says 13. Does NOT mean the two values are absent.
sf sobject describe --sobject OpportunityContactRole --target-org <alias> --json

# Also says 13. A metadata retrieve returns active values only.
sf project retrieve start -m "StandardValueSet:ContactRole" --target-org <alias> `
    --target-metadata-dir <scratch> --unzip
```

On 2026-09-08 both of those reported the values absent from Dev, from two
independent code paths, and both were wrong — the values were sitting there
deactivated the whole time.

**Setup is the only place that shows the truth.** Open the Values page and look at
the inactive list. If you want an API check, the useful one is a *positive* test:

```powershell
# 15 = both values active. 13 = at least one is deactivated.
sf sobject describe --sobject OpportunityContactRole --target-org <alias> --json |
    ConvertFrom-Json | ForEach-Object { $_.result.fields } |
    Where-Object { $_.name -eq "Role" } | ForEach-Object { $_.picklistValues.Count }
```

### What it costs if you miss it

`Role` is not cosmetic. It is part of `OpportunityContactRole`'s external ID
(`<airtableId>|<Role>`), part of the `(Opportunity, Contact, Role)` dedupe key,
and it drives `IsPrimary` through the precedence list in
`tools/data-loading/Build-OpportunityContactRoleLoad.ps1`.

The field is **unrestricted**, so Salesforce will not reject an unknown value — it
stores it as free text. That is the dangerous part: **the load reports success.**
Measured against the current load file:

| | |
| --- | --- |
| Rows using the two values | 474 of 596 |
| **Primary contacts designated by them** | **322 of 354** |
| (Opportunity, Contact) pairs that would collide if blanked | 39 |

`Day-to-Day POC` alone designates 312 of 354 primary contacts. Miss this and the
load looks clean while most opportunities end up with the wrong primary contact
and Role values that are not selectable in the UI.

### Proof, from the two loads on 2026-09-09

| Org | Active Role values | OpportunityContactRole result |
| --- | --- | --- |
| Dev (`peodv8dvn`) | 13 | **Step held back.** Loading it would have written 474 off-picklist rows |
| QA (`peodv15dvn`) | 15 | **596 loaded, 0 failed** |

Same CSV, same scripts, same day. The only difference was whether the two values
were active.

---

## 2. Page layout assignment is manual, per profile

**A permission set cannot assign a page layout. Only a profile can.** The three
`LDGCRM_` permission sets grant object and field access, but a user still opens
the record on whatever layout their profile already points at.

*Setup → Profiles → `<profile>` → Page Layout Assignment → Edit Assignment*

**A profile is merged into the target's copy, not replaced**, so a green change set
deployment does not mean the assignment arrived. **Verify by opening a record as a
non-admin**, not by reading the profile.

Note the four `GSA Standard *` / `GSA System Administrator` profiles are
deliberately **not** in this repo (see the comment in
[`sfdx/manifest/package.xml`](../../sfdx/manifest/package.xml)) — they were dropped
from the production change set, which makes this manual step more load-bearing,
not less.

---

## 3. Deploys that run tests are blocked org-wide

Any `sf project deploy validate`, or any deploy that runs tests, fails on a
**pre-existing Apex compile error** in `GSA_FCIC_AC_Manual_InitialBatch`
(`Variable does not exist: metadata`). It belongs to the FCIC app, not this one.

Salesforce compiles *all* Apex in the org before running any test, so one broken
class fails everything regardless of what is being deployed.

For metadata-only changes, use `--test-level NoTestRun`. **This is a workaround,
not a fix** — a deployment that includes Apex stays blocked until the FCIC owner
repairs that class.

---

## 4. Before signing off a target org

Check these directly rather than inferring them from a green deployment. Each has
failed silently at least once:

| Check | Expected | Why it matters |
| --- | --- | --- |
| Role values active | **15**, not 13 | Section 1. Silent data corruption |
| Nine LDGCRM Flows active | 9 of 9 | An inactive Flow changes field *contents*, not row counts — QA once loaded 8,740 records with every Market Segment blank and every count matching |
| Market Segment populated | 0 records without | The above, measured directly |
| Page layouts assigned | open a record as a non-admin | Section 2 |
| `TriggerControls__c` `Contact.On__c` | `True` | The load flips it off and restores it; confirm it was restored |

The three Flows with the transposed `LGDCRM_` prefix are easy to miss: a
`LIKE '%DGCRM%'` search **does not match them**, because "LGDCRM" does not contain
"DGCRM". Search for both spellings.
