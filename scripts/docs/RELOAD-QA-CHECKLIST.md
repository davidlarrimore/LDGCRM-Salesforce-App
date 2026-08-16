# Full reload — reconciliation checklist

> **Who this is for:** whoever has just run a complete **wipe and reload** of a sandbox and needs to
> answer one question: **did everything in Airtable arrive in Salesforce, and is it complete once it
> got there?**
>
> **This is not how to run a load.** For that, use [RUNNING-A-LOAD.md](RUNNING-A-LOAD.md). This is the
> verification pass that comes after.
>
> **Prerequisites:** [SETUP.md](SETUP.md) done, and the load finished.

**What this checks, in order:**

1. **Reconciliation** — every Airtable table against the Salesforce object it became.
2. **Expected losses** — the rows that legitimately did not arrive, and why each one didn't.
3. **Field completeness** — the fields that must not be null, and are invisible to a row count.
4. **Fixes in flight** — did the thing we fixed at source actually land?

---

## ⚠️ The failure this document exists to catch

**A load can report 100% success and still be wrong.** QA was once loaded with every object count
matching Dev and zero failures, while all nine Flows were inactive — so Market Segment came out blank
on *every* Partner Account, Opportunity and Application. Flow activation changes field **contents**,
not row counts.

**A row count is necessary and not sufficient.** Section 3 is the part that catches this, and it is
the part most likely to be skipped.

---

## Environments

| Environment | Alias | Notes |
| --- | --- | --- |
| `Dev` | `peodv8dvn` | Default for every script |
| `QA` | `peodv15dvn` | Migration rehearsal |
| `Full` | `peofl2stgp` | Operations dress rehearsal. **Accounts are real and are never wiped** |
| `Prod` | `gsa-peo` | **PRODUCTION.** Not authorized locally |

Scripts take `-Environment`, resolve the alias themselves, and prove it against the registry. **Never
pass `--target-org` by hand** — any stale command line saying `--target-org gsa-peo` is a silent
retarget to production. Queries below use `<alias>`; substitute the one you are actually verifying.

> ### ⚠️ In a FULL sandbox, Accounts are not rebuilt
>
> A Full sandbox is a copy of production, so its Accounts **are** the records the migration
> reconciles onto. This is enforced in code, not left to the operator. Expect Account row counts to be
> *unchanged* by the wipe and treat Account as a reconciliation-only object. Everything else is the
> same.

---

## Running it

```powershell
.\powershell-scripts\Invoke-SandboxFactoryReset.ps1 -Environment Dev -BootstrapAccounts
# ⚠️ STOP - run the bootstrap a SECOND time and confirm it reports 0 missing. See below.
# ⚠️ STOP - re-apply the two manual Account tags here, BEFORE the load. See below.
.\powershell-scripts\Invoke-FullMigrationLoad.ps1   -Environment Dev -Confirmation "LOAD"
```

Then **read `SUMMARY.txt`** in the run directory before anything else. It is the report, not a log.

### ⚠️ MANDATORY after the bootstrap: run it AGAIN and confirm 0 missing

**The bootstrap can lose rows silently.** On a large insert the `sf` CLI sometimes returns a job
result the script cannot parse. It says so — *"Could not read the job result for this pass… how many
landed is UNKNOWN"* — and correctly refuses to guess, but it **cannot tell you which rows are
missing**, and the run still exits 0.

Measured on 2026-08-16: QA submitted **590** distinct Accounts across passes 1–3, two of those passes
returned an unreadable result, and **589 landed**. `Office to Monitor and Combat Trafficking in
Persons` vanished with no error. The same Account had gone missing from Dev earlier for the same
reason, and was wrongly blamed on the production export.

**The fix is simply to run the bootstrap again.** It is idempotent, inserts only what is absent, and
a small batch returns a readable result:

```powershell
.\powershell-scripts\Invoke-AccountBootstrap.ps1 -Environment <env> -Confirmation "BOOTSTRAP"
```

**Confirm it reports `Planned Accounts missing (will insert)  0`.** If it inserts anything, run it a
third time until that line reads 0. Do **not** skip this because the first run "looked fine" — a
silent loss looks exactly like success.

