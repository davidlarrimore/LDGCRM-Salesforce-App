# Salesforce Account cleanup — for the GSA Salesforce team

**Audience:** whoever owns Account data in the production org (`gsa-peo`).
**When:** sections 1–5 **after** the production migration. **Section 6 is different** — 81 Accounts
cannot be saved by anyone, by any means, until it is worked. It halted the UAT run of 2026-08-24; the
pipeline now works around it and completes, at a measured cost of 10 Accounts and 19 child records
per run. Not a blocker any more, but the highest-value item here.
**What it is not:** an Airtable ask. Every item below is a defect in **Salesforce**, and the Airtable
data for each is correct.

> **This document holds only what is still open.** Delete an item once it is resolved — do not strike
> it through or mark it done. Git carries the history.

## Where these came from

Measured from the production Account export
(`peo-prod-accounts-2026-07-16.xls`, **1,369 Accounts**) using the migration's own name-matching
helpers, not by eye. Re-measure against a fresh export before acting — these are counts from July
2026.

The migration works around all of it, so **none of this is urgent**. It is listed because the
workarounds are fragile, and because duplicate Accounts cause the same trouble for reporting and for
anyone using the org by hand.

## ⚠️ Two things NOT to conclude from this data

**1. Last Modified Date tells you nothing.** **1,208 of 1,369 Accounts (88%) show `12/10/2024`.**
Some mass update touched almost the whole object, so "which copy was modified more recently" cannot
identify the survivor. An earlier draft of the migration notes used it as evidence; that was wrong.

**2. `Level 3 or below` does NOT mean "duplicate".** It is a legacy `Account_Level__c` value on **40
of 1,369** Accounts, and it means the record was **missed by whatever levelling exercise set the
others** — nothing more. It happens to sit on the stale copy in many pairs below, which makes it a
useful *hint*, but plenty of legitimate, non-duplicate offices carry it too. **Never delete a record
because it carries this value.**

## 1. Confirmed duplicates — the same body recorded twice

**10 names, 21 records.** Each is either self-parented, or two records with the **same name and the
same parent**, or confirmed against the public record. These are the safe ones.

⚠️ **Merge, do not blind-delete.** At least two of these have their activity on the copy that looks
stale — see the warnings inline.

