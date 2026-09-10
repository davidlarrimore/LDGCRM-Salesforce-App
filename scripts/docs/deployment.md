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

## 2. Page layout assignment — the custom objects are fine, the shared ones are not

**A permission set cannot assign a page layout. Only a profile can.** The three
`LDGCRM_` permission sets grant object and field access, but a user still opens
the record on whatever layout their profile already points at.

A sandbox refresh copies production's profile layout assignments, so **whatever
production has, Dev and QA now have.** That covers most of this — but not all of
it. Measured in Dev (`peodv8dvn`) on 2026-09-09, for both
`GSA Standard Salesforce User` and `GSA System Administrator`:

| Layout | Assigned? |
| --- | --- |
| The six `LDGCRM_*` custom-object layouts | ✅ **Yes** — and complete, since those objects have no record types |
| `Account-Federal` | ❌ No |
| `Contact-Federal Contact Layout` | ❌ No |
| `Contact-LDGCRM Federal Contact Layout` | ❌ No |
| `Opportunity-Login%2Egov CRM` | ❌ No |

**The split is not random.** Every layout that IS assigned belongs to an object we
own outright. Every layout that is NOT belongs to **Account, Contact or
Opportunity — the objects shared with FCIC and TTS OTCRM**, where the record type
decides the layout and another app's assignment is already sitting there.

The practical effect: a user opens a Federal Account or a Login.gov Opportunity
and gets whatever layout that record type already points at, **not ours**. Nothing
errors. The records are all present and correct; they are just displayed through
the wrong layout.

**What this check can and cannot tell you.** The retrieve above included only our
ten layouts, so the profile reports assignments only among those. "Not assigned"
therefore means precisely *our layout is not the one assigned* — it does not say
which layout is. **The definitive test is opening one record of each type as a
non-admin**, which is also the only test that catches a layout that exists but is
missing fields.

To fix, per profile, per record type:
*Setup → Profiles → `<profile>` → Page Layout Assignment → Edit Assignment*

**A profile is merged into the target's copy, not replaced**, so a green change set
deployment does not mean an assignment arrived. And the four `GSA Standard *` /
`GSA System Administrator` profiles are deliberately **not** in this repo (see the
comment in [`sfdx/manifest/package.xml`](../../sfdx/manifest/package.xml)) — they
were dropped from the production change set, so no change set we build will ever
carry these assignments.

### ⚠️ Checking this yourself: a Profile retrieved ALONE comes back empty

The Metadata API reports a profile's settings **only for components included in
the same retrieve**. Ask for the profile by itself and `layoutAssignments` is
absent entirely — which looks identical to "no layouts are assigned" and will
send you fixing a problem that may not exist.

Retrieve the profile **and the layouts together**:

```xml
<types>
    <members>GSA Standard Salesforce User</members>
    <name>Profile</name>
</types>
<types>
    <members>Account-Federal</members>
    <!-- ...every layout you want an answer about... -->
    <name>Layout</name>
</types>
```

```powershell
# From inside sfdx/. Writes to a scratch dir, so force-app/ is untouched.
sf project retrieve start --manifest <that-file>.xml --target-org peodv8dvn `
    --target-metadata-dir <scratch> --unzip
```

Then read `<layoutAssignments>` in the retrieved `.profile`. Note the layout name
is URL-encoded in `package.xml` (`Opportunity-Login%2Egov CRM`) but appears
**decoded** in the profile XML — compare on the decoded form or you will get false
negatives.

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

## 4. The Partner Portal (P3) API integration

Four things have to arrive, and **they arrive three different ways**. A green
change set means one of the four landed.

| Component | How it travels | Notes |
| --- | --- | --- |
| `LDGCRM_Partnership_Portal_API_R` | **Change set** | Must carry `LDGCRM_Issuer_String__c` too, or it fails on the missing object reference. Production does not have that object |
| The five `ApiNamedQuery` components | **CLI deploy** | The documented exception in CLAUDE.md. Below |
| The External Client App | **By hand** | Consumer key and secret are per-org and are not metadata |
| The integration user, its licence, its two permission-set assignments | **By hand** | `integration-user.md`. None of it is metadata |

### Deploying the named queries

**Pin the manifest to 67.0.** `ApiNamedQuery` does not exist below API 65.0 and
`sourceApiVersion` is 64.0, so a `-m` or `-d` deploy builds a 64.0 manifest and
fails with *"Entity type 'ApiNamedQuery' is not available in this api version"*
**inside a run whose status reads `Succeeded`**. Write a manifest listing the
five members with `<version>67.0</version>` and deploy that:

```powershell
# From inside sfdx/.
sf project deploy start --manifest <the 67.0 manifest> `
    --target-org <alias> --test-level NoTestRun --json
```

`--test-level NoTestRun` is required for the reason in section 3, not for speed.

**Check `numberComponentsDeployed`, never the status.** Both traps in this
document's other sections apply here: a per-component failure hides inside a
`Succeeded` run, and `rollbackOnError` means one bad component reverts the lot.

### Verifying it, in the order that isolates a failure

```powershell
# 1. The queries exist in the target org.
sf data query --use-tooling-api --target-org <alias> `
    --query "SELECT DeveloperName FROM ApiNamedQuery ORDER BY DeveloperName"

# 2. The integration user can CALL one. This is the step that needs ViewSetup.
tools\partnership_portal_integration\Invoke-LdgcrmNamedQuery.ps1 -List
tools\partnership_portal_integration\Invoke-LdgcrmNamedQuery.ps1
```

**A count alone does not prove a parameterised query works.** A parameter the
query does not declare is silently ignored, and an ignored filter returns *more*
rows, which never looks like a failure. Prove it with a filter that must return
nothing:

```powershell
# Must be 0. If it returns everything, the parameter is not being applied.
tools\partnership_portal_integration\Invoke-LdgcrmNamedQuery.ps1 `
    -NamedQuery ldgcrmApplicationContactsModifiedSince -ModifiedSince (Get-Date).AddDays(1)
```

### What will bite in production specifically

- **`LDGCRM_Issuer_String__c` does not exist there.** The permission set grants
  read on it, so the change set must carry the object as well.
- **`View Setup and Configuration` widens the integration** beyond its object
  table — the user can read Setup, including the other two apps' configuration.
  Documented in `integration-user.md` section 3; flag it at review rather than
  discovering it in production.
- **A sandbox refresh wipes the whole user side.** After any refresh, redo the
  user, the licence and both permission-set assignments. The named queries and
  the permission set definition survive, because they come from production.

---

## 5. Before signing off a target org

Check these directly rather than inferring them from a green deployment. Each has
failed silently at least once:

| Check | Expected | Why it matters |
| --- | --- | --- |
| Role values active | **15**, not 13 | Section 1. Silent data corruption |
| Nine LDGCRM Flows active | 9 of 9 | An inactive Flow changes field *contents*, not row counts — QA once loaded 8,740 records with every Market Segment blank and every count matching |
| Market Segment populated | 0 records without | The above, measured directly |
| Page layouts assigned | open a record as a non-admin | Section 2 |
| `TriggerControls__c` `Contact.On__c` | `True` | The load flips it off and restores it; confirm it was restored |
| P3 named queries callable | 5, and a future-dated filter returns **0** | Section 4. A count alone cannot tell a working filter from an ignored one |

The three Flows with the transposed `LGDCRM_` prefix are easy to miss: a
`LIKE '%DGCRM%'` search **does not match them**, because "LGDCRM" does not contain
"DGCRM". Search for both spellings.