> ⚠️ **Never re-run a single pass by hand from its CSV.** Bootstrapped Accounts carry no external ID,
> so there is nothing to deduplicate on and a second insert creates duplicate Accounts. Re-run the
> whole script, which re-reads the org first.

### ⚠️ MANDATORY between the reset and the load: re-tag AmeriCorps and MCC

**The reset destroys these two tags and nothing reports it.** Salesforce holds two Accounts named
`AmeriCorps` and two named `Millennium Challenge Corporation`; the correct one is **top level**, and
it is identified by hand because the names are character-identical. The factory reset hard-deletes
Accounts carrying an external ID, and the bootstrap recreates them **untagged**.

Skip this and **5 records are silently withheld** — Opportunities `MyAmericorps`, `Grantee and
Sponsor Portal` and `MCC`, Partner Account `AC`, and Application `AmeriCorps Grantee and Sponsor
Portal (Ernst & Young…)`. The load still reports success; the Partner Account failure is classified
*expected*. There is no automated check for this.

**The Account Ids differ per org and change on every rebuild — always re-query, never paste.**

```powershell
# 1. Find the two TOP-LEVEL Accounts (ParentId = null is what makes them correct)
sf data query --target-org <alias> -q "SELECT Id, Name, ParentId FROM Account WHERE Name IN ('AmeriCorps','Millennium Challenge Corporation') ORDER BY Name"

# 2. Build a two-row CSV of Id,LDGCRM_External_ID__c using the ParentId = null rows:
#      <top-level AmeriCorps Id>,recLIsbBAhuXuc1OR
#      <top-level MCC Id>,recdA0Zjx6ihcKKHa
# 3. Apply it
.\powershell-scripts\Invoke-SalesforceLoad.ps1 -Environment <env> -ObjectApiName "Account" `
    -CsvFile "<absolute path to the CSV>" -Operation Update -Confirmation "LOAD"

