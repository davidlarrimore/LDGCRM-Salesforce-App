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
pass `--target-org` by hand.** Queries below use `<alias>`; substitute the one you are actually
verifying.

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
.\powershell-scripts\Invoke-FullMigrationLoad.ps1   -Environment Dev -Confirmation "LOAD"
```

> **No manual Account tagging.** Until 2026-08-17 this procedure required tagging `AmeriCorps`,
> `Millennium Challenge Corporation` and `U.S. Army Futures Command` by hand between the reset and
> the load, because the matcher refused to choose between same-named Accounts. It now resolves them
> itself — see "Duplicate Account names" in `TRANSFORMATION-RULES.md`. Verified by a reset-and-load
> with no intervention: **9,220 of 9,220 rows, 0 failures**, matching QA on every object.

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

| Airtable table | → Salesforce object | Relationship | Measured 2026-08-16 |
| --- | --- | --- | --- |
| Accounts | Account *(tagged)* | **Not 1:1.** Reconciled onto existing Accounts, never created. Gap = unplaced Accounts | 719 → 700 |
| Partner Accounts | `LDGCRM_Partner_Account__c` | ≈1:1. Gap = parent Account unreconciled | 99 → 99 |
| Contacts **+ Opportunity Contacts** | Contact | **Two tables in, merged on email.** Expect *more* than the Contacts export | 1,514 + 520 → 1,918 |
| Opportunities | Opportunity | ≈1:1. Gap = Account unreconciled, or no Status | 904 → 904 |
| Applications | `LDGCRM_application__c` | ≈1:1. Gap = parent Partner Account missing | 1,058 → 1,052 |
| Impediments | `LDGCRM_Impediment__c` | 1:1 **minus the `None` placeholder**, excluded by rule | 38 → 37 |
| Impediments × Opportunities | `LDGCRM_Opportunity_Impediment__c` | One row per pair, `None` links excluded | — → 311 |
| Applications × Contacts | `LDGCRM_Application_Contact__c` | One row per pair, composite key | — → 2,793 |
| Opportunity Contacts | `OpportunityContactRole` | **Insert + read-then-diff**, never upsert | 520 → 596 |
| *(freeform columns)* | `ContentNote` | Built last, from columns with no field | — → 737 |
| Market Segments | `LDGCRM_Market_Segment__c` | Keyed on **name**, not `rec…` | 7 → 5 |
| Meetings | *(not migrated)* | Deferred by decision — see `BACKLOG.md` | 1,849 → 0 |
| Issuer Strings | *(no object)* | Collapses onto Application's portal-team fields | 907 → n/a |

> **Where these figures come from.** The Airtable side is measured from the 2026-08-16 pull. The
> Salesforce side is the org **immediately before** the reset that precedes this reload — genuinely
> measured, and materially better than the figures it replaced (Opportunity was 887, Application
> 1,033, Partner Account 96), but it is the *stitched* state described under "Open items", not a
> clean end-to-end run. **Re-stamp it from your own `SUMMARY.txt` when this reload finishes.**

### ⚠️ One row is anchored and the rest drift — know which before you call a change a regression

**Account is the stable one, and not for the reason it looks like.** It is rebuilt from a fixed
**production export** (`data/prod-accounts/`, 1,342 rows), so its row count is reproducible across
rebuilds and comparable across orgs. A moved Account count means the export changed or the bootstrap
lost rows — both worth chasing.

**What actually differs between Dev, QA and Full is ownership, not row count.** The bootstrap *does*
set `OwnerId`, from the export's `Account Owner` display name, but only where that name resolves to a
single **active** user in the target org. Every org has a different user population, so the same
export produces different owners. Dev today: **760** Accounts owned by the operator who ran the
bootstrap and **583** by `SystemUser DataLoader` — an artefact of this org, nothing like production's
distribution. That cascades: Contact inherits its Account's owner, which is why **1,750 of 1,918**
migrated Contacts sit under `SystemUser DataLoader` here. **Do not read Dev or QA ownership as a
preview of production**, and do not treat a Dev/QA ownership difference as a defect.

**Every Airtable-sourced row above will move before go-live, and that is normal.** Opportunity,
Partner Account, Application, Application–Contact, Contact and Impediment all come from a base that
is **still in daily operational use**. These counts are a snapshot, not a target. The figures above
held steady across 2026-08-15/16 only because the data owners do not work weekends — expect them to
drift again on the next working day.

So the check is **not** "does the number match the table". It is:

1. Does the Airtable side match the pull you just took? *(re-measure it, do not trust this table)*
2. Is the gap between the two sides explained by section 2's withheld reasons?
3. Did anything move **down** without a corresponding Airtable change? That is the regression shape.

A count that rose because someone added Opportunities on Monday is the pipeline working.

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

⚠️ **Do not mistake the run's own output for this check.** Post-load validation prints two lines that
look like it has already been done —

```
  Opportunity                            0 migrated record(s) with no Market Segment
  LDGCRM_application__c                  0 migrated record(s) with no Market Segment
```

— but those are **reported, not enforced**: a non-zero value there does *not* add a problem and does
*not* fail the run. They also cover only two of the three objects; **`LDGCRM_Partner_Account__c` is
not printed at all.** Run all three queries above yourself. This is the exact check that would have
caught the 2026-08-14 QA load, so it is the wrong one to delegate to a line you skimmed.

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

### Nothing Account-shaped is currently in flight

The 11 Airtable Account fixes tracked here (9 merges, a wrong `Parent`, a rename) **have landed**, and
the Salesforce-side unlock that went with them is done too — the Department of Justice
`Environment and Natural Resources Division` Account no longer carries the USDA row's
`LDGCRM_External_ID__c`. Verified 2026-08-16: the Airtable Accounts pull is **719** (was 731), and
`AIRTABLE-DATA-QUALITY-REQUESTS.md` reports no open Airtable asks against Accounts.

You should therefore see the *result* of those fixes in this reload rather than checking for their
arrival: Opportunity, Application and Partner Account all reconcile higher than the figures this
document previously carried, which is what those merges were for.

One small non-Account ask remains open and costs 2 records — `CLEAR` is not an identity-platform
picklist value. It is in `AIRTABLE-DATA-QUALITY-REQUESTS.md` and does not block a reload.

Two Opportunity expectations to confirm on this reload:

| Check | Expected |
| --- | --- |
| `Demographic tags dropped (unmapped)` | **0** |
| `Identity platform tags dropped (unmapped)` | **2** — the two `CLEAR` tags, and nothing else |

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

- ⚠️ **The baseline in section 1 is still a stitched sequence, not one pass.** The load halted, was
  resumed, and steps were re-run afterwards. Every number is real, but it is **not a defensible
  end-to-end baseline.** This reload is how that gets fixed: stamp section 1 from your own
  `SUMMARY.txt` when it finishes, and this bullet can go.
- **Meetings** — deferred by decision, blocked on an Einstein Activity Capture spike.
- **Opportunity owners that do not resolve** land on the fallback owner. Pre-flight reports who,
  before a Full or Prod run.
- **`LDGCRM_Broker_App_Parent__c`** — a handful of self-referential links stay unloaded.
- **Contact ownership** — inheriting the Account's owner puts ~92% of Contacts under a service
  account. Open decision, see `BACKLOG.md`.
