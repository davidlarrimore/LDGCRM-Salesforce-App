# Production readiness — the north star

> **Who this is for:** the project owner and whoever is building the pipeline, together. It answers
> one question — **what still has to be true before the production load can run?** — and it is the
> page to open first when picking up this project after time away.
>
> **This is not a run log.** Individual loads write their own report to
> `scripts/logs/data-migration/<run>/SUMMARY.txt`, which is gitignored and disposable. This file is source
> controlled *because* those are not: run output tells you what happened once, this tells you where
> the programme is.

**Last reviewed:** 2026-08-14 · **Target org:** `gsa-peo` (production, not yet authorized on any
dev machine).

---

## Where we are in one line

**Every object except Meetings is built, and now proven in TWO orgs** — Dev (8,734 records, twice,
identically) and **QA (8,740 records, first attempt, 2026-08-14)** — both with zero unexpected
failures. **Every Salesforce config change is now closed too.** What stands between that and
production is no longer engineering work of any kind: it is **a sandbox that does not exist yet, a
production authorization nobody has requested, and a decision about Meetings.**

**Reproducibility is evidence, not a claim.** Dev reloaded twice from empty against a freshly pulled
Airtable export and produced identical results both times. QA then loaded first time in an org that
had never held migration data, with every object matching Dev except three explainable differences.

---

## The gates, in the order they have to clear

Each gate is a thing that must be TRUE, with what it is waiting on and who owns it. A gate is not
closed until it has been demonstrated, not merely built.

| # | Gate | Status | Owner |
| --- | --- | --- | --- |
| 1 | The pipeline loads every in-scope object | 🟢 **Done** — 8,734 records, reproduced identically across two independent reloads | Engineering |
| 2 | Meetings decided — build, defer, or drop | 🔴 **Blocked on a spike**, not on code | Project owner + SF admin |
| 3 | Salesforce config changes landed | 🟢 **Done 2026-08-14** — CR-1 and CR-2 fixed, CR-3 accepted as-is | Salesforce config owner |
| 4 | A full rehearsal in **QA**, end to end | 🟠 **RE-OPENED** — the 2026-08-14 run was invalid (all nine Flows were off). Needs a reset and reload, after CR-6 is promoted | Engineering |
| 5 | Airtable data quality at an accepted level | 🟡 **Improving** — 9 items closed 2026-08-13 | Airtable data owners |
| 6 | The **Full** sandbox exists and Operations rehearse in it | 🔴 **Not provisioned.** Hand-off *packaging* is done (2026-08-14) — `scripts/` is a self-contained bundle, proven by running it from an unrelated directory | GSA IT / Operations |
| 7 | Production authorized, scheduled, supervised | 🔴 **Not started** | Project owner + GSA IT |

Detail on each below. **Gates 2, 3, 5 and 6 are not engineering work** — the pipeline cannot move
them, and chasing them is the critical path.

---

## 1. The pipeline loads every in-scope object — 🟢 Done

A full wipe-and-reload of Dev (`peodv8dvn`) on 2026-08-13 loaded **8,734 records, up 28%** on the
previous run. Per-object counts and per-script status live in
[engineering/ARCHITECTURE.md](engineering/ARCHITECTURE.md) — that file, not this one, is the
authority on build status.

**What "done" does and does not mean here.** It means every transform runs, resolves its lookups
against a real org, and loads. It does **not** mean the data is complete: several hundred rows are
deliberately *withheld* each run because their parent doesn't reconcile, and that is gate 5, not a
defect. It also does not mean it works in an org other than Dev — that is gate 4.

**One object is not built:** Meetings — see gate 2.

---

## 2. Meetings — 🔴 blocked on a spike, not on code

1,845 Airtable rows, 0 loaded. **The approach changed on 2026-08-13 and the new one is not a
transform.** Airtable holds a meeting date but no time, so loading them as Events means synthesizing
scheduling history that never existed. The agreed direction is instead to stand up **Einstein
Activity Capture**, let real calendar events sync, and fuzzy-match Airtable's meetings onto them.

