# Deployment guide — standing the app up in a new org

> **Who this is for:** everyone with a hand in a deployment, together — the project owner, GSA IT
> Engineering who deploy the change set, the Salesforce admin who provisions users, and whoever runs
> the migration pipeline. It is the **order of operations**, not the mechanics of any one step.
>
> **It is not the runbook.** How to run a load is [RUNNING-A-LOAD.md](RUNNING-A-LOAD.md); if you have
> never seen this project, start at [OVERVIEW.md](OVERVIEW.md). This file answers a different
> question: **what happens, in what order, and who does it.**
>
> Two companion documents live in the **engineering repository** rather than in this folder, and are
> marked **†** throughout: **PRODUCTION-CHANGE-SET-INVENTORY.md**, the component-by-component listing
> of what the change set contains, and **PRODUCTION-READINESS.md**, which tracks whether the project
> is ready to go at all. Ask whoever handed you this bundle for them.

Use it for any org the app has not stood up in before — the Full sandbox rehearsal and production
follow the same sequence. Production differs in three specific places, each marked **🔴 Production**.

---

## The one thing to take away

**Metadata, then people, then data — and the order is not a preference.**

Each phase is a precondition for the next in a way that fails *quietly* rather than loudly:

- Load before the change set lands and the fields do not exist. This one is loud — the pipeline
  names the missing component and stops.
- Load before the Flows are switched on and **every count is correct while Market Segment is blank
  across the whole migration.** Nothing turns red. This has already happened once, in QA.
- Load before the users exist and their records land on the fallback owner, indistinguishably from
  the people who are *meant* to land there. Provisioning them afterwards does not move the records —
  **a re-load does**, and re-loading after go-live overwrites whatever anyone has edited by hand.

That last one is the reason user setup is phase 3 and not an afterthought.

---

## The phases

