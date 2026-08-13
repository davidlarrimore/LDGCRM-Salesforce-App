# Full reload QA checklist

Operational runbook for a complete wipe-and-reload, written for whoever actually runs it. The trigger
for this one is the **record-ownership work built 2026-08-13** — ownership is set by the transforms at
load time, so it cannot be verified without reloading.

Work top to bottom. **Phase 3 is a hard gate**: do not start the full load until the test batch
passes, because the ownership design rests on one Bulk API behaviour this pipeline has never
exercised.

Related: [`README.md`](README.md) (pipeline + load order), [`TRANSFORMATION-RULES.md`](TRANSFORMATION-RULES.md)
(field rules + the ownership section), [`BACKLOG.md`](BACKLOG.md), and the `sfdx-sandbox-ops` skill.

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
production-like as possible. `Build-ProdAccountSeed.ps1` parses `data/peo-prod-accounts-2026-07-16.xls`
(an HTML table saved with an `.xls` extension — a Salesforce report export, not binary Excel) and
inserts every production Account name the target org doesn't already have.

Know what the Account wipe actually does, because it is not intuitive: `cleanup-gsa-peo.ps1` only
deletes rows **where `LDGCRM_External_ID__c` is populated**. Untagged rows — including previously
seeded production Account names — survive, and the seed then re-inserts only what's missing by name.

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

Worth confirming with whoever owns the production org what the `SNA ` prefix denotes — four owners
carry it (`SNA MSadi`, `SNA YMekonnen`, `SNA NALohning`, `SNA JTScholz`), which reads like a class of
account rather than four unrelated individuals.

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

`scripts/cleanup/cleanup-gsa-peo.ps1` is **interactive and destructive**. It exports the record IDs it
is about to delete first (audit trail), then requires a typed `HARD DELETE` confirmation. Against
production it additionally requires typing the org alias (`Assert-LdgcrmProductionConsent`).

- [ ] **Run it from a real new process** or the typed prompt won't appear:
      `powershell -File scripts\cleanup\cleanup-gsa-peo.ps1 -Environment Dev`
      The `&` call operator hits "NonInteractive mode" in some harnesses.
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
- [ ] Confirm untagged/pre-existing records survived (compare against baseline).
- [ ] Keep the exported ID CSVs in `logs/cleanup/` — the only record of what was deleted.

---

## Phase 3 — 🚦 Ownership test batch (HARD GATE)

**Do not proceed until this passes.** The ownership design rests on a behaviour never exercised
against this org: a **partially-populated `OwnerId` column**, resolved rows carrying a User Id and
fallback rows blank.

The intent: Bulk API 2.0 reads empty as "not supplied", so an insert lands on the loading user and a
re-run leaves a manually-reassigned owner alone. That is documented behaviour, not proof. A 19-row
Opportunity batch already failed 19/19 once on an assumption that looked equally safe.

- [ ] Build a **15–25 row Opportunity batch containing both cases** — at least 5 rows with a resolved
      `OwnerId`, at least 5 blank. A single-kind batch proves nothing.
- [ ] Load it. Confirm **0 failures**, specifically no `INACTIVE_OWNER_OR_USER` and no null-owner
      rejection.
- [ ] **Verify blank rows landed on the loading user** — not nobody, not an error.
- [ ] **Verify resolved rows landed on the right person** — spot-check 2–3 against Airtable's
      `Pod Opportunity Lead`.
- [ ] **Test the non-revert claim** — the other half of the design. Manually reassign one loaded
      record to a different user, re-run the same load, confirm the owner is **unchanged**. If it
      reverts, every re-run of this pipeline will stomp real reassignments.

**If the gate fails:** the contingency is writing the fallback owner's Id explicitly instead of a
blank — fixes the insert path, sacrifices non-revert. A real tradeoff. Stop and discuss.

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
  -> LDGCRM_Opportunity_Impediment__c
  -> LDGCRM_Application_Contact__c
  -> OpportunityContactRole        (INSERT + read-then-diff, never upsert)
