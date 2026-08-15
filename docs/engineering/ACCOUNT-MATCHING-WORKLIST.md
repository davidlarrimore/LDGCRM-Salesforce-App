# Account matching — the remaining 34, and who fixes each

**Researched 2026-08-15** against the production Account list (1,360 rows, as rebuilt into Dev from
`peo-prod-accounts-2026-07-16.xls`) and public sources.

> **The headline: 23 of the 34 need no new Account.** The list was previously read as "agencies
> missing from Salesforce". Most of them are in production already — under their formal legal name,
> under a differently-spelled name, or claimed by a second Airtable row. **Only 6 are genuinely new.**

| Workstream | Rows | Owner | Effort |
| --- | --- | --- | --- |
| [A. Seed 9 external IDs](#a-seed-10-external-ids-salesforce-data) | 9 | Engineering | one update load |
| [B. Set ParentId on the same-named Accounts](#b-set-parentid-on-the-same-named-accounts-salesforce-data) | 11 rows blocked | Engineering | needs a decision each |
| [C. Create 6 new Accounts](#c-create-6-new-accounts-salesforce-config) | 6 | Salesforce config | small |
| [D. Merge 6 duplicate Airtable rows](#d-merge-6-duplicate-airtable-rows-airtable) | 6 | **Airtable** | in the Fix List |
| [D1. The Tax Court duplicate](#d1-the-tax-court--a-duplicate-in-production-not-just-in-airtable) | 3 + 2 | **Both** | production merge needed |
| [E. Fill in Parent on 12 rows](#e-fill-in-parent-on-12-rows-airtable) | 12 | **Airtable** | in the Fix List |
| Rename `United States Virgin Islands` | 1 | **Airtable** | in the Fix List |

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

**One to confirm before loading:** `U.S.Senate` is missing a space. That is a defect in the
production Account name, not in Airtable. Seeding the external ID makes the match work regardless;
fixing the name is separate and optional.

> **`United States Virgin Islands` was in this list and has been moved to Airtable** (project owner,
> 2026-08-15). The match to `Territory of Virgin Islands` is confirmed correct, but the fix is to
> rename the **Airtable** row rather than seed an external ID, so the two systems agree on the name
> rather than agreeing only through a hidden key. It is now in the Fix List.
>
> This is the judgement call that separates the two approaches, and it is worth stating: seed the
> external ID when **both names are legitimate** and neither side should have to give up its own
> vocabulary (`Amtrak` vs `National Railroad Passenger Corporation (Amtrak)`). Rename when **one
> name is simply better** and the other is nobody's preferred term.

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

## D. Merge duplicate Airtable rows *(Airtable)*

The Salesforce Account exists and a **different Airtable row already claimed it**, so this row is a
second description of the same office:

`Court Services And Offender Supervision Agency` · `Executive Office of the President` ·
`U.S. Supreme Court` · `Chief Digital and Artificial Intelligence Office` ·
`Office of the Secretary - DOC` · `Office of the Undersecretary for Political Affairs`
*(claimed as `Under Secretary for Political Affairs`)*

Plus three where the losing row and the claiming row have **the same name AND the same parent**,
which is what makes them genuinely one office recorded twice:

| Row reported as duplicate | Claimed by | Shared parent |
| --- | --- | --- |
| `Under Secretary for Nuclear Security` `recbyMnp1lAeSyUW1` | `recRUUclzfaGB7JEK` | Department of Energy |
| `Deputy Commissioner for Operations` `recem3YiYxbZSoRzD` | `recZC9gVe1flfEuS6` | Social Security Administration |
| `Office of Communications` `recxjIMfLr118aF43` | `rec1dQcLw9nbweDEF` | Office of Personnel Management |

> **Same name at level 3 and below is NOT by itself a duplicate** (project owner, 2026-08-15) —
> several agencies legitimately run an `Office of Communications`. The test is whether the **parent**
> matches too. It does for all three above. Checking that is what caught the case below.

---

## D2. `Environment and Natural Resources Division` — a mis-match, not a duplicate

**Found 2026-08-15 by checking whether the parents actually agreed. They did not**, and this one was
about to be sent to the data owners as a merge request that would have destroyed the correct row.

| | Airtable row | Parent |
| --- | --- | --- |
| Reported as the duplicate | `recxmAuYgs0XGRIsJ` | **Department of Justice** ✅ correct |
| The row that claimed the Account | `recOTuuxYnWwBq9Fs` | **Department of Agriculture** ❌ |

The Salesforce Account is `Environment and Natural Resources Division` **under Department of
Justice**. The USDA-parented row took it; the correctly-parented DOJ row was locked out.

**How it happened: the wrong field was edited.** `recOTuuxYnWwBq9Fs` was
`Natural Resources and Environment` under `Department of Agriculture` — a USDA mission area, and item
1 on the previous fix list, where we asked for its **`Parent`** to be corrected to
`U.S. Department of Agriculture`. Instead its **`Name`** was changed to
`Environment and Natural Resources Division` and the parent left alone. The renamed row then collided
with DOJ's division of that name.

Its real target exists and it is not claiming it: `Under Secretary for Natural Resources and
Environment` under `U.S. Department of Agriculture`.

**Fix:** restore `recOTuuxYnWwBq9Fs`'s name to `Natural Resources and Environment` and set its
`Parent` to `U.S. Department of Agriculture` — the change originally asked for. `recxmAuYgs0XGRIsJ`
then matches DOJ's Account on the next run with no further action.

⚠️ **Clear the stolen external ID first.** DOJ's Account currently carries
`LDGCRM_External_ID__c = recOTuuxYnWwBq9Fs`. Renaming Airtable alone will not release it — the
reconciliation matches external ID *before* name, so the wrong binding would survive the fix.

### The pipeline weakness this exposes

**Where a name matches exactly one Salesforce Account, the parent is not checked at all.** Parent is
used only to break ties between several same-named candidates. So a single-candidate name match wins
even when Airtable says the row belongs to a different agency entirely — which is precisely how a
USDA row acquired a DOJ Account.

**Parent should be a veto, not just a tie-breaker:** where an Airtable row names a parent and the
candidate Account's parent contradicts it, that is not a match at any candidate count. Without it,
any rename in Airtable can silently re-point an Account belonging to another agency, and the run
still reports success.

---

## D1. The Tax Court — a duplicate in PRODUCTION, not just in Airtable

Investigated 2026-08-15 after the pipe character in `U.S. Tax Court | US Tax Court` looked like a
merged cell. It is worse than that: **both systems hold duplicates.**

**Production has two Accounts for one court**, straight from `peo-prod-accounts-2026-07-16.xls`:

| Name | Production Id | Level | Parent | Created | By |
| --- | --- | --- | --- | --- | --- |
| `U.S. Tax Court` | `0013d00000BjqjD` | Level 2 | `U.S. Supreme Court` | 10 Dec 2024 | SystemUser DataLoader |
| `US Tax Court` | `0013d00000BEpfc` | Level 3 or below | *(none)* | 8 Aug 2023 | Jewel Dorsey |

`Clerk of the Court` hangs off the first one, so it is the better-formed of the two.

**Airtable has three rows for the same court:**

| Airtable row | Record ID | Matched to |
| --- | --- | --- |
| `U.S. Tax Court` | `recmHTalRWAChHW9u` | production `U.S. Tax Court` |
| `US Tax Court` | `recaIpw4URTgPYINx` | production `US Tax Court` |
| `U.S. Tax Court \| US Tax Court` | `rec3f05eVwFfswnOq` | **nothing left to match** |

So the third row is not the cause of the problem — it is the *symptom*. Two Airtable rows had already
taken the two production records, and the merged-cell row arrived to find both gone. Merging only the
Airtable side would leave the production duplicate in place and the CRM would still show the court
twice.

**What is needed, and it is two separate decisions:**

1. **Production** — merge `US Tax Court` into `U.S. Tax Court`, keeping the latter (it has the child
   record and a parent). ⚠️ **This is a production Account this migration does not own**, so it needs
   the config owner, not the pipeline.
2. **Airtable** — collapse the three rows to one.

ℹ️ **Worth flagging while someone is in there:** production has the U.S. Tax Court parented under
`U.S. Supreme Court`. The Tax Court is an Article I legislative court and does not sit under the
Supreme Court. Airtable's `Federal Judiciary` is closer to right. Not this migration's to fix, but it
will propagate into the CRM hierarchy as-is.

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