| # | Phase | Owner | Blocks the next? |
| --- | --- | --- | --- |
| 1 | [Deploy the change set](#1-deploy-the-change-set) | GSA IT Engineering | **Yes** — the load has nowhere to write |
| 2 | [Activate the nine Flows](#2-activate-the-nine-flows) | Salesforce config owner | **Yes** — pre-flight blocks the load |
| 3 | [Users, access and ownership](#3-users-access-and-ownership) | Salesforce admin + Partnerships | **Yes, in effect** — see above |
| 4 | [Prepare the load](#4-prepare-the-load) | Whoever runs the pipeline | Yes |
| 5 | [Run the migration](#5-run-the-migration) | Whoever runs the pipeline | — |
| 6 | [Verify and hand over](#6-verify-and-hand-over) | All of the above | — |

Phases 1–3 can be done days ahead. Only 4–6 need a window.

---

## 1. Deploy the change set

**Metadata moves between orgs by change set only.** Not by `sf project deploy`, not from this
repository, not even for a change that is obviously correct and only going to a sandbox. The one
exception is deleting corrupted metadata.

The current set is named in **PRODUCTION-CHANGE-SET-INVENTORY.md †** — component-by-component, with
what each one is and why it matters. Regenerate that file when a new version of the set is cut; do
not hand-edit it.

### Check two dependencies before uploading

Both are things the change set *references* but does not carry, so the deployment fails on them
rather than the org quietly ending up wrong.

- **`OrgWide_Hide_Salesforce_Classic_System`.** All three `LDGCRM_G_*` permission set groups include
  it alongside their own permission set. It is not an LDGCRM component and is not in the change set —
  **confirm it already exists in the target org.**
- **The four `GSA Standard *` / `GSA System Administrator` profiles** must exist in the target. A
  profile in a change set is *merged* into the target's copy, never created wholesale from it.

### What "deployed successfully" does not mean

The inventory † carries the full list in its **Verification notes**; three matter enough to repeat:

- **A Flow can be Active in the source and land as Draft in the target.** All nine did exactly that
  in QA. This is why phase 2 exists as its own phase.
- **A change set cannot delete anything.** Components removed in Dev survive in the target and appear
  in no deployment report. They come out by hand in Setup.
- **A profile is merged, not replaced.** Permissions already in the target's profile stay, so a green
  deployment does not mean the target profile matches the source.

### Verify against the inventory, not against the deployment report

Walk the inventory's † component list in the target org's Setup. The deployment report tells you what
Salesforce accepted; the inventory tells you what should be there.

One nuance worth knowing so it does not look like a fault: the single validation rule
(`Account.Level1_and_Level2_account_restrictions`) deploys **inactive**, with an
always-false condition. That is its state in the source, and it has no effect on the load.

---

## 2. Activate the nine Flows

**Nine record-triggered Flows must be Active before any data is loaded.** Three of them derive
`LDGCRM_Market_Segment__c` down the parent chain — Account → Partner Account → Opportunity →
Application — on create.

**Why this is a phase and not a checklist line.** A QA load once reported 8,740 records and zero
failures with all nine switched off. Nothing failed, nothing was withheld, and every object count
matched Dev — because **flow activation changes what is in the fields, not how many records there
are.** Market Segment came out blank on every Partner Account, Opportunity and Application in the org.

And **activating them afterwards does not repair it.** All three fire on create or on parent change,
and the pipeline upserts — so a re-run is an update that never re-triggers them. The only fix is a
factory reset and a full reload, which in production is not a fix at all.

### How it happens depends on the org

| | |
| --- | --- |
| **Sandbox** | `Invoke-FullMigrationLoad.ps1 -ActivateFlows` switches on whatever is off, then re-reads the org to confirm |
| **🔴 Production** | **By hand, in Setup, by the config owner.** `-ActivateFlows` is refused outright for `-Environment Prod` |

Run pre-flight without `-ActivateFlows` first either way: it is read-only and it reports exactly which
flows are off, which is the list to hand over. The load **blocks** while any of them is inactive, so
this cannot be forgotten — only done in the wrong order.

**It can activate a Flow. It can never create one.** An absent Flow is a change set, back to phase 1.

> **Version numbers do not compare across orgs.** Each org counts its own saves, so Dev on v4 while
> production is on v2 is normal and is not drift. Only active-versus-latest *within one org* means
> anything.

---

## 3. Users, access and ownership

Three separate things, commonly conflated, and the migration depends on all three.

### 3a. Licences — "active" is not "can own a record"

A Chatter Free, portal or community user is active and can own nothing. Assigning one fails with
`OP_WITH_INVALID_USER_TYPE_EXCEPTION`, an error that names neither the user nor the field, so the
resolvers filter on `UserType = 'Standard'` and treat everyone else as absent.

**Anyone who should own migrated records needs a Standard licence**, not merely an account.

### 3b. Permission set groups — what people get assigned

Three groups come across in the change set. Assign people to the group, not to the bare permission
set.

| Permission set group | For |
| --- | --- |
| `LDGCRM_G_Partnership_Team_Member_CRE` | The Partnerships team — create, read, edit |
| `LDGCRM_G_Partnership_Viewer_R` | Read-only access to the app |
| `LDGCRM_G_Production_Support_CRED` | Support — create, read, edit, delete |

### 3c. Public groups — the step that carries no error message

**Sharing on these objects is driven by two public groups, `LDGCRM_Team_Members` and
`LDGCRM_Viewers`, and fourteen sharing rules that point at them.** The objects are
org-wide-default-restricted: without a sharing rule reaching them, a record is visible to its owner
and nobody else.

**The group *definitions* deploy. Their membership does not** — the retrieved definitions carry no
members at all. So after deployment the rules exist, reference real groups, and grant access to an
empty set of people. Nothing errors. The app simply looks empty to everyone who is not an admin, and
the natural diagnosis — a permissions problem — is the wrong one.

**Populate both groups in the target org, then have a non-admin confirm they can see records.**

A permission set group is not a substitute: one grants *object and field* access, the other decides
*which records* you can see. People need both.

### 3d. Record owners — provision before the load, not after

Ownership is resolved **at load time**, from the Airtable collaborator on each row:

| Object | Owner comes from |
| --- | --- |
| Opportunity | Airtable's `Pod Opportunity Lead` |
| `LDGCRM_application__c` | Its Partner Account's owner |
| Contact | Its resolved Account's owner |
| `LDGCRM_Impediment__c` | Nothing in Airtable — always the fallback |
| `LDGCRM_Partner_Account__c` | Master-Detail child — inherits its Account's owner |

Where that person is not an active, record-eligible user, the record goes to a **named fallback
owner** (`peter.marks@gsa.gov`). That is deliberate and correct for someone who has left the team —
and indistinguishable, afterwards, from a current colleague nobody got round to provisioning.

**[`../reference/salesforce-user-roster.csv`](../reference/salesforce-user-roster.csv) is where the
business states which is which**, and pre-flight tests every assertion in it against the
target org — **for Full and Prod only**, since developer sandboxes carry no expectation these logins
exist.

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
provisioning can happen before the load rather than after it.

### 3e. 🔴 Production: load as a dedicated integration user

Run the production load under a service account, not a personal login. Otherwise the fallback owner
is whoever was on shift, and thousands of records land on someone with no relationship to them.
There is precedent in this org already: a service account owns 651 production Accounts for exactly
this reason.

---

## 4. Prepare the load

By this point the metadata is in, the Flows are on, and the people exist.

1. **Authorize the org alias.** Every script takes `-Environment`, never a bare alias, and resolves
   it through the registry — then asks the org who it is and refuses to continue if the answer
   disagrees. Authorizing is a one-time step per machine:
   [SETUP.md](SETUP.md#authorizing-a-new-environment).
2. **Set up the bundle and the Airtable token** — [SETUP.md](SETUP.md). Airtable access needs an
   admin on the base, so start it early.
3. **Pull fresh Airtable data.** The export folder is a current-state mirror, overwritten each pull;
   an old pull is never the right input. Expect counts to move when you re-pull, and re-baseline
   rather than treating older figures as pass/fail targets.
4. **Run the readiness check** — `Test-LdgcrmReadiness.ps1`. Read-only, safe against any environment
   including production. It checks the machine, the token, every Airtable table, which orgs you can
   reach, who you are in the target org, and that every field the load writes exists and is writable
   there.
5. **Coordinate.** More than one person can write to these orgs — at least one colleague uses the
   Data Loader GUI against the same sandbox, and other teams share the org outright. Loads are
   re-runnable; a load nobody expected is still an incident.

**🔴 Production also needs a change window agreed in advance**, and one thing re-confirmed by hand:
`purecloud.ContactWebHookv1`, a managed Genesys trigger that fires on every Contact insert. Its body
is hidden, it cannot be retrieved, and it has no kill switch — **what it does is unknowable from this
repository.** It was confirmed inert in the org in the past; confirm it again before a production run,
because it is the one outward-facing side effect the pipeline cannot see.

---

## 5. Run the migration

The mechanics are [RUNNING-A-LOAD.md](RUNNING-A-LOAD.md). Three things belong here rather than there,
because they are deployment decisions rather than operating ones.

### Tell the config owner what the load changes in the org itself

Beyond writing records, the load flips four org settings — **three of them permanently**, and two of
those belong to another team's application. Anyone who owns configuration in the target org should
see this list *before* the run, not discover it after.

| Change | Environments | Restored? |
| --- | --- | --- |
| Every active **Contact duplicate rule** → inactive | **All, production included** | **No — permanent** |
| Every active **Contact matching rule** → inactive | **All, production included** | **No — permanent** |
| The nine **LDGCRM Flows** → active | **Sandbox only** — see phase 2 | **No — permanent** |
| `TriggerControls__c` "Contact" `On__c` → `false` | All | **Yes** — restored and re-queried, inside the Contact step |

The duplicate rule is `OTCRM_Contact_Duplicate`, which matches on first and last name only and cost
167 Contacts in a single Dev run. It belongs to TTS OTCRM, which is defunct, so it needs no
cross-team sign-off — but it does need saying out loud, because it stays off afterwards.

The operator-facing version of this list, with what to do if a restore fails, is
[RUNNING-A-LOAD.md](RUNNING-A-LOAD.md#-what-the-load-changes-in-your-org). The boundary is the
important part here: **every one of these flips the status of a component that already exists.** The
pipeline will not add a field, a picklist value or a record-type assignment, and it will not promote
anything between orgs. Where a load needs any of those it names the component precisely and stops —
back to phase 1.

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

## 6. Verify and hand over

**Success counts are not evidence.** Every serious defect found on this project passed its load
cleanly. Three different questions hide behind a green run, and it answers only the first:

1. Did the rows Salesforce received get accepted? — the load result
2. Were all the rows *sent*? — **withheld** rows, which are usually the bigger number
3. Is what landed in them correct? — post-load validation

Start with `SUMMARY.txt` in the run folder, then walk
[RELOAD-QA-CHECKLIST.md](RELOAD-QA-CHECKLIST.md) — it is written as a rehearsal checklist but its
verification sections apply to any org.

Then the deployment-specific ones:

- **A non-admin can see records.** The single best test that phase 3c actually happened.
- **Market Segment is populated**, on Partner Accounts, Opportunities and Applications — the check
  that proves phase 2 happened, and the one no row count will ever make for you.
- **Owners look right**, particularly anyone the roster flagged.

### Two things that are one-way

**Manual ownership changes belong *after* the final load.** The fallback owner is written explicitly
rather than left blank, so a re-run pushes a manually reassigned record straight back. Decide which
load is the last one before anyone starts tidying.

**Rollback is a best-effort tidy-up, not a safety net.** Read [ROLLBACK.md](ROLLBACK.md) before
relying on it, and read it before the run rather than during it.

---

## After go-live

Neither of these blocks a deployment; both are easy to lose track of once the load is done.

- **Meetings are not migrated in the initial load** — a project owner decision, solved separately
  afterwards. The Airtable data is captured on every pull, so nothing needs preserving specially.
- **Duplicate and misfiled Accounts in production** are tracked by the GSA Salesforce team, to be
  worked after the migration. Two of them force a manual re-tagging step on every sandbox rebuild,
  which resolving them would remove.

Both are written up in the engineering repository — **BACKLOG.md** and
**SALESFORCE-ACCOUNT-CLEANUP.md** — if you need the detail.

---

## What this guide does not decide

Deliberately open, because they are the project owner's calls and not engineering's:

- **What happens to the Airtable base at cutover** — whether it goes read-only, when, and who tells
  the team. The pipeline only ever reads Airtable, so nothing technical forces the question; but
  until it is answered, edits made in Airtable after the final pull are silently lost.
- **The production window, and who supervises it.**
- **How many Standard licences are needed**, which falls out of phase 3 once the roster is walked
  against the target org.
