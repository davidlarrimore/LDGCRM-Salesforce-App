# Production readiness — the north star

> **Who this is for:** the project owner and whoever is building the pipeline, together. It answers
> one question — **what still has to be true before the production load can run?** — and it is the
> page to open first when picking up this project after time away.
>
> **This is not a run log.** Individual loads write their own report to
> `scripts/logs/data-migration/<run>/SUMMARY.txt`, which is gitignored and disposable. This file is
> source controlled *because* those are not: run output tells you what happened once, this tells you
> where the programme is.

**Last reviewed:** 2026-08-15 · **Target org:** `gsa-peo` (production, not yet authorized on any
dev machine).

---

## Where we are in one line

**Every object except Meetings is built and proven in Dev, the pipeline has run clean in a second org,
and every blocking config change has landed.** What stands between that and production is **no longer
engineering work of any kind**: it is a QA rehearsal that has to be redone, an Operations rehearsal in
the Full sandbox that has not started, a production authorization nobody has requested, and a decision
about Meetings.

Per-object counts and per-script build status live in
[engineering/ARCHITECTURE.md](engineering/ARCHITECTURE.md) — that file, not this one, is the
authority on build status.

---

## The gates, in the order they have to clear

Each gate is a thing that must be TRUE, with what it is waiting on and who owns it. **A gate is
closed when it has been demonstrated, not when the code exists.**

| # | Gate | Status | Owner |
| --- | --- | --- | --- |
| 1 | The pipeline loads every in-scope object | 🟢 **Done** — full Dev reload, 0 unexpected failures, derived fields verified by query | Engineering |
| 2 | Meetings decided — build, defer, or drop | 🔴 **Blocked on a spike**, not on code | Project owner + SF admin |
| 3 | Salesforce config changes landed | 🟢 **Done in Dev and QA** (verified 2026-08-15) — **nothing promoted to Full or Prod yet** | Salesforce config owner |
| 4 | A full rehearsal in **QA**, end to end | 🟠 **Unblocked** — needs a factory reset and full reload | Engineering |
| 5 | Airtable data quality at an accepted level | 🟡 **Down to 2 items**, one with 8 Airtable fixes outstanding | Airtable data owners |
| 6 | The **Full** sandbox exists and Operations rehearse in it | 🟠 **Provisioned** (`PEOfL2STGp`) — the rehearsal has not happened | GSA IT / Operations |
| 7 | Production authorized, scheduled, supervised | 🔴 **Not started** | Project owner + GSA IT |

**Gates 2, 3, 5, 6 and 7 are not engineering work** — the pipeline cannot move them, and chasing
them is the critical path.

---

## 1. The pipeline loads every in-scope object — 🟢 Done

A full wipe-and-reload of Dev (`peodv8dvn`) loads every object except Meetings with zero unexpected
failures, reproduced across several reloads from empty against freshly pulled Airtable data.

Two things that broke earlier rehearsals are now verified rather than assumed on every run:

- **The org duplicate rule is switched off by the load itself**, so Contact no longer loses rows to it.
- **Market Segment is checked by querying the field**, not by trusting row counts — the exact failure
  that invalidated an earlier QA run, where every count looked right and every one of those fields
  was blank.

**What "done" does and does not mean here.** Every transform runs, resolves its lookups against a real
org, and loads. It does **not** mean the data is complete: several hundred rows are deliberately
*withheld* each run because their parent doesn't reconcile — that is gate 5, not a defect. It also
does not mean it works in an org other than Dev — that is gate 4.

**One object is not built:** Meetings — see gate 2.

---

## 2. Meetings — 🔴 blocked on a spike, not on code

~1,850 Airtable rows, 0 loaded. **The approach changed and the new one is not a transform.** Airtable
holds a meeting date but no time, so loading them as Events means synthesizing scheduling history that
never existed. The agreed direction is instead to stand up **Einstein Activity Capture**, let real
calendar events sync, and fuzzy-match Airtable's meetings onto them.

**The open question, and nobody should start designing the match until it is answered:** is Einstein
Activity Capture feeding queryable `Event` records in this org? Dev held **0 standard Event records**
when last checked, so today it is not.

