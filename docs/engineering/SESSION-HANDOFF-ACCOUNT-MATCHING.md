# Session handoff — Account matching and creation

> **Temporary working file.** Delete it once the work below lands. It exists so a
> new session can pick up mid-stream without re-deriving anything.
>
> **Current as of 2026-08-16, after the first full Dev load.** Everything here
> was measured, not assumed.

## Where the Account workstream stands

**The Airtable side is DONE.** Nothing further is needed from the data owners.

**Dev has been loaded end to end.** 9,194 records, 1 expected failure, 0
unexpected. See "The load" below.

| | |
| --- | --- |
| Airtable Account rows | **719** |
| Matched onto an existing Account | **690** |
| Created by `AccountCreate` | **9** |
| Left for a human | **20 — of which 18 cost nothing** |
| **Actually costing records** | **0** — the 2 that did are tagged, see below |

### The standing rule that shrank this

**Project owner, 2026-08-16: a row carrying no Opportunities, Partner Accounts or
Applications does not need matching.** Contacts and Meetings reach Salesforce
*through* those, so a row carrying only them costs nothing on its own.

**Score the rule on `Opportunities` + `Partner Agencies` only.** The Airtable
Accounts table also has a `Programs` column, and it is *not* Applications — those
IDs belong to a `Programs` table that no transform reads. Applications reach an
Account **through** its Partner Accounts, so counting `Partner Agencies` already
covers them.

⚠️ **`@($null)` has `.Count` of 1.** Airtable omits empty fields entirely, so
`@($rec.fields.Opportunities).Count` returns 1 for a row with no Opportunities
and silently overstates the whole population. Filter first:
`@($rec.fields.Opportunities | Where-Object { $_ })`. This produced a confident,
wrong answer once already this session — 19 of 20 review rows appeared to carry
records when they carry none.

## ⚠️ AmeriCorps and MCC — RESOLVED by a hand-applied tag that a reset UNDOES

**Closed 2026-08-16.** These were the only unresolved rows costing records. The
top-level Account is correct for both; they are tagged in Dev and the 5 records
load. Full reasoning, sources and the per-org procedure are in
`TRANSFORMATION-RULES.md`, "AmeriCorps and Millennium Challenge Corporation —
tagged by hand".

**This is a SALESFORCE defect, not an Airtable one.** Airtable holds exactly one
row for each, correctly filed with no parent. Salesforce production holds **two
Accounts of each name**, character-identical, the stale copy misfiled under
Department of Labor / Department of State. The real fix is a production data
cleanup that is not this pipeline's to make — see
`docs/data-quality/SALESFORCE-ACCOUNT-CLEANUP.md`.

**The cascade cannot resolve it**: a parentless Airtable row takes the "no agency
named" path, finds two exact-name hits, and returns `Confirm` *before* reaching
the top-level acceptance rule — so it never notices only one candidate is top
level.

⚠️ **THE TAG DOES NOT SURVIVE A FACTORY RESET.** The reset hard-deletes Accounts
carrying an external ID and the bootstrap recreates them untagged, silently
returning 5 records to "withheld" with no error anywhere.
**`scripts/docs/RELOAD-QA-CHECKLIST.md` carries the mandatory re-tagging step
between the reset and the load.** Ids are per-org and change every rebuild —
re-query, never paste.

**Do not re-decide this from the names.** The wrong record in each pair looks
plausible: AmeriCorps is funded through the Labor appropriations act, and the
Secretary of State chairs MCC's board. Both bodies are independent agencies.

**These duplicates were NOT introduced by `-RepairAmbiguousHierarchy`.** They are
in production. Dev previously held only one of each, so the matcher was matching
by luck and Dev was *hiding* a real production ambiguity; the repair made Dev
faithful to production and surfaced it. That is the repair working correctly, and
it is why the same break would otherwise have appeared for the first time in
Full or Prod.

## The load

`Invoke-FullMigrationLoad-20260816-094717`, Dev, 25 minutes.

| | |
| --- | --- |
| Loaded | **9,194** |
| Failed | **1** (expected — the AmeriCorps Partner Account above) |
| Unexpected failures | **0** |
| Withheld | 96 |
| Post-load validation | no problems |

**Market Segment was verified populated, not assumed.** 98/98 Partner Accounts,
901/901 Opportunities, 1,051/1,051 Applications, distributed across all five
segments. This is the check the 2026-08-14 QA run failed silently — it reported
8,740 records and 0 failures with Market Segment blank on every row, because the
Flows were inactive and flow activation changes field *contents*, not row counts.
**A row count cannot detect it. Query the field.**

Remaining withheld rows are Airtable data gaps, not pipeline faults: 41 Contacts
with no Account, 1 Application that is its own Broker App Parent, and the 6
decommissioned Applications below.

**The 6 Applications with no Partner Account are a SETTLED RULE, not an open
item** (project owner, 2026-08-16). All six are `Status = Decommissioned`, and
every *live* Application has its link — 0 missing across 757 Active, 100 Partner
Pause, 70 Not Active and every other status. The gap is 6 of 89 Decommissioned
rows. Cost: those 6 plus 16 Application-Contact junction rows, 15 of them from
`SPEARS Opportunity Portal`. Documented in TRANSFORMATION-RULES.md, "Decommissioned
Applications with no Partner Agreement". **Do not re-raise it as a data-quality
ask** — it was checked and closed.

