# Production readiness — the north star

> **Who this is for:** the project owner and whoever is building the pipeline, together. It answers
> one question — **what still has to be true before the production load can run?** — and it is the
> page to open first when picking up this project after time away.
>
> **This is not a run log.** Individual loads write their own report to
> `scripts/logs/data-migration/<run>/SUMMARY.txt`, which is gitignored and disposable. This file is
> source controlled *because* those are not: run output tells you what happened once, this tells you
> where the programme is.

**Last reviewed:** 2026-08-17 · **Target org:** `gsa-peo` (production).

---

## Where we are in one line

**The build is finished.** Every in-scope object loads, the Account workstream is closed, every
blocking config change has landed, and there are no open Airtable asks. **What is left is two
rehearsals** — one in QA that engineering can run today, and one in the Full sandbox that Operations
run themselves.

Per-object counts and per-script build status live in
[engineering/ARCHITECTURE.md](engineering/ARCHITECTURE.md) — that file, not this one, is the
authority on build status.

**This file says whether we are ready.
[../scripts/docs/DEPLOYMENT-GUIDE.md](../scripts/docs/DEPLOYMENT-GUIDE.md) says what a deployment
actually consists of** — change set, Flow activation, user and sharing setup, then the load — in the
order it has to happen, with an owner per phase. Both rehearsals below are that guide, run end to
end.

---

## The gates, in the order they have to clear

Each gate is a thing that must be TRUE, with what it is waiting on and who owns it. **A gate is
closed when it has been demonstrated, not when the code exists.**

| # | Gate | Status | Owner |
| --- | --- | --- | --- |
| 1 | The pipeline loads every in-scope object | 🟢 **Done** — full Dev reload, 0 unexpected failures, derived fields verified by query | Engineering |
| 2 | Salesforce config changes landed | 🟢 **Done in Dev and QA** (verified 2026-08-15) — **nothing promoted to Full yet** | Salesforce config owner |
| 3 | A full rehearsal in **QA**, end to end | 🟠 **Unblocked** — needs a factory reset and full reload | Engineering |
| 4 | Airtable data quality at an accepted level | 🟢 **No open Airtable asks** — the one remaining item is Salesforce config | Salesforce config owner |
| 5 | Operations rehearse in the **Full** sandbox | 🟠 **Sandbox provisioned** (`PEOfL2STGp`) — the rehearsal has not happened | GSA IT / Operations |

**Only gate 3 is engineering work.** Gate 2 closes when the Dev/QA config travels to Full, gate 5
when Operations run the bundle themselves.

---

## What is deliberately out of scope

**Meetings are not migrated in the initial load.** Decided by the project owner — the Airtable data is
**backed up**, and the meeting history is solved separately, afterwards. It is **not a blocker on
production** and it is not a gate.

The approach that was being designed (stand up Einstein Activity Capture, fuzzy-match Airtable's
meetings onto real calendar events, enrich rather than duplicate) is preserved in
[engineering/BACKLOG.md](engineering/BACKLOG.md) §1, along with why loading them as synthesized Events
was rejected. Nothing there needs revisiting before go-live.

**The backup already exists and needs no extra step.** `Get-AirtableExport.ps1` pulls the Meetings
table like any other, so the data is captured on every run. `scripts/data/airtable-exports/` is a
**current-state mirror the next pull overwrites, deliberately** — the latest pull is the one that
matters, and no snapshot is taken or kept. Re-pull when Meetings are picked up.

---

## 1. The pipeline loads every in-scope object — 🟢 Done

A full wipe-and-reload of Dev (`peodv8dvn`) loads every in-scope object with zero unexpected
failures, reproduced across several reloads from empty against freshly pulled Airtable data.

Two things that broke earlier rehearsals are now verified rather than assumed on every run:

- **The org duplicate rule is switched off by the load itself**, so Contact no longer loses rows to it.
- **Market Segment is checked by querying the field**, not by trusting row counts — the exact failure
  that invalidated an earlier QA run, where every count looked right and every one of those fields
  was blank.

**What "done" does and does not mean here.** Every transform runs, resolves its lookups against a real
org, and loads. It does **not** mean the data is complete: several hundred rows are deliberately
*withheld* each run because their parent doesn't reconcile — that is gate 4, not a defect. It also
does not mean it works in an org other than Dev — that is gate 3.

---

## 2. Salesforce config changes — 🟢 done in Dev and QA

**Every change request that blocked a load has landed**, verified 2026-08-15 by querying both orgs
rather than reading the change-set record. Notably `LDGCRM_Level_of_Priority__c` carries all four
values **and** they are assigned to the `Login_gov` record type — checked by reading the record type
metadata, because record-type picklist narrowing is enforced by the Bulk API and is invisible to
`sf sobject describe`.