**The open question, and nobody should start designing the match until it is answered:** is Einstein
Activity Capture feeding queryable `Event` records in this org? Confirmed 2026-08-13 that Dev holds
**0 standard Event records**, so today it is not.

Full analysis in [engineering/BACKLOG.md](engineering/BACKLOG.md) §2.

**Decision needed:** build the match, defer Meetings out of the migration, or drop them.

---

## 3. Salesforce config changes — 🟢 ALL CLOSED 2026-08-14

**Metadata moves by CHANGE SET only.** A CLI deploy from this repo is sanctioned for exactly one
purpose — deleting corrupted metadata — so none of these can be unblocked by engineering. Full
specifications, including the exact formula edits, are in
[engineering/SALESFORCE-CHANGE-REQUESTS.md](engineering/SALESFORCE-CHANGE-REQUESTS.md).

| | What | Why it matters | Blocking? |
| --- | --- | --- | --- |
| ~~**CR-1**~~ | ~~Set `Unique = false` on the two Partner Portal Team fields~~ | ✅ **Done 2026-08-14** — also widened Text(50) → Text(255), which cleared the six over-long team names. Verified: **681 Applications now carry a portal team**, 0 failures | No longer blocking |
| ~~**CR-2**~~ | ~~Retire `LDGCRM_PP_Issuer_Strings__c`~~ | ✅ **Done 2026-08-14** — checklist item re-pointed at `LDGCRM_P3_Team_UUID__c` (denominator stays 9, second formula untouched, ceiling 78 → 89), then the field deleted by CLI. Salesforce cascaded the layout / permission-set / report-type cleanup | No longer blocking |
| ~~**CR-3**~~ | ~~Blank `Launch Level` reports 100% complete~~ | ✅ **Accepted as-is 2026-08-14** (project owner) — does not break anything, and the field is ignored once the app is live. ⚠️ The migration-side default that keeps this correct is now **load-bearing**: removing `Build-ApplicationLoad.ps1`'s Launch Level default returns 607 Applications to reporting 100% | No |

**One coupling to watch:** all three `LDGCRM_` permission sets grant field-level security on
`priority_type__c`, which **does not exist in QA at all**. That reference will fail a change set into
any org lacking the field — independent of this migration. **It did not affect the QA data load** (gate 4 passed), because a data load does not deploy permission sets; it will matter when change sets move to the Full sandbox.

---

## 4. A full rehearsal in QA — 🟠 RE-OPENED

> **⚠️ The 2026-08-14 run below does not count as a rehearsal, and every figure in it is still
> accurate — which is exactly the problem.** All nine LDGCRM Flows were inactive in QA for the whole
> run. Nothing failed, nothing was withheld, and every object count matched Dev, because flow
> activation changes field *contents*, not row counts. Market Segment came out blank on all 92 Partner
> Accounts, all 842 Opportunities and all 1,026 Applications.
>
> The Flows were switched on the same day, but activating them does **not** backfill: all three Market
> Segment Flows fire on create or parent change, and the pipeline upserts, so a re-run is an update
> that will not re-trigger them. **QA needs a factory reset and a full reload.**
>
> **Do that after CR-6 is promoted**, not before. QA still runs the name-only Contact duplicate rule,
> so a reload today would halt at step 5 exactly as Dev did on 2026-08-15.
>
> The pre-flight added on 2026-08-14 now blocks a run against inactive Flows, so this specific failure
> cannot recur silently. What it cost was a day of believing a gate was closed.

**Loaded on 2026-08-14 — 8,740 records in 19m37s, zero unexpected failures.** QA's first ever load,
and the first time the pipeline ran against any org but Dev. Kept below because what it *did* prove
(no Dev-specific dependencies, change sets travelling correctly, the trigger bypass working in a fresh
org) remains true and is worth not re-deriving.

