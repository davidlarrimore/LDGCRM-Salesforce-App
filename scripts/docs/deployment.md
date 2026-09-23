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
| `LDGCRM_Partner_Portal_API_R` | **Change set** | Must carry the `LDGCRM_Issuer_String__c` object too, or it fails on the missing object reference. Production does not have that object. Include its `LDGCRM_Issuer_String__c` field so the object arrives complete |
| The six `ApiNamedQuery` components | **CLI deploy** | The documented exception in CLAUDE.md. Below |
| The External Client App | **By hand** | Consumer key and secret are per-org and are not metadata |
| The integration user, its licence, its two permission-set assignments | **By hand** | `integration-user.md`. None of it is metadata |

### Deploying the named queries

**Pin the manifest to 67.0.** `ApiNamedQuery` does not exist below API 65.0 and
`sourceApiVersion` is 64.0, so a `-m` or `-d` deploy builds a 64.0 manifest and
fails with *"Entity type 'ApiNamedQuery' is not available in this api version"*
**inside a run whose status reads `Succeeded`**. Write a manifest listing the
six members with `<version>67.0</version>` and deploy that:

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
# 1. The queries exist in the target org. Expect 6.
sf data query --use-tooling-api --target-org <alias> `
    --query "SELECT DeveloperName FROM ApiNamedQuery ORDER BY DeveloperName"

# 2. The integration user can CALL one. This is the step that needs ViewSetup.
tools\partnership_portal_integration\Invoke-LdgcrmNamedQuery.ps1 -List
tools\partnership_portal_integration\Invoke-LdgcrmNamedQuery.ps1
```

**The portal's main lookup is the one to prove**, and proving it needs two
counts, not one. Run it for a team you know, then run
`...ByTeamUuid` for the same team. In Dev those are **4 and 10**. Equal numbers
mean the admin filter is doing nothing; 1,089 means the team filter is.

```powershell
tools\partnership_portal_integration\Invoke-LdgcrmNamedQuery.ps1 `
    -NamedQuery ldgcrmApplicationContactsPartnerAdminByTeamUuid -TeamUuid <a real team>
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

### ⚠️ Do NOT activate them, and do not put activation in the plan

Activation in the API Catalog is for **Agentforce actions**. It does not gate
REST, and it takes something away: an activated query **cannot be deleted or
edited** until it is deactivated again.

Proved in Dev on 2026-09-09. `ldgcrmApplicationContactsByEmail` was deployed by
CLI, nobody opened the API Catalog for it, it returned 5 rows over REST, and a
dry-run delete validated clean — callable and unactivated at the same moment.
The one query that *had* been activated refused deletion with *"Cannot delete
Named Query... It is activated as agent action."*

That refusal already cost this project a stranded duplicate in Dev. **Adding an
activation step to a production runbook would make every named query in
production undeletable and uneditable, for no gain.**

There is no CLI command to activate or deactivate, and no field to read.
`CatalogedApi` 404s on both APIs, the catalog metadata types list zero
components, and `ApiNamedQuery` is `createable=false updateable=false
deletable=false` with no active field. If you ever need to know a query's state,
a **dry-run destructive deploy** is the only way to ask:

```powershell
sf project deploy start --manifest <empty 67.0 package.xml> `
    --post-destructive-changes <manifest naming the query> `
    --target-org <alias> --test-level NoTestRun --dry-run
```

Refuses means activated. Validates clean means not. Nothing is deleted either
way. Otherwise, verify a query by **calling** it — the checks below.

### What will bite in production specifically

- **`LDGCRM_Issuer_String__c` does not exist there.** The permission set grants
  read on it, so the change set must carry the object — and its issuer string
  field, a separate component in the change set UI, or the object arrives empty.
  The field it replaces, `LDGCRM_PP_Issuer_Strings__c`, is deleted **after** it
  arrives — section 5.
- **`View Setup and Configuration` widens the integration** beyond its object
  table — the user can read Setup, including the other two apps' configuration.
  Documented in `integration-user.md` section 3; flag it at review rather than
  discovering it in production.