Full analysis in [engineering/BACKLOG.md](engineering/BACKLOG.md) §2.

**Decision needed:** build the match, defer Meetings out of the migration, or drop them.

---

## 3. Salesforce config changes — 🟢 done in Dev and QA

**Every change request that blocked a load has landed**, verified 2026-08-15 by querying both orgs
rather than reading the change-set record. Notably `LDGCRM_Level_of_Priority__c` carries all four
values **and** they are assigned to the `Login_gov` record type — checked by reading the record type
metadata, because record-type picklist narrowing is enforced by the Bulk API and is invisible to
`sf sobject describe`.

[engineering/SALESFORCE-CHANGE-REQUESTS.md](engineering/SALESFORCE-CHANGE-REQUESTS.md) is now empty
of open items.

⚠️ **Nothing has been promoted to Full or Prod.** Neither org is authorized here, and the whole set of
changes made in Dev still has to travel to both. **Treat this gate as green for the rehearsal and
open for production** — it closes when the same verification has been run against Full.

---

## 4. A full rehearsal in QA — 🟠 unblocked, not yet run

QA has loaded before, but **no run to date counts as a rehearsal.** The last one completed with every
object count matching Dev while all nine LDGCRM Flows were inactive, so Market Segment came out blank
across the entire migration — flow activation changes field *contents*, not row counts. A pre-flight
check now blocks a run against inactive Flows, so that specific failure cannot recur silently.

**Activating the Flows does not backfill.** All three Market Segment Flows fire on create or parent
change and the pipeline upserts, so a re-run is an update that will not re-trigger them. QA needs a
**factory reset and a full reload**, not a re-run.

**Nothing is blocking it any more.** The config change that would have failed every Opportunity
carrying a Priority Type is verified present in QA, so the reset and reload can be scheduled.

**What a QA run proves that Dev never can:** that the pipeline has no hidden dependency on
Dev-specific state, that change sets travel correctly, that the FCIC trigger bypass flips and restores
another team's config safely in a fresh org, and that the Account bootstrap can build a hierarchy from
near-nothing.

**Two standing cautions for any run in a non-Dev org:**

- **QA can trail Dev by a change set.** Never assume Dev's metadata state applies — verify against the
  org you are actually loading.
- **Market Segment must be *resolvable*, not merely present.** The Account reconciliation matches on
  `LDGCRM_Market_Segment__r.LDGCRM_External_ID__c`, so segments carrying the right names and no
  external IDs resolve nothing and leave Market Segment blank everywhere, silently. This is why
  Market Segment is step 1 of the load rather than an assumed precondition.

Run it with [../scripts/docs/RELOAD-QA-CHECKLIST.md](../scripts/docs/RELOAD-QA-CHECKLIST.md).

---

## 5. Airtable data quality — 🟡 down to two items

Tracked in
[data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md](data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md),
which lists **only what is still open**.

| Item | Whose call |
| --- | --- |
| Airtable Accounts with no Salesforce match | Mostly **ours** — 8 fixes sit with the data owners; the rest is external-ID seeding, hierarchy gaps and 5 Accounts to create. See [engineering/ACCOUNT-MATCHING-WORKLIST.md](engineering/ACCOUNT-MATCHING-WORKLIST.md) |
| `Gov Employees` is not a Salesforce picklist value | Salesforce config |

**This gate never reaches zero, and it should not block production.** The pipeline is built to withhold
rows it cannot place rather than guess, and to report exactly what it withheld and why. The decision to
make is *what level of incompleteness is acceptable to go live with*, not *when is Airtable perfect*.

**Much of what used to sit here is now a settled business rule**, not an open ask — derived contact
names, the `Launch Level` default, over-long URLs, contacts under two addresses. Those live in
[engineering/TRANSFORMATION-RULES.md](engineering/TRANSFORMATION-RULES.md) and **must not be
re-raised**.

**How to read a load's contribution to this gate:** the **ROWS WITHHELD** section of any run's
`SUMMARY.txt`, which counts them by reason and compares against the previous run.

---

## 6. The Full sandbox — 🟠 provisioned, rehearsal not started

`Full` is the org where **GSA IT Operations** rehearse the migration themselves, running the scripts
and applying the change sets, immediately before production.

