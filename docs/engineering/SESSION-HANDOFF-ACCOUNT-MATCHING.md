# Session handoff — Account matching and creation

> **Temporary working file.** Delete it once the work below lands. It exists so a
> new session can pick up mid-stream without re-deriving anything.
>
> **Current as of 2026-08-16 morning.** Everything here was measured, not assumed.

## Where the Account workstream stands

**The Airtable side is DONE.** Nothing further is needed from the data owners.
Every remaining item is ours.

| | |
| --- | --- |
| Airtable Account rows | **719** |
| Matched | **682** |
| Unmatched | 16 |
| Ambiguous | 22 |
| Unresolved rows carrying **no** Opportunities / Partner Accounts / Applications | **31 — ignored by rule** |
| Unresolved rows carrying real records | **7** |

### The standing rule that shrank this

**Project owner, 2026-08-16: a row carrying no Opportunities, Partner Accounts or
Applications does not need matching.** Contacts and Meetings reach Salesforce
*through* those, so a row carrying only them costs nothing on its own. That took
the actionable pile from 36 review items to 7.

### The 7 that remain, all ours

| Airtable row | Records | What it needs |
| --- | --- | --- |
| `U.S. International Trade Commission` | 14 | **Merge the duplicate Salesforce Account** — `U.S International Trade Commission` (`001cq00000V5xQWAAZ`, missing a full stop) into `U.S. International Trade Commission` (`001cq00000V5xQRAAZ`). Both normalise identically, so the matcher correctly refuses to guess. Airtable is already clean — the duplicate row was deleted and its meeting moved. |
| `Conflict & Stabilization Operations` | 1 | Present in the production export, **missing from Dev**. Airtable is correct. Fix Dev's bootstrap. |
| `Office to Monitor and Combat Trafficking in Persons` | 1 | Same. |
| `DC Pre-trial Services` | 1 | Genuinely new — create |
| `Conference of State Bank Supervisors` | 1 | Genuinely new — create |
| `Federal Judiciary` | 1 | Genuinely new — create |
| `U.S. Digital Service` | 1 | Genuinely new — create |

## State of the org

**Dev (`peodv8dvn`) was factory-reset and re-bootstrapped 2026-08-15 22:20.**

- 817 records hard-deleted; **1,352 Accounts** rebuilt, 1,087 parented.
- **0 external IDs on Account** — orphaned tags and the seven wrong links are gone.
- `Account_Level__c` populated on **1,352 of 1,352**, zero mismatches against depth.
- Every other object is EMPTY. Only Account and the bootstrap have run.

## What was built

| File | |
| --- | --- |
| `scripts/powershell-scripts/Common.AccountMatching.ps1` | **NEW.** The shared matching cascade, agency resolution, depth→level ladder, market-segment map |
| `scripts/powershell-scripts/Build-AccountCreationLoad.ps1` | **NEW.** Creates Accounts Airtable needs that the org lacks. `-PlanOnly` reports without writing a load file |
| `tools/Test-AccountMatching.ps1` | **NEW.** 36 unit tests. Skips the cascade cases if the production export is absent |
| `scripts/powershell-scripts/Build-AccountReconciliation.ps1` | Rewritten onto the shared resolver |
| `scripts/powershell-scripts/Invoke-AccountBootstrap.ps1` | Sets `Account_Level__c` on insert, plus a backfill pass |
| `scripts/powershell-scripts/Invoke-FullMigrationLoad.ps1` | New `AccountCreate` step, **before** `Account` |

## Decisions taken, so they are not re-litigated

1. **Parent is a VETO, not a tie-breaker.** Only the named agency's subtree is a
   candidate. Seven Accounts were previously linked to the wrong agency's office.
2. **Agency names are resolved, not looked up verbatim** — "The Executive Office of
   the President" against "Executive Office of the President", "Army" against
   "Department of the Army". 51 rows previously lost their subtree entirely.
3. **Exactly one top-level Account of exactly this name is accepted** as the same
   body filed at a different depth. This matches 55 states and territories.
4. **A strong name match (>=85) anywhere in the org is NEVER an automatic create.**
   Caught six Commerce duplicates, then `Amtrak` and `Senate`.
5. **`Account_Level__c` derives from DEPTH**, never from the parent's own value or
   the export — the export's legacy `Level 3 or below` is not assigned to the
   `Federal` record type and would fail 40 rows.
6. **Name new Accounts the way the org already does** — bare name, or the agency
   suffix where the bare name is taken. The suffix map is learned from production.

## Traps already hit — do not re-discover

- **The index must be IMMUTABLE.** Claiming is tracked separately and filtered at
  the point of use. Removing claimed records broke the hierarchy and cost 11
  regressions: an agency is still an agency after its own row has claimed it.
- **Cache `LdgcrmLoose` / `LdgcrmTokens` / `LdgcrmKey` on each record.** Deriving
  them per row took the reconciliation from ~90s to over five minutes.
- **Airtable column names are not what you would guess.** The Opportunities table
  uses `Opportunity Name`, not `Name`, and `Est. Annual Revenue (fully ramped)`.
  Contacts have NO `Accounts Record ID` — they carry `Partner Account Record ID`
  and reach the Account through it. Both mistakes produced confident, wrong
  answers (904 of 904 "blank" Opportunities; zero Contacts everywhere).
  **A 100%-of-population result is a field-name bug, not a finding.**
- **Never redirect `sf` stderr** (`2>&1`, `2>$null`) — PS 5.1 turns the update
  banner into a terminating error.
- **Sort run directories on the trailing timestamp, not the folder name.**

## ⚠️ Open: Dev is missing ~17 Accounts the production export has

The bootstrap did not rebuild them — two passes returned an unreadable Bulk
result, and the ambiguous-hierarchy repair was never applied (21 records to
remove, 31 to recreate, all verified inert).

**This makes the create list org-specific.** Two of the four "genuinely new"
Accounts above are only new *in Dev*. Regenerate the list against the target org;
never carry it across.

## Nothing has been loaded

Every run so far is read-only or `-PlanOnly`. The `AccountCreate` step is wired
into the orchestrator but has **never run live**.

## Suggested next steps

1. Merge the duplicate ITC Account in Salesforce — unblocks 14 records.
2. Finish Dev's bootstrap so the two State bureaus stop looking absent.
3. Re-run `Build-AccountCreationLoad.ps1 -PlanOnly`, confirm the create list, load it.
4. Run the reconciliation load, then the full migration.
