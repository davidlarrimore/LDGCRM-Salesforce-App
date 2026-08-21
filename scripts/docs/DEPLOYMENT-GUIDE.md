# Deployment guide — standing the app up in a new org

> **Who this is for:** everyone with a hand in a deployment — the project owner, GSA IT Engineering
> who deploy the metadata, the Salesforce admin who provisions users, and whoever runs the migration
> pipeline.
>
> How to run a load is [RUNNING-A-LOAD.md](RUNNING-A-LOAD.md). If you have never seen this project,
> start at [OVERVIEW.md](OVERVIEW.md).
>
> Two companion documents live in the **engineering repository** rather than in this folder, and are
> marked **†** throughout: **PRODUCTION-CHANGE-SET-INVENTORY.md**, the component-by-component listing
> of what ships, and **PRODUCTION-READINESS.md**, which tracks whether the project is ready to go.
> Ask whoever handed you this bundle for them.

Use it for any org the app has not stood up in before — the Full sandbox rehearsal and production
follow the same sequence. Everywhere production differs is marked **🔴 Production**.

---

## Metadata, then people, then data

The order is not a preference, and three of the four ways of getting it wrong fail *quietly*:

- **Load before the metadata lands** and the fields do not exist. This one is loud — the pipeline
  names the missing component and stops.
- **Load before the Flows are switched on** and every count is correct while Market Segment is blank
  across the whole migration. Nothing turns red. This has already happened once, in QA, which is why
  the load now activates them itself and refuses to run while any is off.
- **Load before the users exist** and their records land on the fallback owner, indistinguishably
  from the people who are *meant* to land there. Provisioning them afterwards does not move the
  records — a re-load does, and re-loading after go-live overwrites whatever anyone has edited by
  hand.
