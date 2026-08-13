# Full reload QA checklist

> **Who this is for:** whoever is running a complete **wipe and reload** of a sandbox — emptying it
> and rebuilding from scratch, usually to rehearse the production migration or to verify something
> that can only be checked at load time.
>
> **This is not the normal way to load data.** For an ordinary load, use
> [RUNNING-A-LOAD.md](RUNNING-A-LOAD.md). Come here only when you specifically need to start from
> an empty org.
>
> **Prerequisites:** work through [SETUP.md](SETUP.md) first, and read
> [RUNNING-A-LOAD.md](RUNNING-A-LOAD.md) — this checklist assumes you know what the pipeline does
> and adds verification around it rather than explaining it.
>
> ⚠️ **This procedure permanently deletes records.** Hard deletes bypass the Recycle Bin. It is
> blocked from production by construction, but it will happily empty a sandbox someone else is
> using — coordinate first.

Operational runbook for a complete wipe-and-reload, written for whoever actually runs it. The trigger
for the 2026-08-13 run was the **record-ownership work** — ownership is set by the transforms at
load time, so it cannot be verified without reloading.

Work top to bottom. **Phase 3 is a hard gate**: do not start the full load until the test batch
passes, because the ownership design rests on one Bulk API behaviour this pipeline has never
exercised.

Related: [`README.md`](../engineering/ARCHITECTURE.md) (pipeline + load order), [`TRANSFORMATION-RULES.md`](../engineering/TRANSFORMATION-RULES.md)
(field rules + the ownership section), [`BACKLOG.md`](../engineering/BACKLOG.md), and the `sfdx-sandbox-ops` skill.

---

## ⚠️ Before anything: `gsa-peo` now means PRODUCTION

The org registry (`scripts/common/Common.Orgs.ps1`, 2026-08-13) changed what aliases mean. Until then
every script hard-coded `gsa-peo`, which pointed at the **Dev sandbox**. It now names **production**.

| Environment | Alias | What it is |
| --- | --- | --- |
| `Dev` | `peodv8dvn` | Day-to-day development and pipeline testing. Default for every script. |
| `QA` | `peodv15dvn` | Full end-to-end migration rehearsal before the Operations hand-off. |
| `Full` | *not provisioned* | Operations dress rehearsal: scripts + change sets, immediately before production. |
| `Prod` | `gsa-peo` | **PRODUCTION.** Real Login.gov partner data. Deliberately not authorized locally. |

**Never pass `--target-org` by hand in this runbook.** Scripts take `-Environment Dev|QA|Full|Prod`
and resolve the alias themselves, then prove the alias still points where the registry says via
`Assert-LdgcrmOrgTarget`. Any command below that needs a raw alias uses `<alias>` — substitute the
one for the environment you are actually working in.

Any stale command line still saying `--target-org gsa-peo` is a **silent retarget to production**.
Treat finding one as a defect, not a typo.

---

## Decisions

### D1. Scope of the wipe — ✅ settled

The wipe includes an option to **bootstrap the production Accounts**, so the load is as
production-like as possible. `Invoke-SandboxFactoryReset.ps1` takes `-BootstrapAccounts` (run it without
prompting) or `-SkipBootstrap` (never run it), and calls `Invoke-AccountBootstrap.ps1`, which rebuilds
Account **names and the parent hierarchy** from `data/peo-prod-accounts-<yyyy-MM-dd>.xls` — an HTML
table saved with an `.xls` extension, a Salesforce report export, not binary Excel.

Know what the Account wipe actually does, because it is not intuitive: cleanup only deletes rows
**where `LDGCRM_External_ID__c` is populated**, and bootstrapped Accounts carry none. Bootstrapped
Accounts therefore survive a later cleanup, which is exactly what makes the bootstrap safely
repeatable — it inserts only what's missing, by name.

**The bootstrap now sets Account owners too** (added 2026-08-13). The export names owners by *display
name* (`SNA MSadi`) rather than email, so it uses `Resolve-SalesforceOwnerIdsByName` — same
active-only and refuse-to-guess-on-duplicates guards as the email resolver, because this data trips
both (`Matthew Taylor` matches two Users in Dev, one active and one inactive). Owners are set **only
on insert**; an existing Account keeps whatever owner it has.

⚠️ It does **not** make Contact ownership meaningful — see D2. In production 92% of Accounts are
owned by a service account or one person, so faithfully reproducing that reproduces something
largely uninformative. It makes the rehearsal *accurate*, not the data *useful*.

### D2. Contact ownership — ⚠️ needs a decision, see the analysis below

Short version: **the premise behind "Contacts inherit their Account's owner" does not hold, and not
just in the sandbox.** See "The Contact ownership problem" below before running this. It may mean
changing the rule rather than changing the seed.

