# Account matching — the remaining 34, and who fixes each

**Researched 2026-08-15** against the production Account list (1,360 rows, as rebuilt into Dev from
`peo-prod-accounts-2026-07-16.xls`) and public sources.

> **The headline: 23 of the 34 need no new Account.** The list was previously read as "agencies
> missing from Salesforce". Most of them are in production already — under their formal legal name,
> under a differently-spelled name, or claimed by a second Airtable row. **Only 6 are genuinely new.**

| Workstream | Rows | Owner | Effort |
| --- | --- | --- | --- |
| [A. Seed 10 external IDs](#a-seed-10-external-ids-salesforce-data) | 10 | Engineering | one update load |
| [B. Set ParentId on 14 same-named Accounts](#b-set-parentid-on-the-same-named-accounts-salesforce-data) | 11 rows blocked | Engineering | needs a decision each |
| [C. Create 6 new Accounts](#c-create-6-new-accounts-salesforce-config) | 6 | Salesforce config | small |
| [D. Merge 6 duplicate Airtable rows](#d-merge-6-duplicate-airtable-rows-airtable) | 6 | **Airtable** | in the Fix List |
| [E. Fill in Parent on 12 rows](#e-fill-in-parent-on-12-rows-airtable) | 12 | **Airtable** | in the Fix List |

---

## A. Seed 10 external IDs *(Salesforce data)*

These 10 Airtable rows **already have a production Account**, unclaimed, under a different name.
Neither name is wrong — Airtable uses the common name, production uses the formal one.

**Do not fix this by renaming Airtable to match**, and do not add a name-alias table to the pipeline.
Write `LDGCRM_External_ID__c` onto the Salesforce Account once. `Build-AccountReconciliation.ps1`
matches on external ID **before** name, so the binding is permanent and survives either side being
renamed later. It is a one-time data update, not a lookup the pipeline has to keep consulting.

| Airtable row | Airtable record ID | Production Account | Sits under |
| --- | --- | --- | --- |
| `Senate` | `rec8IktOJbrgTaTig` | `U.S.Senate` | U.S. Congress |
| `Udall Foundation` | `recA0RxfQZXblmfkA` | `Morris K. Udall and Stewart L. Udall Foundation` | — |
| `United States Virgin Islands` | `reccouuBTMQSBuZqz` | `Territory of Virgin Islands` | — |
| `Economic and Business Affairs` | `recqHR0cR8XENC4F8` | `Economic & Business Affairs` | Under Secretary for Economic Growth |
| `Bureau of Overseas Building Operations` | `recfkbTRu97EXnqXk` | `Overseas Buildings Operations` | Under Secretary for Management |
| `Office of the Secretary` *(Labor)* | `recZ83VX9A77iNN2V` | `Office of the Secretary - DOL` | Department of Labor |
| `Amtrak` | `recZk2Mvn4TtpYk0d` | `National Railroad Passenger Corporation (Amtrak)` | Federal Transit Administration |
| `DC Pre-trial Services` | `recxup2VSDjYvDvrF` | `Pretrial Services Agency for the District of Columbia` | District of Columbia |
| `Bureau of Global Talent Management` | `reca9eRg2LGY7Q58t` | `Global Talent Management Director General of Foreign Service & Director of Global Talent` | Under Secretary for Management |
| `Office of the Undersecretary for Public Diplomacy and Public Affairs` | `recberEJtFW8eouIE` | `Under Secretary for Public Diplomacy and Public Affairs` | *(currently mis-parented under Arms Control)* |

⚠️ **Key this by NAME, not by Account Id.** Salesforce Ids differ per org, so an Id-keyed file is
correct in exactly one sandbox and silently wrong everywhere else. Resolve the name to an Id in the
target org at load time.

**Two to confirm before loading**, because both are a judgement about identity rather than spelling:

- **`Territory of Virgin Islands`** — almost certainly the same entity as `United States Virgin
  Islands`, but it is a production record this migration does not own.
- **`U.S.Senate`** is missing a space. That is a defect in the production Account name, not in
  Airtable. Seeding the external ID makes the match work regardless; fixing the name is separate and
  optional.

---

## B. Set ParentId on the same-named Accounts *(Salesforce data)*

**This group is ours, not Airtable's**, and the previous framing had it the wrong way round.

Reconciliation tells same-named Accounts apart by comparing Airtable's `Parent` against
`Account.ParentId`. For every one of these, **all the Salesforce candidates have no parent set at
all**, so there is nothing to compare and the migration correctly refuses to guess:

| Name | Copies in production | Parent set on any? | Airtable says the parent is |
| --- | --- | --- | --- |
| `Office of the Inspector General` | 4 | none | Department of Agriculture |
| `Office of the Director` | 2 | none | Office of Personnel Management |
| `Office of the Administrator` | 2 | none | NASA |
| `Office of the Deputy Secretary` | 2 | none | Department of State |
| `AmeriCorps` | 2 | none | *`AmeriCorps` — itself, which is an Airtable error* |
| `National Geospatial-Intelligence Agency` | 2 | none | Under Secretary of Defense Intelligence |

These are the records `Invoke-AccountBootstrap.ps1` already reports as unresolvable: the production
export names parents **by name**, and these names are themselves ambiguous, so the bootstrap cannot
place them without guessing. It refuses, correctly.

**What is needed:** a human decides which copy belongs to which agency and sets `ParentId`. Once any
one copy has a parent, Airtable's `Parent` column disambiguates the rest automatically on the next
run — no code change.

*(`AmeriCorps` needs the Airtable side fixing too: a row cannot be its own parent. That half is in
the Fix List.)*

---

## C. Create 6 new Accounts *(Salesforce config)*

The genuinely absent ones. Parents researched from public sources rather than guessed:

| New Account | Parent | Basis |
| --- | --- | --- |
| `USA.gov` | `Technology Transformation Services` *(exists, under Federal Acquisition Service)* | Run by GSA TTS |
| `Recreation.gov` | `Forest Service` *(exists)* | Interagency programme, but **USFS administers the contract**; costs split FS / NPS / USACE |
| `U.S. Digital Service` | `Executive Office of the President` *(exists)* | Renamed **U.S. DOGE Service**, in the EOP, Jan 2025 |
| `Office of the General Counsel` | `Nuclear Regulatory Commission` *(exists)* | NRC has an OGC; copies exist under USDA, VA and ED but none under NRC |
| `Federal Judiciary` | *(top-level)* | Umbrella term; `Judicial Conference of the United States` and `Administrative Office of the U.S. Courts` already exist beneath it |
| `Conference of State Bank Supervisors` | *(top-level)* | **Not a federal agency** — a trade association of state banking regulators |

⚠️ **`Recreation.gov` is a judgement call.** It has 14 participating agencies. Forest Service is the
defensible parent because it holds the contract, but Interior or top-level are reasonable
alternatives — this is a business decision, not a research finding.

Sources: [Recreation.gov: Overview and Issues for Congress](https://www.congress.gov/crs-product/IF12778) ·
[GSA TTS services](https://tts.gsa.gov/services/) ·
[Executive order establishing DOGE](https://www.whitehouse.gov/presidential-actions/2025/01/establishing-and-implementing-the-presidents-department-of-government-efficiency/)

---

## D. Merge 6 duplicate Airtable rows *(Airtable)*

The Salesforce Account exists and a **different Airtable row already claimed it**, so this row is a
second description of the same office:

`Court Services And Offender Supervision Agency` · `Executive Office of the President` ·
`U.S. Supreme Court` · `Chief Digital and Artificial Intelligence Office` ·
`Office of the Secretary - DOC` · `Office of the Undersecretary for Political Affairs`
*(claimed as `Under Secretary for Political Affairs`)*

⚠️ **`U.S. Tax Court | US Tax Court` is different and worth a look.** **Both** names exist as
separate production Accounts and both are already claimed, so that pipe character looks like two
Airtable rows merged into one cell.

---

## E. Fill in Parent on 12 rows *(Airtable)*

The 12 with no `Parent` at all and no production match, minus the ones resolved above. Listed in the
Fix List with record IDs. `Federal Judiciary` is worth doing first — `U.S. Tax Court` names it as
parent, so settling it clears two rows.

---

## How this changes the count

| | Before this research | After |
| --- | --- | --- |
| Read as "missing from Salesforce" | 23 | **6** |
| Actually already in production | — | 16 |
| Blocked by *our* missing hierarchy | 0 *(believed to be Airtable's fault)* | 11 |