| | QA | Dev |
| --- | --- | --- |
| Migrated total | **8,740** | 8,734 |
| Account | 587 | 584 |
| Contact | 1,871 (10 dup-rule rejects) | 1,870 (11) |
| Application–Contact links | 2,701 | 2,699 |
| **Every other object** | **exact match** | |
| Unexpected failures | **0** | 0 |

**What this proved that Dev never could** — the point of the gate:

- The pipeline has **no hidden dependency on Dev-specific state**. It ran clean in an org holding one
  Account and nothing else.
- **CR-1 and CR-2 travelled correctly by change set** — 681 Applications carry a portal team here
  too, `LDGCRM_PP_Issuer_Strings__c` is absent, and the Level 1 formula matches.
- **The FCIC trigger bypass flips and restores another team's config safely** in a fresh org.
- **The Account bootstrap builds a hierarchy from near-nothing** — 1 Account to 1,346, 1,101 parented.
- The org duplicate rule **exists here but fires slightly differently** (10 rejects vs 11) — the only
  behavioural difference found between the two orgs, and an expected partial either way.

**Two defects were found by preparing for this run, both of which would have reached production:**

1. **Market Segment was required by pre-flight but never loaded.** QA held five segments with the
   right names and no external IDs; the reconciliation resolves by external ID, so it would have
   matched nothing and left Market Segment blank across the entire migration, silently. Pre-flight's
   count check could not see it. Fixed by loading Market Segment as step 1 and checking
   *resolvability* rather than presence. **Under the old code QA could not have been loaded at all** —
   pre-flight would have hard-failed on it.
2. **The run report compared across orgs.** QA's first run diffed itself against a *Dev* run and
   reported every finding as NEW. Fixed: `run-info.json` records each run's org and the baseline
   lookup matches on it, so a first run in a new org correctly reports no baseline.

<details><summary>What we expected to find, kept for the record</summary>

Known differences expected to surface here and not before:

- **QA can trail Dev by a change set.** Never assume Dev's metadata state applies. Confirmed example:
  `priority_type__c` exists in Dev and does not exist in QA.
- **The org-specific things the pipeline discovered in Dev may differ**: the FCIC Contact trigger and
  its `TriggerControls__c` kill switch, the org-level Contact duplicate rule, the `purecloud`
  managed webhook on Contact insert, the pre-existing Apex compile error that fails any deploy which
  runs tests.
- **Account reconciliation needs Accounts to reconcile onto.** A fresh org needs
  `Invoke-AccountBootstrap.ps1` first, or every downstream object withholds nearly everything.
- **Market Segment must be *resolvable*, not merely present.** Found 2026-08-14: QA held all five
  segments with the right names and **no external IDs**, so the Account reconciliation — which
  matches on `LDGCRM_Market_Segment__r.LDGCRM_External_ID__c` — would have resolved nothing and left
  Market Segment blank across the whole migration, with pre-flight passing and no error anywhere.
  Fixed by making Market Segment **step 1 of the load** (`Build-MarketSegmentLoad.ps1`) rather than
  an unmet precondition, and by changing pre-flight to report *resolvable* segments, not a count.

**Run it with** [operations/RELOAD-QA-CHECKLIST.md](operations/RELOAD-QA-CHECKLIST.md).

</details>

---

## 5. Airtable data quality — 🟡 improving

Tracked item by item, with a resolved log, in
[data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md](data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md).
**Nine items were resolved at source on 2026-08-13** and the effect was large — the reload gained
1,915 records.

**This gate never reaches zero, and it should not block production.** The pipeline is built to
withhold rows it cannot place rather than guess, and to report exactly what it withheld and why. The
decision to make is *what level of incompleteness is acceptable to go live with*, not *when is
Airtable perfect*.

The largest remaining items, measured 2026-08-14 against a fresh export:

| Item | Scale | Status |
| --- | --- | --- |
| Airtable Account rows matching no Salesforce Account | **155** rows | 🟡 172 → 155. **The biggest single blocker** — holds back ~275 records across 5 objects |
| Contacts with no name | **1,054** of 1,535 | 🔴 Open. 592 get a real name derived from their email; 314 get only the local part; 45 don't load at all |
| Applications with no Launch Level | **621** rows | 🟡 Worked around — see CR-3 |
| The same person under two different email addresses | 10 people | 🔴 Open — **deliberately not auto-merged**; two contacts is the honest outcome |
| Contacts with an email address in the `Name` field | 3 | 🔴 Open — loads verbatim as the contact's name |
| Issuer Strings / portal team fields | — | ✅ **Closed 2026-08-14** — optional by business rule; `#N/A` transformed to blank |

**The list shortened on 2026-08-14 by decision rather than by data work.** Issuer strings and the
partner-portal Team Name/UUID were confirmed **optional**, which closed six items at once. Data
quality is now dominated by two things: **Account matching** and **contact names**.

**How to read a load's contribution to this gate:** the **ROWS WITHHELD** section of any run's
`SUMMARY.txt`, which counts them by reason and compares against the previous run.

---

## 6. The Full sandbox — 🔴 not provisioned

`Full` is the org where **GSA IT Operations** rehearse the migration themselves, running the scripts
and applying the change sets, immediately before production. It does not exist yet: the
`-Environment Full` entry in `scripts/powershell-scripts/Common.Orgs.ps1` has no alias or instance URL.

**Why it is a separate gate from QA.** QA proves the *pipeline* works in a second org. Full proves
the *hand-off* works — that someone who did not build this can run it from the documentation. The
Operations team have `sf` and Windows PowerShell and nothing else guaranteed, which is why this repo
is PowerShell-only.

### The hand-off packaging is done (2026-08-14)

Operations will take the pipeline into **their own GitHub repository** as a `/scripts` folder, so
`scripts/` was restructured to be self-contained: `data/`, `logs/`, the operator runbooks and the
credential template all live inside it, and every path resolves off the bundle root rather than this
repository's. `tools/Export-OpsBundle.ps1` builds the zip and verifies it by reading the archive
back; `tools/Test-BundleStructure.ps1` guards against the folder quietly regaining an outward
dependency. Proven by extracting the zip to an unrelated directory and running it there.

Two consequences that matter for this gate specifically:

- **Accounts are never deleted or rebuilt in a Full sandbox.** It is a copy of production, so its
  Accounts *are* the records the migration reconciles onto — rebuilding them from a stale export
  would invalidate the rehearsal. Enforced in code, in one place, across all three scripts that
  could do it. Every other object still resets normally, so the rehearsal is otherwise unchanged.
  `RELOAD-QA-CHECKLIST.md` carries the "skip these steps in Full" note.
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
  [operations/ROLLBACK.md](operations/ROLLBACK.md) first: it is a best-effort tidy-up, not a safety
  net, and deleting a created record does **not** undo an updated one.

**Still needed:** production authorization, a scheduled and supervised window, agreement on who runs
it, and one thing that must be re-checked rather than assumed — **the `purecloud.ContactWebHookv1`
managed trigger on Contact insert.** Its body is hidden and cannot be inspected; it was
user-confirmed inert in Dev on 2026-08-13. It is an outward-facing side effect this pipeline cannot
see, and it has no kill switch.

---

## Keeping this file honest

- **Update it when a gate moves**, in the same change that moves it — the same standing convention
  that keeps the data-quality doc and the reload checklist in step.
- **Do not paste run counts in here.** They move several times a day and this file is not the place
  they belong; point at the object and let `SUMMARY.txt` or `ARCHITECTURE.md` carry the number.
- **A gate is closed when it has been demonstrated**, not when the code exists. "Built" and "proven
  in an org that is not Dev" are different claims, and this project has already learned the
  difference more than once.