### D3. Who runs the load — ⚠️ needs a decision, see below

**GSA IT Operations will run this in production.** That breaks the current fallback design, because
the fallback owner *is* whoever runs the load. See "The fallback owner problem" below.

---

## The Contact ownership problem

**The rule as agreed:** Contacts inherit their Account's owner, because Airtable records no Contact
owner at all.

**The assumption underneath it:** that Accounts carry meaningful owners.

**They don't — and this is not a sandbox artifact.** Checking the real production Account export:

| Account owner in production | Accounts | Share |
| --- | --- | --- |
| `SystemUser DataLoader` | 651 | 48% |
| `SNA MSadi` | 607 | 44% |
| 12 named individuals | 111 | 8% |

**92% of production Accounts are owned by either a data-loader service account or a single user.**
So Contacts inheriting their Account's owner would put roughly 92% of migrated Contacts under a
service account or one person — which is arguably *worse* than the fallback, because it looks like
real ownership data when it isn't.

In the Dev sandbox the same rule currently resolves to the loading user for ~1,346 of 1,350 Accounts,
because the production seed loads **Name only, no owner**. That was a deliberate, user-confirmed
decision on 2026-08-13, taken on the explicit basis that *nothing in this migration read Account
ownership*. That premise expired the moment Contact ownership started reading it.

**Three ways forward — this needs a decision, not a default:**

- **(a) Drop the inheritance.** All Contacts take the fallback owner. Honest and simple: Airtable
  genuinely has no Contact owner, and neither does Account in any meaningful way.
- **(b) Inherit only from real people.** Skip inheritance where the Account's owner is a service
  account (`SystemUser DataLoader`) — and decide whether the 607 under `SNA MSadi` are a real
  assignment or another bulk-load artifact. Roughly 111 Accounts' contacts would get genuine owners.
- **(c) Keep as agreed.** Accept that ~92% of Contacts land on a service account or one person.

**Resolved 2026-08-13: `SNA ` is a prefix on real people, not a class of service account.** All 14
owner names in the export match real Users — `SNA MSadi` → `mahendar.sadineni@gsa.gov`,
`SNA YMekonnen` → `yonathan.mekonnen@gsa.gov`, `SNA NALohning` → `nicholas.lohning@gsa.gov`,
`SNA JTScholz` → `jennifer.scholz@gsa.gov`. Most are inactive in the Dev sandbox; their status in
production is unverified, since production isn't authorized on this machine.

---

## The fallback owner problem

The agreed rule is "fall back to the loading/integration user", implemented as a **blank `OwnerId`** —
Bulk API 2.0 reads empty as "not supplied", so Salesforce assigns the record to whoever is
authenticated. That is exactly right when the person running the load is the intended owner.

**With GSA IT Operations running it in production, it is not.** Consequences:

- Every unresolved record — ~266 Opportunities, ~177 Applications, and most Contacts — would be owned
  by an IT Operations engineer with no business relationship to the record.
- These objects use **org-wide-default-restricted sharing with owner-based sharing rules**, so
  ownership decides *visibility*. Records owned by an Ops account may simply not be visible to the
  Partnerships team who need them.
- It is **non-deterministic**: the owner depends on which individual engineer happened to run it.

**Recommended fix — run production loads as a dedicated integration user**, not an individual's
account. Then "the loading user" is a stable, intended, documented owner, the blank-`OwnerId` design
stays correct, and re-runs still don't stomp manual reassignments. This is already the established
pattern in this very org — `SystemUser DataLoader` owns 651 production Accounts for exactly this
reason.

**Additional safety worth building** (not yet implemented): a preflight assertion in
`Invoke-SalesforceLoad.ps1` that fails if the authenticated user isn't the expected fallback owner,
so an Ops engineer running it under their own login is stopped rather than silently becoming the
owner of thousands of records.

The alternative — writing an explicit fallback owner Id into the CSV — fixes *who* owns unresolved
records but sacrifices the non-revert property on re-runs. That is a real tradeoff, not a free win.

---

## Phase 0 — Pre-flight

- [ ] **Confirm the target environment**, and let the script's own banner prove it. Every script
      prints a `TARGET:` banner and validates the alias against the registry before doing anything;
      production prints in red with an explicit warning.
- [ ] **Confirm Rahul is not running a Data Loader GUI load.** Standing rule — two load processes
      against the same org can race or double-load.
- [ ] **Confirm the authenticated user is the intended fallback owner** (see D3). This is silent —
      nothing warns you:
      `sf org display user --target-org <alias>`