# 4. VERIFY - the tags must be on the top-level records, and only those
sf data query --target-org <alias> -q "SELECT Id, Name, ParentId, LDGCRM_External_ID__c FROM Account WHERE LDGCRM_External_ID__c IN ('recLIsbBAhuXuc1OR','recdA0Zjx6ihcKKHa')"
```

`-CsvFile` needs an **absolute** path — a relative one resolves against your shell's working
directory, not the bundle, and the script stops with "CSV file not found".

Why the top-level record is the right one, with sources, is in
`docs/engineering/TRANSFORMATION-RULES.md`, "AmeriCorps and Millennium Challenge Corporation —
tagged by hand". **Do not re-decide it from the Account names**: the wrong record in each pair looks
plausible (AmeriCorps is funded through the Labor appropriations act; the Secretary of State chairs
MCC's board), and both bodies are in fact independent agencies.

---

## What the pipeline already checks for you

Do not re-do these by hand. `SUMMARY.txt` section 6 (*POST-LOAD VALIDATION*) fails the run on each:

| Automated check | Fails the run if |
| --- | --- |
| FCIC junk Accounts | any **new** `FCIC_Individual` Account appeared — the Contact trigger bypass leaked |
| `TriggerControls__c.Contact.On__c` | still `false` — another app's trigger left disabled |
| Inactive owners | any migrated record is owned by an inactive user |
| Partner Portal Team UUID | fewer Applications carry it than were submitted |
| Partner Portal Admin | fewer junction rows are flagged than were submitted, or **zero** are |
| Flows active | fewer than 9 of 9 at pre-flight — **blocks the run before it starts** |
| Contact duplicate rules | any is still active at pre-flight |

**Everything below is what the pipeline cannot check itself.**

---

## 1. Reconciliation — Airtable in, Salesforce out

One row per Airtable table. **Re-measure both sides every run**; the counts move whenever the data
owners touch the base.

```powershell
# Airtable side - counts straight from the current pull
Get-ChildItem .\data\airtable-exports\*.json | ForEach-Object {
    $n = (Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).Count
    "{0,-30} {1,6}" -f $_.BaseName, $n
}
```

> This lists **all 22 tables**, because the pull backs up the whole base. Only the 10 in the table
> below migrate; the rest have no Salesforce counterpart and no row here. A file you cannot find in
> the table is backup-only, not an object someone forgot to load.

```
# Salesforce side - only rows this migration created
sf data query -q "SELECT COUNT() FROM <Object> WHERE LDGCRM_External_ID__c != null" --target-org <alias>
```

| Airtable table | → Salesforce object | Relationship | Last measured |
| --- | --- | --- | --- |
| Accounts | Account *(tagged)* | **Not 1:1.** Reconciled onto existing Accounts, never created. Gap = unplaced Accounts | 731 → 637 |
| Partner Accounts | `LDGCRM_Partner_Account__c` | ≈1:1. Gap = parent Account unreconciled | 99 → 96 |
| Contacts **+ Opportunity Contacts** | Contact | **Two tables in, merged on email.** Expect *more* than the Contacts export | 1,514 + 520 → 1,888 |
| Opportunities | Opportunity | ≈1:1. Gap = Account unreconciled, or no Status | 904 → 887 |
| Applications | `LDGCRM_application__c` | ≈1:1. Gap = parent Partner Account missing | 1,058 → 1,033 |
| Impediments | `LDGCRM_Impediment__c` | 1:1 **minus the `None` placeholder**, excluded by rule | 38 → 37 |
| Impediments × Opportunities | `LDGCRM_Opportunity_Impediment__c` | One row per pair, `None` links excluded | — → 311 |
| Applications × Contacts | `LDGCRM_Application_Contact__c` | One row per pair, composite key | — → 2,741 |
| Opportunity Contacts | `OpportunityContactRole` | **Insert + read-then-diff**, never upsert | 520 → 588 |
| *(freeform columns)* | `ContentNote` | Built last, from columns with no field | — → 721 |
| Market Segments | `LDGCRM_Market_Segment__c` | Keyed on **name**, not `rec…` | 7 → 5 |
| Meetings | *(not migrated)* | Deferred by decision — see `BACKLOG.md` | 1,849 → 0 |
| Issuer Strings | *(no object)* | Collapses onto Application's portal-team fields | 907 → n/a |

**Three of these look wrong and are not:**

- **Contact exceeds the Contacts export**, because `Opportunity Contacts` has no link back to
  `Contacts` and is folded in, then merged on email.
- **`OpportunityContactRole` exceeds its source table**, because roles also come from the Application
  and Opportunity relationships, not only from that table.
- **Account is far below its source.** Airtable Accounts are *matched*, never created — the shortfall
  is the unplaced-Account list, not a load failure.

---

## 2. Expected losses — the rows that legitimately did not arrive

`SUMMARY.txt` splits these already. What you are checking is that each is **the same shape as last
run**, not that it is zero.

- **Section 2, LOAD FAILURES** — every failure must be under *EXPECTED*. Anything under *UNEXPECTED*
  stops the run and is a real defect.
- **Section 3, ROWS WITHHELD** — rows the transform never submitted. **Usually the bigger number**,
  and invisible to the Bulk API. Each carries its reason and a CSV.
- **Section 4, NEEDS A HUMAN** — the pipeline refused to guess. Read every one.

| Expected loss | Cause | Direction of travel |
| --- | --- | --- |
| Partner Account foreign-key failures | Parent Account among the unplaced | ↓ as Accounts are fixed |
| Opportunities withheld | Account unreconciled, or no Status in Airtable | ↓ |
| Applications withheld | Parent Partner Account absent | ↓ |
| Contacts skipped, no Account | No Account link in Airtable at all, or it didn't reconcile | partly permanent |
| Application–Contact withheld | Junction partner itself withheld | ↓ |
| Notes withheld | Parent record withheld | ↓ |
| Market Segment skipped | Row has no Name — the load key | permanent, 2 rows |
| Impediment skipped | The `None` placeholder | permanent, by rule |

⚠️ **A withheld count that goes UP without an Airtable change is a regression.** `SUMMARY.txt` prints
`(was N)` against each — that comparison is the check, not the absolute number.

⚠️ **Zero duplicate-rule rejections is now correct.** The load deactivates the Contact duplicate rules
itself, permanently, in every org. Any `DUPLICATES_DETECTED` means something re-enabled one.

---

## 3. Field completeness — the nooks and crannies

**This is the section a row count cannot replace.** Every query below counts records that arrived but
are missing something they should have.

### 3a. Market Segment — set by Flow, not by the load

The three objects whose Market Segment comes from a before-save Flow. **All three must be 0.** A
non-zero count means the Flows did not fire, and *nothing else in the load will tell you.*

```
sf data query -q "SELECT COUNT() FROM LDGCRM_Partner_Account__c WHERE LDGCRM_External_ID__c != null AND LDGCRM_Market_Segment__c = null" --target-org <alias>
sf data query -q "SELECT COUNT() FROM Opportunity                WHERE LDGCRM_External_ID__c != null AND LDGCRM_Market_Segment__c = null" --target-org <alias>
sf data query -q "SELECT COUNT() FROM LDGCRM_application__c      WHERE LDGCRM_External_ID__c != null AND LDGCRM_Market_Segment__c = null" --target-org <alias>
```

⚠️ **Re-running does not fix a blank.** All three Flows fire on create or parent change and the
pipeline upserts, so a re-run is an update that will not re-trigger them. If these come back non-zero,
you need a **factory reset and full reload**, not a re-run.

### 3b. Application — checklist and launch data

```
# Launch Level: must be 0. Blank falls through a formula's else-branch and reports 100% complete.
sf data query -q "SELECT COUNT() FROM LDGCRM_application__c WHERE LDGCRM_External_ID__c != null AND LDGCRM_Launch_Level__c = null" --target-org <alias>