- **A sandbox refresh wipes the whole user side.** After any refresh, redo the
  user, the licence and both permission-set assignments. The named queries and
  the permission set definition survive, because they come from production.

---

## 5. ⚠️ POST-DEPLOYMENT STEP — delete `LDGCRM_application__c.LDGCRM_PP_Issuer_Strings__c`

**Run this after the Sprint 2 change set has deployed and been verified, in every
org it reaches.** Sprint 2 removes this field from every org. It is the deprecated Text(40),
unique, one-per-Application field labelled *Issuer Strings (Deprecated)*, replaced
by the `LDGCRM_Issuer_String__c` object (Auto Number ID, Text(200) string,
Master-Detail to Application). Leaving it in place leaves two places to record an
issuer string, one of which cannot hold most of them.

| Org | State (2026-09-23) |
| --- | --- |
| Production | **Has the field** |
| Dev (`peodv8dvn`) | **Deleted.** SOQL rejects the column; it is in Deleted Fields until it expires. Deleted 2026-08-14 and 2026-09-09 too, and a refresh restored it both times |
| QA / UAT / Full | Assume present — every refresh copies production |

**Run `tools/metadata/Remove-DeprecatedField.ps1` rather than doing this by hand.**
It implements every step below — the state probe, the export, the destructive
manifest pair, the dry run, the component-count check, the SOQL verification and
the `force-app/` cleanup — and it is safe to re-run, because it detects a field
that is already gone and says so instead of reporting a hollow success:

```powershell
# Check first; changes nothing.
powershell tools/metadata/Remove-DeprecatedField.ps1 -OrgAlias <alias> -WhatIf

# Then the real one. The token is "DELETE FIELD IN PRODUCTION" against production.
powershell tools/metadata/Remove-DeprecatedField.ps1 -OrgAlias <alias> `
    -Field PP_Issuer_Strings -Confirmation "DELETE FIELD"
```

The rest of this section is what the script does and why, and is what to read when
it fails or when a target org disagrees with it.

### Why a change set cannot do it

A change set only adds and changes; it **cannot carry a deletion**. This is a
**destructive Metadata API change**, so it travels the same way as the
`ContactRole` value set in section 1: in GSA IT Engineering's CLI deployment, not
in the change set. Until production drops the field, **every sandbox refresh puts
it back**, so deleting it from a sandbox is only ever temporary.

### Order — after the new object, never before

1. The change set carrying `LDGCRM_Issuer_String__c` **and** its
   `LDGCRM_Issuer_String__c` field has deployed (section 4).
2. **Export the field's values from the target org.** In production OEs maintain
   it by hand from ZenDesk move-to-production requests, so it is real data and the
   delete destroys it:

   ```powershell
   # From inside sfdx/. data/ is gitignored.
   sf data export bulk --target-org <alias> --result-format csv --wait 10 `
       --output-file ..\data\salesforce-backups\LDGCRM_PP_Issuer_Strings__c-<alias>.csv `
       --query "SELECT Id, Name, LDGCRM_External_ID__c, LDGCRM_PP_Issuer_Strings__c FROM LDGCRM_application__c WHERE LDGCRM_PP_Issuer_Strings__c != null"
   ```

3. Delete the field (below).

### Nothing blocks it — checked, not assumed

A field delete **hard-blocks only on a formula reference**. No formula, validation
rule, Flow or named query in `force-app/` references the field (searched
2026-09-17). Page layouts, permission-set FLS and report-type columns are removed
automatically by the delete. The report type
`LDGCRM_Login_gov_Applications_with_Partner_Portal_Issuer_Strings` loses its only
issuer string column, so **any saved report built on it loses that column
silently** — check them before deleting in production. `force-app/` is scoped to
this app, so re-check the target org for references from outside it.

### The delete

`destructiveChanges.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
    <types>
        <members>LDGCRM_application__c.LDGCRM_PP_Issuer_Strings__c</members>
        <name>CustomField</name>
    </types>
    <version>64.0</version>