- [ ] **Re-confirm `purecloud.ContactWebHookv1` is inert.** Installed **managed** trigger on Contact
      insert, body hidden, no kill switch — an outward-facing side effect this pipeline cannot
      inspect. User-confirmed inert in Dev on 2026-08-13. **This must be re-confirmed before any
      production run**, where a webhook firing on 1,900 Contact inserts is a real-world event.
- [ ] **Check for org automation on any object being loaded for the first time in this environment.**
      The repo's metadata is LDGCRM-scoped and does not show other apps' triggers:
      ```
      sf data query --use-tooling-api --target-org <alias> -q "SELECT Name, Status, NamespacePrefix, TableEnumOrId FROM ApexTrigger WHERE TableEnumOrId = '<Object>'"
      ```
      A new environment is **not** guaranteed to have the same automation as Dev. Re-run this per
      environment; do not carry Dev's findings forward as fact.
- [ ] **Decide whether to re-pull Airtable.** `Get-AirtableExport.ps1` **overwrites**
      `data/airtable-exports/` in place. A fresh pull reflects today's Airtable but shifts every count
      below. To keep this run comparable to the figures here, **do not re-pull**. Current export:
      2026-08-12.
- [ ] Confirm `logs/` and `data/` are still gitignored — both carry applicant PII.

---

## Phase 1 — Capture the baseline

Without this you cannot tell a successful reload from a partial one.

```powershell
$objs = 'Account','LDGCRM_Partner_Account__c','Contact','Opportunity','LDGCRM_application__c',
        'LDGCRM_Impediment__c','LDGCRM_Opportunity_Impediment__c','LDGCRM_Application_Contact__c',
        'OpportunityContactRole','LDGCRM_Market_Segment__c'
foreach ($o in $objs) {
  $tot = (& sf data query -q "SELECT COUNT() FROM $o" --target-org <alias> --json | ConvertFrom-Json).result.totalSize
  "{0,-34} {1}" -f $o, $tot
}
```

**Dev sandbox baseline, 2026-08-13 pre-reload:**

| Object | Total | External-ID tagged |
| --- | --- | --- |
| Account | 1,350 | 588 |
| `LDGCRM_Partner_Account__c` | 76 | 74 |
| Contact | 1,939 | 1,936 |
| Opportunity | 744 | 742 |
| `LDGCRM_application__c` | 691 | 688 |
| `LDGCRM_Impediment__c` | 40 | 39 |
| `LDGCRM_Opportunity_Impediment__c` | 268 | 267 |
| `LDGCRM_Application_Contact__c` | 1,884 | 1,880 |
| `OpportunityContactRole` | 515 | 515 |
| `LDGCRM_Market_Segment__c` | 6 | 5 |
| Event / Task | 0 | 0 |

- [ ] **The untagged rows are pre-existing test data and must survive the wipe.** Standing rule: do
      not touch pre-existing test data at all, migrate or delete. The external-ID filter is what
      enforces this — don't defeat it.
- [ ] Capture the current owner distribution so the "before" is on record:
      ```
      sf data query -q "SELECT OwnerId, Owner.Name, COUNT(Id) FROM Opportunity GROUP BY OwnerId, Owner.Name" --target-org <alias> --result-format csv
      ```

---

## Phase 2 — Wipe

`scripts/cleanup/Invoke-SandboxFactoryReset.ps1` is **interactive and destructive**. It exports the record IDs
it is about to delete first (audit trail), then requires a typed `HARD DELETE` confirmation. Against
production it additionally requires typing the org alias (`Assert-LdgcrmProductionConsent`).