## State of the org

**Dev (`peodv8dvn`), 2026-08-16.** Factory reset found the org already clean —
0 tagged records across all 10 objects. Bootstrapped with
`-RepairAmbiguousHierarchy`: 21 inert duplicates removed, 36 inserted.

- **1,367 Accounts**, 1,116 parented.
- `Account_Level__c` correct on **1,367 of 1,367**, zero mismatches against depth.
- `Defense Technical Information Center` is deliberately parentless: the export
  defines **two** Accounts named `Under Secretary of Defense for Research and
  Engineering`, so its parent is genuinely ambiguous in the source. Not a bug.

### ⚠️ Leave the duplicate ITC Account alone

The org holds **two** International Trade Commission Accounts:
`U.S. International Trade Commission` (`001cq00000V5xQRAAZ`) and
`U.S International Trade Commission` (`001cq00000V5xQWAAZ`, missing a full stop).
The project owner has no rights to delete the second, and it does not matter:
Airtable's row matches the correct one **character for character**, so the
duplicate is never tagged and nothing migrates into it. It sits inert.

**Do not "tidy" its name to match the good one.** They currently differ exactly
and are identical once punctuation is stripped; making them exactly equal would
put the row back into ambiguity and strand 14 records. `Test-AccountMatching.ps1`
pins this.

## Decisions taken, so they are not re-litigated

1. **Parent is a VETO, not a tie-breaker.** Only the named agency's subtree is a
   candidate. Seven Accounts were previously linked to the wrong agency's office.
2. **Agency names are resolved, not looked up verbatim** — "The Executive Office of
   the President" against "Executive Office of the President", "Army" against
   "Department of the Army". 51 rows previously lost their subtree entirely.
3. **Exactly one top-level Account of exactly this name is accepted** as the same
   body filed at a different depth. This matches 55 states and territories.
   *(See the AmeriCorps/MCC section — this rule does not currently fire when a
   nested Account shares the name.)*
4. **A strong name match (>=85) anywhere in the org is NEVER an automatic create.**
   Caught six Commerce duplicates, then `Amtrak` and `Senate`.
5. **`Account_Level__c` derives from DEPTH**, never from the parent's own value or
   the export — the export's legacy `Level 3 or below` is not assigned to the
   `Federal` record type and would fail 40 rows.
6. **Name new Accounts the way the org already does** — bare name, or the agency
   suffix where the bare name is taken. The suffix map is learned from production.

## ⚠️ The bootstrap can lose Accounts SILENTLY — always run it twice

**Found 2026-08-16 in QA, and it explains an earlier wrong conclusion.**
`Invoke-AccountBootstrap.ps1` submitted **590** distinct Accounts across three
passes; two passes returned a Bulk result the script could not parse, and
**589 landed**. `Office to Monitor and Combat Trafficking in Persons` vanished
with no error and the run exited 0.

The script's warning is honest — it says the insert count is a floor and refuses
to guess — but it **cannot name the missing rows**, so nothing surfaces them.

**This is what actually made Dev "short ~17 Accounts", not the production
export.** An earlier draft of this handoff blamed the export and named this exact
bureau as looking absent. Re-running the bootstrap inserted it with
`inserted 1, failed 0`, so the row was always valid.

**Always run the bootstrap a second time and confirm
`Planned Accounts missing (will insert)  0`.** It is idempotent and re-reads the
org first. `scripts/docs/RELOAD-QA-CHECKLIST.md` and `TROUBLESHOOTING.md` both
carry the step and a snippet for listing what is absent.

⚠️ **Never re-submit a pass CSV by hand** — bootstrapped Accounts carry no
external ID, so a second insert creates duplicates with nothing to dedupe on.

## ⚠️ A partial re-run must cover the steps that WITHHELD, not just the later ones

**Cost 16 records in Dev on 2026-08-16.** After tagging AmeriCorps and MCC the
load was resumed with `-OnlySteps PartnerAccount,…` — everything *below* Account.
That recovered the Opportunities, the Partner Account and the Application, but
**not the 8 Contacts the Contact step had withheld for the very same reason**,
nor the 8 junction rows beneath them. Dev and QA then disagreed on exactly those
three objects.

`SUMMARY.txt`'s ROWS WITHHELD section groups by reason. **Read it and pick the
steps whose withheld reason matches the thing you fixed** — step order is not the
criterion.

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
  **A 100%-of-population result is a field-name bug, not a finding** — unless the
  field is one a Flow sets on every row, where 100% is the *correct* answer and
  0% is the failure. Know which you are looking at.
- **Never redirect `sf` stderr** (`2>&1`, `2>$null`) — PS 5.1 turns the update
  banner into a terminating error. This also applies to
  `tools/Test-BundleStructure.ps1`, whose passing output *includes* expected
  parameter-binding rejections on stderr; redirecting them fails a passing test.
- **Sort run directories on the trailing timestamp, not the folder name.**
