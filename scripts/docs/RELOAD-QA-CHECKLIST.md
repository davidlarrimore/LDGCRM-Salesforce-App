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

Related: **ARCHITECTURE.md** (pipeline + load order), **TRANSFORMATION-RULES.md**
(field rules + the ownership section), **BACKLOG.md**, and the `sfdx-sandbox-ops` skill.

---

## ⚠️ Before anything: `gsa-peo` now means PRODUCTION

The org registry (`powershell-scripts/Common.Orgs.ps1`, 2026-08-13) changed what aliases mean. Until then
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
Account **names and the parent hierarchy** from whatever export sits in `data/prod-accounts/`. Any of
`.xls`, `.xlsx` or `.csv` — the format is detected by reading the file (today's is an HTML table
saved with an `.xls` extension, a Salesforce report export, not binary Excel), the filename does not
matter, and the newest file wins.

> ### ⚠️ In a FULL sandbox, skip every Account rebuild step in this checklist
>
> A Full sandbox is a copy of production, so its Accounts **are** the real records this migration
> reconciles onto. Rebuilding them from a stale export would invalidate the rehearsal the Full
> sandbox exists to provide.
>
> This is enforced, not left to the operator: the factory reset drops `Account` from its delete list
> and says so on screen, the bootstrap is not offered, `-BootstrapAccounts` is rejected, and
> `Invoke-AccountBootstrap.ps1` will not accept `-Environment Full` at all. **Every other object
> still resets normally** — they carry `LDGCRM_External_ID__c` because this migration created them.
>
> So when running this checklist against `Full`: expect the Account row counts to be *unchanged* by
> the wipe, and treat phase 4a (Account) as a reconciliation-only step. Everything else is the same.

Know what the Account wipe actually does in Dev/QA, because it is not intuitive: cleanup only deletes
rows **where `LDGCRM_External_ID__c` is populated**, and bootstrapped Accounts carry none.
Bootstrapped Accounts therefore survive a later cleanup, which is exactly what makes the bootstrap
safely repeatable — it inserts only what's missing, by name.

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
- [ ] ⚠️ **Confirm all nine LDGCRM Flows are ACTIVE in the target org.** The orchestrator now checks
      this and blocks the run — look for `LDGCRM Flows  9 of 9 active and current` in the pre-flight
      output. **Do not wave this through.** QA was loaded on 2026-08-14 with 8,740 records and zero
      unexpected failures while all nine were inactive: nothing failed, nothing was withheld, and
      every object count matched Dev. Market Segment was blank on all 92 Partner Accounts, all 842
      Opportunities and all 1,026 Applications, because the three before-save Flows that derive it
      never ran. Flow activation changes field *contents*, not row counts, so the Dev-vs-QA count
      comparison in this checklist passed too.

      If any are off, either switch them on in Setup or re-run with `-ActivateFlows` (sandbox only —
      rejected for `-Environment Prod`). If any are **absent**, that needs a change set; the pipeline
      does not deploy metadata.

      **A newly refreshed or newly provisioned sandbox is the likely case for this**, so treat it as
      mandatory rather than a formality. Flows arriving via change set are not necessarily active on
      arrival — all nine landed in QA as Draft.
- [ ] **Confirm `LDGCRM_Screen_Flow_Developer_Data_Delete_Flow` is NOT in the target org.** It
      bulk-deletes migrated records and is Dev-only. Pre-flight fails if it is found in QA/Full/Prod.
      If it fires, find out how it got there — do not just deactivate it.
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
- [ ] **Verify every picklist target field: the right field, and every value it must accept.**
      Two *different* failure modes, both of which have actually happened here. Run this per
      environment — a field can be correct in Dev and wrong in QA, which is exactly the state
      `priority_type__c` / `LDGCRM_Level_of_Priority__c` was found in on 2026-08-13.

      1. **Right field?** Confirm the API name starts with `LDGCRM_`. This sandbox is shared with
         TTS OTCRM and FCIC, which label their fields in the same business vocabulary, so a
         Salesforce field whose **label** matches the Airtable column name is *not* evidence it is
         ours. Opportunity has both `priority_type__c` (labelled "Priority Type", owned by TTS
         OTCRM) and `LDGCRM_Level_of_Priority__c` (ours) — the un-prefixed one is the better label
         match and the wrong answer. **If the best label match is un-prefixed, stop and ask the
         field's owner.** Writing another app's field is worse than loading nothing.
      2. **Every value present?** For each restricted picklist being loaded, diff the distinct
         Airtable values against what the **record type** exposes — not what the field defines, and
         not `sf sobject describe`, neither of which shows the record-type narrowing that the Bulk
         API enforces:
         ```
         sf project retrieve start -m "CustomObject:<Object>" --target-org <alias> --target-metadata-dir <scratch> --unzip
         ```
         then read `recordTypes/<RecordType>.recordType-meta.xml` (values are URL-encoded:
         `,`→`%2C`, `/`→`%2F`, `&`→`%26`, `'`→`%27`). Any Airtable value with no match is a row that
         will fail with `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST`.
      - ⚠️ **Retrieve `CustomObject:<Object>`, never `RecordType:<Object>.<RT>` on its own.** The
        targeted RecordType retrieve is **lossy** — it returned only 4 of 33 `<picklistValues>`
        blocks and would have silently deleted the other 29 from the repo.
      - ⚠️ **Missing values are fixed by change set, not from here.** Adding a picklist value is a
        *promotion* and goes through outbound/inbound change sets. CLI deploys from this repo are
        limited to **deleting** corrupted or incorrect metadata. Note QA can trail Dev by a change
        set, so confirm against the environment you are actually loading.
      - ℹ️ **To check what a change set actually carries, retrieve it by name** — a change set's Name
        works as an unmanaged package name, and this is the only way to see its contents (change sets
        have no query API). Read-only, and `--target-metadata-dir` keeps it out of the source tree:
        ```
        cd sfdx
        sf project retrieve start --package-name "LDGCRM_Sprint_1_12" --target-org <alias> --target-metadata-dir <scratch> --unzip
        ```
        Components land in metadata format (`objects/Opportunity.object`, one file per object with
        its fields and record types inline) — **not** the `force-app` source layout. Expect the record
        type here to carry **fewer** `<picklistValues>` blocks than a full object retrieve (13 vs 33
        for `Login_gov`): a change set only carries the fields it actually includes, so the other
        apps' picklists are absent. That is correct, not lossy — unlike the targeted `RecordType:`
        retrieve warned about above.
      - ✅ **Checked 2026-08-13 — `LDGCRM_Sprint_1_12` carries both identity-platform fields
        completely.** `LDGCRM_Existing_Identity_Platforms__c` and
        `LDGCRM_Alternative_Identity_Platforms__c` are both present (`MultiselectPicklist`,
        `restricted=true`, 25 values each) **and** the `Login_gov` record type in the same change set
        assigns all 25 values to each. No promotion gap — these two fields do not need change-set work
        before a QA/Full/Prod load. **This is the state to re-verify, not to assume**, if the change
        set is regenerated.
      - ⚠️ **The two identity-platform config fixes below are NOT in any change set yet.** The change
        set carries `Ping/Foregerock` (the ForgeRock misspelling) and has **no `CLEAR` value at all**.
        Both fixes are picklist-value changes, so both are change-set promotions. If they land,
        `$IdentityPlatformMap` in `Build-OpportunityLoad.ps1` must change in the same cut — see §4d.