- [ ] **Either** run it from a real console so the prompt appears:
      `powershell -File scripts\cleanup\Invoke-SandboxFactoryReset.ps1 -Environment Dev -BootstrapAccounts`
      **or** approve it non-interactively by passing the same token the prompt asks for:
      ```powershell
      powershell -File scripts\cleanup\Invoke-SandboxFactoryReset.ps1 `
          -Environment Dev -BootstrapAccounts -Confirmation "HARD DELETE"
      ```
      Every load script takes the same treatment (`-Confirmation "LOAD"` / `"BOOTSTRAP"`), so the
      whole reload can be driven from a script or an agent. The token is case-sensitive and each
      non-interactive approval is banner-logged to the transcript.
- [ ] Decide `-BootstrapAccounts` (rebuild the Account tree straight after the deletes, no prompt) vs
      `-SkipBootstrap` (never). Omitting both prompts interactively.
- [ ] Scope with `-ObjectsCsv` if not wiping everything. Comma-separated, no spaces.

**Default delete order** (correct — reverse of load order):

```
LDGCRM_Application_Contact__c -> LDGCRM_Opportunity_Impediment__c -> LDGCRM_Application__c
-> Opportunity -> Contact -> LDGCRM_Impediment__c -> LDGCRM_Partner_account__c -> Account
```

- [ ] ⚠️ **`OpportunityContactRole` is NOT in the default object list.** It should cascade away with
      its parent Opportunity — **verify rather than assume**, because 515 orphaned rows would survive
      and then collide with the read-then-diff insert:
      ```
      sf data query -q "SELECT COUNT() FROM OpportunityContactRole" --target-org <alias>
      ```
      Expect 0 after the Opportunity delete. If not, delete explicitly before reloading.
- [ ] ⚠️ **`LDGCRM_Market_Segment__c` must NOT be wiped.** Commented out of the default list
      deliberately — all 6 segments are correct and three before-save Flows depend on them. Confirm 6
      after the wipe.
- [ ] Confirm Master-Detail cascades behaved — deleting Opportunity or Impediment also removes
      `LDGCRM_Opportunity_Impediment__c`; deleting Account also removes `LDGCRM_Partner_Account__c`.
- [ ] ⚠️ **Expect the Account delete to fail on any Account that pre-existing test data hangs off.**
      This is the platform protecting test data, not a bug — but the script treats a partial delete
      as fatal, stops, and **withholds the Account bootstrap**, so the run has to be finished by hand.

      It happened on 2026-08-13: 587 of 588 Accounts deleted, and
      `U.S. Citizenship and Immigration Services` survived with
      `DELETE_FAILED: ... associated with the following application contacts.: LDGAC-0002 ... LDGAC-0005`.
      The chain was **not** the one you would guess from the error — it ran through **Contact**, not
      Partner Account: two untagged test Contacts (`Terry L. Harrison`, `Test Contact`) were parented
      onto that real migrated Account, the delete cascaded toward them, and the restricted lookup from
      the four `LDGAC-000x` junction rows blocked it.

      **Fixed at source rather than worked around** (2026-08-13): those Contacts were re-pointed at
      `Test Account`, `HHS- Test1` was moved onto `Test Account` (so it inherits `Test Market Segment`
      instead of the real `Benefits`), and the parentless `State Citizenship` Application was given
      `Test Partner Account`. The pre-existing test island is now self-contained and references no
      migrated record, so the next reset should delete all 588. **If this recurs, find what the
      surviving Account is a parent of and re-point it — don't exclude the Account from the wipe.**
- [ ] If the delete did stop early, run the bootstrap by hand before loading — it is skipped
      deliberately, because bootstrapping on top of a half-deleted org corrupts the next run's
      preflight counts:
      `powershell scripts/data-migration/Invoke-AccountBootstrap.ps1 -Environment Dev -Confirmation "BOOTSTRAP"`
- [ ] Confirm untagged/pre-existing records survived (compare against baseline).
- [ ] Keep the exported ID CSVs in `logs/cleanup/` — the only record of what was deleted.

---

## Phase 3 — 🚦 Ownership test batch (HARD GATE)

**Do not proceed until this passes.** Every record now carries an explicit `OwnerId` — either the
record's own owner or the named fallback (`peter.marks@gsa.gov`). This pipeline has never written
`OwnerId` at all before, so the whole column is unexercised. A 19-row Opportunity batch already
failed 19/19 once on an assumption that looked equally safe.

- [ ] **Confirm the fallback owner resolves before anything else.** Every transform now calls
      `Resolve-FallbackOwnerId`, which **throws** rather than degrading if the address doesn't match
      an active User. A transform that runs at all has already proved this — but in a *new*
      environment it is the first thing that will fail, and the message is explicit about why.
- [ ] Build a **15–25 row Opportunity batch containing both cases** — at least 5 rows owned by a
      resolved `Pod Opportunity Lead`, at least 5 on the fallback owner. A single-kind batch proves
      nothing.
- [ ] Load it. Confirm **0 failures**, specifically no `INACTIVE_OWNER_OR_USER`.
- [ ] **Verify fallback rows landed on `peter.marks@gsa.gov`** — not on the loading user. If they
      landed on the loader, the explicit Id isn't being written and Ops would silently own them in
      production.
- [ ] **Verify resolved rows landed on the right person** — spot-check 2–3 against Airtable's
      `Pod Opportunity Lead`.
- [ ] **Confirm the known re-run behaviour, so nobody reports it as a bug later.** Manually reassign
      one fallback-owned record, re-run the load, and expect the owner to be **pushed back to the
      fallback owner**. That is the accepted cost of a named fallback (see
      `TRANSFORMATION-RULES.md`); it is not a defect, but Operations should know before they discover
      it on live data.

**If the gate fails:** stop and discuss — do not work around it by blanking `OwnerId`, which would
silently hand every unresolved record to whoever runs the load.

---

## Phase 4 — Full load, in order

Parents before children. Per object: run the transform, read its review CSVs, load, verify, *then*
move on. **Do not batch these** — an error early silently withholds rows from everything later.

```
Market Segment (already loaded - do not touch)
  -> Account (prod seed INSERT, then reconciliation UPDATE)
  -> LDGCRM_Partner_Account__c
  -> Contact                       ⚠️ requires -DisableTriggerControl
  -> Opportunity
  -> LDGCRM_application__c
  -> LDGCRM_application__c SECOND PASS (Broker App Parent self-lookup only)
  -> LDGCRM_Opportunity_Impediment__c
  -> LDGCRM_Application_Contact__c
  -> OpportunityContactRole        (INSERT + read-then-diff, never upsert)
