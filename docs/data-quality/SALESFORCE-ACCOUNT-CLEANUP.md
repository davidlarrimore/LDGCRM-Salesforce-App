# Salesforce Account cleanup — for the GSA Salesforce team

**Audience:** whoever owns Account data in the production org (`gsa-peo`).
**When:** **after** the production migration, not before. Nothing here blocks the migration.
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

40 Accounts carry **`Level 3 or below`**, a value the migration does not use and which is **not
assigned to the `Federal` record type**. Any process that writes it back will fail those rows.

The migration derives `Account_Level__c` from the record's actual depth and never reads this value,
so it costs nothing today. Worth normalising while the duplicates are being worked, since the two
overlap heavily — 16 of the 40 sit on a name that another Account also bears.

## Impact on the migration

Small, and fully worked around today — but the workarounds are the fragile part.

| Item | Effect |
| --- | --- |
| AmeriCorps + MCC duplicates | **5 records** would not migrate. Worked around by tagging the correct Account **by hand**, which a sandbox rebuild silently undoes — see `scripts/docs/RELOAD-QA-CHECKLIST.md`. **Resolving the duplicates removes the need for the manual step entirely.** |
| `Under Secretary of Defense for Research and Engineering` duplicate | `Defense Technical Information Center` cannot be parented — its parent name is ambiguous, so the bootstrap refuses to guess and leaves it top level. |
| Every other duplicate above | No records lost. The migration matches on parent as well as name, so same-named Accounts under different agencies resolve correctly. |