# Portal team: expect a large positive number. 0 means Unique regressed or the columns were withheld.
sf data query -q "SELECT COUNT() FROM LDGCRM_application__c WHERE LDGCRM_External_ID__c != null AND LDGCRM_P3_Team_UUID__c != null" --target-org <alias>

# Literal "#N/A" must never reach the org - it is transformed to blank.
sf data query -q "SELECT COUNT() FROM LDGCRM_application__c WHERE LDGCRM_P3_Team_UUID__c = '#N/A' OR LDGCRM_P3_Partner_Portal_Team_Name__c = '#N/A'" --target-org <alias>

# Required parent lookup: must be 0.
sf data query -q "SELECT COUNT() FROM LDGCRM_application__c WHERE LDGCRM_External_ID__c != null AND LDGCRM_Partner_Account__c = null" --target-org <alias>
```

### 3c. Opportunity

```
# Account lookup: must be 0. An Opportunity with no Account is orphaned.
sf data query -q "SELECT COUNT() FROM Opportunity WHERE LDGCRM_External_ID__c != null AND AccountId = null" --target-org <alias>

# Revenue: expect a large positive number of non-zero fully-ramped values.
# NOTE: this is the formula field, NOT Amount - the migration never writes Amount, so 0 there is correct.
sf data query -q "SELECT COUNT() FROM Opportunity WHERE LDGCRM_External_ID__c != null AND LDGCRM_Est_Annual_Revenue_fully_ramped__c > 0" --target-org <alias>

# Record type: every migrated Opportunity must be Login_gov, never TTS_OTCRM_Opportunity.
sf data query -q "SELECT RecordType.DeveloperName, COUNT(Id) FROM Opportunity WHERE LDGCRM_External_ID__c != null GROUP BY RecordType.DeveloperName" --target-org <alias> --result-format csv
```

### 3d. Contact and the junctions

```
# Record types: expect only Federal and GSA. Anything else means a wrong record type was assigned.
sf data query -q "SELECT RecordType.DeveloperName, COUNT(Id) FROM Contact WHERE LDGCRM_External_ID__c != null GROUP BY RecordType.DeveloperName" --target-org <alias> --result-format csv

# Partner Portal Admin flags - note the TRANSPOSED prefix LGDCRM_, it is not a typo here.
sf data query -q "SELECT COUNT() FROM LDGCRM_Application_Contact__c WHERE LGDCRM_P3_Partner_Portal_Admin__c = true" --target-org <alias>