```

### 4a. Account

- [ ] **Bootstrap first** (skip if `Invoke-SandboxFactoryReset.ps1 -BootstrapAccounts` already did it). Always
      dry-run before applying — it is read-only and writes the pass plan to `logs/data-migration/`:
      ```powershell
      powershell scripts/data-migration/Invoke-AccountBootstrap.ps1 -Environment Dev -PlanOnly
      powershell scripts/data-migration/Invoke-AccountBootstrap.ps1 -Environment Dev
      ```
      It runs multiple passes by design: `Account.ParentId` is self-referential and the export names
      parents by name, so the tree is built outward from the roots until a pass changes nothing —
      four levels deep in the current export. Confirm it converged rather than stopping early.
- [ ] ⚠️ **Verify Account owners actually got set — this path is unexercised.** The bootstrap now
      assigns `OwnerId` from the export's "Account Owner" display name (added 2026-08-13), but
      **only on INSERT**; an Account that already exists keeps its current owner. A `-PlanOnly` run
      against the un-wiped Dev sandbox shows **0 inserts**, so nothing has ever tested it. After the
      wipe there will be inserts, and this is the first run where it matters:
      ```
      sf data query -q "SELECT Owner.Name, COUNT(Id) FROM Account GROUP BY Owner.Name ORDER BY COUNT(Id) DESC" --target-org <alias> --result-format csv
      ```
      Expect a spread across `SystemUser DataLoader` and a handful of named people — **not** every
      Account on the loading user. Only 5 of the export's 14 owner names match an *active* User in
      Dev (notably `SNA MSadi`, who owns 607 production Accounts, is inactive there), so a large
      share legitimately falls back to the loading user. That is expected, not a failure.
- [ ] `Build-AccountReconciliation.ps1` → `Invoke-SalesforceLoad.ps1 -Operation Update` (Id-keyed,
      **not** upsert)
- [ ] Expect ~587 matched, ~169 unmatched. The unmatched are the known Airtable duplicate-row problem
      — fixed at source, not routed around.

### 4b. `LDGCRM_Partner_Account__c`

- [ ] Run `Build-PartnerAccountLoad.ps1`. Expect **94 ready, 5 skipped, 5 of 7 owner emails resolved**.
- [ ] Load (upsert). Expect ~74 succeed, ~20 fail — all tracing to parent Accounts among the 169
      unmatched. Same failures as previous runs = correct, not a regression.
- [ ] ⚠️ **THE ORCHESTRATOR WILL STOP HERE, EVERY TIME, AND THAT IS NOT A BUG TO FIX BY RETRYING.**
      `Invoke-SalesforceLoad.ps1` exits non-zero on *any* Bulk failure, and this step's correct
      outcome includes ~20 failures — so `Invoke-FullMigrationLoad.ps1` records
      `PartnerAccount ... LOAD FAILED (exit 1)` and halts, even though the step did exactly what it
      should. Confirmed on 2026-08-13.

      **Verify it's the expected failure, then resume past it** — do not re-run PartnerAccount:
      ```powershell
      # 74 tagged + 2 pre-existing = 76 means the step succeeded as designed
      sf data query -q "SELECT COUNT() FROM LDGCRM_Partner_Account__c WHERE LDGCRM_External_ID__c != null" --target-org <alias>

      powershell scripts/data-migration/Invoke-FullMigrationLoad.ps1 -Environment Dev `
          -StartAtStep Contact -Confirmation "LOAD"
      ```
      To prove the 20 failures are the known cause rather than something new, check that each
      missing row's `LDGCRM_Account__r.LDGCRM_External_ID__c` is absent from the org's tagged
      Accounts. On 2026-08-13 that accounted for **20 of 20**.

      The same shape bites the factory reset (a partial Account delete is treated as fatal and
      withholds the bootstrap). Both are "fail loudly on an expected partial", which is the right
      default but makes the documented-correct path look broken to an operator following the runbook.
      Worth teaching the loader to distinguish an expected partial from a real failure before the
      Operations hand-off.