</Package>
```

`package.xml` — empty, required alongside it:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
    <version>64.0</version>
</Package>
```

```powershell
# From inside sfdx/. Dry run first: it reports any blocking reference without deleting.
sf project deploy start --manifest <dir>\package.xml `
    --post-destructive-changes <dir>\destructiveChanges.xml `
    --target-org <alias> --test-level NoTestRun --dry-run --json

# Then the real one.
sf project deploy start --manifest <dir>\package.xml `
    --post-destructive-changes <dir>\destructiveChanges.xml `
    --target-org <alias> --test-level NoTestRun --json
```

**⚠️ Use `--manifest`, never `--metadata-dir`.** `--metadata-dir` silently ignores
a destructive manifest and reports `Succeeded` having deleted nothing. **Check
`numberComponentsDeployed` is 1**, not just the status.

### Verifying it — the Tooling API lies for about 15 days

A deleted field stays in the **Recycle Bin's Deleted Fields for 15 days**, and
Tooling API `FieldDefinition` keeps listing it for that long. So a
`FieldDefinition` query is **not** evidence the delete failed. Ask SOQL instead,
which leads:

```powershell
# Must FAIL with "No such column 'LDGCRM_PP_Issuer_Strings__c'".
sf data query --target-org <alias> `
    -q "SELECT LDGCRM_PP_Issuer_Strings__c FROM LDGCRM_application__c LIMIT 1"
```

Within those 15 days the field can still be **undeleted** from Setup → Object
Manager → Application → Fields & Relationships → Deleted Fields. After that it is
gone, and so is its data — which is why step 2 exports it first.

### After a sandbox refresh

Re-run the delete in the refreshed sandbox, and then `sf project retrieve` will
stop writing the field back into `force-app/`. A retrieve never deletes a local
file, so remove
`sfdx/force-app/main/default/objects/LDGCRM_application__c/fields/LDGCRM_PP_Issuer_Strings__c.field-meta.xml`
by hand if it reappears. **Do not commit it.**

---

## 6. ⚠️ POST-DEPLOYMENT STEP — delete `LDGCRM_application__c.LDGCRM_Est_Monthly_Active_Users__c`

**Deprecated in Sprint 2. Delete it by hand in every org that has it.** It is the
Number(18, 0) field labelled *Estimated Monthly Active Users*, help text *"From
the cost estimate"*. Its Airtable source column, `# of Estimated Monthly Active
Users`, was never migrated, so nothing in `tools/data-loading/` writes it.

Mechanically this is the same job as section 5, and the same rules apply: a change
set cannot carry a deletion, and a deletion in a sandbox is undone by the next
refresh. What differs is the org state, which is **not** the same as section 5's
and has to be established before anything is deleted.

### First establish which orgs actually have it

| Org | State (2026-09-23) |
| --- | --- |
| Production | **Check it. Do not assume either way.** The field is *not* in `LDGCRM_Sprint_1_24` — the inventory was snapshotted 2026-08-17, after the 2026-08-13 deletion — so it reached production only if an earlier change set carried it |
| Dev (`peodv8dvn`) | **Deleted.** SOQL rejects the column; it is in Deleted Fields until it expires |
| QA / UAT / Full | Assume present — every refresh copies production |

Use the same script as section 5 — this field is registered in it as
`-Field Est_Monthly_Active_Users`, and `-Field All` (the default) does both.

**`force-app/` cannot answer this.** A retrieve never deletes a local file, so the
file being present is equally consistent with "the org has it" and "it was deleted
from the org months ago and the file was left behind". Ask the org:

```powershell
# Field present => returns rows. Field absent => fails with
# "No such column 'LDGCRM_Est_Monthly_Active_Users__c'".
sf data query --target-org <alias> `
    -q "SELECT COUNT(Id) FROM LDGCRM_application__c WHERE LDGCRM_Est_Monthly_Active_Users__c != null"
```