# No contact should be named after a role inbox - that means the splitter fabricated a person.
sf data query -q "SELECT Id, FirstName, LastName, Email FROM Contact WHERE LDGCRM_External_ID__c != null AND (LastName LIKE '%helpdesk%' OR LastName LIKE '%support%')" --target-org <alias> --result-format csv
```

### 3e. Nothing was created that should not have been

```
# Meetings are not migrated. Both must be 0.
sf data query -q "SELECT COUNT() FROM Event WHERE LDGCRM_External_ID__c != null" --target-org <alias>
sf data query -q "SELECT COUNT() FROM Task  WHERE LDGCRM_External_ID__c != null" --target-org <alias>
```

ℹ️ **There is no equivalent check for `Lead`.** It has no `LDGCRM_External_ID__c` field, so the query
older versions of this checklist listed would simply error. The migration never writes Lead at all —
there is nothing to verify, not a check that was forgotten.

---

## 4. Fixes in flight — did the thing we fixed actually land?

**The second purpose of this document.** When something is fixed at source, this is where you confirm
it reached Salesforce, then **delete the row** — a fix that has landed is not a check.

### Currently in flight: 11 Airtable Account fixes

Sent to the data owners on 2026-08-15 — 9 merges, one wrong `Parent`, one rename. Full list in
`AIRTABLE-DATA-QUALITY-REQUESTS.md` §1.

| After the fixes land, expect | Check |
| --- | --- |
| Airtable Accounts **down by 11 rows** | the pull count drops from 731 |
| Unplaced Accounts **down**, and no new ones | `Account-reconciliation-unmatched-*.csv` + `…-ambiguous-*.csv` |
| `DUPLICATE AIRTABLE ROW` findings **down to 0** | `SUMMARY.txt` section 4 |
| Records previously stranded on the losing rows now load | Opportunity / Application / Contact counts up |

⚠️ **One of these needs a Salesforce-side action first, and Airtable alone will not release it.** The
Department of Justice `Environment and Natural Resources Division` Account carries
`LDGCRM_External_ID__c = recOTuuxYnWwBq9Fs` — the USDA row that wrongly claimed it. Reconciliation
matches external ID **before** name, so **clear that value** or the correct DOJ row stays locked out
however the Airtable merge goes.

```
sf data query -q "SELECT Id, Name, LDGCRM_External_ID__c FROM Account WHERE LDGCRM_External_ID__c = 'recOTuuxYnWwBq9Fs'" --target-org <alias>
```

### The general shape

For any fix: name the object, the count you expect to move, and the direction. If you cannot say what
number should change, the fix is not verifiable and the claim it landed is not either.

---

## 5. Sign-off

| Item | Expected | Actual | ✓ |
| --- | --- | --- | --- |
| Environment confirmed by the script banner | | | |
| Rahul coordination confirmed | yes | | |
| `SUMMARY.txt` — unexpected failures | **0** | | |
| `SUMMARY.txt` — post-load validation problems | **0** | | |
| Every reconciliation row explained | yes | | |
| Withheld counts flat or down vs last run | yes | | |
| Market Segment blank on PA / Opp / App | **0 / 0 / 0** | | |
| Applications with no Launch Level | **0** | | |
| Applications with no parent Partner Account | **0** | | |
| Applications holding literal `#N/A` | **0** | | |
| Opportunities with no Account | **0** | | |
| Opportunity record types | `Login_gov` only | | |
| Contact record types | `Federal` + `GSA` only | | |
| Event / Task created | **0 / 0** | | |
| Partner Portal Admin flags | large, non-zero | | |
| Partner Portal Team UUID populated | large, non-zero | | |

---

## Open items this reload will not close

- ⚠️ **The current baseline is a stitched sequence of three partial runs, not one pass.** The load
  halted, was resumed, and two steps were re-run afterwards. Every number is real, but it is **not a
  defensible end-to-end baseline** — establish one on the next clean factory-reset-and-reload before
  quoting figures to anyone.
- ⚠️ **`LDGCRM_application__c` dropped 1,045 → 1,033 and it is not explained.** It moved while every
  parent object improved, which is the shape of a regression rather than data movement. **Diagnose
  before re-baselining it away.**
- **Unplaced Airtable Accounts** — **resolved.** 690 of 719 rows match and 9 are created by the load;
  the remaining 20 carry no Opportunities, Partner Accounts or Applications and cost nothing. Two
  needed a manual tag — see the re-tagging step above, which you must not skip.
- **Meetings** — deferred by decision, blocked on an Einstein Activity Capture spike.
- **Opportunity owners that do not resolve** land on the fallback owner. Pre-flight reports who,
  before a Full or Prod run.
- **`LDGCRM_Broker_App_Parent__c`** — a handful of self-referential links stay unloaded.
- **Contact ownership** — inheriting the Account's owner puts ~92% of Contacts under a service
  account. Open decision, see `BACKLOG.md`.