- [ ] ⚠️ **Verify `LDGCRM_Partner_Account_Owner__c` holds ACTIVE users only** — it now feeds
      Application's `OwnerId`, so a stale inactive owner propagates downstream.
- [ ] Spot-check the Market Segment before-save Flow fired (matches the parent Account's segment).

### 4c. Contact — ⚠️ the one load that disables another app's trigger

- [ ] Run `Build-ContactLoad.ps1`. Expect **~1,553 ready**, **~390 skipped for no Account**, and an
      Account-source split of roughly **965 Airtable column / 151 via Application / 399 via
      Opportunity / 38 inferred from a `.gov` domain**.
- [ ] ⚠️ **Contacts with no resolvable Account are now SKIPPED, not loaded** (new 2026-08-13). Review
      `logs/data-migration/Contact-no-account-*.csv`. Most trace to the unmatched-Account problem and
      return automatically once that is fixed.
- [ ] Spot-check `logs/data-migration/Contact-domain-inferred-account-*.csv` — the only inferred
      links in the pipeline. `-DisableDomainInference` turns them off; they are worth ~38 contacts.
- [ ] **Expect the name-source counts to swing hard, and expect that.** Pre-wipe the transform reports
      ~973 real names + ~970 "recovered from an existing Salesforce Contact". That second number is
      largely the transform **reading back its own previously-loaded placeholders** — 978 existing
      Contacts have an email address in `LastName`. Once Contact is wiped that source is gone, so
      expect a large shift toward email placeholders. Correct behaviour, not a regression.
- [ ] Load **with the trigger bypass** (needs explicit sign-off per load):
      ```powershell
      scripts\data-migration\Invoke-SalesforceLoad.ps1 -Environment Dev `
          -ObjectApiName "Contact" `
          -CsvFile "data\salesforce-loads\Contact-upsert.csv" `
          -DisableTriggerControl "Contact"
      ```
- [ ] ⚠️ **Verify no NEW junk FCIC Accounts — measure a delta, not a total.**
      `GSA_FCIC_ContactTrigger` creates an Account named after the person for every Contact inserted
      with a blank `AccountId`. **Dev already carries 4 such Accounts** from an 18-row Contact test
      batch on 2026-08-13; they hold no external ID, so no factory reset removes them and the count
      never returns to zero. Testing for zero would report a bypass failure on every run for ever.
      `Invoke-FullMigrationLoad.ps1` records the pre-run figure in
      `full-load-<ts>/fcic-junk-baseline.txt` and compares against it. By hand:
      ```
      sf data query -q "SELECT COUNT() FROM Account WHERE RecordType.DeveloperName = 'FCIC_Individual'" --target-org <alias>
      ```
      Expect it **unchanged from before the load** — 4 in Dev as of 2026-08-13, and a different
      number in any other environment, so measure it before you start rather than carrying Dev's
      figure forward.
- [ ] ⚠️ **Verify `TriggerControls__c.Contact.On__c` is back to `true`.** Restored in a `finally` block
      with a verifying re-query, proven under real failure — check anyway. Leaving it off silently
      breaks another team's app.
- [ ] Expect ~4 `DUPLICATES_DETECTED` rejections from the org-level duplicate rule. Known, documented.

### 4d. Opportunity

- [ ] Run `Build-OpportunityLoad.ps1`. Expect **742 ready**, 186 withheld (142 unreconciled Accounts,
      28 no Status, 16 no Account link), **476 owner-resolved / 266 fallback**.
- [ ] Load (upsert). Expect 742/742.
- [ ] Verify the `Login_gov` record type is set and its restricted picklists took — this object failed
      19/19 once on record-type picklist narrowing that `sf sobject describe` does not reveal.
- [ ] Verify Market Segment came from the before-save Flow, and revenue formulas computed (~467
      non-zero).

### 4e. `LDGCRM_application__c`

- [ ] Run `Build-ApplicationLoad.ps1`. Expect **688 ready**, 359 withheld, **511 owner-inherited /
      177 fallback**. Must run *after* Partner Account and Opportunity are loaded, or it withholds
      far more.
- [ ] Load (upsert). Expect 688/688.
- [ ] Verify Market Segment came from the Flow; no formula field was written.
### 4e-bis. `LDGCRM_application__c` — Broker App Parent SECOND PASS

- [ ] ⚠️ **Load `LDGCRM_application__c-broker-parent-upsert.csv`, and only AFTER 4e.** It is written
      automatically by `Build-ApplicationLoad.ps1` (no separate transform to run), but loading it
      before the main file fails every row: Bulk API 2.0 does not resolve an external-ID reference
      between two rows of the same batch, which is the entire reason this pass exists.
      ```powershell
      scripts\data-migration\Invoke-SalesforceLoad.ps1 -Environment Dev `
          -ObjectApiName "LDGCRM_application__c" `
          -CsvFile "data\salesforce-loads\LDGCRM_application__c-broker-parent-upsert.csv"
      ```
- [ ] Expect **63 links**, 7 withheld. Confirm 63/63 succeed — a `Foreign key external ID ... not
      found` failure here means it ran before the main load.
- [ ] Review `logs/data-migration/Application-broker-parent-skipped-*.csv`: 6 rows wait on an
      Application the Account data-quality issue withheld, and **1 is a self-reference**
      (`ACF Login.gov ACF-ockta-oidc` is its own Broker App Parent) which is dropped by design.
- [ ] Spot-check the hierarchy landed:
      ```
      sf data query -q "SELECT COUNT() FROM LDGCRM_application__c WHERE LDGCRM_Broker_App_Parent__c != null" --target-org <alias>
      ```

### 4f. `LDGCRM_Opportunity_Impediment__c`

- [ ] Requires Impediment **and** Opportunity loaded (two Master-Details).
- [ ] Expect **267/267**. Verify the placeholder Impediment named `None` was **excluded** (465 links,
      53% of the otherwise-loadable set). A count far above 267 means the exclusion regressed.
- [ ] Verify `LDGCRM_Blocked_Revenue__c` rolls up a genuine figure, not a multi-million placeholder.

### 4g. `LDGCRM_Application_Contact__c`

- [ ] Expect **1,880/1,880**, keyed on the composite external ID `<contact>|<application>`.
- [ ] ⚠️ The duplicate-check Flow throws a hard error, fires only on Create, and **misses intra-batch
      duplicates** — it is not a safety net. Any duplicate error here means the composite key
      regressed.

### 4i. Notes — LAST, after every other object

- [ ] Run `Build-NotesLoad.ps1 -Environment Dev`. Expect **~537 notes ready**, ~59 placeholder values
      skipped (`None`/`N/A`), ~200 waiting on a parent the Account issue withheld.
- [ ] Dry-run the loader first: `Invoke-NotesLoad.ps1 -Environment Dev -PlanOnly`.
- [ ] ⚠️ **The access preflight must pass.** The org has an unmanaged
      `ContentDocumentLinkTrigger` that rejects a link when the running user lacks **Edit** access to
      the parent record — and **its kill switch is inert**, so it cannot be turned off. The loader
      checks every parent and refuses to create anything if any fail; do not bypass it. Notes are
      created before they are linked, so a mid-run failure leaves orphaned notes with no external ID
      to find them by.
- [ ] Load: `Invoke-NotesLoad.ps1 -Environment Dev` (typed `LOAD` gate). It runs three steps —
      insert `ContentNote`, resolve `ContentDocumentId`s, insert `ContentDocumentLink`.
- [ ] **Keep the created-note-Id file** it prints (`logs/data-migration/Notes-created-noteids-*.csv`).
      `ContentNote` has no external ID, so that file is the only record of what the run created.
- [ ] Verify notes are attached and **visible in the UI** on a Partner Account and an Application,
      and that line breaks render (not literal `&lt;br&gt;`). Visibility depends on the layout
      carrying `RelatedContentNoteList` — Partner Account's was missing entirely and was deployed on
      2026-08-13. In a **different environment that change has to be deployed too**, or 144 notes
      load successfully and nobody can see them.
- [ ] Confirm sharing landed as `ShareType=I` / `Visibility=InternalUsers` — these notes carry
      internal partner commentary and the org has active Guest users.

### 4h. `OpportunityContactRole`

- [ ] **INSERT + read-then-diff, never upsert** — Salesforce forbids External ID fields on this object
      entirely; there is no upsert path and no metadata fix.
- [ ] Confirm Phase 2 left 0 rows, or the diff will under-insert.
- [ ] Expect **515 rows**, ~83 skipped pending an unresolved Opportunity/Contact.

---

## Phase 5 — Ownership verification (the point of this reload)

- [ ] Owner distribution matches the transform's predicted split:

      | Object | Expect own owner | Expect fallback (`peter.marks@gsa.gov`) |
      | --- | --- | --- |
      | Opportunity | 471 | 271 |
      | `LDGCRM_application__c` | 511 | 177 |
      | Contact | 1,553 | 0 |
      | `LDGCRM_Impediment__c` | 0 | 39 |
      | `LDGCRM_Application_Contact__c` | 0 | 1,880 |

      ```
      sf data query -q "SELECT OwnerId, Owner.Name, COUNT(Id) FROM Opportunity GROUP BY OwnerId, Owner.Name ORDER BY COUNT(Id) DESC" --target-org <alias> --result-format csv
      ```
- [ ] **No record owned by an inactive user** — expect 0 on Opportunity, Contact and
      `LDGCRM_application__c`:
      ```
      sf data query -q "SELECT COUNT() FROM Opportunity WHERE Owner.IsActive = false" --target-org <alias>
      ```
- [ ] Spot-check 3 Opportunities against their Airtable `Pod Opportunity Lead`.
- [ ] Spot-check 3 Applications against their Partner Account's owner.
- [ ] **Contact ownership will look like the fallback** unless D2 changed the rule — see "The Contact
      ownership problem". Do not log this as a failure without checking that section first.
- [ ] Confirm the unresolved-owner review CSVs exist and name the known people (`elizabeth.mays`,
      `tony.parrilla`, `gabriel.vorleto`, `sierra.stewart`):
      `logs/data-migration/Opportunity-unresolved-owner-*.csv`,
      `logs/data-migration/PartnerAccount-unmapped-owner-*.csv`
- [ ] **Sharing recalculation:** these objects use org-wide-default-restricted sharing with
      owner-based rules, so changing ~2,000 owners triggers a recalculation. Allow time before judging
      visibility, and spot-check that a record is visible to the expected group.

---

## Phase 6 — Side-effect sweep

Standing rule: **check for side effects, not just successes.** Every serious problem in this migration
was found this way, never in a success count.

- [ ] Account total unchanged by the Contact load (no junk FCIC Accounts).
- [ ] `TriggerControls__c.Contact.On__c` = `true`.
- [ ] `LDGCRM_Market_Segment__c` still 6 records.
- [ ] No unexpected new records on objects nobody loaded (Event, Task, Case, Lead).
- [ ] Pre-existing/untagged test records still at baseline counts.
- [ ] Review every `logs/data-migration/*-skipped-*.csv` and `*-review-*.csv` from this run and fold
      anything new into [`AIRTABLE-DATA-QUALITY-REQUESTS.md`](../data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md).
      Findings sitting unread in `logs/` are the failure mode that rule exists to prevent.

---

## Sign-off

| Item | Expected | Actual | ✓ |
| --- | --- | --- | --- |
| Environment / alias confirmed by banner | | | |
| Rahul coordination confirmed | yes | | |
| Loading user = intended fallback owner | | | |
| Phase 3 ownership gate | passed | | |
| Account | per D1 | | |
| `LDGCRM_Partner_Account__c` | ~76 | | |
| Contact | ~1,553 (account-less now skipped) | | |
| Fallback owner resolved | `peter.marks@gsa.gov` | | |
| Opportunity | 744 | | |
| `LDGCRM_application__c` | 691 | | |
| `LDGCRM_Opportunity_Impediment__c` | 268 | | |
| `LDGCRM_Application_Contact__c` | 1,884 | | |
| `OpportunityContactRole` | 515 | | |
| `LDGCRM_Market_Segment__c` | 6 | | |
| Junk FCIC Accounts created | 0 | | |
| `TriggerControls__c` restored | true | | |
| Records owned by inactive users | 0 | | |

---

## Known gaps this reload will NOT close

Expected, documented, not to be logged as failures:

- **~169 unmatched Airtable Accounts**, cascading into 142 Opportunities, 359 Applications, 849
  Application-Contact pairs and 20 Partner Accounts. Fixed at source in Airtable.
- **`LDGCRM_Broker_App_Parent__c`** — 7 of 70 links stay unloaded: 6 waiting on an Application the
  Account issue withheld, 1 a self-reference needing an Airtable fix. The other 63 load in step 4e-bis.
- **Meetings** (1,845 rows) — **deferred by decision 2026-08-13, and out of scope for this reload.**
  Rather than synthesize the start/end times Airtable never recorded, the approach is now to stand up
  **Einstein Activity Capture**, let real Google Calendar events sync, and fuzzy-match Airtable's
  meetings onto them. That depends on an org configuration change outside this repo and an unresolved
  spike (do EAC events exist as standard `Event` records at all?). See `BACKLOG.md` §2.
- **Notes** — **built 2026-08-13** (`Build-NotesLoad.ps1` + `Invoke-NotesLoad.ps1`), but runs *after*
  everything else by definition, so it is a step at the end of this reload rather than a known gap.
  537 notes ready; 200 wait on parents the Account data-quality issue withheld.
- **Contact ownership meaningfulness** — see D2.
