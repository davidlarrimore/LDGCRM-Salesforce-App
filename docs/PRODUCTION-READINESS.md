# Production readiness — the north star

> **Who this is for:** the project owner and whoever is building the pipeline, together. It answers
> one question — **what still has to be true before the production load can run?** — and it is the
> page to open first when picking up this project after time away.
>
> **This is not a run log.** Individual loads write their own report to
> `logs/data-migration/<run>/SUMMARY.txt`, which is gitignored and disposable. This file is source
> controlled *because* those are not: run output tells you what happened once, this tells you where
> the programme is.

**Last reviewed:** 2026-08-14 · **Target org:** `gsa-peo` (production, not yet authorized on any
dev machine).

---

## Where we are in one line

**Every object except Meetings is built, and proven twice by independent wipe-and-reload cycles of
the Dev sandbox — 8,734 records, identical both times, zero unexpected failures.** What stands
between that and production is not transform work: it is one rehearsal in an org nobody has loaded
yet, three Salesforce config changes only the config owner can make, and a production authorization
that does not exist yet.

**Reproducibility is now evidence, not a claim.** The second cycle ran against a freshly pulled
Airtable export and produced the same 8,734 records, the same 13 expected failures, the same 357
withheld rows and the same 24 findings.

---

## The gates, in the order they have to clear

Each gate is a thing that must be TRUE, with what it is waiting on and who owns it. A gate is not
closed until it has been demonstrated, not merely built.

| # | Gate | Status | Owner |
| --- | --- | --- | --- |
| 1 | The pipeline loads every in-scope object | 🟢 **Done** — 8,734 records, reproduced identically across two independent reloads | Engineering |
| 2 | Meetings decided — build, defer, or drop | 🔴 **Blocked on a spike**, not on code | Project owner + SF admin |
| 3 | Salesforce config changes landed | 🔴 **3 open** (CR-1, CR-2, CR-3) | Salesforce config owner |
| 4 | A full rehearsal in **QA**, end to end | 🔴 **Not started** — QA has never been loaded | Engineering |
| 5 | Airtable data quality at an accepted level | 🟡 **Improving** — 9 items closed 2026-08-13 | Airtable data owners |
| 6 | The **Full** sandbox exists and Operations rehearse in it | 🔴 **Not provisioned** | GSA IT / Operations |
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

## 3. Salesforce config changes — 🔴 3 open

**Metadata moves by CHANGE SET only.** A CLI deploy from this repo is sanctioned for exactly one
purpose — deleting corrupted metadata — so none of these can be unblocked by engineering. Full
specifications, including the exact formula edits, are in
[engineering/SALESFORCE-CHANGE-REQUESTS.md](engineering/SALESFORCE-CHANGE-REQUESTS.md).

| | What | Why it matters | Blocking? |
| --- | --- | --- | --- |
| **CR-1** | Set `Unique = false` on `LDGCRM_P3_Partner_Portal_Team_Name__c` and `LDGCRM_P3_Team_UUID__c` | A portal team legitimately owns many Applications (one owns 54), so `unique=true` would fail 442 of 696 rows. The transform currently **omits both columns entirely** rather than fail most of the load — so the field is empty org-wide | **Yes** — 696 Applications carry no team until it lands |
| **CR-2** | Retire `LDGCRM_PP_Issuer_Strings__c`, fixing its two dependent formulas first | It is deprecated, but `LDGCRM_Level_1_Complete_Pct__c` counts it as 1 of 9 checklist items and `LDGCRM_Launch_Checklist_Completion__c` hard-codes that 9 — deleting it silently moves a second metric | No, but **needs a /8-vs-/9 decision** before it can be specified |
| **CR-3** | A blank `Launch Level` falls through the `CASE` in `LDGCRM_Launch_Checklist_Completion__c` to its else value of `1` | Reported 607 of 1,026 migrated Applications as 100% launch-complete purely because the field was empty. **Mitigated for migrated records**; the formula defect itself is still live for anything else | No, but it is a **live reporting defect** |

**One coupling to watch:** all three `LDGCRM_` permission sets grant field-level security on
`priority_type__c`, which **does not exist in QA at all**. That reference will fail a change set into
any org lacking the field — independent of this migration, and it will bite at gate 4.

---

## 4. A full rehearsal in QA — 🔴 not started

**QA (`peodv15dvn`) has never been loaded.** It was authorized on this machine on 2026-08-13
(`dave.larrimore@gsa.gov.peo.peodv15dvn`), so `-Environment QA` works, but every count in this repo
comes from Dev.

**This is the single largest untested risk in the project.** Everything proven so far is proven in
one org that has been reloaded a dozen times and whose metadata is the source for change sets. Known
differences that will surface here, not before:

- **QA can trail Dev by a change set.** Never assume Dev's metadata state applies. Confirmed example:
  `priority_type__c` exists in Dev and does not exist in QA.
- **The org-specific things the pipeline discovered in Dev may differ**: the FCIC Contact trigger and
  its `TriggerControls__c` kill switch, the org-level Contact duplicate rule, the `purecloud`
  managed webhook on Contact insert, the pre-existing Apex compile error that fails any deploy which
  runs tests.
- **Account reconciliation needs Accounts to reconcile onto.** A fresh org needs
  `Invoke-AccountBootstrap.ps1` first, or every downstream object withholds nearly everything.

**Run it with** [operations/RELOAD-QA-CHECKLIST.md](operations/RELOAD-QA-CHECKLIST.md).

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
| Issuer Strings `#N/A` team cells | **273** (136 name + 137 UUID) | 🔴 Open |
| Applications with no Launch Level | **621** rows | 🟡 Worked around — see CR-3 |
| The same person under two different email addresses | 10 people | 🔴 Open — **deliberately not auto-merged**; two contacts is the honest outcome |
| Contacts with an email address in the `Name` field | 3 | 🔴 Open — loads verbatim as the contact's name |

**How to read a load's contribution to this gate:** the **ROWS WITHHELD** section of any run's
`SUMMARY.txt`, which counts them by reason and compares against the previous run.

---

## 6. The Full sandbox — 🔴 not provisioned

`Full` is the org where **GSA IT Operations** rehearse the migration themselves, running the scripts
and applying the change sets, immediately before production. It does not exist yet: the
`-Environment Full` entry in `scripts/common/Common.Orgs.ps1` has no alias or instance URL.

**Why it is a separate gate from QA.** QA proves the *pipeline* works in a second org. Full proves
the *hand-off* works — that someone who did not build this can run it from the documentation. The
Operations team have `sf` and Windows PowerShell and nothing else guaranteed, which is why this repo
is PowerShell-only.

**Needed:** the sandbox provisioned, then authorized per the runbook in
[engineering/ARCHITECTURE.md](engineering/ARCHITECTURE.md) ("Environments and org aliases").

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