**Nothing is open.** The change-request list that tracked these was retired on 2026-08-17 once it
emptied; git carries it. A new blocker gets raised with the config owner directly.

⚠️ **Nothing has been promoted to Full.** The whole set of changes made in Dev still has to travel
there. **Treat this gate as green for the rehearsal and open for production** — it closes when the
same verification has been run against Full.

---

## 3. A full rehearsal in QA — 🟠 unblocked, not yet run

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

**One step in that checklist is mandatory and has no automated guard.** Two Accounts — `AmeriCorps`
and `Millennium Challenge Corporation` — are matched by a **hand-applied external ID**, because
Salesforce holds two Accounts of each name and only depth distinguishes them. The factory reset
deletes tagged Accounts and the bootstrap recreates them untagged, so **skipping the re-tag silently
withholds 5 records while the run still reports success.** Resolving the underlying duplicates (gate
4's cleanup list) would remove the step entirely.

Run it with [../scripts/docs/RELOAD-QA-CHECKLIST.md](../scripts/docs/RELOAD-QA-CHECKLIST.md).

---

## 4. Airtable data quality — 🟢 no open Airtable asks

Tracked in
[data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md](data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md),
which lists **only what is still open**.

**The Account matching workstream is finished.** 690 of 719 Airtable Account rows match an existing
Salesforce Account, 9 are created by the load, and the remaining 20 carry no Opportunities, Partner
Accounts or Applications — so by the project owner's standing rule they cost nothing.

The one remaining item is **Salesforce config**, not Airtable:

| Item | Cost | Whose call |
| --- | --- | --- |
| `CLEAR` is not an identity-platform picklist value | 2 Opportunities | Salesforce config |

**A separate, non-blocking list now exists for Salesforce *data*:**
[data-quality/SALESFORCE-ACCOUNT-CLEANUP.md](data-quality/SALESFORCE-ACCOUNT-CLEANUP.md) — duplicate
and misfiled Accounts in the production org, to be worked **after** the migration. It costs no
records today, but two of its duplicates force a **manual re-tagging step on every sandbox rebuild**
(see gate 3), which resolving them would remove.

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

## 5. Operations rehearse in the Full sandbox — 🟠 not started

`Full` is the org where **GSA IT Operations** rehearse the migration themselves, running the scripts
and applying the change sets, immediately before production.

**The sandbox exists.** `PEOfL2STGp`, alias `peofl2stgp`, fully populated in the registry at
`scripts/powershell-scripts/Common.Orgs.ps1` — alias, sandbox name, instance URL and Lightning URL, so
nothing in the pipeline needs changing to target it. **What this gate waits on is the rehearsal**,
not the sandbox.

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

Authorize the alias per the runbook in
[engineering/ARCHITECTURE.md](engineering/ARCHITECTURE.md) ("Environments and org aliases"):

```powershell
sf org login web --alias peofl2stgp --instance-url https://gsa-peo--peofl2stgp.sandbox.my.salesforce.com
```

---

## Not tracked here

**Org authorization, the production window and who supervises it** are logistics handled outside this
document. They are not gates, and their absence from the table is deliberate rather than an oversight.

The production safeguards they rely on are already built and need no further work: two independent
confirmation tokens (`-Confirmation "LOAD"` plus `-ProductionConfirmation <alias>` for
`-Environment Prod`), `Assert-LdgcrmOrgTarget` verifying the alias against the registry and reading
`Organization.IsSandbox` from the org itself, a Sandbox Factory Reset that cannot target production at
parameter-bind time, and `Invoke-MigrationRollback.ps1` — which is a best-effort tidy-up, not a safety
net, so read [../scripts/docs/ROLLBACK.md](../scripts/docs/ROLLBACK.md) before relying on it.

⚠️ **One thing must be re-checked before a production run rather than assumed:** the
`purecloud.ContactWebHookv1` managed trigger on Contact insert. Its body is hidden and cannot be
inspected, it has no kill switch, and it was only ever user-confirmed inert in Dev. It is an
outward-facing side effect this pipeline cannot see.

---

## Keeping this file honest

- **Update it when a gate moves**, in the same change that moves it.
- **Do not paste run counts in here.** They move several times a day; point at the object and let
  `SUMMARY.txt` or `ARCHITECTURE.md` carry the number.
- **Record what is true now, not how it got here.** Superseded status, resolved items and run history
  are deleted rather than struck through — git carries the record.
