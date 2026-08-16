# Account matching — every unplaced Airtable Account, and who fixes each

**Measured 2026-08-15** against a full Airtable pull (731 Accounts) and the production Account list
(1,369 rows, `peo-prod-accounts-2026-07-16.xls`).

**54 Airtable rows cannot be placed** — 47 match no Salesforce Account, 7 match more than one. They
hold back roughly 130 records across 6 objects, all of which return automatically once the Account
resolves.

| Workstream | Rows | Owner |
| --- | --- | --- |
| [A. Seed 28 external IDs](#a-seed-the-external-id--production-already-holds-the-account-salesforce-data) | 28 | Engineering |
| [B. Decide between two candidates](#b-decide-between-two-real-candidates-needs-a-human) | 5 | Salesforce config |
| [C. Create 5 new Accounts](#c-create-5-new-accounts-salesforce-config) | 5 | Salesforce config |
| [D. Set `ParentId` on same-named Accounts](#d-set-parentid-on-the-same-named-accounts-salesforce-data) | 4 | Engineering |
| [E. Airtable fixes](#e-airtable-fixes-data-owners) | 12 | **Airtable data owners** |

## The naming convention behind most of this

Production disambiguates same-named offices by **appending an agency suffix** — `Office of the
General Counsel - NRC`, `Office of Civil Rights - GSA`, `Human Resources - OPM`. Airtable stores the
**bare office name plus a `Parent` column**. Neither is wrong, and they will never match on name
alone.

That single pattern accounts for most of this list, and it is why the fix is nearly always **seed the
external ID**, never rename either side.

⚠️ **Searching production for the exact Airtable name is not enough.** `Office of the General Counsel`
under NRC exists as `Office of the General Counsel - NRC`; an exact-name search finds only the USDA
copy and concludes it is missing. Search the **descendants of the agency Airtable names as parent**,
not the whole export by name.

---

## A. Seed the external ID — production already holds the Account *(Salesforce data)*

Write `LDGCRM_External_ID__c` onto the named production Account once.
`Build-AccountReconciliation.ps1` matches external ID **before** name, so the binding is permanent
and survives either side being renamed later.

⚠️ **Key this file by NAME, not by Account Id.** Salesforce Ids differ per org, so an Id-keyed file
is correct in exactly one sandbox and silently wrong everywhere else.

| Airtable row | Airtable record ID | Production Account | Sits under |
| --- | --- | --- | --- |
| `Amtrak` | `recZk2Mvn4TtpYk0d` | `National Railroad Passenger Corporation (Amtrak)` | Federal Transit Administration |
| `Bureau of Consular Affairs` | `recGWTR7qF40UsPoY` | `Consular Affairs` | Under Secretary for Management |
| `Bureau of Global Talent Management` | `reca9eRg2LGY7Q58t` | `Global Talent Management Director General of Foreign Service & Director of Global Talent` | Under Secretary for Management |
| `Bureau of Overseas Building Operations` | `recfkbTRu97EXnqXk` | `Overseas Buildings Operations` | Under Secretary for Management |
| `Deputy Commissioner for Hearings Operations` | `recppnhXPNWEkkoZo` | `Hearings Operations` | Social Security Administration |
| `Deputy Commissioner for Human Resources` | `recYyhKXPDctqGn4Y` | `Human Resources - SSA` | Social Security Administration |
| `Director of Net Assessment` | `recwLfBOMCvwLG1km` | `Office of Net Assessment` | Department of Defense |
| `Directorate for Engineering` | `recI5YWyskcjT0B7V` | `Directorate of Engineering` | National Science Foundation |
| `Economic and Business Affairs` | `recqHR0cR8XENC4F8` | `Economic & Business Affairs` | Under Secretary for Economic Growth |
| `Federal Permitting Improvement Steering Council (FPISC)` | `recgzrImH83t4ojB7` | `Federal Permitting Improvement Steering Council` | *(top level — Airtable says GSA)* |
| `General Counsel of the Department of Defense` | `recuaDLV87HElihkl` | `Office Of The General Counsel - DOD` | Department of Defense |
| `GSA Board of Contract Appeals` | `recndDpeyjocdiZhZ` | `Civilian Board of Contract Appeals` | General Services Administration |
| `Human Resources` | `rec7hDwLVHGaN0Q9C` | `Human Resources - OPM` | Office of Personnel Management |
| `Interpol – Washington` | `recjuOinZo1lcygOP` | `INTERPOL Washington` | Department of Justice |
| `Office of Civil Rights` | `recZm3lohKstoGPkE` | `Office of Civil Rights - GSA` | General Services Administration |
| `Office of Civil Rights and Equal Opportunity` | `recPwR9pCwcYRbgah` | `Civil Rights and Equal Opportunity` | Social Security Administration |
| `Office of Community Oriented Policing Services` | `rechiow7teikpt5GP` | `Community Oriented Policing Services` | Department of Justice |
| `Office of Diversity, Equity, Inclusion & Accessibility` | `recFvaedNVkgSboU8` | `Office of Diversity, Equity, Inclusion, and Accessibility - OPM` | Office of Personnel Management |
| `Office of Legislative Affairs` | `recBEJ3IpqG63DaG6` | `Office of Legislative Affairs - DOJ` | Department of Justice |
| `Office of the Assistant Secretary for Health (OASH)` | `reciQOx5r2ZMiQrBO` | `Office of the Assistant Secretary for Health` | Department of Health and Human Services |
| `Office of the Chief Financial Officer` | `recoIZ3ORuk7f1ruq` | `Office of the Chief Financial Officer - GSA` | General Services Administration |
| `Office of the Counselor` | `recR5VS8h2JSZjtXh` | `Counselor` | Department of State |
| `Office of the General Counsel` | `recECwoRzxBLfJg1C` | `Office of the General Counsel - NRC` | Nuclear Regulatory Commission |
| `Office of the Secretary` *(Labor)* | `recZ83VX9A77iNN2V` | `Office of the Secretary - DOL` | Department of Labor |
| `Office of the Undersecretary for Public Diplomacy and Public Affairs` | `recberEJtFW8eouIE` | `Under Secretary for Public Diplomacy and Public Affairs` | *(currently mis-parented under Arms Control)* |
| `Senate` | `rec8IktOJbrgTaTig` | `U.S.Senate` | U.S. Congress |
| `United States Special Operations Command` | `rec4mwNYBkNiPVmVB` | `U.S. Special Operations Command` | Department of Defense |
| `United States Transportation Command` | `recAAr6PY2TyJPeD4` | `U.S. Transportation Command` | Department of Defense |

**Two names here are defects on the production side**, not blockers — seeding the external ID works
regardless, and fixing them is optional and separate:

- `U.S.Senate` is missing a space.
- `Under Secretary for Public Diplomacy and Public Affairs` sits under *Under Secretary for Arms
  Control and International Security*, which is wrong.

---

## B. Decide between two real candidates *(needs a human)*

Production holds more than one plausible Account and the migration must not guess.

| Airtable row | Candidate 1 | Candidate 2 | The question |
| --- | --- | --- | --- |
| `Office of the United States Attorneys` `rec2zGjxFcRgANNBl` | `U.S. Attorneys` *(DOJ)* | `Executive Office for U. S. Attorneys` *(DOJ)* | The collective, or the office that administers it? |
| `DC Pre-trial Services` `recxup2VSDjYvDvrF` | `Pretrial Services Agency` *(under CSOSA)* | `Pretrial Services Agency for the District of Columbia` *(under District of Columbia)* | **Production holds both** — likely a production duplicate |
| `U.S. Trustee Program` `recBFToK2YrCGUf0N` | `Executive Office for U.S. Trustees` *(DOJ)* | *(create)* | EOUST administers the U.S. Trustee Program — same thing, or parent-of? |
| `Bureau of Arms Control, Verification, and Compliance` `recC56iMu8tgyzoTs` | `Arms Control, Deterrence, and Stability` *(successor bureau)* | *(create)* | State merged AVC into ADS in the 2022 reorg |
| `Office of Secretary` `recY6Zz0QaJRrsKgh` | — | *(create under Department of State)* | State has no `Office of the Secretary` in production |

---

## C. Create 5 new Accounts *(Salesforce config)*

The genuinely absent ones. Parents researched from public sources rather than guessed:

| New Account | Parent | Basis |
| --- | --- | --- |
| `USA.gov` | `Technology Transformation Services` *(exists, under Federal Acquisition Service)* | Run by GSA TTS |
| `Recreation.gov` | `Forest Service` *(exists)* | Interagency programme, but **USFS administers the contract** |
| `U.S. Digital Service` | `Executive Office of the President` *(exists)* | Renamed **U.S. DOGE Service**, in the EOP, Jan 2025 |
| `Federal Judiciary` | *(top-level)* | Umbrella term; `Judicial Conference of the United States` and `Administrative Office of the U.S. Courts` already exist beneath it |
| `Conference of State Bank Supervisors` | *(top-level)* | **Not a federal agency** — a trade association of state banking regulators |

⚠️ **`Recreation.gov` is a judgement call.** It has 14 participating agencies. Forest Service is the
defensible parent because it holds the contract, but Interior or top-level are reasonable
alternatives — a business decision, not a research finding.

Sources: [Recreation.gov: Overview and Issues for Congress](https://www.congress.gov/crs-product/IF12778) ·
[GSA TTS services](https://tts.gsa.gov/services/) ·
[Executive order establishing DOGE](https://www.whitehouse.gov/presidential-actions/2025/01/establishing-and-implementing-the-presidents-department-of-government-efficiency/)

---

## D. Set `ParentId` on the same-named Accounts *(Salesforce data)*

**This group is ours, not Airtable's.** Reconciliation tells same-named Accounts apart by comparing
Airtable's `Parent` against `Account.ParentId`. For every one of these, **all the Salesforce
candidates have no parent set at all**, so there is nothing to compare and the migration correctly
refuses to guess:

| Name | Copies | Parent set on any? | Airtable says the parent is |
| --- | --- | --- | --- |
| `Office of the Inspector General` | 4 | none | Department of Defense |
| `Office of the Director` | 2 | none | Office of Personnel Management |
| `Office of the Administrator` | 2 | none | NASA |
| `Office of the Deputy Secretary` | 2 | none | Department of Housing and Urban Development |

These are the records `Invoke-AccountBootstrap.ps1` already reports as unresolvable: the production
export names parents **by name**, and these names are themselves ambiguous.

**What is needed:** a human sets `ParentId` on each copy. Once any one copy has a parent, Airtable's
`Parent` column disambiguates the rest automatically on the next run — no code change.

---

## E. Airtable fixes *(data owners)*

**The full task list, as sent to the data owners, is in
[AIRTABLE-DATA-QUALITY-REQUESTS.md](../data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md) §1** — 9
merges, one wrong `Parent`, one rename. Not duplicated here; keep the two in step.

Two of them have consequences on our side:

- **`Environment and Natural Resources Division`** — DOJ's Account currently carries
  `LDGCRM_External_ID__c = recOTuuxYnWwBq9Fs`, the USDA row that took it. ⚠️ **Clear that external ID
  when the Airtable merge happens.** Fixing Airtable alone will not release the Account, because
  reconciliation matches external ID *before* name.
- **The Tax Court is duplicated in PRODUCTION as well as Airtable.** `U.S. Tax Court`
  (`0013d00000BjqjD`, Level 2, under `U.S. Supreme Court`, has a `Clerk of the Court` child) and
  `US Tax Court` (`0013d00000BEpfc`, no parent). Merge into the former. ⚠️ A production Account this
  migration does not own — needs the config owner. Also note production parents it under the Supreme
  Court; it is an Article I legislative court and does not sit there.

---

## The pipeline weakness this exposes — still unbuilt

**Where a name matches exactly one Salesforce Account, the parent is not checked at all.** Confirmed
in `Build-AccountReconciliation.ps1`: the parent comparison lives inside the `$Candidates.Count -gt 1`
branch, so a single-candidate name match wins even when Airtable says the row belongs to a different
agency entirely.

**Parent should be a veto, not just a tie-breaker.** Without it, any rename in Airtable can silently
re-point an Account belonging to another agency, and the run still reports success — which is exactly
how a USDA row acquired a DOJ Account.

**A live instance of this:** `Office Of The Secretary` (`rec9OzViuP62Sw3k0`, Airtable parent
*Housing and Urban Development*) currently matches production's `Office of the Secretary` under
**Department of Commerce**, and the run reports it as a clean match.

Working data: the newest `Invoke-FullMigrationLoad-*` run directory under
`scripts/logs/data-migration/` — `Account-reconciliation-unmatched-*.csv` and `…-ambiguous-*.csv`.