- [ ] ⚠️ **Re-pull Airtable — this is no longer optional for Opportunity.** `Get-AirtableExport.ps1`
      **overwrites** `data/airtable-exports/` in place, and a fresh pull shifts every count below, so
      this used to be a judgement call. It isn't any more: Airtable converted the two
      identity-platform columns from linked records to multi-selects (see the
      **AIRTABLE-DATA-QUALITY-REQUESTS.md**), and
      **`Build-OpportunityLoad.ps1` now hard-fails against any export predating that conversion**
      rather than silently dropping 453 values:
      ```
      453 identity-platform values are still Airtable rec... IDs, so this export predates the
      linked-record -> multi-select conversion ... Re-pull before building
      ```
      The 2026-08-12 export **predates it**. Re-pull, then treat every count in this checklist as
      needing re-baselining against the new export rather than as a pass/fail target:
      `.\powershell-scripts\Get-AirtableExport.ps1`
      This is a deliberate hard failure, not a bug to work around — the whole point is that a stale
      export can no longer produce a quietly incomplete load.
      - ⚠️ **The re-pull moves more than the identity columns, so re-baseline before judging any
        number.** Measured 2026-08-13: Airtable is down to **904 Opportunity rows from the export's
        928 — 24 deleted** since 2026-08-12, on top of whatever changed in the other ~70 columns.
        Every Opportunity figure in §4d was derived from the 928-row export, so **"742 ready" will not
        reproduce, and a lower number is not evidence of a regression.** Record the new baseline as
        you go, and diff *transform behaviour* (skip reasons, dropped-tag counts) rather than absolute
        totals. Deleted rows do **not** disappear from Salesforce on their own: an upsert never
        deletes, so anything already loaded and since removed from Airtable stays until someone
        removes it deliberately — out of scope here, but do not mistake it for a load failure.
      - **The pull now covers TEN tables, not nine** — `Issuer Strings` was added 2026-08-13 (PR #1).
        It is the only source of the partner-portal Team Name / Team UUID that §4e puts on the
        Application, so an export missing it makes `Build-ApplicationLoad.ps1` fail with a clear
        "no Airtable export found for 'Issuer Strings'". Row counts from the 2026-08-13 pull, for
        reference when re-baselining: Accounts 747, Partner Accounts 99, Applications 1,056,
        Contacts 1,535, Opportunities 904, Opportunity Contacts 520, Impediments 40, Market Segments
        7, Meetings 1,848, **Issuer Strings 901**.
- [ ] **`Full`/`Prod` only — read the OWNER ROSTER block in pre-flight.** It compares
      `reference/salesforce-user-roster.csv` against the target org and reports anyone the business
      marked `ExpectedInSalesforce=yes` who has **no active Salesforce User**. Their records still
      load, onto the fallback owner — **this check changes no behaviour and never blocks.**

      It exists because the fallback is correct for someone who has *left* and wrong for someone who
      is current staff but was never provisioned, and **the two are indistinguishable in the run
      output.** The roster is where the business states which is which.

      Also reports owners present in Airtable but absent from the roster, so the file cannot silently
      go stale. **Deliberately skipped in Dev/QA** — there is no expectation the Partnerships team
      have logins in a developer sandbox (only 12 of 17 resolve in Dev), so running it there would
      print warnings on every run until nobody read them.
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

`powershell-scripts\Invoke-SandboxFactoryReset.ps1` is **interactive and destructive**. It exports the record IDs
it is about to delete first (audit trail), then requires a typed `HARD DELETE` confirmation. Against
production it additionally requires typing the org alias (`Assert-LdgcrmProductionConsent`).

- [ ] **Either** run it from a real console so the prompt appears:
      `.\powershell-scripts\Invoke-SandboxFactoryReset.ps1 -Environment Dev -BootstrapAccounts`
      **or** approve it non-interactively by passing the same token the prompt asks for:
      ```powershell
      .\powershell-scripts\Invoke-SandboxFactoryReset.ps1 `
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
      `.\powershell-scripts\Invoke-AccountBootstrap.ps1 -Environment Dev -Confirmation "BOOTSTRAP"`
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
Market Segment (STEP 1 - loaded by the pipeline as of 2026-08-14)
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
      .\powershell-scripts\Invoke-AccountBootstrap.ps1 -Environment Dev -PlanOnly
      .\powershell-scripts\Invoke-AccountBootstrap.ps1 -Environment Dev
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
- [ ] 🆕 **Review the AMBIGUOUS-HIERARCHY REPAIR plan the bootstrap now prints** (added 2026-08-14).
      Several agencies run an office with the same generic name — production has four
      `Office of the Inspector General` and three `Office of the Director`. The bootstrap identifies
      Accounts by name, so once two exist it cannot tell them apart, refuses to parent either, and
      will not insert the ones the org is missing. They carry no external ID, so **no factory reset
      clears them and every later run hits the same wall.**

      **The plan prints whether or not you intend to act on it. Nothing is removed without
      `-RepairAmbiguousHierarchy`.** Measured 2026-08-14 in Dev: **6 office names, 11 records to
      remove, 15 to recreate** (the org gains the 4 it was short).
      ```powershell
      # preview only - always do this first
      .\powershell-scripts\Invoke-AccountBootstrap.ps1 -Environment Dev -PlanOnly
      # apply it
      .\powershell-scripts\Invoke-AccountBootstrap.ps1 -Environment Dev -RepairAmbiguousHierarchy
      ```
      - ⚠️ **Read the `NOT repaired` block, it is the important half.** A name is only rebuilt when
        **every** record under it is provably inert — no external ID, child Account, Opportunity,
        Contact, Partner Account, Note or Activity. On 2026-08-14 that check **blocked 8 records**,
        including `AmeriCorps` (Opportunity + Contact + Partner Account) and
        `U.S. Army Futures Command`. Those stay ambiguous, by design. **A run where nothing is
        blocked deserves a second look, not relief.**
      - The delete is an ordinary delete, not a hard delete — the records sit in the Recycle Bin, and
        they are rebuilt moments later in the same run.
      - It verifies against the org afterwards and **stops the run** if any record survived, rather
        than rebuilding on top of the ambiguity it was meant to clear.
- [ ] `Build-AccountReconciliation.ps1` → `Invoke-SalesforceLoad.ps1 -Operation Update` (Id-keyed,
      **not** upsert)
- [ ] Expect ~585 matched, ~154 unmatched, **8 ambiguous**. The unmatched are mostly agencies with no
      Salesforce Account at all — see AIRTABLE-DATA-QUALITY-REQUESTS.md, which no longer frames this
      as an Airtable duplicate problem.
- [ ] 🆕 **Check the `...of which resolved by parent agency` line** (added 2026-08-14). Reconciliation
      now tells same-named Accounts apart using Airtable's `Parent` column against Salesforce's
      `Account.ParentId`, instead of giving up at "2 candidates share this name".
      - **It only works if the target org's Account hierarchy is populated**, which is what the repair
        step above is for. If the count is **0** and there are still ambiguous rows, the script says
        so explicitly and the ambiguous CSV will show `(no parent set)` against every candidate —
        that means the hierarchy is missing, not that the matching is broken.
      - ⚠️ **Expect some rows to come back as `DUPLICATE AIRTABLE ROW`.** Airtable holds three rows
        for `Office of Communications` all naming OPM as the parent, and two for
        `Office of the Director`. They resolve to the *same* Salesforce Account, so only the first
        claims it and the rest are reported. **This is a guard, not a failure** — without it they
        would each overwrite the previous row's external ID and the load would report full success.

### 4b. `LDGCRM_Partner_Account__c`

- [ ] Run `Build-PartnerAccountLoad.ps1`. Expect **99 ready, 0 skipped** (2026-08-14; was 94 ready /
      5 skipped — the Airtable owners linked the last 5 rows to an Account, so nothing is skipped here
      any more).
- [ ] Load (upsert). Expect **97 succeed, 2 fail** — both tracing to parent Accounts among the 154
      unmatched. Same failures as previous runs = correct, not a regression.
- [ ] ✅ **FIXED 2026-08-13, confirmed 2026-08-14 — the orchestrator no longer stops here.** It used to halt every time:
      `Invoke-SalesforceLoad.ps1` exited non-zero on *any* Bulk failure, and this step's correct
      outcome includes some failures, so a correct run was indistinguishable from a broken one and
      cost a manual diagnosis and resume. It now **classifies** failures against a per-object list of
      known causes (`ExpectedFailures` in the orchestrator's step table) and reports
      `PartnerAccount ... PARTIAL (expected failures)` while carrying on.

      Expect to see a `FAILURE CLASSIFICATION` block showing all failures matched and the count
      within the allowance — `max(20 rows, 5% of the batch)`. It still halts if **any** failure
      doesn't match a known cause, or if the count exceeds the allowance.

      *The manual verification below is no longer required, but is kept because it is still the way
      to check the failures are the ones you think they are:*
      ```powershell
      # 74 tagged + 2 pre-existing = 76 means the step succeeded as designed
      sf data query -q "SELECT COUNT() FROM LDGCRM_Partner_Account__c WHERE LDGCRM_External_ID__c != null" --target-org <alias>

      .\powershell-scripts\Invoke-FullMigrationLoad.ps1 -Environment Dev `
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
- [ ] **Market Segment loaded and resolvable.** It is now deleted by the reset and reloaded as step 1:
      ```
      sf data query -q "SELECT COUNT() FROM LDGCRM_Market_Segment__c WHERE LDGCRM_External_ID__c != null" --target-org <alias>
      ```
      Expect **5**. A count of 0 means every downstream record will carry a blank Market Segment and
      **nothing will error** — the reconciliation resolves a segment through its external ID, not its
      Name. Pre-flight reports this as "N present, M resolvable"; only M matters.
- [ ] Spot-check the Market Segment before-save Flow fired (matches the parent Account's segment).

### 4c. Contact — ⚠️ the one load that disables another app's trigger

- [ ] Run `Build-ContactLoad.ps1`. Expect **~1,882 ready**, **~54 skipped for no Account** (2026-08-13 reload; was ~1,553 / ~390), and an
      Account-source split of roughly **965 Airtable column / 151 via Application / 399 via
      Opportunity / 38 inferred from a `.gov` domain**.
- [ ] ⚠️ **Contacts with no resolvable Account are now SKIPPED, not loaded** (new 2026-08-13). Review
      `logs/data-migration/Contact-no-account-*.csv`. Most trace to the unmatched-Account problem and
      return automatically once that is fixed.
- [ ] Spot-check `logs/data-migration/Contact-domain-inferred-account-*.csv` — the only inferred
      links in the pipeline. `-DisableDomainInference` turns them off; they are worth ~38 contacts.
- [ ] **Check the name-source split.** Expect roughly:

      | Name source | Expect |
      | --- | --- |
      | real Name from Airtable | ~973 |
      | read back from a Contact already in the org | **0 pre-wipe, 0 post-wipe** — see below |
      | **DERIVED from the email** | **~597** |
      | email local part only (no split possible) | ~317 |
      | role/shared mailbox (not a person) | ~56 |
      | skipped — no name AND no email | 45 |

- [ ] ⚠️ **"read back from a Contact already in the org" must be 0, or near it — a large number here
      is a REGRESSION, not a success.** It counts names taken from Contacts already in the target
      org. Any Contact this pipeline loaded previously carries an email address in `LastName`, so a
      high number means the transform is reading back **its own placeholders** and reporting them as
      recovered names — and because that step matches *before* the email derivation, it silently
      suppresses it.

      This has now bitten twice. It is what made the old summary claim "970 names recovered from
      Salesforce" when nothing had been recovered, and while building the derivation it reduced 597
      derived names to 172. The guard skips existing Contacts whose `LastName` contains `@`; the
      transform prints how many it ignored:

      ```
      1454 existing Contacts with an email in peodv8dvn; 729 carry a real name.
        718 ignored - their LastName is an email placeholder written by an earlier run.
      ```

      A genuinely non-zero figure is legitimate **only** in an org holding real Contacts this
      migration did not create — which is the production case, and the reason the step exists.

- [ ] ⚠️ **Verify the per-domain name order was learned, and from Airtable only.** The transform
      prints it:

      ```
      Learning each domain's email name order from Airtable's authored names...
      483 known name/email pairs; 30 domain(s) have enough evidence to fix an order.
        last.first domains: dol.gov, pbgc.gov
      ```

      **`dol.gov` and `pbgc.gov` must appear.** If they don't, `batchelet.doug@dol.gov` becomes
      "Batchelet Doug" and ~44 contacts load with reversed names. If the pair count is far above
      ~490, the learner is being fed Salesforce Contacts as well as Airtable ones — that is circular
      (derived names confirming their own order) and must be fixed, not accepted.

- [ ] Spot-check derived names in `logs/data-migration/Contact-name-review-*.csv` (rows whose
      `Source` starts `Derived from email`). Verify at least one of each rule:

      | Address | Should become |
      | --- | --- |
      | `batchelet.doug@dol.gov` | Doug Batchelet — *order reversed by domain* |
      | `christopher.m.tork.ctr@army.mil` | Christopher Tork — *DoD suffix + middle initial* |
      | `matt_hunnell@…` | Matt Hunnell — *underscore* |
      | `smitha_singi-reddy@…` | Smitha **Singi-Reddy** — *hyphen preserved, not split* |
      | `jwoolf@gsa.gov` | LastName `jwoolf`, **no forename invented** |

- [ ] Review `logs/data-migration/Contact-role-mailbox-*.csv` (~56 rows). These are inboxes, not
      people — `support@`, `tracs-helpdesk@`, `fmcsa_api@`. None should have a `FirstName`. Whether
      they belong in the CRM at all is an open question for the data owners; they are referenced by
      Opportunity Contact Roles and Application junctions, so skipping them would cost those links.
- [ ] Confirm **no contact named after a role** reached the org — a "Tracs Helpdesk" or "Fmcsa Api"
      means the role-mailbox pattern missed a case and the splitter fabricated a person:
      ```
      sf data query -q "SELECT Id, FirstName, LastName, Email FROM Contact WHERE LDGCRM_External_ID__c != null AND (LastName LIKE '%helpdesk%' OR LastName LIKE '%support%' OR LastName LIKE '%Api%' OR FirstName LIKE '%Help%')" --target-org <alias> --result-format csv
      ```
- [ ] If a derived name ever lands on the **wrong person**, `-DisableEmailNameDerivation` reverts to
      the old address-as-`LastName` behaviour without a code change.
- [ ] Load **with the trigger bypass** (needs explicit sign-off per load):
      ```powershell
      scripts\powershell-scripts\Invoke-SalesforceLoad.ps1 -Environment Dev `
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
      `<run>/fcic-junk-baseline.txt` and compares against it. By hand:
      ```
      sf data query -q "SELECT COUNT() FROM Account WHERE RecordType.DeveloperName = 'FCIC_Individual'" --target-org <alias>
      ```
      Expect it **unchanged from before the load** — 4 in Dev as of 2026-08-13, and a different
      number in any other environment, so measure it before you start rather than carrying Dev's
      figure forward.
- [ ] ⚠️ **Verify `TriggerControls__c.Contact.On__c` is back to `true`.** Restored in a `finally` block
      with a verifying re-query, proven under real failure — check anyway. Leaving it off silently
      breaks another team's app.
- [ ] ✅ **FIXED IN DEV 2026-08-15 — but the fix has NOT been promoted, so expect 167
      `DUPLICATES_DETECTED` rejections and a halt in any org that has not received it yet.**

      `OTCRM_Contact_Matching_Rule` matched on **first + last name only**, so 178 different mailboxes
      sharing the name `Help Desk` collided. It now also requires **Email**, all three `Exact` and
      `NullNotAllowed`. Re-verified in Dev: **1,888 submitted, 1,888 loaded, 0 failures** (was 1,721).
      **QA, Full and Prod still run the name-only rule** — see CR-6. Until promoted, that org halts.

      ⚠️ **The rule is owned by TTS OTCRM, not by this app**, and it is filtered to `RecordType =
      Federal`, which is what migrated partner contacts get. Confirm it is present and correct in the
      target org rather than assuming Dev's state applies.

      On 2026-08-14 someone bulk-filled the Airtable `Name` field from the `Roles` field: all 178 rows
      whose Role is `Help Desk POC` are now named `Help Desk`. They are 178 different mailboxes across
      78 domains and 41 agencies, so the org rule (First + Last name) accepts one and rejects the rest.
      **139 of the 140 rejected addresses appear nowhere else in Salesforce** — this is lost data, not
      helpful duplicate-suppression. See AIRTABLE-DATA-QUALITY-REQUESTS.md item 3.

      **Once it is fixed, expect the baseline ~10**, of which **6 are correct and permanent**: the same
      person under two email addresses, whose second copy the rule rightly rejects.
      To finish a run while the data is still broken, resume with
      `-StartAtStep Opportunity` — everything downstream loads clean, just short of those contacts.

### 4d. Opportunity

- [ ] Run `Build-OpportunityLoad.ps1`. Expect **842 ready**, 62 withheld — **all 62 unreconciled Accounts** (2026-08-13 reload; was 742 ready / 186 withheld across 142 unreconciled + 28 no Status + 16 no Account link, the last two now fixed at source),
      28 no Status, 16 no Account link), **476 owner-resolved / 266 fallback**.
- [ ] Load (upsert). Expect 742/742.
- [ ] Verify the `Login_gov` record type is set and its restricted picklists took — this object failed
      19/19 once on record-type picklist narrowing that `sf sobject describe` does not reveal.
- [ ] Verify Market Segment came from the before-save Flow, and revenue formulas computed (~467
      non-zero).
- [ ] ✅ **Identity platforms now load** — newly unblocked, so this is the first reload that carries
      them and the counts below are the *pre-load transform* figures, not yet proven post-load.
      Both fields and their full 25-value `Login_gov` assignments are confirmed present in
      `LDGCRM_Sprint_1_12` (checked 2026-08-13, see §1), so **no change set is needed to enable them**
      — but re-verify in the environment you are loading, which may trail Dev by a change set.
      Against the Airtable state of 2026-08-13: **259 Opportunities with Existing Identity Platforms,
      175 with Alternative** (176 have a value; one row's only tag is `CLEAR`, which drops, leaving it
      blank). Both are restricted multipicklists, so a bad tag fails the **whole row** — if this
      object starts failing rows it did not fail before, suspect these two fields first.
- [ ] ℹ️ **Expect exactly 2 dropped identity-platform tags, both `CLEAR`, in
      `Opportunity-value-review-<ts>.csv`.** Salesforce has no `CLEAR` value. Not a bug and not an
      Airtable problem — it needs adding to both fields **and** the `Login_gov` record type, by change
      set. **More than 2 drops means Airtable added a vendor** the map doesn't know: read the review
      CSV, add it to `$IdentityPlatformMap`, and confirm the Salesforce value exists before re-running.
      A **hard failure** naming `rec...` IDs instead means the export is stale — re-pull, see §1.
- [ ] ℹ️ Airtable's `Ping / Forgerock` lands as **`Ping/Foregerock`** — the Salesforce value misspells
      ForgeRock. Expected (6 rows), mapped deliberately. Once the Salesforce value is corrected to
      `Ping/Forgerock`, update `$IdentityPlatformMap` in the same change or those 6 rows start failing.
- [ ] ✅ **Level of Priority NOW LOADS (unblocked 2026-08-14).** It was empty on every Opportunity
      until the field's values were fixed. Expect **371 of the 842** to carry one:
      `Strategic` 249, `High Volume` 70, `IdV Upgrade` 38, `Leadership Escalation` 14.
      ```
      sf data query -q "SELECT LDGCRM_Level_of_Priority__c, COUNT(Id) FROM Opportunity WHERE LDGCRM_External_ID__c != null GROUP BY LDGCRM_Level_of_Priority__c" --target-org <alias> --result-format csv
      ```
      - ⚠️ **This needs the metadata in the target org first.** `LDGCRM_Level_of_Priority__c` is
        `restricted=true`, so a value it does not define **fails the whole row**. Dev was fixed on
        2026-08-14; **QA/Full/Prod need it by change set** — the four values on the field *and*
        assigned to the `Login_gov` record type. A value the record type omits is rejected even when
        the field defines it.
      - ℹ️ **Airtable's `N/A` maps to BLANK deliberately** (157 rows). It means the field does not
        apply; a priority literally called "N/A" would read as data while meaning its absence.
        Blank rows in this field are therefore expected, not a gap.
      - ℹ️ `Low`/`Medium`/`High` were **retired** (deactivated) on 2026-08-14 — 0 records used them.
        A metadata deploy cannot delete a picklist value, so they remain in the value set as
        `isActive=false` until someone clicks **Del** in Setup.
      - ⚠️ **A new Airtable value is DROPPED and reported, not passed through** — read
        `Opportunity-value-review-*.csv`. Airtable went from seven distinct values to five in one day
        with no code change, so `$PriorityTypeMap` going stale is the likeliest failure here.
      - **Do not "fix" a blank by writing `priority_type__c`** — that field belongs to TTS OTCRM
        despite its matching "Priority Type" label. See `TRANSFORMATION-RULES.md`.

### 4e. `LDGCRM_application__c`

- [ ] Run `Build-ApplicationLoad.ps1`. **Re-baselined 2026-08-14 against the re-pulled export**
      (1,058 Airtable rows): expect **1,045 ready**, **13 withheld** — 8 for no Partner Account in
      Airtable + 5 for a Partner Account not loaded (was 8 + 22; the Account merges freed 17). Must
      run *after* Partner Account and Opportunity are loaded, or it withholds far more.
      *(Trend on the same underlying rule: 688 ready → 1,026 → 1,045. Re-baseline each run rather than
      reading movement as a regression.)*
- [ ] Load (upsert). Expect 1,045/1,045.
- [ ] Verify Market Segment came from the Flow; no formula field was written.
- [ ] ℹ️ **Expect ~607 Applications to have Launch Level DEFAULTED to `1 - Very Low Impact`** (the
      build prints the count). Airtable leaves it blank on 621 of 1,056 rows, and blank is not
      neutral: `LDGCRM_Launch_Checklist_Completion__c` falls through its `CASE` to an else value of
      100%. **Verify no migrated Application reports 100% completion** — before this default, 607 did:
      ```
      sf data query -q "SELECT COUNT() FROM LDGCRM_application__c WHERE LDGCRM_Launch_Level__c = null AND LDGCRM_External_ID__c != null" --target-org <alias>
      ```
      Expect **0**. A non-zero count means the default regressed and those records are reporting
      themselves fully launch-complete.
- [ ] ✅ **Partner Portal Team Name / Team UUID are now written.** Expect the run to print
      `Partner-portal team columns will be written (both fields are non-unique)` and
      `Partner Portal Team resolved`. **Expect ~681 Applications carrying a team.**
      - The transform still reads both fields' definitions live and **withholds the columns if either
        is ever set back to `Unique = true`** — one portal team legitimately owns many Applications
        (`DOI - FWS - ECOS` owns 54), so writing them against a unique field fails the whole row.
      - If you see a red `PARTNER PORTAL TEAM COLUMNS WITHHELD` block, `Unique` has been
        re-introduced on one of the fields. That is a regression, not an expected state.
      - **The team is OPTIONAL** (business rule 2026-08-14). Applications with no team are fine, and
        the 9 whose issuer strings name two different teams stay blank deliberately.
      - This is a Salesforce-config item, not an Airtable one — see
        **AIRTABLE-DATA-QUALITY-REQUESTS.md**.
- [ ] Review `logs/data-migration/Application-portal-team-review-*.csv` — **27 rows, two kinds**, told
      apart by the `Issue` column. The team belongs to the Application and Airtable duplicates it onto
      every issuer string, so both are "the copies disagree"; they differ in whether that's resolvable.
      - **`CONFLICT` — 9 Applications** whose issuer strings name two different teams. Both fields
        deliberately left blank; there is no defensible tie-break. Airtable fix, not a code change.
      - **`INCOMPLETE` — 18 Applications** carrying the team on only some issuer strings. **Expected
        and non-blocking** — the team is unambiguous so it migrates correctly. Do not treat these as
        failures; they are listed so the missing copies can be filled in.
### 4e-bis. `LDGCRM_application__c` — Broker App Parent SECOND PASS

- [ ] ⚠️ **Load `LDGCRM_application__c-broker-parent-upsert.csv`, and only AFTER 4e.** It is written
      automatically by `Build-ApplicationLoad.ps1` (no separate transform to run), but loading it
      before the main file fails every row: Bulk API 2.0 does not resolve an external-ID reference
      between two rows of the same batch, which is the entire reason this pass exists.
      ```powershell
      scripts\powershell-scripts\Invoke-SalesforceLoad.ps1 -Environment Dev `
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
- [ ] Expect **296/296** (2026-08-13 reload; was 267). Verify the placeholder Impediment named `None` was **excluded** (465 links,
      53% of the otherwise-loadable set). A count far above 267 means the exclusion regressed.
- [ ] Verify `LDGCRM_Blocked_Revenue__c` rolls up a genuine figure, not a multi-million placeholder.

### 4g. `LDGCRM_Application_Contact__c`

- [ ] Run `Build-ApplicationContactLoad.ps1`. **Re-baselined 2026-08-14**: expect **2,750 ready**,
      **77 skipped** waiting on a side (was 2,699 / 128 — the Account merges freed 51).
- [ ] Load (upsert). Expect **2,750/2,750**, keyed on the composite external ID
      `<contact>|<application>`, and **1,079 flagged Partner Portal Admin** in the org afterwards.
- [ ] ⚠️ The duplicate-check Flow throws a hard error, fires only on Create, and **misses intra-batch
      duplicates** — it is not a safety net. Any duplicate error here means the composite key
      regressed.
- [ ] ℹ️ **The Partner Portal Admin flag now has two sources, UNIONed** — `Contacts.Roles` and the
      Issuer Strings table's `Partner Portal Admin Email`. Expect **86 associations that exist only
      because Issuer Strings names an admin** (42 of them in the load; the rest wait on their
      Application). These are *new junction rows*, not just flags — if the count is 0, the Issuer
      Strings export is missing or the email match broke.
- [ ] Review `logs/data-migration/ApplicationContact-admin-source-*.csv` — provenance per flag.
      Expect **883 `BOTH` / 116 `Contacts.Roles only` / 86 `Issuer Strings only`** (2026-08-14; was
      882/117/86), and **0 admin emails matching no Contact**. A non-zero count there means someone
      administers a portal team but isn't a Contact in Airtable, so no junction row can be created for
      them.
      - ⚠️ **This breakdown counts ALL pairs including skipped ones (1,085), so it does not sum to the
        1,079 flags in the org.** That is expected, not an inconsistency.

### 4i. Notes — LAST, after every other object

- [ ] Run `Build-NotesLoad.ps1 -Environment Dev`. Expect **~730 notes ready** (2026-08-14; was 716,
      and 537 before that), placeholder values skipped (`None`/`N/A`), and only **7** waiting on a
      parent the Account issue withheld (was 21).
      *(The orchestrator runs this as step 12 of 12, so a normal full run does not need it invoked
      separately — these steps are for an object-by-object load.)*
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
- [ ] Confirm Phase 2 left 0 rows, or the diff will under-insert. *(Verified 0 on 2026-08-14 — it
      cascades away with its parent Opportunity.)*
- [ ] Expect **566 rows** (2026-08-14; was 565, and 515 before that), fewer skipped as Accounts
      resolve. **34 withheld**, waiting on a side the Account issue held back.

---

## Phase 5 — Ownership verification (the point of this reload)

- [ ] Owner distribution matches the transform's predicted split:

      | Object | Expect own owner | Expect fallback (`peter.marks@gsa.gov`) |
      | --- | --- | --- |
      | Opportunity | 510 | **332** |
      | `LDGCRM_application__c` | ~360 | ~329 |
      | Contact | 1,876 | 0 |
      | `LDGCRM_Impediment__c` | 0 | 38 |
      | `LDGCRM_Application_Contact__c` | 0 | 2,750 |

      ⚠️ **Re-baselined 2026-08-14.** Measured Opportunity split: **332 on the fallback owner**, then
      Daniel Ruggiero 226, Melissa Sowerwine 132, Omodayo Yunusa 65, Ryan Von Sonnenbrot 47, Trevor
      Sinclair 21. Every figure in this table is a moving target; diff the *transform's* reasoning,
      not the absolute number.

      ⚠️ **The fallback is still the largest single owner on Opportunity (332 of 842, ~39%)** because
      247 distinct Airtable owner emails resolve to no active Salesforce User. That is the "missing
      Salesforce logins" item in **AIRTABLE-DATA-QUALITY-REQUESTS.md**, not a pipeline fault.

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

## Phase 5b — Partner portal data verification (Issuer Strings)

**Why this phase exists:** everything sourced from the **Issuer Strings** table can go missing
*without any load error*. The table is newer than the rest of the pipeline, and its two failure modes
— a missing/stale export, or the admin email match ceasing to resolve — both produce a CSV that loads
100% successfully with a field simply left blank. **Success counts will not catch this.** Neither
will the owner checks above.

`Invoke-FullMigrationLoad.ps1` now runs checks 1–3 automatically in post-load validation (comparing
the org against the load file, so it re-baselines itself rather than going stale). Run them by hand
too if you loaded object-by-object rather than through the orchestrator.

- [ ] **1. Partner Portal Admin flag landed.** Compare the load file against the org — these must
      match, and the count must not be zero:
      ```powershell
      $csv = @(Import-Csv "data\salesforce-loads\LDGCRM_Application_Contact__c-upsert.csv")
      @($csv | Where-Object { $_.LGDCRM_P3_Partner_Portal_Admin__c -eq "true" }).Count   # expect 1,079
      ```
      ```
      sf data query -q "SELECT COUNT() FROM LDGCRM_Application_Contact__c WHERE LGDCRM_P3_Partner_Portal_Admin__c = true" --target-org <alias>
      ```
      ⚠️ **A count of 0 means the source broke, not that nobody is an admin.** Both sources
      (`Contacts.Roles` *and* Issuer Strings' `Partner Portal Admin Email`) would have to be silent
      at once — check the Airtable export is current and actually includes `Issuer Strings.json`.
- [ ] **2. The Issuer-Strings-created associations exist.** Expect **86**. These are junction rows
      that exist *only* because Issuer Strings names an admin — the Contacts table never links those
      people to those Applications. The build step prints the count; if it says 0, the second source
      is not running.
- [ ] **3. Partner Portal Team Name / UUID.** Verify they landed:
      ```
      sf data query -q "SELECT COUNT() FROM LDGCRM_application__c WHERE LDGCRM_P3_Team_UUID__c != null" --target-org <alias>
      ```
      Expect **691** (2026-08-14; was 681 — Airtable added 7 issuer strings). Also expect **0**
      holding the literal `#N/A` — it is transformed to blank:
      ```
      sf data query -q "SELECT COUNT() FROM LDGCRM_application__c WHERE LDGCRM_P3_Team_UUID__c = '#N/A' OR LDGCRM_P3_Partner_Portal_Team_Name__c = '#N/A'" --target-org <alias>
      ```
      - ⚠️ If the load **fails with `DUPLICATE_VALUE`**, `Unique` has been re-introduced on one of the
        fields — one portal team owns many Applications by design.
- [ ] **4. Review the two Issuer Strings review CSVs** and confirm the counts still match what the
      data-quality doc tells the Airtable owners — if they have diverged, the doc is now lying to
      them and needs updating in the same change:
      - `Application-portal-team-review-*.csv` — expect **9 `CONFLICT`**, **18 `INCOMPLETE`**.
      - `ApplicationContact-admin-source-*.csv` — expect **883 `BOTH` / 116 `Contacts.Roles only` /
        86 `Issuer Strings only`** (1,085 rows), and **0** admin emails matching no Contact.
- [ ] **5. Spot-check one record end to end.** Open an Application in the UI that should have a portal
      team, confirm the team fields and that its Application Contacts show the right person with
      **Partner Portal Admin checked**. A count proves rows exist; only this proves they are right.

---

## Phase 6 — Side-effect sweep

Standing rule: **check for side effects, not just successes.** Every serious problem in this migration
was found this way, never in a success count.

- [ ] Account total unchanged by the Contact load (no junk FCIC Accounts).
- [ ] `TriggerControls__c.Contact.On__c` = `true`.
- [ ] `LDGCRM_Market_Segment__c` still 6 records (5 tagged + the untagged `Test Market Segment`).
- [ ] ⚠️ **Market Segment CONTENTS, not just the segment count** — this is the check that would have
      caught the 2026-08-14 QA load, where all nine Flows were off and every count still matched Dev.
      All three must be **0**:
      ```
      sf data query -q "SELECT COUNT() FROM LDGCRM_Partner_Account__c WHERE LDGCRM_External_ID__c!=null AND LDGCRM_Market_Segment__c=null" --target-org <alias>
      sf data query -q "SELECT COUNT() FROM Opportunity WHERE LDGCRM_External_ID__c!=null AND LDGCRM_Market_Segment__c=null" --target-org <alias>
      sf data query -q "SELECT COUNT() FROM LDGCRM_application__c WHERE LDGCRM_External_ID__c!=null AND LDGCRM_Market_Segment__c=null" --target-org <alias>
      ```
      A non-zero count means the before-save Flows did not fire. **Re-activating them does not fix
      the loaded records** — those Flows run on create or parent change, and the pipeline upserts, so
      a re-run is an update that will not re-trigger them. It needs another wipe and reload.
- [ ] No unexpected new records on objects nobody loaded (Event, Task, Case, Lead).
- [ ] Pre-existing/untagged test records still at baseline counts.
- [ ] Review every `logs/data-migration/*-skipped-*.csv` and `*-review-*.csv` from this run and fold
      anything new into **AIRTABLE-DATA-QUALITY-REQUESTS.md**.
      Findings sitting unread in `logs/` are the failure mode that rule exists to prevent.

---

## Sign-off

| Item | Expected | Actual | ✓ |
| --- | --- | --- | --- |
| Environment / alias confirmed by banner | | | |
| Rahul coordination confirmed | yes | | |
| Loading user = intended fallback owner | | | |
| Phase 3 ownership gate | passed | | |
| Account | **585** tagged (per D1) | | |
| `LDGCRM_Partner_Account__c` | **97** tagged (99 submitted, 2 known fails) | | |
| Contact | **~1,876** (account-less now skipped) | | |
| Contact names DERIVED from email | ~592 | | |
| Contact names read back from the org | **0–2** — anything higher is the self-referential bug. ⚠️ Only true on a **wiped** org; a plan-only run against a loaded org legitimately shows ~940 | | |
| `last.first` domains learned | `dol.gov`, `pbgc.gov` | | |
| Contacts with a role inbox as `LastName`, **no FirstName** | ~57 (correct — address kept whole) | | |
| Contacts where a role name was **split into a person** | **7**, all from Airtable's `Name` field | | |
| Fallback owner resolved | `peter.marks@gsa.gov` | | |
| Opportunity | **842** | | |
| `LDGCRM_application__c` | **1,045** | | |
| `LDGCRM_Opportunity_Impediment__c` | **296** | | |
| `LDGCRM_Application_Contact__c` | **2,750** + pre-existing | | |
| `OpportunityContactRole` | **566** | | |
| `ContentNote` | **730** | | |
| `LDGCRM_Market_Segment__c` | 6 (5 tagged) | | |
| Junk FCIC Accounts created | 0 (total stays at the pre-run baseline, **4** in Dev) | | |
| `TriggerControls__c` restored | true | | |
| Records owned by inactive users | 0 | | |
| Market Segment blank on PA / Opp / App | **0 / 0 / 0** — non-zero means the Flows did not fire | | |
| Applications with a NULL Launch Level | 0 | | |
| Opportunities with fully-ramped revenue > 0 | **~507** (formula field — **not** `Amount`, which this migration never writes and which is correctly 0) | | |
| **Partner Portal Admin flags** | **1,079** (0 = source broke, not "no admins") | | |
| **Associations added by Issuer Strings** | **86** | | |
| **Partner Portal Team UUID populated** | **691** (0 = `Unique` regressed, or the transform withheld the columns) | | |
| Applications holding literal `#N/A` | 0 | | |
| Admin emails matching no Contact | 0 | | |
| Orchestrator halts on an expected partial | **0** — it classifies and continues as of 2026-08-14 | | |

---

## Results of the 2026-08-15 Dev reload — CURRENT BASELINE

**This is the figure set to diff against.** The wipe and Account bootstrap ran on 2026-08-14 (8,830
records hard-deleted); the ambiguous-hierarchy repair crashed on a code defect and was fixed and
re-run on 2026-08-15, followed by a fresh Airtable pull and the full load.

**The load HALTED at step 5 of 12 on the Contact duplicate problem above**, and was completed by
resuming with `-StartAtStep Opportunity`. Steps 6–12 ran with **0 failures**.

| Object | 08-14 | **08-15** | Δ | Why |
| --- | --- | --- | --- | --- |
| Account | 585 | **637** | **+52** | Airtable Account merges + the hierarchy repair |
| `LDGCRM_Partner_Account__c` | 97 | **96** | −1 | |
| Contact | 1,876 | **1,721** | **−155** | ⛔ the `Help Desk` rename |
| Opportunity | 842 | **887** | **+45** | more Accounts reconcile |
| `LDGCRM_application__c` | 1,045 | **1,033** | −12 | |
| `LDGCRM_Impediment__c` | 38 | **37** | −1 | |
| `LDGCRM_Opportunity_Impediment__c` | 296 | **311** | +15 | |
| `LDGCRM_Application_Contact__c` | 2,750 | **2,532** | **−218** | cascade from the missing contacts |
| `OpportunityContactRole` | 566 | **579** | +13 | |
| `ContentNote` | 730 | **721** | −9 | |
| `LDGCRM_Market_Segment__c` | 5 | **5** | 0 | |
| **Total** | 8,831 | **8,559** | **−272** | |

**Read the deltas in two groups.** Account +52 and Opportunity +45 are the Airtable owners' merge work
landing — genuine progress. Contact −155 and Application-Contact −218 are the `Help Desk` rename.
Undo that one edit and this run would have been the best yet.

**Post-load verification — all passed:**

| Check | Result |
| --- | --- |
| Market Segment blank on Partner Account / Opportunity / Application | **0 / 0 / 0** — the Flows fired |
| LDGCRM Flows at pre-flight | **9 of 9 active and current** |
| Records owned by an inactive user (3 objects) | **0** |
| FCIC junk Accounts | **4** — unchanged from baseline |
| `TriggerControls__c.Contact.On__c` | **true** — restored |
| Event / Task / Lead | **0 / 0 / 0** |
| Applications with a NULL Launch Level | **0** |
| Applications holding literal `#N/A` | **0** |
| Applications with Partner Portal Team UUID | **681** |
| Applications with Broker App Parent | **66** |
| Partner Portal Admin flags | **1,074** |

### Results of the 2026-08-14 full reload (superseded — kept for the trend)

Sandbox wiped (8,018 records hard-deleted), Accounts rebuilt from the production export, Airtable
re-pulled, then loaded end to end in **19m 47s**.

| Object | Airtable rows | Loaded | 08-13 | Notes |
| --- | --- | --- | --- | --- |
| Account | 747 | **585** tagged | 584 | 154 unmatched, 8 ambiguous |
| `LDGCRM_Partner_Account__c` | 99 | **97** | 92 | 99 submitted, 2 known fails |
| Contact | 1,535 | **1,876** | 1,870 | 1,886 submitted, 10 duplicate-rule rejects |
| Opportunity | 904 | **842** | 842 | 62 skipped, all unreconciled Accounts |
| `LDGCRM_application__c` | 1,058 | **1,045** | 1,026 | 8 no Partner Account, 5 not loaded |
| `LDGCRM_Impediment__c` | 40 | 38 | 38 | 2 skipped (no Name) |
| `LDGCRM_Opportunity_Impediment__c` | — | **296** | 296 | 465 `None` links excluded by design |
| `LDGCRM_Application_Contact__c` | — | **2,750** | 2,699 | 1,079 admin flags; 86 via Issuer Strings |
| `OpportunityContactRole` | 520 | **566** | 565 | insert + read-then-diff |
| `ContentNote` | — | **730** | 716 | 7 parent not loaded |
| `LDGCRM_Market_Segment__c` | 7 | 6 | 6 | now deleted + reloaded as step 1 |
| **Total** | | **8,831** | 8,734 | **+97** |

**All QA phases passed. 0 unexpected failures. 265 rows withheld.**

✅ **The orchestrator ran all 12 steps end to end without stopping once** — the friction point flagged
below after the 2026-08-13 run is fixed. `PartnerAccount` and `Contact` both reported
`PARTIAL (expected failures)` with every failure matched to a known cause, and the run carried on.

**Verified in the org after the load:**

| Check | Result |
| --- | --- |
| Market Segment blank on Partner Account / Opportunity / Application | **0 / 0 / 0** — the Flows fired |
| Records owned by an inactive user (4 objects) | **0** |
| FCIC junk Accounts | **4** — unchanged from baseline |
| `TriggerControls__c.Contact.On__c` | **True** — restored |
| Event / Task / Lead | **0 / 0 / 0** |
| Applications with a NULL Launch Level | **0** |
| Applications holding literal `#N/A` | **0** |
| Applications with Partner Portal Team UUID | **691** (was 681) |
| Applications with Broker App Parent | **66** (was 63) |
| Opportunities with computed fully-ramped revenue > 0 | **507** (was ~467) |
| Impediment blocked-revenue rollup | genuine figures; `None` correctly absent |
| Admin flag provenance | **883 BOTH / 116 Roles-only / 86 Issuer-Strings-only** |
| Portal team review | **9 CONFLICT / 18 INCOMPLETE** |

**Two expected stops, both documented, neither a defect — and neither halted the run this time:**
- **PartnerAccount** — 2 of 99 failed, both parent Accounts still untagged. Within the allowance of 20.
- **Contact** — 10 of 1,886 rejected by the org duplicate rule (First+Last name). Was 12.

### ⚠️ Two Contact checks that only read correctly on a freshly-wiped org

Both were measured on a `-PlanOnly` run against the **still-loaded** org immediately before the wipe,
and both looked like serious regressions. They are not — they are the documented circular-read
behaviour, and the wipe cleared them. **Do not raise these unless you see them post-wipe:**

| Check | Against the loaded org | After the wipe |
| --- | --- | --- |
| Names "read back from a Contact already in the org" | **940** | **2** (the pre-existing test records) |
| Names DERIVED from the email | suppressed | **592** |

The pre-wipe figure is the transform reading back **its own derived names** from the previous load and
counting them as recovered. It is exactly the failure mode §4c warns about, and seeing it on a
plan-only run is expected rather than alarming.

### Results of the 2026-08-13 full reload (superseded — kept for the trend)

| Object | Loaded | Previous |
| --- | --- | --- |
| Account | 584 tagged | 588 |
| `LDGCRM_Partner_Account__c` | 92 | 74 |
| Contact | 1,870 | 1,483 |
| Opportunity | 842 | 742 |
| `LDGCRM_application__c` | 1,026 | 688 |
| `LDGCRM_Opportunity_Impediment__c` | 296 | 267 |
| `LDGCRM_Application_Contact__c` | 2,699 | 1,880 |
| `OpportunityContactRole` | 565 | 515 |
| `ContentNote` | 716 | 537 |
| **Total** | **8,734** | 6,819 |

⚠️ On that run the orchestrator **halted twice on expected partials** and needed manual resumes. That
was the single biggest friction point in this runbook; it is resolved as of 2026-08-14.

---

## Known gaps this reload will NOT close

Expected, documented, not to be logged as failures:

- **154 unmatched Airtable Accounts** (was ~169), cascading into 62 Opportunities, 13 Applications,
  77 Application-Contact pairs, 34 Opportunity Contacts, 7 Notes and 2 Partner Accounts.
  ⚠️ **The nature of this gap changed on 2026-08-14.** Every duplicate row previously listed has been
  merged at source. What remains is mostly **agencies, bureaus, territories and courts with no
  Salesforce Account at all** (`U.S. Census Bureau`, `Guam`, `The Supreme Court of the United
  States`…), so most of it now needs Accounts *creating in Salesforce* rather than an Airtable edit.
  Two Airtable follow-ons remain and are worth doing: the **`Department of Treasury` name collision**
  (2 rows share the name; unblocks 5 Opportunities) and **8 generic office names** that match 2+
  Salesforce Accounts. See AIRTABLE-DATA-QUALITY-REQUESTS.md.
- **`LDGCRM_Broker_App_Parent__c`** — 4 of 70 links stay unloaded (was 7): 3 waiting on an Application
  the Account issue withheld, 1 a self-reference needing an Airtable fix. The other **66** load in
  step 4e-bis.
- **247 Opportunity owners do not resolve to an active Salesforce User**, so 332 Opportunities land on
  the fallback owner. That is the "missing Salesforce logins" item in the data-quality doc, not a
  pipeline fault, and it is not closed by any reload.
- **Meetings** (1,845 rows) — **deferred by decision 2026-08-13, and out of scope for this reload.**
  Rather than synthesize the start/end times Airtable never recorded, the approach is now to stand up
  **Einstein Activity Capture**, let real Google Calendar events sync, and fuzzy-match Airtable's
  meetings onto them. That depends on an org configuration change outside this repo and an unresolved
  spike (do EAC events exist as standard `Event` records at all?). See `BACKLOG.md` §2.
- **Notes** — **built 2026-08-13** (`Build-NotesLoad.ps1` + `Invoke-NotesLoad.ps1`), and now **step 12
  of 12 in the orchestrator**, so it runs as part of a normal full load rather than being a known gap.
  730 notes loaded on 2026-08-14; only 7 wait on parents the Account issue withheld (was 200).
- **Contact ownership meaningfulness** — see D2.
- **9 Applications with no portal team** — their issuer strings name two different teams, so both
  fields are deliberately left blank. **Accepted outcome**: the portal team is optional (business
  rule 2026-08-14). Not a load failure and not an Airtable ask.
- **Partner Portal Admins recorded in two places that disagree** — 117 pairs asserted only by
  `Contacts.Roles`, 86 only by Issuer Strings. Both are honoured (union), so nothing is lost, but the
  underlying duplication is an Airtable question rather than something this reload closes.