That query answers both questions at once: whether the field exists, and whether
it holds data worth exporting. Do **not** ask `FieldDefinition` — section 5
explains why it is the wrong witness in both directions.

### Nothing blocks it — checked 2026-09-18, not assumed

A field delete **hard-blocks only on a formula reference**. Searched across
`force-app/`: no formula, validation rule, Flow, named query, report type,
FlexiPage or list view names this field. It is **not on `Application Layout`**,
and **no permission set grants FLS on it** — all four `LDGCRM_` permission sets
carry `viewAllFields=false` on `LDGCRM_application__c`, so that absence is real
rather than hidden by the flag described in CLAUDE.md.

The practical consequence: **no user can see this field today**, on any layout,
through any of our permission sets. Deleting it removes nothing from anyone's
screen. `force-app/` is scoped to this app, so still re-check the target org for
references from FCIC or TTS OTCRM before deleting in production.

### Export first if the org holds data

Unlike section 5's field, this one has no known hand-maintained data — but the
count query above is the only thing that proves it for a given org. **If it
returns anything other than 0, export before deleting**; the delete destroys the
values and the 15-day window is the only way back.

```powershell
# From inside sfdx/. data/ is gitignored.
sf data export bulk --target-org <alias> --result-format csv --wait 10 `
    --output-file ..\data\salesforce-backups\LDGCRM_Est_Monthly_Active_Users__c-<alias>.csv `
    --query "SELECT Id, Name, LDGCRM_External_ID__c, LDGCRM_Est_Monthly_Active_Users__c FROM LDGCRM_application__c WHERE LDGCRM_Est_Monthly_Active_Users__c != null"
```

### The manual delete

*Setup → Object Manager → **Application** → Fields & Relationships →
**Estimated Monthly Active Users** → **Del*** → confirm.

For GSA IT Engineering's CLI deployment it is the same destructive pair as
section 5, with one member swapped — reuse those commands, including the
**`--manifest`, never `--metadata-dir`** warning and the
`numberComponentsDeployed` check:

```xml
<types>
    <members>LDGCRM_application__c.LDGCRM_Est_Monthly_Active_Users__c</members>
    <name>CustomField</name>
</types>
```

### Verifying it

```powershell
# Must FAIL with "No such column 'LDGCRM_Est_Monthly_Active_Users__c'".
sf data query --target-org <alias> `
    -q "SELECT LDGCRM_Est_Monthly_Active_Users__c FROM LDGCRM_application__c LIMIT 1"
```

`FieldDefinition` keeps listing the field for ~15 days, and Setup → Object Manager
→ Application → **Deleted Fields** can still undelete it for that long. After
that it is gone, along with its data.

### After a sandbox refresh

Re-run the delete, and remove
`sfdx/force-app/main/default/objects/LDGCRM_application__c/fields/LDGCRM_Est_Monthly_Active_Users__c.field-meta.xml`
by hand if a retrieve writes it back. **Do not commit it.**

### Its twin, which this section does not decide

`LDGCRM_num_est_annual_idv__c` was dropped on the same day, for the same reason,
and is in the same state — deleted from Dev, file back in `force-app/`. Nothing
here deprecates it. **Whoever deletes this field will be looking straight at it**,
so get a decision on it before starting rather than in the middle.

---

## 7. Before signing off a target org

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
| `LDGCRM_PP_Issuer_Strings__c` deleted | SOQL on the field **fails** | Section 5. `FieldDefinition` still lists it for ~15 days; a refresh brings it back |
| `LDGCRM_Est_Monthly_Active_Users__c` deleted | SOQL on the field **fails** | Section 6. Same 15-day trap, same refresh behaviour. Confirm the org had it before recording it as done |

The three Flows with the transposed `LGDCRM_` prefix are easy to miss: a
`LIKE '%DGCRM%'` search **does not match them**, because "LGDCRM" does not contain
"DGCRM". Search for both spellings.