```

### 4a. Account

- [ ] `Build-ProdAccountSeed.ps1` → `Invoke-SalesforceLoad.ps1 -Operation Insert`
- [ ] `Build-AccountReconciliation.ps1` → `Invoke-SalesforceLoad.ps1 -Operation Update` (Id-keyed,
      **not** upsert)
- [ ] Expect ~587 matched, ~169 unmatched. The unmatched are the known Airtable duplicate-row problem
      — fixed at source, not routed around.

### 4b. `LDGCRM_Partner_Account__c`

- [ ] Run `Build-PartnerAccountLoad.ps1`. Expect **94 ready, 5 skipped, 5 of 7 owner emails resolved**.
- [ ] Load (upsert). Expect ~74 succeed, ~20 fail — all tracing to parent Accounts among the 169
      unmatched. Same failures as previous runs = correct, not a regression.
- [ ] ⚠️ **Verify `LDGCRM_Partner_Account_Owner__c` holds ACTIVE users only** — it now feeds
      Application's `OwnerId`, so a stale inactive owner propagates downstream.
- [ ] Spot-check the Market Segment before-save Flow fired (matches the parent Account's segment).

### 4c. Contact — ⚠️ the one load that disables another app's trigger

- [ ] Run `Build-ContactLoad.ps1`.
- [ ] **Expect the name-source counts to swing hard, and expect that.** Pre-wipe the transform reports
      ~973 real names + ~970 "recovered from an existing Salesforce Contact". That second number is
      largely the transform **reading back its own previously-loaded placeholders** — 978 existing
      Contacts have an email address in `LastName`. Once Contact is wiped that source is gone, so
      expect roughly **481 real / ~8 recovered / ~998 email placeholders / 45 skipped**, matching the
      original load. Correct behaviour, not a regression.
- [ ] Load **with the trigger bypass** (needs explicit sign-off per load):
      ```powershell
      scripts\data-migration\Invoke-SalesforceLoad.ps1 -Environment Dev `
          -ObjectApiName "Contact" `
          -CsvFile "data\salesforce-loads\Contact-upsert.csv" `
          -DisableTriggerControl "Contact"
      ```
- [ ] ⚠️ **Verify zero junk FCIC Accounts.** `GSA_FCIC_ContactTrigger` creates an Account named after
      the person for every Contact inserted with a blank `AccountId` — and ~827 Contacts have no
      resolvable Account. Account total must be unchanged:
      ```
      sf data query -q "SELECT COUNT() FROM Account WHERE RecordType.DeveloperName = 'FCIC_Individual'" --target-org <alias>
      ```
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
- [ ] ⚠️ `LDGCRM_Broker_App_Parent__c` is **not** loaded — self-referential lookup needing a second
      pass, **not yet built** (~68 rows). Expected gap, not a failure.

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

### 4h. `OpportunityContactRole`

- [ ] **INSERT + read-then-diff, never upsert** — Salesforce forbids External ID fields on this object
      entirely; there is no upsert path and no metadata fix.
- [ ] Confirm Phase 2 left 0 rows, or the diff will under-insert.
- [ ] Expect **515 rows**, ~83 skipped pending an unresolved Opportunity/Contact.

---

## Phase 5 — Ownership verification (the point of this reload)

- [ ] Owner distribution matches the transform's predicted split:

      | Object | Expect resolved | Expect fallback |
      | --- | --- | --- |
      | Opportunity | 476 | 266 |
      | `LDGCRM_application__c` | 511 | 177 |
      | Contact | 1,116 | 827 |

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
      anything new into [`AIRTABLE-DATA-QUALITY-REQUESTS.md`](AIRTABLE-DATA-QUALITY-REQUESTS.md).
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
| Contact | ~1,939 | | |
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
- **`LDGCRM_Broker_App_Parent__c`** (~68 rows) — second pass not built.
- **Meetings** (1,845 rows) — blocked on three decisions. See `BACKLOG.md` §2.
- **Notes chunk** — must be built last, not started.
- **Contact ownership meaningfulness** — see D2.