- **Load without granting yourself access to the app** and the org answers your queries with the
  subset you can see rather than what is actually there. Nothing errors — a record you cannot see is
  indistinguishable from one that does not exist. See
  [2f](#2f-the-person-running-the-load-needs-both-of-the-above-on-their-own-account).

---

## The phases

| # | Phase | Owner | Blocks the next? |
| --- | --- | --- | --- |
| 1 | [Deploy the metadata](#1-deploy-the-metadata) | GSA IT Engineering | **Yes** — the load has nowhere to write |
| 2 | [Users, access and ownership](#2-users-access-and-ownership) | Salesforce admin + Partnerships | **Yes, in effect** — see above |
| 3 | [Prepare the load](#3-prepare-the-load) | Whoever runs the pipeline | Yes |
| 4 | [Run the migration](#4-run-the-migration) | Whoever runs the pipeline | — |
| 5 | [Verify and hand over](#5-verify-and-hand-over) | All of the above | — |

Phases 1 and 2 can be done days ahead. Only 3–5 need a window.

**Switching the nine Flows on is not a phase, in any environment**, because nothing manual happens:
pre-flight activates them itself, without being asked, and refuses to run while any is still off.
Production is no longer an exception to this — see [phase 4](#4-run-the-migration).

---

## 1. Deploy the metadata

**GSA IT Engineering deploy the app's metadata from their own GitHub repository, via the Salesforce
CLI.** The component set originates as a Salesforce change set built in Dev, and
**PRODUCTION-CHANGE-SET-INVENTORY.md †** lists it component by component, with what each one is and
why it matters. Regenerate that file when a new version is cut; do not hand-edit it.

**Nothing in this bundle deploys metadata, and it never will.** If a load is blocked by a missing
field, picklist value or record-type assignment, the pipeline names the component precisely and
stops. Adding it is GSA IT Engineering's deployment, not a step anyone takes here.

### Check two dependencies first

Both are referenced by components in the set but not carried by it, so the deployment fails on them
rather than the org quietly ending up wrong.

- **`OrgWide_Hide_Salesforce_Classic_System`.** All three `LDGCRM_G_*` permission set groups include
  it alongside their own permission set. It is not an LDGCRM component — **confirm it already exists
  in the target org.**
- **The four `GSA Standard *` / `GSA System Administrator` profiles** must exist in the target. A
  profile is *merged* into the target's copy, never created wholesale from it.

### What "deployed successfully" does not mean

The inventory † carries the full list in its **Verification notes**. Four matter enough to repeat,
and they apply whether the components arrive by CLI or by change set:

- **A profile is merged, not replaced.** Permissions already in the target's profile stay, so a green
  deployment does not mean the target profile matches the source. Page layout assignments are the
  case this bites — see [2c](#2c-page-layouts--assign-them-on-the-profile-by-hand).
- **A Flow can be Active in the source and land as Draft in the target.** All nine did exactly that
  in QA.
- **Deleting is not the inverse of deploying.** Components removed from the source survive in the
  target and appear in no deployment report. A CLI delete needs `--manifest` with
  `--post-destructive-changes`; **`--metadata-dir` silently ignores a destructive manifest** and
  reports "Succeeded" having deployed nothing. Check `numberComponentsDeployed`, not the status.
- **A metadata deploy deactivates a picklist value rather than deleting it**, and `sf sobject
  describe` hides inactive values — so a field can look clean while the old value is still in the
  value set. The retrieved metadata file is the authority.

### ⚠️ Any deploy that runs tests currently fails org-wide

`GSA_FCIC_AC_Manual_InitialBatch`, part of the unrelated FCIC app sharing this org, has a genuine
Apex compile error. Salesforce compiles all Apex in the org before running any test, so that one
class cascades into failures across every deployment regardless of what is being deployed.

This bites a CLI deploy harder than a change set, because `--test-level` is now an explicit choice.
On a sandbox, `--test-level NoTestRun` sidesteps it for metadata-only changes. **Establish before the
production window which test level that deployment will use and whether this blocks it** — it is not
a question to discover on the day, and fixing the class belongs to whoever owns the FCIC app.

### Verify against the inventory, not the deployment report

Walk the inventory's † component list in the target org's Setup. The deployment report says what
Salesforce accepted; the inventory says what should be there.

The single validation rule (`Account.Level1_and_Level2_account_restrictions`) deploys **inactive**,
with an always-false condition. That matches its state in the source and has no effect on the load.

**A Flow's version number is a per-org counter**, so Dev on v4 against a target on v2 is normal and
is not drift. The only comparison that means anything is active-versus-latest *within one org* — a
version deployed and never switched on.

---

## 2. Users, access and ownership

### 2a. Licences — "active" is not "can own a record"

A Chatter Free, portal or community user is active and can own nothing. Assigning one fails with
`OP_WITH_INVALID_USER_TYPE_EXCEPTION`, an error that names neither the user nor the field, so the
resolvers filter on `UserType = 'Standard'` and treat everyone else as absent.

**Anyone who should own migrated records needs a Standard licence**, not merely an account.

### 2b. Permission set groups — what people get assigned

Assign people to the group, not to the bare permission set.

| Permission set group | For |
| --- | --- |
| `LDGCRM_G_Partnership_Team_Member_CRE` | The Partnerships team — create, read, edit |
| `LDGCRM_G_Partnership_Viewer_R` | Read-only access to the app |
| `LDGCRM_G_Production_Support_CRED` | Support — create, read, edit, delete |

**These grant the record types.** All three permission sets make `Account.Federal`, `Contact.Federal`,
`Contact.GSA`, `LDGCRM_application__c.LDGCRM_Application` and `Opportunity.Login_gov` visible, which
is why those record types are marked *not* visible on the profiles themselves.

**`LDGCRM_G_Production_Support_CRED` is also what the person running the migration assigns to
themselves** — the load needs the D as well as the CRE. See
[2f](#2f-the-person-running-the-load-needs-both-of-the-above-on-their-own-account).

### 2c. Page layouts — assign them on the profile, by hand

**A permission set cannot assign a page layout. Only a profile can.** The permission set groups above
hand someone the record type and the fields, and say nothing about which layout renders when they
open the record. Where the assignment is missing the user gets whatever layout the profile already
defaulted to — very possibly another team's — with no error and no empty screen.

**Do this in the target org, on `GSA Standard Salesforce User`**, after the deployment:
*Setup → Profiles → GSA Standard Salesforce User → Page Layout Assignment → Edit Assignment.*

| Object | Record type | Layout |
| --- | --- | --- |
| Contact | **`Federal`** | `LDGCRM Federal Contact Layout` |
| Contact | **`GSA`** | `LDGCRM Federal Contact Layout` |
| Opportunity | `Login_gov` | `Login.gov CRM` |
| `LDGCRM_application__c` | `LDGCRM_Application` | `Application Layout` |
| `LDGCRM_Partner_Account__c` | *(none)* | `Partner Account Layout` |
| `LDGCRM_Application_Contact__c` | *(none)* | `Application Contact Layout` |
| `LDGCRM_Impediment__c` | *(none)* | `Impediments Layout` |
| `LDGCRM_Opportunity_Impediment__c` | *(none)* | `Opportunity Impediment Layout` |
| `LDGCRM_Market_Segment__c` | *(none)* | `Market Segment Layout` |

**Check the two Contact rows first.** In the profile as it stands in Dev, the seven `LDGCRM_*` rows
and the Opportunity row are assigned and **Contact has no LDGCRM assignment at all**, even though
`Contact-LDGCRM Federal Contact Layout` is in the component set. Both Contact record types are ones
this migration writes: Federal for partner-agency staff, GSA for anyone with a `@gsa.gov` address.

Repeat for any other profile whose users work in this app, and for `GSA System Administrator` if
admins are expected to see the same thing. **A profile is merged, not replaced**, so an assignment the
deployment does not carry is not one it will add.

**Verify by opening a record as a non-admin**, not by reading the profile — one Contact of each
record type, one Opportunity, one Application.

> Account's `Federal` record type is assigned the `Account-Federal` layout, which is **not** in the
> component set. It has to already exist in the target org.

### 2d. Public groups — the step that carries no error message

**Sharing on these objects is driven by two public groups, `LDGCRM_Team_Members` and
`LDGCRM_Viewers`, and fourteen sharing rules that point at them.** The objects are
org-wide-default-restricted: without a sharing rule reaching them, a record is visible to its owner
and nobody else.

**The group definitions deploy. Their membership does not** — the definitions carry no members at
all. After deployment the rules exist, reference real groups, and grant access to an empty set of
people. Nothing errors; the app simply looks empty to everyone who is not an admin.

**Populate both groups in the target org, then have a non-admin confirm they can see records.**

**Put whoever is running the migration in `LDGCRM_Team_Members` while they run it**, for the same
reason and with a worse failure mode — see
[2f](#2f-the-person-running-the-load-needs-both-of-the-above-on-their-own-account).

A permission set group is not a substitute: one grants *object and field* access, the other decides
*which records* you can see. People need both.

### 2e. Record owners — provision before the load, not after

Ownership is resolved **at load time**, from the Airtable collaborator on each row:

| Object | Owner comes from |
| --- | --- |
| Opportunity | Airtable's `Pod Opportunity Lead` |
| `LDGCRM_application__c` | Its Partner Account's owner |
| Contact | Its resolved Account's owner |
| `LDGCRM_Impediment__c` | Nothing in Airtable — always the fallback |
| `LDGCRM_Partner_Account__c` | Master-Detail child — inherits its Account's owner |

Where that person is not an active, record-eligible user, the record goes to a **named fallback
owner** (`peter.marks@gsa.gov`) — correct for someone who has left the team, and indistinguishable
afterwards from a current colleague nobody got round to provisioning.

**[`../reference/salesforce-user-roster.csv`](../reference/salesforce-user-roster.csv) is where the
business states which is which**, and pre-flight tests every assertion in it against the target org,
**for Full and Prod only**, since developer sandboxes carry no expectation these logins exist.

| What pre-flight finds | Result |
| --- | --- |
| Marked `yes`, no user at that address or under that name | ⚠️ Warning — a provisioning gap someone can still fix |
| Marked `yes`, user exists **under a different email address** | 🛑 **Blocks the load** |
| Marked `yes`, user exists but on a licence that cannot own records | 🛑 **Blocks the load** |
| Marked `no`, absent | ✅ Confirmed quietly — the fallback is the intended outcome |
| Present in Airtable, absent from the roster | ⚠️ Warning — the roster has gone stale |

The two blocking cases block because the person **already exists** and something small and fixable —
a spelling, a licence — is stopping their records reaching them. **Fix the Salesforce user**, not the
roster, not Airtable, and never by adding an alias map to the pipeline.

Expect that report to be non-empty on a first production pre-flight. Run it early enough that
provisioning can happen before the load.

### 2f. The person running the load needs both of the above, on their own account

**Before the load, the admin running it must assign themselves the
`LDGCRM_G_Production_Support_CRED` permission set group and add themselves to the
`LDGCRM_Team_Members` public group, in the target org.** This is a step they do to their own user,
not one the pipeline can do for them, and neither half of the pair substitutes for the other:

| Without | What the load hits |
| --- | --- |
| The **permission set group** | No object or field access to the `LDGCRM_` objects. Steps fail row by row with `INSUFFICIENT_ACCESS_OR_READONLY`, or the readiness check reports fields it cannot write |
| The **public group** | Object access exists, but the sharing rules never reach you. Records you do not own are invisible to *your* SOQL, and several transforms read the org before deciding what to send |

`CRED` and not `CRE` because the pipeline deletes: the factory reset hard-deletes migrated records,
and [ROLLBACK.md](ROLLBACK.md) removes what a run created. `LDGCRM_Team_Members` and not
`LDGCRM_Viewers` because every step writes.

**The public-group half is the one that fails quietly.** These objects are org-wide-default
restricted (2d), so a record you cannot see does not error — it reads as absent. The transforms that
query the target org before building their CSV would then draw the wrong conclusion from a partial
answer: rows withheld because a parent Partner Account "does not exist", an insert-and-diff step
re-inserting rows it could not see, a reconciliation matching against a fraction of the Accounts.
Each of those is a green run with wrong contents, which is the failure mode this project keeps
finding.

The Notes step is the concrete case that has already been documented: attaching a note requires
*your* user to have edit access to every parent record it lands on, not merely to the note.

> **Being a System Administrator is not a substitute, and do not plan around it being one.** A
> profile carrying *View All Data* / *Modify All Data* will get through without either grant, which
> is exactly why this goes unnoticed in a sandbox and then bites in production — the account that
> should run the production load is the dedicated integration user in 2g, which has no business
> holding *Modify All Data*.

**Remove both again afterwards** where the account is not meant to keep standing access to the app.

### 2g. 🔴 Production: load as a dedicated integration user

Run the production load under a service account, not a personal login. Otherwise the fallback owner
is whoever was on shift, and thousands of records land on someone with no relationship to them. There
is precedent in this org: a service account owns 651 production Accounts for this reason.

That account needs the two grants in 2f like anyone else, and it is the case where they should
**not** be removed afterwards: the load is re-runnable, and stripping its access turns the next run
into a fresh diagnosis of a solved problem.

---

## 3. Prepare the load

By this point the metadata is in and the people exist.

1. **Grant your own user access to the app.** `LDGCRM_G_Production_Support_CRED` plus membership of
   the `LDGCRM_Team_Members` public group, in the target org, on the account you will run the load
   under — [2f](#2f-the-person-running-the-load-needs-both-of-the-above-on-their-own-account). Do it
   before the readiness check in step 5, which reports what *your* user can write and will otherwise
   report a problem that is yours rather than the org's.

2. **Authorize the org alias.** Every script takes `-Environment`, never a bare alias, and resolves it
   through the registry — then asks the org who it is and refuses to continue if the answer disagrees.
   One-time per machine: [SETUP.md](SETUP.md#authorizing-a-new-environment).
3. **Set up the bundle and the Airtable token** — [SETUP.md](SETUP.md). Airtable access needs an admin
   on the base, so start it early.
4. **Pull fresh Airtable data** — `.\powershell-scripts\Get-AirtableExport.ps1`. A step you run
   yourself: the transforms read the JSON files off disk and no part of a load contacts Airtable, so
   until this has run there is nothing to migrate. The export folder is a current-state mirror,
   overwritten each pull; an old pull is never the right input. Expect counts to move when you
   re-pull, and re-baseline rather than treating older figures as pass/fail targets.
   [RUNNING-A-LOAD.md](RUNNING-A-LOAD.md#pulling-from-airtable) has the options.
5. **Run the readiness check** — `Test-LdgcrmReadiness.ps1`. Read-only, safe against any environment
   including production. It checks the machine, the token, every Airtable table, which orgs you can
   reach, who you are in the target org, and that every field the load writes exists and is writable
   there.
6. **Coordinate.** More than one person can write to these orgs — at least one colleague uses the
   Data Loader GUI against the same sandbox, and other teams share the org outright. Loads are
   re-runnable; a load nobody expected is still an incident.

### 🔴 Production only

Two things a sandbox run does not need.

- **A change window agreed in advance.**
- **`purecloud.ContactWebHookv1` re-confirmed by hand.** A managed Genesys trigger that fires on every
  Contact insert. Its body is hidden, it cannot be retrieved, and it has no kill switch — what it does
  is unknowable from this repository. It was confirmed inert in the org in the past; confirm it again
  before a production run.

Why the Flows matter enough to be a gate rather than a warning: a QA load reported 8,740 records and
zero failures with all nine switched off. Nothing failed, nothing was withheld, and every object count
matched Dev, because flow activation changes what is *in* the fields rather than how many records
there are — Market Segment came out blank on every Partner Account, Opportunity and Application.
**Switching them on afterwards does not repair it**, since the three Market Segment Flows fire on
create or parent change and the pipeline upserts. The only fix is a full reload.

---

## 4. Run the migration

The mechanics are [RUNNING-A-LOAD.md](RUNNING-A-LOAD.md).

### Tell the config owner what the load changes in the org itself

Beyond writing records, the load flips four org settings — **three of them permanently**, and two of
those belong to another team's application. Anyone who owns configuration in the target org should
see this list *before* the run.

| Change | Environments | Restored? |
| --- | --- | --- |
| Every active **Contact duplicate rule** → inactive | **All, production included** | **No — permanent** |
| Every active **Contact matching rule** → inactive | **All, production included** | **No — permanent** |
| The nine **LDGCRM Flows** → active | **All, production included** — pre-flight does it, with no flag | **No — permanent** |
| `TriggerControls__c` "Contact" `On__c` → `false` | All | **Yes** — restored and re-queried, inside the Contact step |

The duplicate rule is `OTCRM_Contact_Duplicate`, which matches on first and last name only and cost
167 Contacts in a single Dev run. It belongs to TTS OTCRM, which is defunct, so it needs no
cross-team sign-off — but it stays off afterwards, which is worth stating before the run rather than
after.

The operator-facing version, with what to do if a restore fails, is
[RUNNING-A-LOAD.md](RUNNING-A-LOAD.md#-what-the-load-changes-in-your-org). **Every one of these flips
the status of a component that already exists.** The pipeline will not add a field, a picklist value
or a record-type assignment, and it will not promote anything between orgs. Where a load needs any of
those it names the component and stops — back to phase 1.

### Plan first, then load

`-PlanOnly` runs every transform against the real org, read-only, and reports what each step would
load. It is a genuine dry run, not a simulation.

**🔴 Production takes two different confirmation tokens**, so that someone who automated a sandbox run
cannot retarget it by changing one word:

```powershell
.\powershell-scripts\Invoke-FullMigrationLoad.ps1 -Environment Prod `
    -Confirmation "LOAD" -ProductionConfirmation gsa-peo
```

### Accounts are never rebuilt outside Dev and QA

A Full sandbox is a copy of production, so its Accounts **are** the records this migration reconciles
onto. Deleting them would replace the thing being tested with a stale export. This is enforced in
code, in one place: the factory reset drops Account from its delete list and says so loudly, the
bootstrap refuses to start, and the orchestrator rejects the flag. Every *other* object still resets
normally in a Full sandbox.

---

## 5. Verify and hand over

**Success counts are not evidence.** Every serious defect found on this project passed its load
cleanly. Three questions hide behind a green run, and it answers only the first:

1. Did the rows Salesforce received get accepted? — the load result
2. Were all the rows *sent*? — **withheld** rows, usually the bigger number
3. Is what landed in them correct? — post-load validation

Start with `SUMMARY.txt` in the run folder, then walk
[RELOAD-QA-CHECKLIST.md](RELOAD-QA-CHECKLIST.md) — written as a rehearsal checklist, but its
verification sections apply to any org.

Then the deployment-specific checks, all of them as a non-admin:

- **Records are visible at all** — proves the public groups (2d) got populated.
- **The right layout renders** on a Contact of each record type, an Opportunity and an Application
  (2c). A wrong layout renders perfectly happily, so nothing else will catch this.
- **Market Segment is populated** on Partner Accounts, Opportunities and Applications. No
  row count will catch this either.
- **Owners look right**, particularly anyone the roster flagged.

**Meetings are deliberately not migrated**, so an empty Activity timeline is the expected result and
not a gap to report. The Login.gov team pick them up separately after go-live.

### Two things that cannot be undone later

**Manual ownership changes belong after the final load.** The fallback owner is written explicitly
rather than left blank, so a re-run pushes a manually reassigned record straight back. Decide which
load is the last one before anyone starts tidying.

**Rollback is a best-effort tidy-up, not a safety net.** Read [ROLLBACK.md](ROLLBACK.md) before
relying on it, and before the run rather than during it.

---

## Still to be decided

- **What happens to the Airtable base at cutover** — whether it goes read-only, when, and who tells
  the team. The pipeline only ever reads Airtable, so nothing technical forces the question; until it
  is answered, edits made in Airtable after the final pull are silently lost.
- **The production window, and who supervises it.**
- **How many Standard licences are needed**, which falls out of phase 2 once the roster is walked
  against the target org.