**It exists.** Sandbox `PEOfL2STGp`, alias `peofl2stgp`, fully populated in the registry at
`scripts/powershell-scripts/Common.Orgs.ps1` — alias, sandbox name, instance URL and Lightning URL.

⚠️ **Provisioned is not the same as reachable.** Only Dev and QA are authorized on this machine, so
`-Environment Full` currently fails at `Assert-LdgcrmOrgTarget` with "could not reach org alias" —
which is the correct outcome, because the registry records which org Full *is*, not whether you can
log into it. Authorize with:

```powershell
sf org login web --alias peofl2stgp --instance-url https://gsa-peo--peofl2stgp.sandbox.my.salesforce.com
```

**What this gate is actually waiting on is the rehearsal**, not the sandbox.

**Why it is a separate gate from QA.** QA proves the *pipeline* works in a second org. Full proves the
*hand-off* works — that someone who did not build this can run it from the documentation.

### The hand-off packaging is done

Operations take the pipeline into **their own GitHub repository** as a `/scripts` folder, so `scripts/`
is self-contained: `data/`, `logs/`, the operator runbooks and the credential template all live inside
it, and every path resolves off the bundle root. `tools/Export-OpsBundle.ps1` builds the zip and
verifies it by reading the archive back; `tools/Test-BundleStructure.ps1` guards against the folder
quietly regaining an outward dependency.

Two consequences that matter for this gate:

- **Accounts are never deleted or rebuilt in a Full sandbox.** It is a copy of production, so its
  Accounts *are* the records the migration reconciles onto. Enforced in code, in one place, across all
  three scripts that could do it. Every other object still resets normally.
- **Two things must be handed over out-of-band**, because neither is in the repo: the production
  Account export (gitignored, and only needed if Operations also rehearse in a *developer* sandbox),
  and Airtable Personal Access Token access, which requires an admin account on the base.

**Needed:** the sandbox provisioned, then authorized per the runbook in
[engineering/ARCHITECTURE.md](engineering/ARCHITECTURE.md) ("Environments and org aliases") — which
means filling in `Alias`, `SandboxName`, `InstanceUrl` and `LightningUrl` for `Full` in the registry.
Nothing else in the pipeline needs to change.

---

## 7. Production — 🔴 not started

**Production is not authorized on any machine here, deliberately.** The local `gsa-peo` alias was
deleted when it was discovered that it had always pointed at the Dev sandbox while carrying the
production org's name — so any stale command using it now fails loudly instead of writing to
production.

What is already built for this, and does not need revisiting:

- **Two independent confirmation tokens.** `-Confirmation "LOAD"` approves the load;
  `-ProductionConfirmation <alias>` is additionally required for `-Environment Prod`, so automation
  written for a sandbox cannot be retargeted at production by changing one flag.
- **`Assert-LdgcrmOrgTarget`** verifies the alias against the registry *and* reads
  `Organization.IsSandbox` from the org itself before any script proceeds.
- **The Sandbox Factory Reset cannot target production by construction** — `-Environment` does not
  accept `Prod` at parameter binding. There is deliberately no production confirmation prompt on it,
  because offering one would create a way to approve it by mistake.
- **A rollback exists** (`Invoke-MigrationRollback.ps1`) — but read
  [../scripts/docs/ROLLBACK.md](../scripts/docs/ROLLBACK.md) first: it is a best-effort tidy-up, not a
  safety net, and deleting a created record does **not** undo an updated one.

**Still needed:** production authorization, a scheduled and supervised window, agreement on who runs
it, and one thing that must be re-checked rather than assumed — **the `purecloud.ContactWebHookv1`
managed trigger on Contact insert.** Its body is hidden and cannot be inspected; it was user-confirmed
inert in Dev. It is an outward-facing side effect this pipeline cannot see, and it has no kill switch.

---

## Keeping this file honest

- **Update it when a gate moves**, in the same change that moves it.
- **Do not paste run counts in here.** They move several times a day; point at the object and let
  `SUMMARY.txt` or `ARCHITECTURE.md` carry the number.
- **Record what is true now, not how it got here.** Superseded status, resolved items and run history
  are deleted rather than struck through — git carries the record.