| Name | Keep | Remove / merge away | Why it is certain |
| --- | --- | --- | --- |
| **AmeriCorps** | `0013d00000Bfmup` — Level 1, top level | `0013d00000Bfm3D` — under Department of Labor | AmeriCorps is an [independent federal agency](https://en.wikipedia.org/wiki/AmeriCorps); it is not part of Labor. Its funding merely runs through the Labor-HHS-ED appropriations act. |
| **Millennium Challenge Corporation** | `0013d00000BjNj1` — Level 1, top level | `0013d00000BPxAA` — under Department of State | MCC is *"an independent agency [separate from the State Department](https://en.wikipedia.org/wiki/Millennium_Challenge_Corporation) and USAID"*. The Secretary of State chairs its board, which is governance, not parentage. |
| **Department of Defense** | `001t000000r9YNi` — Level 1, top level | `0013d00000B9d16` — **parented to itself** | A record cannot be its own child. |
| **Office of the Director of National Intelligence** | `0013d00000BjNCy` — Level 1, top level | `0013d00000BF50l` — **parented to itself** | Same. |
| **District of Columbia** *(3 copies)* | `0013d00000Bjqlh` — Level 1, top level, has activity | `0013d00000BYxTm` (top level) and `0013d00000BZ1nr` (**parented to itself**) | Three records for one jurisdiction; one is self-parented. |
| **Defense Human Resources Activity** | `001SJ00000HVk8i` — Level 3 | `0013d00000BnfII` | Same name, **same parent** (Under Secretary of Defense Personnel and Readiness). |
| **Federal Voting Assistance Program** | `001SJ00000HVcxv` — Level 2 | `0013d00000DmbzX` | Same name, **same parent** (Department of Defense). |
| **Government Accountability Office** | `001t000000r9YMa` | `0013d00000Bjqjd` | Same name, **same parent** (U.S. Congress), both Level 2. Neither carries the legacy value — pick on related records. |
| **National Weather Service** | ⚠️ **decide** — `001SJ00000HVqjo` is Level 3; `001SJ00000CEZtS` has the **activity (11/5/2024)** | the other | Same name, **same parent** (NOAA). **The tidier record is not the used one.** Merge. |
| **Office of Administration** | ⚠️ **decide** — `0013d00000C8sER` has the **activity (10/26/2023)** | `0013d00000Bjqmf` | Same name, **same parent** (President Personnel Office), both Level 2. |

## 2. Ampersand vs "and" — duplicates hiding behind punctuation

**5 pairs.** Identical names once `&` is read as `and`, **under the same parent**. These do not show
up in a duplicate-name report that compares strings literally, which is likely why they survived.

| Parent | The pair |
| --- | --- |
| Environmental Protection Agency | `Office of Research & Development` `0013d00000Bjqik` / `Office of Research and Development` `001SJ00000HVpFK` |
| Small Business Administration | `Office of Communications & Public Liaison` `0013d00000Bjql8` / `…and…` `001SJ00000HVpEK` |
| Small Business Administration | `Office of Congressional & Legislative Affairs` `0013d00000Bjql9` / `…and…` `001SJ00000HVpEN` |
| General Services Administration | `Office of Congressional & Intergovernmental Affairs` `001SJ00000HVpEM` / `…and…` `0013d00000BjqjN` |
| *(Executive Office of the President, recorded two ways)* | `Office of Management & Budget` `0013d00000Bjqmg` under **President Personnel Office** / `Office of Management and Budget` `001SJ00000HVpF3` under **Executive Office of the President** |

The OMB pair is worth a second look: the two copies disagree about the parent's *name* as well
(`President Personnel Office` vs `Executive Office of the President`), so resolving it may mean
fixing a parent Account too.

### The punctuation duplicate that must be left alone

| | |
| --- | --- |
| `U.S. International Trade Commission` | `0013d00000BjNja` — Level 1, **correct** |
| `U.S International Trade Commission` | `0013d00000BJ1pR` — Level 3 or below, missing a full stop |

Delete or merge the second **only**. ⚠️ **Do not "fix" its name to match the first.** The migration
matches the Airtable row to the correct record character-for-character; making the two names
*identical* would make the pair ambiguous and strand **14 records**. Either remove the bad record or
leave it exactly as it is.

## 3. Probably the same body filed at two depths — needs an org-chart decision

**4 names, 8 records.** Both copies plausibly describe one organisation, but confirming that is a
judgement about the real org chart, so nothing here is safe to merge on the data alone.

| Name | The two records | The question |
| --- | --- | --- |
| **National Geospatial-Intelligence Agency** | `001SJ00000HVcyP` under Department of Defense / `0013d00000Bnf59` under Defense Intelligence Agency | NGA is a DoD combat support agency. Is the DIA parentage simply wrong? |
| **U.S. Army Futures Command** | `001SJ00000HVcqU` under Department of the Army / `0013d00000B8gtm` under Department of Defense | AFC is an Army command, so the Army record is likely correct and the DoD one a stray. |
| **Under Secretary of Defense for Research and Engineering** | `0013d00000Bjqk3` under Department of Defense / `0013d00000BC2Jo` under Office of the Secretary of Defense | USD(R&E) sits within OSD. **This pair actively costs us something** — see "Impact" below. |
| **City of Tallahassee** | `001SJ00000HVPDO` top level / `0013d00000EEv8n` under State of Florida | Here the *nested* record is probably the right one — a city belongs under its state. **Opposite of the AmeriCorps case**, which is why it is in this section and not the first. |

## 4. Generic office names that are NOT duplicates — do not merge these

**8 names, 19 records.** Different agencies genuinely have offices of the same name. Listed so that a
duplicate-name report does not send someone merging them.

| Name | Copies | Agencies |
| --- | --- | --- |
| Office of the Inspector General | 4 | OPM, Social Security Administration, Transportation, Defense |
| Office of the Director | 3 | OPM, National Science Foundation, CDC |
| Departmental Management | 2 | Justice, Education |
| Headquarters | 2 | NASA, Homeland Security |
| Office of Communications | 2 | OPM, NASA |
| Office of Congressional and Intergovernmental Affairs | 2 | GSA, Labor *(the GSA pair in §2 is separate)* |
| Office of the Administrator | 2 | EPA, Centers for Medicare & Medicaid Services |
| Office of the Deputy Secretary | 2 | Labor, Housing and Urban Development |

Also legitimately distinct despite near-identical names: `Office of Diversity, Inclusion and Civil
Rights` (Interior, `001SJ00000HVpEV`) and `Office of Diversity, Inclusion, and Civil Rights` (SBA,
`0013d00000BjqlC`) — one comma apart, two different agencies.

## 5. Legacy `Account_Level__c` value — 40 records

40 Accounts carry **`Level 3 or below`**, a value which is **not assigned to the `Federal` record
type**. Any process that writes it back will fail those rows.

It is no longer harmless. Two live validation rules read `Account_Level__c` (see section 6), and
this value satisfies neither — so it is the single field behind every record in that section. Worth
normalising while the duplicates are being worked, since the two overlap heavily — 16 of the 40 sit
on a name that another Account also bears.

## 6. ⚠️ 81 Accounts that nobody can save — the highest-value item here

**Everything else in this document costs the migration nothing. This one costs records every run.**
Two validation rules on Account are live, both correct, and neither reads a field this migration
writes:

| Rule | Requires |
| --- | --- |
| `OTCRM_Federal_Parent_Account_Level_Check` | a `Level 2` Account's parent is `Level 1`, a `Level 3`'s is `Level 2`, a `Level 4+`'s is `Level 3` |
| `Parent_Account_Required_for_Level_3_Acct` | an Account marked `Level 3 or below` has a parent |

Salesforce re-runs every validation rule on **every** save, so an Account whose *existing* hierarchy
breaks a rule rejects **any** edit — from this pipeline, from Data Loader, or from a person in the
UI. **81 Federal Accounts are in that state** (73 on the first rule, 8 on the second). It stopped the
UAT migration run of 2026-08-24 dead, rejecting 20 updates on `ParentId` without `ParentId` ever
being sent.

**Almost all of it is two records.** The children are fine; their parent is a duplicate carrying the
wrong level:

| The parent at fault | Its level | Should be | Children it makes unsaveable |
| --- | --- | --- | --- |
| `Department of Defense` (`0013d00000B9d16`) | `Level 3 or below`, **and it is its own parent** | `Level 1` — a sound twin already exists at `001t000000r9YNi` | **62** |
| `President Personnel Office` (`001t000000r9YMd`) | `Level 2` | see below — no twin exists | 7 |
| `District of Columbia` (`0013d00000BYxTm`) | `Level 3 or below` | sound twin at `0013d00000Bjqlh` | 2 |
| `Office of the Director of National Intelligence` (`0013d00000BF50l`) | `Level 3 or below`, self-parented | sound twin at `0013d00000BjNCy` | 1 |
| `Defense Human Resources Activity` (`0013d00000BnfII`) | `Level 3 or below` | sound twin at `001SJ00000HVk8i` | 1 |

**The migration now repairs 66 of the 81 itself.** `Build-AccountParentRepair.ps1` repoints a child
onto the sound twin of its parent wherever one exists, and reports the rest. That is a workaround, not
a fix: **the duplicate parents are still there**, and merging them is what actually resolves this.

**The other 15 are accepted rather than repaired, so the migration completes** (project owner,
2026-08-24). They are matched by name in the Account step's `ExpectedFailures`, so Salesforce still
rejects them, the run still reports them, and it no longer halts. **This is the only reason the
pipeline runs at all today**, and it is why this section is urgent rather than post-migration
housekeeping.

What that costs, per run, until the records are corrected — measured, not estimated:

| | |
| --- | --- |
| Accounts left untagged | **10** of the 15 (the other 5 are not matched to an Airtable row, so nothing asks for them) |
| Opportunities withheld | **9** — their Account never gets its external ID |
| Meetings withheld | **10** |
| Partner Accounts withheld | **0** — none hang off these, so there is no Master-Detail cascade |
| Contacts withheld | **0** |

**Nothing is lost permanently.** Every one of those rows loads on a plain re-run once the Accounts
below are fixed — no code change, no manual tagging. And the acceptance is bounded: the run still
halts if these failures ever exceed the step's allowance (35 of 690 rows), so this cannot quietly
grow.

### The 15 the pipeline will not guess at

- **7 under `President Personnel Office`** — `White House`, `Office of Management and Budget`,
  `Office of the Vice President`, `Office of Policy Development`,
  `Information Technology Oversight and Reform` and two more. There is only **one** PPO record, so
  there is no twin to repoint to. This looks like a genuine mis-filing rather than a duplicate: PPO
  is itself `Level 2` under `Executive Office of the President`, so either these children should be
  `Level 3`, or they should hang off `Executive Office of the President` directly. **An org-chart
  decision, not a data fix** — the migration deliberately changes nothing here.
- **8 marked `Level 3 or below` with no parent at all** — `Administrative Office of the U.S. Courts`,
  `Center for Analytics`, `District of Columbia`, `National Center for Injury Prevention and Control
  (Injury Center)`, `Office of Federal Financial Management`, `Office of the Assistant Secretary of
  the Navy (Financial Management & Comptroller)`, `U.S International Trade Commission`,
  `US Tax Court`. Each needs either a parent choosing or relabelling to `Level 1`.

## Impact on the migration

Small, and fully worked around today — but the workarounds are the fragile part.

| Item | Effect |
| --- | --- |
| AmeriCorps + MCC duplicates | **5 records** would not migrate. Worked around by tagging the correct Account **by hand**, which a sandbox rebuild silently undoes — see `scripts/docs/RELOAD-QA-CHECKLIST.md`. **Resolving the duplicates removes the need for the manual step entirely.** |
| `Under Secretary of Defense for Research and Engineering` duplicate | `Defense Technical Information Center` cannot be parented — its parent name is ambiguous, so the bootstrap refuses to guess and leaves it top level. |
| Every other duplicate above | No records lost. The migration matches on parent as well as name, so same-named Accounts under different agencies resolve correctly. |
| **Section 6 — the 81 unsaveable Accounts** | **Halted the UAT run of 2026-08-24 outright.** Now worked around twice over: `Build-AccountParentRepair.ps1` repoints 66 onto the sound twin of their parent, and the Account step *accepts* the remaining 15 as classified failures so the run completes. Cost per run: **10 Accounts untagged, 9 Opportunities and 10 Meetings withheld**, all recovered by a re-run. These are the two most fragile workarounds in this document — one writes `ParentId` on records this migration did not create, the other tolerates a failure on purpose. **Fixing the Accounts retires both.** |
