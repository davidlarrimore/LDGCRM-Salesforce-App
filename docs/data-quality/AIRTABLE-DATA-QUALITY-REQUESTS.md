# Airtable data quality requests

> **Who this is for:** whoever owns and maintains the **Airtable base** — not developers. Every item
> here is something you can fix in Airtable that will pull more records into Salesforce.
>
> **You don't need to understand the migration to act on this.** Each item says what's wrong, which
> rows, and how many records it unblocks. Work top down; the list is ordered by impact.
>
> **Nothing here requires an engineer.** Every transform re-reads Airtable on each run, so fixing an
> item and asking for a re-run picks up the newly valid records automatically — no code change, no
> deployment.
>
> Developers looking for the technical mapping decisions want
> [TRANSFORMATION-RULES.md](../engineering/TRANSFORMATION-RULES.md) instead.

This is a running list of things in the Airtable base that are blocking, or would improve, the
migration into Salesforce.

**This list grows as more tables get migrated** (Contacts, Opportunities, and a few others haven't
been reviewed yet as of 2026-08-13) — it isn't the final/complete list, just everything found so far.

## 📈 Where things stand after the 2026-08-14 full reload

The sandbox was wiped and rebuilt from scratch again on **2026-08-14**, against a freshly pulled
Airtable export, to measure exactly what your latest round of fixes moved.

| | 2026-08-12 | 2026-08-13 | **2026-08-14** |
| --- | --- | --- | --- |
| **Total records migrated** | 6,819 | 8,734 | **8,831** |
| Opportunities | 742 | 842 | 842 |
| Applications | 688 | 1,026 | **1,045** |
| Contacts | 1,483 | 1,870 | **1,876** |
| Application–Contact links | 1,880 | 2,699 | **2,750** |
| Notes | 537 | 716 | **730** |
| Partner Accounts | 74 | 92 | **97** |

**Zero unexpected failures**, and for the first time the whole 12-step load ran end to end without
stopping once.

**Four more items closed this round** — see the [Resolved log](#-resolved-log):

- ✅ **Every one of the 12 duplicate Account rows this document asked you to merge is gone.** All 8
  "confirmed duplicates" and all 4 "needs confirmation" rows have been merged into their canonical
  twin. This was the top item on the list for two weeks.
- ✅ **Every Partner Account now has exactly one Account link** (4 with none → 0; `USDT-SSP`'s
  double link → resolved). Partner Accounts migrated went 92 → **97**.
- ✅ **`Technical Emails` is gone from the Subscription Type field** (711 → 0). Nothing is being
  dropped on load any more.
- 🟡 **Duplicate contact rows dropped 80%** — email addresses appearing on 2+ rows went 61 → **12**.

### ⚠️ The Accounts item has changed character — please read this before working it

It is still roughly the same size (155 → **154** unmatched), which makes it look like nothing
happened. **That reading is wrong, and the number is hiding a real success.**

The 154 are now an almost entirely *different* set of rows. Every duplicate this document named has
been fixed. What remains is not duplicates at all — it is **agencies, bureaus, territories and
courts that have no Salesforce Account to match, because one was never created**:

> `U.S. Census Bureau`, `United States Postal Service`, `Bureau of Diplomatic Security`,
> `United States Army Corps of Engineers`, `The Supreme Court of the United States`,
> `Guam`, `American Samoa`, `Puerto Rico`, `Northern Mariana Islands`, `United States Virgin Islands`,
> `John F. Kennedy Center for the Performing Arts`, `U.S. Commission on Civil Rights` …

**So this is no longer an Airtable de-duplication ask.** For most of the 154 the question is now for
whoever owns the Salesforce org: *should these Accounts be created?* The Airtable rows look correct.
See [the reframed item below](#accounts-rows-that-dont-match-an-existing-salesforce-account--172--155).

### Current measurements — 2026-08-14 (after the reload)

| Item | Airtable rows | Records it holds back | Change |
| --- | --- | --- | --- |
| Accounts not matching a Salesforce Account | **154** | ~166 across 5 objects | 155 → 154, but see above |
| Contacts with no name | **1,054** of 1,535 | 0 — they load with a derived name | unchanged |
| Issuer Strings `#N/A` cells | **273** (136 name + 137 UUID) | 0 — ✅ closed, optional field | unchanged |
| Applications with no Launch Level | **621** | 0 — but see CR-3 | unchanged |
| Contacts with neither name nor email | **31** | 31 | unchanged |
| `Technical Emails` subscription | **0** | 0 | ✅ **711 → 0** |
| Partner Accounts with no Account link | **0** | 0 | ✅ **4 → 0** |
| Partner Accounts linked to two Accounts | **0** | 0 | ✅ **1 → 0** |
| Emails appearing on 2+ Contact rows | **12** | 0 — rows are merged | 🟡 **61 → 12** |
| Applications with no Partner Account link | **8** | 8 | unchanged (6 are `Decomissioned`) |
| Impediments with no name | **2** | 2 | unchanged |
| Contacts with an email in the `Name` field | **3** | 0 — loads as a name | unchanged |

**What the remaining 154 unmatched Accounts hold back:** 62 Opportunities, 13 Applications,
77 Application–Contact links, 34 Opportunity Contacts and 7 Notes. Every one of those figures
except Opportunities came down this round.

### How to read the status on each item

Items are **never deleted from this document when they're fixed** — they're marked resolved and kept,
so you can see what's already been done and nobody re-raises something that's closed. Every item
carries one of:

| Status | Meaning |
| --- | --- |
| 🔴 **Open** | Nothing has changed yet. Still blocking or still worth doing. |
| 🟡 **Partially resolved** | Some of it is done; the item says exactly what's left and who owns it. |
| ✅ **Resolved** | Done. Kept for the record, with the date and what changed. |

**A resolved item does not mean the records have loaded yet.** Fixing the data unblocks a record; it
still migrates on the next run. The [Resolved log](#-resolved-log) at the bottom is the short version
— every closure in date order.

Progress against a specific load attempt is tracked separately, in
[`scripts/docs/RELOAD-QA-CHECKLIST.md`](../operations/RELOAD-QA-CHECKLIST.md). **The two are kept
in step:** when an item here is resolved, the corresponding expectation in that checklist (row counts,
"expect N skipped", known-empty fields) is updated in the same change, so a checklist that says
"expect 142 blocked" never outlives the fix that unblocked them.

## Blocking — these records can't migrate until fixed

Salesforce requires certain fields to always have a value (e.g. every Partner Account must be linked
to an Account, every Application must be linked to a Partner Account). Airtable rows missing that
link get skipped rather than guessed at. None of these are broken on the Salesforce side — they need
a decision or a data fix in Airtable.

### Accounts: rows that don't match an existing Salesforce Account — 🟡 172 → 155 → 154 (but see below)

**Status: 🟡 The duplicate half of this item is ✅ DONE. What's left is a different question.**

**✅ All 12 named duplicate rows have been merged** (verified against the 2026-08-14 export — every
one of the 8 "confirmed duplicates" and all 4 "needs confirmation" rows is gone, and each canonical
twin is present exactly once). **Thank you — this was the top item on the list for two weeks.**

**The count barely moved (155 → 154) and that is misleading.** The remaining rows are almost
entirely a *different* population. They are not duplicates of anything; they are real organisations
with no Salesforce Account to match:

> `U.S. Census Bureau`, `United States Postal Service`, `Bureau of Diplomatic Security`,
> `United States Army Corps of Engineers`, `The Supreme Court of the United States`,
> `United States Courts of Appeals`, `Special Courts: United States Tax Court`,
> `Guam`, `American Samoa`, `Puerto Rico`, `Northern Mariana Islands`, `United States Virgin Islands`,
> `John F. Kennedy Center for the Performing Arts`, `U.S. Commission on Civil Rights`,
> `Council of Inspectors General on Integrity and Efficiency`, `Udall Foundation` …

**What we need now is different from what this item used to ask for.** For most of the 154 there is
nothing to fix in Airtable — the row is correct. The question is for **whoever owns the Salesforce
org**: should an Account be created for these bodies? Until one exists, the migration has nothing to
attach their Opportunities and Applications to.

Please still check the list for anything that *is* a duplicate or is genuinely stale — but expect
that to be the minority now, not the bulk.

What the remaining 154 hold back (all down again this round except Opportunities):

| Blocked by unmatched Accounts | 2026-08-12 | 2026-08-13 | **2026-08-14** |
| --- | --- | --- | --- |
| Partner Accounts | ~20 | 2 | **2** |
| Applications | 359 | 22 | **13** |
| Opportunities | 142 | 62 | **62** |
| Contacts (no agency) | 390 | 54 | **49** |
| Application–Contact links | 849 | 128 | **77** |

Airtable has 747 Account rows; Salesforce has 585 tagged. Matching is by ID first, then exact name.
Full list: `scripts/logs/data-migration/Account-reconciliation-unmatched-*.csv` (ask engineering for the
latest one).

### ⚠️ NEW 2026-08-14: the `Department of the Treasury` merge left two rows with the same name — 🔴 OPEN

**This is a small follow-on from the merge work, and it is blocking 5 Opportunities.**

`Department of the Treasury` was correctly merged toward `Department of Treasury` — but there are now
**two Airtable rows both named `Department of Treasury`**. Only one of them can claim the single
Salesforce Account of that name; the other is left unmatched, and the 5 Opportunities hanging off it
are withheld.

**What we need:** merge the two `Department of Treasury` rows into one, relinking anything that
points at the loser. This is the single highest-value remaining Account fix — 5 Opportunities for one
merge.

*(Three other names are also duplicated within Airtable, but they are generic sub-office names and
are covered by the next item rather than this one: `Office of Communications` ×3,
`Office of the Director` ×2, `Office Of The Secretary` ×2.)*

### ⚠️ NEW 2026-08-14: 8 rows have generic office names that match more than one Salesforce Account — 🔴 OPEN

**The migration refuses to guess on these, so they stay unmatched.** Eight Airtable Account rows are
named after a generic sub-office, and Salesforce has **two or more** Accounts with that exact name —
belonging to different parent agencies. There is no safe way to pick one.

| Airtable row | Its Market Segment (the clue to the real parent) |
| --- | --- |
| `Office of Communications` | Finance & Regulation |
| `Office of Communications` | Defense |
| `Office of Communications` | Finance & Regulation |
| `Office of the Director` | Finance & Regulation |
| `Office of the Director` | Finance & Regulation |
| `Office of the Deputy Secretary` | Defense |
| `Office of the Inspector General` | Infrastructure |
| `Departmental Management` | Benefits |

**What we need:** disambiguate the names so each points at one agency — e.g.
`Office of Communications (Treasury)` vs `Office of Communications (DoD)`. The Market Segment column
already tells you which is which. Renaming them in Airtable to match the parent agency's naming is
enough; no other change is needed.

Full list: `scripts/logs/data-migration/Account-reconciliation-ambiguous-*.csv`.

**Confirmed pattern (2026-08-13): most of these look like duplicate rows within Airtable itself, not
missing Accounts.** Checked the 13 of the 172 that were specifically blocking Partner Account loads
— **8 of the 13 are duplicate Airtable rows** for an entity that already exists in Salesforce under a
differently-formatted twin row:

| Orphaned Airtable row | Already-linked Airtable twin |
| --- | --- |
| `Air Force` | `Department of the Air Force` |
| `Army` | `Department of the Army` |
| `Navy` | `Department of the Navy` |
| `Department of the Interior` | `Department of Interior` |
| `General Service Administration` | `General Services Administration` |
| `Technology Transformation Services (TTS)` | `Technology Transformation Services` |
| `United States House of Representatives` | `U.S. House of Representatives` |
| `U.S. Office of Special Counsel` | `Special Counsel` |

The other 5 of the 13 originally had no Salesforce counterpart found by a first-pass keyword search:
`Department of Agriculture`, `National Institute of Standards and Technology`,
`State of Arkansas`, `Bureau of Consular Affairs`,
`U.S. International Development Finance Corporation`. **Three of these five turned out not to be
genuinely missing after all — see the follow-up investigation directly below, which re-checked with a
live Salesforce query instead of a manual keyword search and found near-miss wording differences the
first pass missed.**

Given 8 of 13 checked turned out to be duplicates, the same is likely true for a meaningful chunk of
the remaining 159 — worth a duplicate-row pass across the full 172 before assuming they're all
genuinely new Accounts.

**What we need:** for each of the 172, one of — (a) **it's a duplicate of another Airtable row** for
an Account that already exists in Salesforce — decide which row is canonical, and either delete/merge
the duplicate or update anything linking to it (Partner Accounts, Applications, etc.) to point at the
canonical row instead; (b) it's a genuinely new Account not yet in Salesforce, flag it as such; or (c)
it's stale/no longer relevant, fine to leave unmigrated.

### Follow-up (2026-08-13): the 14 highest-impact Account rows — ✅ 13 of 14 RESOLVED 2026-08-14

**Status: ✅ Effectively closed. 13 of these 14 rows are done — thank you.** This section used to be
the main worklist on this document. It is kept because closed items are never deleted here, but
**there is only one row left to act on.**

Re-checked against the 2026-08-14 export: 12 of the rows have been merged away entirely, and
`Office of Inspector General` now matches a Salesforce Account. The `Department of the Interior` fix
alone was worth 203 Applications.

| Airtable Account row | Was | **Now** |
| --- | --- | --- |
| `Department of the Interior` | Confirmed duplicate — blocked **203** Applications | ✅ merged |
| `General Service Administration` | Confirmed duplicate — 65 Applications | ✅ merged |
| `Technology Transformation Services (TTS)` | Confirmed duplicate — 24 Applications | ✅ merged |
| `National Institute of Standards and Technology` | Needed confirmation — 17 Applications | ✅ merged |
| `Department of the Treasury` | Needed confirmation — 17 Opportunities | ✅ merged ⚠️ *but see the name-collision item above — the merge left two rows sharing the target name* |
| `Department of Agriculture` | Needed confirmation — 14 Opportunities | ✅ merged |
| `Office of Inspector General` | Ambiguous, no confident match | ✅ now matches |
| `U.S. International Development Finance Corporation` | Needed confirmation | ✅ merged |
| `Army` | Confirmed duplicate — 4 Partner Accounts | ✅ merged |
| `Navy` | Confirmed duplicate | ✅ merged |
| `United States House of Representatives` | Confirmed duplicate | ✅ merged |
| `U.S. Office of Special Counsel` | Confirmed duplicate | ✅ merged |
| `Air Force` | Confirmed duplicate | ✅ merged |
| **`Bureau of Consular Affairs`** | **Genuinely missing — no Salesforce match** | 🔴 **STILL OPEN — the only one left** |

**The one remaining ask:** `Bureau of Consular Affairs` has no Salesforce Account and never did. It
blocks 1 Partner Account, 2 Applications and 2 Opportunities (both already `Closed Won`, so the
urgency is low). **Decide one of:** create the Account in Salesforce, point the Airtable row at an
existing parent (e.g. Department of State), or confirm it is fine left unmigrated.

All but two of these rows (`United States House of Representatives`, created 2024-01-23;
`Office of Inspector General`, created 2023-08-30) were created on **2023-06-21** — the original
Airtable base's bulk-import date. They were longstanding structural duplicates baked in from day one,
not recent data-entry mistakes, which is why fixing them did not disrupt anyone's active work.

**What we asked for, and where it landed:**

1. ✅ **The 8 confirmed duplicates — DONE.** All merged into their already-linked twin
   (`Army`→`Department of the Army`, `Navy`→`Department of the Navy`, `Air Force`→`Department of the
   Air Force`, `General Service Administration`→`General Services Administration`, `Technology
   Transformation Services (TTS)`→`Technology Transformation Services`, `United States House of
   Representatives`→`U.S. House of Representatives`, `U.S. Office of Special Counsel`→`Special
   Counsel`, `Department of the Interior`→`Department of Interior`).
2. ✅ **The 4 "same entity, worded differently" rows — DONE.** `National Institute of Standards and
   Technology`, `Department of Agriculture`, `U.S. International Development Finance Corporation` and
   `Department of the Treasury` are all merged. ⚠️ **One follow-on:** the Treasury merge left **two**
   Airtable rows named `Department of Treasury` — see the name-collision item above. It is a small
   fix worth 5 Opportunities.
3. ✅ **`Office of Inspector General` — RESOLVED.** It now matches a Salesforce Account, so the
   HHS-OIG Partner Account and its Applications are no longer blocked by it.
4. 🔴 **`Bureau of Consular Affairs` — STILL OPEN, and now the only one left.** Genuinely no
   Salesforce match. Both of its 2 linked Opportunities are already `Closed Won`, so this is the
   lowest-urgency item on the list, but it still needs a decision: new Account, or safe to leave
   unmigrated.

**Not something the migration pipeline is working around.** Per an explicit decision (2026-08-13): the
migration will not silently guess at or auto-merge Account matches, no matter how confident the guess.
Every Partner Account, Application, and (once built) Opportunity row that depends on one of these
unresolved Accounts will simply be skipped or fail to load until the underlying Account data is fixed
in Airtable — that's expected, by-design behavior, not a bug the pipeline should route around. This
list is what unblocks them.

### Partner Accounts: 5 rows have no working link to an Account — ✅ RESOLVED 2026-08-14

**Status: ✅ Resolved. Thank you — nothing further needed.** Verified against the 2026-08-14 export:
**all 99 Partner Account rows now have exactly one Account link.** Partner Accounts migrated went
92 → **97**.

- **No Account linked at all: 4 → 0.** `USDT(inactive)`, `DOD-AFRL-Bifrost - placeholder`, `USACE`
  and `DOD-ARMY-CAC (INACTIVE AGREEMENT)` all now carry a link.
- **Linked to two Accounts at once: 1 → 0.** `USDT-SSP` now resolves to a single Account.

*(2 Partner Accounts still fail to load, but for the separate reason that their parent Account is
among the 154 unmatched — that is the Accounts item above, not this one.)*

### Missing Salesforce logins block record ownership across three objects at once

**Updated 2026-08-13** — this started as a Partner Account-only note. Now that records are assigned
to their real owners rather than all landing on the person running the migration, the same handful of
missing Salesforce logins turns out to block ownership in several places at once. Any record whose
Airtable owner has no active Salesforce user falls back to the migration user — nothing is lost or
blocked, but the record won't show up under the right person's name, and because these objects use
owner-based sharing, ownership also affects who can see them.

Ranked by how many records each person would fix:

| Person | Opportunities | Meetings | Partner Accounts | Total records |
| --- | --- | --- | --- | --- |
| `elizabeth.mays@gsa.gov` | 157 | 182 | several | **~340** |
| `tony.parrilla@gsa.gov` | 15 | 50 | several | **~65** |
| `gabriel.vorleto@gsa.gov` | 105 | 8 | — | **~113** |
| `sierra.stewart@gsa.gov` | 8 | 11 | — | **~19** |
| `trish.nguyen@gsa.gov` | — | 21 | — | 21 |
| `diondra.humphries@gsa.gov` | — | 13 | — | 13 |
| 8 others | — | ~20 combined | — | ~20 |

Two distinct situations, which need different answers:

- **No Salesforce user at all:** `elizabeth.mays@gsa.gov`, `tony.parrilla@gsa.gov`,
  `sierra.stewart@gsa.gov`, `robert.owens@gsa.gov`, `nour.aldimashki@gsa.gov`,
  `goutham.kommanaboyina@gsa.gov`, `brianna.naolu@gsa.gov`.
- **User exists but is deactivated:** `gabriel.vorleto@gsa.gov`, `trish.nguyen@gsa.gov`,
  `diondra.humphries@gsa.gov`, `becky.badalato@gsa.gov`, `hanna.kim@gsa.gov`,
  `matt.pritchard@gsa.gov`, `ambuj.neupane@gsa.gov`. Salesforce won't assign records to a deactivated
  user, so these behave the same as "missing" for migration purposes.

**What we need:** for each person, either confirm they're current staff who need an active Salesforce
login, or name who their records should be reassigned to. The first two names alone account for
roughly 400 records.

*(Note for engineers: this is a `gsa-peo` sandbox observation. Confirm against production before
acting — the sandbox's user list is not guaranteed to match.)*

### Applications: 11 records look like incomplete drafts — ✅ RESOLVED 2026-08-13

**Status: ✅ Resolved.** **0 Applications** now have both a blank Status and no Partner Account link,
down from 11. The four near-duplicate HHS-named rows and the `Test Application` scratch record are no
longer in that state. Nothing further needed.

### Applications: rows with a Name or URL too long for Salesforce — ✅ RESOLVED 2026-08-13 (one left)

**Status: ✅ Resolved for Names and the `URL` column.** Verified against a fresh export:

- **Application Name over 80 characters: 5 → 0.** Nothing is being truncated any more.
- **`URL` over 255 characters: 13 → 0.** Nothing is being blanked any more.

**One remains, and it's the easy one:** a single **`Launch Deck URL` of 275 characters** — a Google
redirect wrapper around a Drive link, where the underlying Drive URL would fit comfortably. Replacing
it with the plain Drive link closes this item entirely. (The other 8 rows still in
`scripts/logs/data-migration/Application-overlength-*.csv` are the long *partner-portal team names*, tracked
separately under Issuer Strings above — not Application data.)

### Applications: 1 row has a mistyped go-live year (`ECOMP`) — ✅ RESOLVED 2026-08-13

**Status: ✅ Resolved.** `ECOMP`'s Actual Go-Live Date is now **`2020-02-18`**, a valid date —
previously `0202-02-18`, which Salesforce rejected outright. The field now migrates.

*(One thing worth a second look, purely as a sanity check: this document originally guessed the
intended value was `2022-02-18`, and it was set to `2020`. Either is plausible and neither blocks
anything — just confirm 2020 is the year you meant.)*

### Applications: 621 rows have no Launch Level — 🟡 WORKED AROUND, but a real value would be better

**New 2026-08-13.** 621 of 1,056 Applications have no `Launch Level`. Nothing is blocked — but this
one was quietly causing a **wrong number in Salesforce**, which is worth explaining because it isn't
obvious.

Salesforce calculates a "Launch Checklist Completion %" from the Launch Level. With the level empty,
the calculation fell through to its default and reported the application as **100% complete**. Before
we fixed it, **607 migrated Applications were reporting themselves fully launch-complete** while
their underlying checklist was at most 78% done.

**We now default a blank Launch Level to `1 - Very Low Impact`** on load (project owner's decision),
which fixed it — 607 → 0 reporting 100%. So nothing is broken today.

**What we need — nothing urgent, but:** that default is an *assumption we're making on your behalf*,
and once it's in Salesforce it looks identical to a real value. For any application where the level
is genuinely known, filling it in is better than our guess. Levels in use: 1 (354 rows), 3 (32),
4 (29), 2 (12), 5 (8).

### Applications: 2 rows have an unusable "Ramp Up Approach" value — ✅ RESOLVED 2026-08-13

**Status: ✅ Resolved.** The `"Q1 - FY'23"` and `"146"` values are gone. All **745** Applications that
carry a Ramp Up Approach now use a real one (`Gradual`/`Immediate`/`Spikes` with a level suffix) —
**0 unusable**. The remaining 311 Applications simply have the field empty, which is fine; it's
optional.

### Issuer Strings: `#N/A` in Team Name / Team UUID — ✅ CLOSED, no Airtable action needed

**Closed 2026-08-14 by a business-rule decision:** #N/A is transformed to blank on the way into
Salesforce. Bad data does not need to reach the CRM, and clearing it in Airtable is not a
prerequisite for anything.

136 `Team Name` cells and 137 `Team UUID` cells hold the literal text `#N/A` — a spreadsheet
artifact. Of 901 issuer strings: 691 carry a real team name, 136 carry `#N/A`, 74 are blank.

**Verified in Salesforce 2026-08-14: 0 Applications hold `#N/A`** in either field.

Still worth tidying in Airtable whenever convenient — a cell containing `#N/A` looks filled in, so
the table reads as 92% complete when the real figure is 77% — but it blocks nothing and is no longer
an ask.

*(No action required. Left here so the item is not re-raised.)*

### Issuer Strings: how the migration reads this table

> ## ✅ These fields are optional — nothing here is an ask any more
>
> **Business rule, 2026-08-14:** issuer strings, partner-portal **Team Name** and **Team UUID** are
> **not required**. A missing value is a perfectly acceptable outcome, and `#N/A` is transformed to
> blank on the way in.
>
> Every Issuer Strings item below is therefore **closed**. They are kept as a record of what the
> table looks like and why the migration treats it the way it does — not as work anyone owes.
>
> **Current state in Salesforce (2026-08-14): 681 Applications carry a portal team.** The rest are
> blank, which is fine.

**Read this before the lists below** — it explains how the table is interpreted. These are the rules
as they stand; if any of them is the wrong call, say so and we'll change the rule rather than the
data.

**The starting point: the partner-portal team belongs to the *Application*** (confirmed by the project
owner). Airtable stores `Team Name` and `Team UUID` on each **issuer string** instead, so the same
values are copied onto every issuer string an Application has, and **every copy is meant to be
identical**. Salesforce stores the team once, on the Application.

So this is a **de-duplication, not a merge**: we read the one value all the copies agree on and write
it to the Application a single time. That single decision is what the rest of the rules follow from —
in particular, copies that *don't* agree are a mistake to fix, never an Application that genuinely has
two teams.

| # | Rule | Why |
| --- | --- | --- |
| 1 | We read `Team Name`, `Team UUID` and `Partner Portal Admin Email` from this table. | The team is recorded nowhere else; the admin is also recorded on Contacts (rule 10). |
| 2 | The Application is updated **once**, from the value its issuer strings agree on. | The team belongs to the Application; the per-issuer-string copies are duplication. |
| 3 | **`#N/A` is treated as empty**, not as text. | It's a failed-lookup artifact. Loading it would put the literal text `#N/A` into Salesforce as if it were a team name. |
| 4 | If the copies **all agree** → migrated. | Nothing to decide. **678 Applications.** |
| 5 | If **some copies are filled in and the rest are blank**, and the filled ones agree → **migrated normally**, using that value. The blanks are reported but change nothing. | The answer is unambiguous. Blocking here would withhold correct data over a cosmetic gap. **18 Applications** — list below. |
| 6 | If the copies name **two different teams** → **both fields left blank**, Application reported. | There's no defensible way to pick a winner; "first one wins" would just mean whichever row happened to sort first. **9 Applications** — list below. |
| 7 | If **no** issuer string has a team → both fields left blank, not reported. | Nothing to migrate and nothing obviously wrong. **182 Applications.** |
| 8 | A **team name over 50 characters** is left blank, but the Team UUID still migrates. | The Salesforce field holds 50. A cut-off team name would look real while not matching the portal. **6 teams, 8 Applications.** |
| 9 | Issuer strings linked to **no Application** are ignored. | There's no record to put the team on. **7 rows.** |
| 10 | **`Partner Portal Admin Email` is read too**, and marks that person as a Partner Portal Admin on the Application. Matched to a contact by email address. | It's one of two places this is recorded — see the disagreement item below. |
| 11 | If that admin **isn't already a contact on the Application**, the link is **created**. | A portal admin plainly is a contact on that application. **86 links** are created this way. |
| 12 | **The issuer string values themselves are not migrated.** | See the note at the very bottom of this document — the Salesforce field is one 40-character value, and most issuer strings are longer than that. |

Two consequences worth being explicit about, because they're easy to misread:

- **Rule 6 is the only one that loses data**, and it affects 9 Applications. Everything else either
  migrates or had nothing to migrate.
- **Fixing any of this is a re-run, not a code change.** Every transform re-reads Airtable from
  scratch, so corrected rows are picked up automatically.

### Issuer Strings: 9 Applications where the team copies disagree — ✅ CLOSED, optional field

**New 2026-08-13.** These hit rule 6 above: one Application's issuer strings name two different teams.
Because the copies are supposed to be identical, this is drifted data rather than an Application with
two teams. **Both fields are currently left blank on all 9.**

Full list, so these can be opened directly in Airtable. **The fix is to make every row for a given
Application say the same thing.**

| Application | Team Name on that row | Team UUID | Issuer String |
| --- | --- | --- | --- |
| **Research.gov** | `IAM Team` | `aba63f37-0687-494a-9ef0-0e92f59385ae` | `urn:gov:nsf:openidconnect.profiles:sp:sso:nsf:research_gov` |
| | `NSF-LoginGov Integration` | `16a70d46-3faa-4ce8-bffb-3d645033c007` | `https://identity.research.gov/sso/sp` |
| **Forms.gov Developer Portal** | `z_inactive` | `5dba269a-50a0-43c1-97b9-fd6a6b030a3f` | `urn:gov:gsa:SAML:2.0.profiles:sp:sso:gsa:prodlogin_mainportal_ial1` |
| | `formsgov_production` | `34a8967a-d5a9-40c2-a3b7-dc85d2049c53` | `urn:gov:gsa:SAML:2.0.profiles:sp:sso:gsa:fs_formio_epa_portal` |
| | *(blank)* | *(blank)* | `urn:gov:gsa:SAML:2.0.profiles:sp:sso:gsa:prodlogin_mainportal` |
| **Made in America** | `Made In America Production` | `c9aff7f4-8d08-4f59-81b5-c50d6075f970` | `urn:gov:gsa:openidconnect.profiles:sp:sso:gsa:miaprod` |
| | `MIAO_formio` | `e1018e8b-3a15-4c34-afcd-c3b8226a177d` | `urn:gov:gsa:SAML:2.0.profiles:sp:sso:gsa:miao_formio_prod_portal` |
| **USA Performance (USAP)** | `USA Learning` | `c7929ce7-2c73-451d-bf72-44854dd4c71d` | `urn:gov:gsa:SAML:2.0.profiles:sp:sso:opm:usaplmstest` |
| | `USA Learning` | `c7929ce7-2c73-451d-bf72-44854dd4c71d` | `urn:gov:gsa:SAML:2.0.profiles:sp:sso:opm:usaplmsdev` |
| | `USAP_TEAM` | `420edf51-eed7-4482-b8d7-6ff779277a17` | `urn:gov:gsa:openidconnect.profiles:sp:sso:opm_prod:usaperformance` |
| **CISA OKTA Partner Platform** | `CISA OKTA PRO` | `5d75b29b-40f0-4208-b15f-ea8800ec3261` | `https://cisa-partner.okta.com` |
| | `Partner Preview Test` | `bf4794c0-5138-4cf5-a86b-c1a137bd5873` | `cisa-partner-dev.oktapreview.com` *(has a trailing space)* |
| **SDSFIE (Spatial Data Standard…)** | `SDSFIE` | `f93a1f17-c09e-4c6a-88cf-6dc281bafa27` | `urn:gov:gsa:openidconnect.profiles:sp:sso:DOD:SDSFIE-PRD` |
| | `CWBI` | `3f6e4f4b-831f-433f-812b-66216315932a` | `urn:gov:gsa:openidconnect.profiles:sp:sso:DOD:SDSFIE-IDENTITY-PROD` |
| **RAM Portal** | `RAM Vetting Service` | `33a71c9e-de85-4a83-9c57-c9795a1d39f6` | `urn:gov:gsa:openidconnect.profiles:sp:sso:state:ramportal` |
| | `Sunil Kumar` ⚠️ | `c407325b-4f71-4b33-bb9e-5198b96f23a7` | `urn:gov:gsa:SAML:2.0.profiles:sp:sso:dos:raiportal` |
| **PHMSA - PRIMS** | `PRIMIS-IAS` | `1b659757-0a00-4141-ab96-fff530d80102` | `urn:gov:gsa:openidconnect.profiles:sp:sso:phmsa:primis-ias-dev` |
| | `PRIMIS-IAC` | `39143673-8e40-4c25-979b-401417696143` | `urn:gov:gsa:openidconnect.profiles:sp:sso:phmsa:primis-iac` |
| **IPaC** | `DOI - FWS - ECOS` | `5add6a5b-1ede-404d-b107-666d7eedb357` | `urn:gov:doi:openidconnect.profiles:sp:sso:fws:ipacProduction` |
| | `DOI-FWS-ECOSphere` | `2cac5b4a-a9d1-42b9-914b-7563abb8e30f` | `urn:gov:doi:openidconnect.profiles:sp:sso:doi-fws-ecosphere:ipac-production` |
| | `DOI - FWS - ECOS` | `5add6a5b-1ede-404d-b107-666d7eedb357` | `urn:gov:doi:openidconnect.profiles:sp:sso:fws:ipacBeta` |

**Patterns worth knowing before you start** — most of these should be quick:

- **Same team, two spellings** (likely just a naming inconsistency, easiest fix): `DOI - FWS - ECOS`
  vs `DOI-FWS-ECOSphere` on **IPaC**; possibly `PRIMIS-IAS` vs `PRIMIS-IAC` on **PHMSA - PRIMS**.
  Note the UUIDs differ too, so these are genuinely two portal teams — confirm whether they should be
  merged in the portal, not just renamed here.
- **A test/dev issuer string under a different team from the production one** — the most common shape.
  **USA Performance (USAP)** is the clearest: two `usaplms` test/dev strings under `USA Learning`, and
  the actual `usaperformance` production string under `USAP_TEAM`. Those `usaplms` strings look like
  they belong to a *USA Learning* application, not this one.
- ⚠️ **`Sunil Kumar` is a person's name in a team field** (RAM Portal) — almost certainly wrong
  regardless of what else is decided.
- **`z_inactive`** (Forms.gov Developer Portal) reads as a retired-team placeholder. That Application
  also has a third issuer string with no team at all.

**What we need:** for each of the 9, confirm which team is correct and make every one of that
Application's issuer strings match it. Where issuer strings actually belong to a *different*
Application, moving them there fixes it just as well.

### Issuer Strings: 18 Applications have the team on only some rows — ✅ CLOSED, optional field

**New 2026-08-13.** These hit rule 5: some of the Application's issuer strings carry the team, the
rest are blank or `#N/A`. **The team is unambiguous, so all 18 migrate correctly and nothing is
blocked.** Listed only because the copies are supposed to match — filling the gaps stops the table
reading as though the team is only partly known.

The issuer strings named here are **the blank ones** — the rows needing the value added:

| Application | Team it should say | Blank rows | Issuer String missing the team |
| --- | --- | --- | --- |
| OASAM - OCIO - OSHA Information System (OIS) | `DOL - OASAM - OCIO` | 1 of 2 | `urn:gov:dol:SAML:2.0.profiles:sp:sso:prd-osha:ois` |
| OIS | `DOL - OASAM - OCIO` | 1 of 2 | `urn:gov:dol:SAML:2.0.profiles:sp:sso:prd-osha:ois` |
| OSHA-SF-UAT-Partner | `DOL - OASAM - OCIO` | 2 of 3 | `https://alliancecommunity.my.site.com/Alliance` |
| | | | `https://alliancecommunity.force.com/Alliance` |
| Data.gov Catalog | `data.gov` | 2 of 3 | `urn:gov:gsa:SAML:2.0.profiles:sp:sso:gsa:datagov-staging-catalog` |
| | | | `urn:gov:gsa:SAML:2.0.profiles:sp:sso:gsa:datagov-production-catalog` |
| MyRRB | `RRB - Benefit Connect` | 2 of 3 | `urn:gov:gsa:SAML:2.0.profiles:sp:sso:RRB:BOS-Pre-Prod` |
| | | | `urn:gov:gsa:openidconnect.profiles:sp:sso:RRB:BOS_AA1_Prod` |
| CMS (Credit Management System) | `DFC-CMS` | 1 of 4 | *(a completely empty row — `reckfaCTqTTXlW5Fb`, no issuer string either; safe to delete)* |
| MyPBA | `PBGC - myPBA` | 1 of 2 | `urn:gov:gsa:openidconnect.profiles:sp:sso:pbgc:mypba` |
| E-Grants Release 1 EGov (MSHA eGOV) | `DOL - OCIO` | 1 of 2 | `urn:gov:dol:openidconnect.profiles:sp:sso:ocio:MSHAEGov3` |
| SEC - eFAP (OracleAM) \| SEC eFAP12 | `SEC - eFAP` | 1 of 2 | `urn:gov:gsa:SAML:2.0.profiles:sp:sso:sec:oam12_prd` |
| EFFS | `SEC - EFFS and ETR` | 1 of 2 | `effssrtsweb.sec.gov` |
| NPS - NAMA | `NPS-NAMA` | 1 of 2 | `urn:gov:gsa:SAML:2.0.profiles:sp:ssp:NPS:NAMA` |
| Wildlife TRACS | `DOI - USFWS - Wildlife and Sport Fish Restoration` | 1 of 4 | `gov:usfws:openidconnect.profiles:sp:sso:tracs-prod` |
| Online Retirement Application (ORA) | `Online Retirement Application` | 1 of 2 | `urn:gov:gsa:SAML:2.0.profiles:sp:sso:opm:ora` |
| ACERS Industry | `ACERS` | 1 of 2 | `https://usdotdtc.my.site.com/industry` |
| CBP Trusted Traveler Programs | `CBP Trusted Traveler Programs` | 1 of 2 | `urn:gov:dhs.cbp.jobs:openidconnect:aws-cbp-ttp` |
| FAA - Delphi Elnvoicing | `DOT - eInvoicing` | 1 of 2 | `SP:EINVOICE_DCC_PROD` |
| PFPA Application Portal | `DOD - PFPA` | 1 of 2 | `https://pfpa.my.salesforce.com` |
| Gulf Restoration Test Team Site | `Gulf Restoration - Team Site` | 1 of 3 | `urn:gov:gsa:openidconnect.profiles:sp:sso:doi:gro-team-site` |

**One thing to check while you're in here:** `OASAM - OCIO - OSHA Information System (OIS)` and `OIS`
are two separate Applications sharing the **same** issuer string
(`urn:gov:dol:SAML:2.0.profiles:sp:sso:prd-osha:ois`). That looks like a duplicate Application rather
than two real ones — worth confirming, since it isn't something the missing team value explains.

Both lists are also produced as a CSV on every run —
`scripts/logs/data-migration/Application-portal-team-review-*.csv`, with an `Issue` column marking each row
`CONFLICT` (the 9) or `INCOMPLETE` (the 18).

**The root fix, if it's ever on the table:** because the team belongs to the Application, storing it
on the Applications table directly — rather than copying it onto each issuer string — would make all
27 of these impossible by construction. Not needed for the migration, which handles the current shape
fine; worth knowing if the Airtable base is ever restructured.

### Issuer Strings: 7 rows aren't linked to any Application, and 2 have no issuer string — ✅ CLOSED, optional field

**New 2026-08-13.** Small, but concrete enough to act on.

**7 rows have no Application link**, so whatever team they name has no record to land on and is
ignored (rule 9). Most have no usable team anyway, but two are worth a look:

| Issuer String | Team Name | Note |
| --- | --- | --- |
| `https://caia-dev.treasury.gov` | `#N/A` | dev/test |
| `urn:gov:gsa:testing:automation` | `#N/A` | test automation |
| `partnerportal-test` | `[Test] QA Dream Team` | test row — probably safe to delete |
| `urn:gov:gsa:openidconnect.profiles:sp:sso:gsa:pmsam` | `#N/A` | **looks real** — should this be linked to an Application? |
| `urn:gov:gsa:openidconnect.profiles:sp:sso:gsa:sam` | `#N/A` | **looks real** — should this be linked to an Application? |
| `https://doledp-edwprod.snowflakecomputing.com` | *(blank)* | production-looking; no team, no Application |
| *(none — row `recxcJQgTtruy4uqF`)* | *(blank)* | an all-but-empty row; only `Migrated to the partner portal` is set. Safe to delete. |

**2 rows have no issuer string value at all:**

- `recxcJQgTtruy4uqF` — the empty row in the table above.
- `reckfaCTqTTXlW5Fb` — this one *is* linked to an Application (*CMS (Credit Management System)*, where
  it appears in the tidy-up list above) and carries a Partner Portal Admin Email, but has no issuer
  string and no team. So it isn't blank so much as unfinished — worth checking whether an issuer string
  was meant to be entered, rather than just deleting it.

**Also worth confirming, though nothing looks wrong:** **182 Applications have no team on any of their
issuer strings.** These are *not* reported individually — there's simply nothing to migrate. But it's
a quarter of the table, so it's worth a sanity check that the gap is expected.

### Issuer Strings: Partner Portal Admins are recorded in two places that disagree — 🔴 OPEN

**New 2026-08-13.** Who administers an application in the partner portal is recorded **twice** in
Airtable, and the two don't match:

1. **`Roles` on the Contacts table** — a contact whose Roles include `Partner Portal Admin`.
2. **`Partner Portal Admin Email` on the Issuer Strings table** — names the admin per issuer string.

In Salesforce this is a single checkbox on the Application-Contact record, so both have to feed it.
**We use both** — someone is marked an admin if *either* source says so, never only where they agree.
Neither is treated as more correct than the other, because both were entered deliberately.

| | Pairs |
| --- | --- |
| Both sources agree | **882** |
| `Roles` says admin, Issuer Strings doesn't name them | **117** |
| Issuer Strings names them, `Roles` doesn't say admin | **86** |

**The 86 are the ones worth your attention.** In every one of those cases the person **isn't recorded
as a contact on that application at all** — 34 people across 68 applications. For example
`sockalingam.ramakrishnan@dol.gov` is named as the portal admin for *State of Alaska Unemployment
Insurance*, but isn't listed among that application's contacts. We now create the missing
application-contact link for them, since a portal admin plainly *is* a contact on that application —
but the gap is real, and it means the Contacts table is missing 86 genuine relationships.

**Good news:** all 239 admin email addresses match a contact that exists in Airtable, so nobody is
lost. That's checked on every run and will be reported if it ever stops being true.

**What we need — two things, neither urgent:**

1. **Worth a spot-check of the 117**, where someone's Roles say Partner Portal Admin but they aren't
   named as the admin on any of that application's issuer strings. Some will be people who *were* the
   admin and have since handed it over — in which case the Role is stale and worth clearing.
2. **Longer term, pick one place to record this.** Two sources for one fact will keep drifting apart.
   The Issuer Strings column is the more precise of the two (it's per application; a Role applies to
   every application on that contact row at once), but that's your call, not ours.

Full per-flag detail, including which source asserted each one, is in
`scripts/logs/data-migration/ApplicationContact-admin-source-*.csv`.

### Issuer Strings: 6 partner-portal team names are too long for Salesforce — ✅ RESOLVED 2026-08-14

**New 2026-08-13.** The Salesforce field holds 50 characters. **6 distinct team names are longer**
(up to 75), affecting **8 Applications** — one team covers three of them. Per rule 8, **the team name
is left blank on those Applications while the Team UUID still migrates**, so the team is correctly
identified, just not labelled.

We're deliberately **not truncating** these. A cut-off team name would look like a real one while not
matching what the partner portal actually shows, which is worse than an empty field.

| Len | Team Name | Application(s) affected |
| --- | --- | --- |
| 75 | `USACE - ERDC - MRSI (MILCON Requirements, Standardization, and Integration)` | MRSI Wizard |
| 65 | `GSA Financial Multiple Shared Tenant Application (MSA) - Momentum` | Pegasys MSA Momentum |
| 63 | `GSA Financial Management Services - Payment, WebVendors, Fedpay` | FedPay Vendor; Pegasys Payment Search (PPS); Web Vendor (WV) |
| 61 | `DOD - Office of Small Business - Mentor Protege Program (MPP)` | Mentor-Protégé Program (MPP) |
| 61 | `DOT - Airline Performance Economic Information System (APEIS)` | OST-APEIS |
| 59 | `DOT - National Transport Library Workroom - Digital Library` | OST- Library Systems (Work Room) |

**What we need — either one fixes it:** a shorter name for these teams in the partner portal, **or**
the Salesforce config owner widens the field. It's a plain text field and extending it is
straightforward, unlike the Application Name limit above, which is a platform cap we can't change.
Widening is probably the better answer — these names look deliberate rather than sloppy.

### Applications: the Partner Portal Team fields can't be loaded yet — ✅ RESOLVED 2026-08-14

**New 2026-08-13. Not an Airtable problem — no action needed from the Airtable data owners.** Recorded
here so the status of this data is visible in one place alongside everything else.

The Airtable side is ready: **696 Applications have a clean, unambiguous partner-portal team**. But
both Salesforce fields — Partner Portal Team Name and Partner Portal Team UUID — are currently set to
**Unique**, meaning no two Applications may share a value.

That's the wrong setting for what this data is. **A portal team legitimately owns many Applications**
— `DOI - FWS - ECOS` owns 54 of them, `DOI - IBC - Quicktime` 39, `Education ICAM Team` 20. With
Unique switched on, **442 of the 696 would be rejected** as duplicates.

The migration therefore **leaves both fields out of the load entirely** rather than failing most of
the Application records over them; everything else about those Applications migrates normally.

**What we need:** whoever owns the Salesforce configuration to switch **Unique off** on both fields.
Neither is an External ID and nothing matches records on them, so nothing depends on the setting.
Once it's changed, the data loads on the next run with no code change.

### Opportunities: 28 records have no Status — ✅ RESOLVED 2026-08-13

**Status: ✅ Resolved. Thank you — nothing further needed.** All 904 Opportunities now carry a Status.
Verified against a fresh export during the 2026-08-13 full reload: **0 rows without one**, down from
28. Those records now migrate.

### Opportunities: 16 records have no Account link — ✅ RESOLVED 2026-08-13

**Status: ✅ Resolved.** Every Opportunity now has an Account link — **0 without one**, down from 16.
This also means they pick up a Market Segment automatically (Salesforce derives it from the Account).

### Opportunities: blocked by the duplicate-Account problem — 🟡 PARTIALLY RESOLVED

**Status: 🟡 Partially resolved — 142 → 62, and held at 62 on 2026-08-14.** These point at Airtable
Account rows that don't match a Salesforce Account (the issue at the top of this document). Progress
on the Account duplicates cut this by more than half, but **this is the one downstream figure that did
not improve this round** — because the duplicates that were merged were not the ones blocking
Opportunities.

**The biggest single win available here is the `Department of Treasury` name collision — 5
Opportunities for one merge.** The rest are spread thinly across the genuinely-missing agencies and
territories described at the top, so they need Salesforce Accounts creating rather than an Airtable
edit. **All 62 will migrate automatically once those Accounts exist**, with no work needed on the
Opportunity records themselves. Current list:
`scripts/logs/data-migration/Opportunity-skipped-*.csv`.

### Opportunities: 729 records have no estimated go-live date — ✅ RESOLVED 2026-08-13

**Status: ✅ Resolved, and this one was a big lift — thank you.** **All 904 Opportunities now have an
`Est. Go Live` value**, up from 199 of 928.

This matters more than the count suggests. Close Date is required on every Salesforce Opportunity, so
until now we fell back to the last status-change date and then the created date — **dates that were
not real forecasts** and couldn't safely be used for reporting. As of this reload **0 Opportunities
use a fallback**: every Close Date in Salesforce is now a genuine estimate from Airtable.

### Opportunities: "Gov?t Employees" has a corrupted apostrophe — ✅ RESOLVED 2026-08-13

**Status: ✅ Resolved.** The literal question mark is gone — **0 records** carry `Gov?t Employees`,
down from 25. The mapping that corrected it on load is now a no-op and can be retired whenever the
transform is next touched.

### Opportunities: the "Priority Type" field can't be migrated yet — 🟡 PARTIALLY RESOLVED

**Status: 🟡 Partially resolved.** Done on 2026-08-13: a malformed Salesforce picklist value (all six
labels concatenated into one string) was deleted, and the correct target field was identified as
Level of Priority. Still outstanding: that field has no values to receive the data.

**Still open, and still not an Airtable problem — no action needed from the Airtable data owners.**
Airtable's Priority Type values (`Strategic`, `High Volume`, `IdV Upgrade`, `Leadership Escalation`,
`HISP - High Volume`, `HISP - Low Volume`, `N/A`) are all reasonable and are staying as they are.

The hold-up is on the Salesforce side. The field these values belong in — Level of Priority — offers
only `Low`, `Medium`, `High`, so there is nowhere for them to land. The seven values need to be added
to that field before the data can migrate.

**What we need:** whoever owns the Salesforce configuration to add the seven values, and to say
whether `Low`/`Medium`/`High` should remain alongside them or be replaced — they describe a
different thing (how important an opportunity is) than Priority Type does (why it's a priority).

Until then this field isn't migrated. **564 Airtable records have a value**, 462 of them on
Opportunities already loaded and waiting to receive it.

### Opportunities: identity-platform columns point at an untracked table — ✅ RESOLVED 2026-08-13

**Status: ✅ Resolved. Thank you — this one is done and needs nothing further from you.**

`Existing Identity Platforms` (259 records) and `Alternative Identity Platforms` (176 records) used to
link to a separate Airtable table that isn't part of the nine this migration reads, so we couldn't
resolve them to the vendor names Salesforce expects.

**Both columns have since been converted to plain multi-selects** holding the vendor names directly,
which is exactly what the Salesforce fields wanted. The per-value counts came through the conversion
unchanged (272 and 181 tags), so no data was lost doing it. Both fields now migrate.

**451 of the 453 selections migrate.** Two vendor names are spelled differently on the two sides and
the migration maps those explicitly rather than asking you to change them, so **no Airtable edit is
needed**. The remaining gap is Salesforce configuration, for the config owner rather than the
Airtable owners:

- **`CLEAR`** (2 records, on `Alternative Identity Platforms`) has no matching Salesforce value at
  all, so those two selections are dropped. We deliberately did *not* file it under a similar-looking
  vendor — CLEAR is its own company. **Add `CLEAR`** to both fields to migrate them, remembering the
  Login.gov record type as well as the field itself (a value the record type omits is rejected at
  load even when the field defines it).
- **`Ping / Forgerock`** (6 records) migrates today, but into a Salesforce value spelled
  **`Ping/Foregerock`** — an extra "e" misspelling ForgeRock, the vendor Ping Identity acquired.
  Airtable's spelling is the correct one; **worth correcting in Salesforce**, after which the mapping
  becomes a straight pass-through.

Salesforce also still defines eight vendors Airtable no longer offers — Google CiviForm, ManTech,
Granicus, Shibboleth, Exostar, Jakobsen Id, Mattr and Idemia — left over from the old linked table.
Nothing migrates into them; harmless, but worth a look when these picklists are next tidied.

> **One note for the migration team, not for Airtable:** this only works from an export pulled
> *after* the conversion. The transform now refuses to run against an older export rather than
> silently dropping the 453 affected values — see the Resolved log entry below.

### Contacts: 1,054 of 1,535 have no name — the single biggest data gap found

**Status: 🔴 OPEN.** **1,054 of 1,535** contacts have no `Name`; **31** have neither a name nor
an email.

Salesforce requires a last name, so where Airtable has none the migration **derives one from the
email address** rather than putting the raw address in the surname field. Of the 951 contacts that
needed this:

| What the migration could do | Contacts |
| --- | --- |
| Recovered a genuine **first and last name** from the address | **592** |
| Only the local part was usable (e.g. `jwoolf`, `crdavis1`) — no defensible split | 314 |
| **Skipped entirely** — no name *and* no email, nothing to identify the person | 45 |

A derived name is a good guess, not a fact: a nickname, a married name or an unusual address
produces the wrong name, and nobody in Salesforce can tell the difference. **Every derived name is
still a name you did not choose.**

Roughly 116 of the nameless ones look like **service or shared mailboxes** (`help`, `support`,
`desk`, `info`, `admin` in the address) rather than people — for example
`enterpriseservicedesk@dol.gov`, `warcit@usgs.gov`, `FEMA-EMI-LCMS@fema.dhs.gov`. The rest look
like real individuals whose name simply wasn't recorded.

**What we need — two separate decisions:**
1. **For real people:** names filled in, ideally as a first/last convention rather than one free-text
   field. Still the single highest-value cleanup for *data quality* on this list. The 314 contacts
   whose address has no split point (`jwoolf`) are the priority — the migration can do nothing
   useful with those, whereas the 592 at least get a plausible name.
2. **For service/shared mailboxes:** a decision on whether they should be Contacts at all. A shared
   help-desk address isn't a person, and forcing it into a Contact record (with a person's first/last
   name) will always look wrong. Options worth discussing: a dedicated record type, a naming
   convention, or storing them somewhere other than Contact entirely.

Full list in the run directory's `Contact-name-review-*.csv`.

### Contacts: 3 rows have an email address in the Name field — 🔴 OPEN

Three Contacts rows hold an **email address in the `Name` field**. The migration cannot tell that
from a real name, so it loads verbatim — Salesforce ends up with a contact called
`shyla.morisetty@dot.gov`.

**What we need:** replace the address in the `Name` field with the person's actual name (the `Email`
field already holds the address). The three are `shyla.morisetty@dot.gov`,
`christopher.villas@cisa.dhs.gov` and `icam-portfolio@gsa.gov`.

### ⚠️ NEW 2026-08-14: 7 help-desk names became "people" in Salesforce — 🔴 OPEN

Where Airtable's `Name` field holds a **help-desk or team name rather than a person**, the migration
takes it at its word and splits it into a first and last name — because it has no way to tell
"Help Desk" from a real name. Salesforce now contains contacts called:

| Airtable `Name` | Became in Salesforce |
| --- | --- |
| `HELP DESK` | First `Help`, Last `Desk` |
| `UI Claimant Portal Help Desk` | First `UI Claimant Portal Help`, Last `Desk` |
| `EBSA Lost & Found Help Desk Information` | First `EBSA Lost & Found Help Desk`, Last `Information` |
| `Peace Corps Help Desk` | First `Peace Corps Help`, Last `Desk` |
| `FDM Help Desk` | First `FDM Help`, Last `Desk` |
| `Help Desk Independent Study System` | First `Help Desk Independent Study`, Last `System` |
| `Wisconsin UI Help Center` | First `Wisconsin UI Help`, Last `Center` |

**This is only these 7.** The other 57 role inboxes the migration detected from their *email address*
(`support@`, `nfrhelpdesk@`, `foiasupport@`) were handled correctly — the address is kept whole and
**no first name is invented**. These 7 slipped through because the role name is in the `Name` field,
where the migration is supposed to trust what you wrote.

**What we need:** this is the same underlying question as the shared-mailbox item above — should
these be Contacts at all? If they should, they need a convention that doesn't read as a person's
name. If they shouldn't, removing the row (or the `Name` value) is enough.

### Contacts: the same person is entered multiple times — 🟡 61 → 12

**Status: 🟡 Down 80%** as of the 2026-08-14 export — email addresses appearing on 2+ Contact rows
went **61 → 12**. Nothing was blocked either way (the migration merges them), but the Airtable table
is now a much closer reflection of the real number of people. The text below still describes why the
duplication happens and applies to the remaining 12.

**This looks like a limitation of how Contacts are set up in Airtable, not careless data entry.**
Airtable has no way to link one person to several Applications, so the same person is entered again
for each association: one row carries their name and roles, the extra rows have a blank name and a
different Applications list. 47 of the 61 duplicated addresses differ in exactly that way.

Salesforce *does* have a proper link between contacts and applications, so the migration merges rows
sharing an email into a single contact (1,599 rows → 1,532 contacts) and will record the individual
application relationships separately. **No action needed for the migration** — but worth knowing that
Airtable's contact count overstates the number of real people, and that adding a proper
contacts↔applications link in Airtable would remove the need for the duplicates.

Three cases need a human eye because the duplicate rows disagree about the person's name:
`Bennet Lohr` vs `Bennett Lohre`, `Moye Xzavier` vs `Xzavier Moye`, and one row where the name field
holds an email address. Two more are **genuinely shared mailboxes used by two different teams** and
were deliberately left as separate contacts: `enterpriseservicedesk@dol.gov` ("EBSA Lost & Found Help
Desk Information" *and* "ENT BPMS Contact Center") and `warcit@usgs.gov` ("HELP DESK" *and* "USGS
WARC IT").

### Contacts: 10 people are in Airtable twice under two different email addresses — 🔴 OPEN

**New 2026-08-13.** These are the same person entered twice with **different** email addresses.
Because we identify a person by their email, we cannot safely tell that the two rows are one person
— so **each loads as its own Salesforce contact**, and Salesforce's duplicate rule then rejects the
second one.

**This is deliberate.** We could merge them on name, but that would assert that two email addresses
belong to one person, and we have no consistent way to know which address is current. Guessing wrong
attaches someone's history to an address they no longer use. **Two contacts is the honest outcome;
consolidating them is a decision only you can make.**

Sorted by how clear-cut they look:

| Person | The two addresses | Looks like |
| --- | --- | --- |
| **Brian Cooke** | `brian.v.cooke@cbp.dhs.gov` + `brian.v.cooke@associates.cbp.dhs.gov` | Same person — employee and contractor address at the same agency |
| **Linda Peters** | `peters.linda.j@dol.gov` + `peters.linda@dol.gov` | Same person — two formats on the same domain |
| **Brian Platz** | `brian_platz@ios.doi.gov` + `brian.p.platz@gmail.com` | Same person — work and personal |
| **Sivaram Ghorakavi** | `@nlrb.gov` + `@eeoc.gov` | Possibly moved agency |
| **Joel Schlagel** | `@usace.army.mil` + `@ios.doi.gov` | Possibly moved agency |
| **Patrick Newbold** | `@cms.hhs.gov` + `@ssa.gov` | Possibly moved agency |
| **Jason Ashley** | `jason.ashley@arkansas.gov` + `jason.k.ashley1@uscg.mil` | Unclear — could be two different people |
| **HELP DESK** | `hceperaton-moodle@hq.dhs.gov` + `warcit@usgs.gov` | Two different shared mailboxes that share a name |

**What we need:** for each, confirm whether it is one person or two. If one, keep a single Airtable
row with the current address and remove the other (or record the old one somewhere that isn't the
Email field). If two, nothing to do — they will keep loading as two contacts, which is correct.

**Two of these are not duplicates at all — they are mismatched data**, and are listed separately
below: `Jyothsna Charagundla` paired with `zhijun.wang@...`, and `Andrea McClain` with
`dunia.z.nooristani@...`.

> **Already handled, for contrast:** where one of the two rows has **no email at all**, we now merge
> it into the one that does — there is no competing address to be wrong about. That resolved
> `Hyon Kim` (a row in Opportunity Contacts with no email, matching `hyon.kim@gsa.gov`) on
> 2026-08-13. It is the only case in the current data.

### Contacts: 4 records were rejected as duplicates of existing Salesforce contacts

Salesforce has a rule blocking two contacts with the same first and last name. Four records hit it,
and each looks like a genuine data issue:

| Last name loaded | Email | Concern |
| --- | --- | --- |
| `Charagundla` | `zhijun.wang@associates.cbp.dhs.gov` | name and email don't match each other |
| `Mundy` | `christine.zagrobelny@maryland.gov` | name and email don't match each other |
| `DESK` | `warcit@usgs.gov` | shared mailbox ("HELP DESK"), not a person |
| `McClain` | `andrea.d.mcclain@dea.gov` | duplicates a contact already in Salesforce |

**What we need:** for the first two, confirm which is right — the name or the email. For the last,
confirm whether it's the same person already in Salesforce.

### Contacts: "Technical Emails" isn't a valid subscription type — ✅ RESOLVED 2026-08-14

**Status: ✅ Resolved. Thank you — nothing further needed.** Verified against the 2026-08-14 export:
**0 contacts** now carry `Subscription Type = "Technical Emails"`, down from 711. Nothing is being
dropped on load any more.

*(For the record, the original ask: Salesforce only offers `Newsletter Recipient` and `Technical
POC`. We deliberately did **not** assume "Technical Emails" meant "Technical POC" — a mailing-list
preference and a point-of-contact role are different things, and guessing would have invented role
data on 711 records.)*

### Contacts: can't be linked to any agency — 🟡 390 → 54 → 49, LARGELY RESOLVED

**Status: 🟡 Down from 390 to 49** as of the 2026-08-14 full reload — an 87% reduction, driven by the
Account fixes above rather than by anything done to the Contact records themselves. **1,876 Contacts
now load, up from 1,483.**

**Changed 2026-08-13.** Contacts with no resolvable Account are **skipped rather than loaded**. A
contact attached to no agency isn't usable in the CRM, can't inherit an owner, and each one caused
Salesforce to auto-create a junk placeholder Account.

Before skipping any, we exhaust three recorded links — Airtable's own Account column (965 contacts),
the contact's Application via its Partner Agreement (151), and, newly, **the contact's Opportunity**
(399). That last route matters: those people come from the Opportunity Contacts table, which has no
Account column of its own, and adding it rescued 399 contacts that would otherwise have been dropped
along with 435 of their Opportunity contact-role records.

A further 38 are matched by email domain where every other contact on that `.gov` domain belongs to
the same agency (listed in `scripts/logs/data-migration/Contact-domain-inferred-account-*.csv` — these are
inferred, not recorded, and are worth a spot-check).

**That leaves 54** (was 390) with no agency at all. As predicted, they traced back to the
unmatched-Account problem at the top of this document, and fixing those Accounts recovered them
automatically with no work on the Contact records.

**What we need:** still nothing separate — closing out the remaining Account duplicates recovers most
of the last 54. Current list: `scripts/logs/data-migration/Contact-no-account-*.csv`.

### Impediments: what does the impediment named "None" mean?

**This is the biggest open question on the Impediments table.** One impediment is named `None`, has
no Description and no Talking Point, and is linked to **465 opportunities** — more than five times
any real impediment (the next highest, `Unresponsiveness`, has 86).

It looks like a placeholder people select to mean *"this opportunity has no impediment"*. If that's
right, migrating it would be actively misleading: it would record 297 opportunities as being
impeded when the data means the opposite, and because Salesforce automatically totals up blocked
revenue per impediment, `None` would appear at the top of any "biggest blockers" report with a
meaningless multi-million-dollar figure.

**We are currently not migrating it** — the 267 links from genuine impediments loaded fine. Reversing
that takes a single setting, no code change.

**What we need:** confirmation of what `None` means. If it means "no impediment", the cleanest fix is
to remove those links in Airtable (an opportunity with no impediment simply shouldn't be linked to
one) and delete the record.

### Impediments: opportunities marked as both blocked and requested — 🟡 DOWN TO 7

**Status: 🟡 The count is now 7, as predicted.** 122 → **7**, because 115 of the original 122 involved
the `None` placeholder impediment, which the migration excludes.

The same opportunity appears in **both** the "Opportunities blocked" and "Opportunities requested"
lists for the same impediment. Salesforce stores a single severity per link, so it can't be both; we
record these as **Blocker** (the more severe reading). The 7 remaining are genuine and listed in
`scripts/logs/data-migration/OpportunityImpediment-severity-conflict-*.csv`.

**What we need:** confirm whether "blocked" or "requested" is correct for those 7, and ideally avoid
putting the same opportunity in both lists going forward. **Note this closes only if the `None`
question above is also closed** — the 115 are suppressed by our exclusion, not fixed at source.

### Impediments: "Feature - Citizenship verification" exists twice — ✅ RESOLVED 2026-08-13

**Status: ✅ Resolved.** Only **one** record with that name now exists, down from two, so linked
opportunities and blocked-revenue totals are no longer split.

## Recommended cleanup — not blocking, but worth doing

- **Impediments: 2 completely empty rows** (`recA9LjxxE56gV73J`, `recXyF5tOHJh07laz`) — no Name,
  Category, Description, or anything else filled in; the only values on them are Airtable's own
  computed rollups. Look like accidental blank rows. Safe to delete from Airtable; they won't migrate
  either way. **These are the same two rows as the "Impediments with no name" count** elsewhere in
  this document — one item, not two.
- **Applications: `"Decomissioned"` is misspelled** in the Status field (should be
  `"Decommissioned"`, two *m*'s) — used on 89 records. We're correcting this automatically on the
  Salesforce side, so it's not blocking anything, but fixing the spelling at the source in Airtable
  would prevent it from being typed wrong again in the future.
- **Applications: 8 records have no Partner Account link — 6 are retired, but ⚠️ 2 are LIVE.**
  Re-checked 2026-08-14.
  - **6 marked `Decomissioned`**, treated as retired/historical and not migrating — no action needed:
    `CBP I'm Ready`, `SAMS (CBP)`, `GSA Federal Advisory Committee Act Training`, `CCP Truck
    Staging`, `SPEARS Opportunity Portal | HUD Section 3 Opportunity Portal`, `Army Contract Writing
    System's (ACWS) Vendor Self Service (VSS)`.
  - ⚠️ **2 are not retired and are being withheld**: **`DOJ JMD`** (`Partner Pause`) and
    **`TSA News – Mobile Application`** (`Move to Production Request`). A Partner Account link is
    required, so these two do not migrate at all. **These are worth linking** — unlike the six above,
    they look like current work.

### Opportunities: only a small number have a real Partner Account link

Salesforce's Opportunity record has a **Partner Account** field. Filling it in turns out to be
possible for far fewer Opportunities than the Airtable views suggest, which is worth knowing before
anyone relies on that field for reporting.

The Partner Accounts table shows an `Opportunities` list, and it looks comprehensive — 961 entries
across 469 Opportunities. **But that list is a roll-up of the Opportunities belonging to the
Partner's parent Account, not a link recorded on the Partner Account itself.** Verified: for 72 of
the 76 Partner Accounts that show any Opportunities, the list is an *exact* match for the parent
Account's own Opportunities. The effect is that all 8 Partner Accounts sitting under the Department
of Defense show the same identical 50 Opportunities; all 3 under Department of Labor show the same
24; and so on. It doesn't tell us which Partner Account an individual Opportunity actually belongs to.

The only place a genuine Opportunity → Partner Account link is actually recorded is on
**Applications**, which reference both. That yields **82 Opportunities with an unambiguous Partner
Account** (no conflicts — each maps to exactly one), of which 66 can be linked in Salesforce today.

So: roughly 82 of 928 Opportunities (~9%) can have their Partner Account populated; the rest have no
recorded link anywhere.

**What we need:** confirmation that this is expected — i.e. that a Partner Account is only meaningfully
tied to an Opportunity once an Application exists connecting them. If Opportunities are *supposed* to
carry a Partner Account earlier than that, the link needs to be recorded somewhere real (most likely
a proper link field on the Opportunities table), because the current roll-up can't supply it.

**Four Partner Accounts don't match the pattern** and may indicate data issues:
`USDT-SSP` (shows 17 Opportunities but its Account has none — this is the record linked to two
Accounts, noted above), `GSA-IAE` and `GSA-OIT` (each show one more than their Account has), and
`GSA-OROS` (shows 9 against its Account's 4).

## Open questions — need a decision, not just a fix

- **"Escalated User Support Cases" column on Partner Accounts** links to records that aren't in any
  of the 10 Airtable tables this migration currently pulls from — is there a separate Cases/Support
  Tickets table that should be included in the migration, or is this column safe to ignore?
- **Partner Accounts' "Goals" column** — short repeated values (`Add Identity Verification`,
  `Increase Adoption`, etc.) with no destination on the Salesforce side yet. Not blocking anything,
  but if this data matters going forward, it needs either a dedicated field or a decision to leave it
  out.

## ✅ Resolved log

Closed items in date order — the short version of what's already been fixed. Nothing here needs
action; it exists so progress is visible and closed items don't get re-raised. Each entry links back
to the full item above, which is kept in place rather than deleted.

| Date | Item | What changed | Who fixed it | Effect |
| --- | --- | --- | --- | --- |
| 2026-08-13 | [Opportunities: identity-platform columns](#opportunities-identity-platform-columns-point-at-an-untracked-table---resolved-2026-08-13) | `Existing Identity Platforms` and `Alternative Identity Platforms` converted from linked records to plain multi-selects holding vendor names | **Airtable data owners** | Both fields now migrate. 272 + 181 tags, none lost in the conversion. 3 spelling differences mapped in code, no Airtable edit needed. ⚠️ Requires an Airtable export pulled *after* the conversion — the 2026-08-12 export predates it, and `Build-OpportunityLoad.ps1` now **fails loudly** rather than dropping the 453 stale values silently. |
| 2026-08-13 | [Opportunities: "Priority Type"](#opportunities-the-priority-type-field-cant-be-migrated-yet---partially-resolved) *(partial)* | Deleted the malformed picklist value that was all six labels concatenated into one string; confirmed the correct target field is Level of Priority, not the identically-labelled TTS OTCRM field | Salesforce config owner | Unblocks the *analysis*, not the data. Still needs the seven values added to Level of Priority before any of the 462 rows can load. |
| 2026-08-13 | [Opportunities: 28 with no Status](#opportunities-28-records-have-no-status--resolved-2026-08-13) | Every Opportunity now has a Status | **Airtable data owners** | 28 → 0. Those records migrate. |
| 2026-08-13 | [Opportunities: 16 with no Account link](#opportunities-16-records-have-no-account-link--resolved-2026-08-13) | Every Opportunity now has an Account link | **Airtable data owners** | 16 → 0. They also pick up a Market Segment automatically. |
| 2026-08-13 | [Opportunities: 729 with no estimated go-live date](#opportunities-729-records-have-no-estimated-go-live-date--resolved-2026-08-13) | `Est. Go Live` filled in across the board | **Airtable data owners** | 199/928 → **904/904**. **0 Opportunities now use a fallback Close Date**, so every Close Date in Salesforce is a real estimate rather than a stand-in. The biggest single data-quality win of the day. |
| 2026-08-13 | [Opportunities: "Gov?t Employees" apostrophe](#opportunities-govt-employees-has-a-corrupted-apostrophe--resolved-2026-08-13) | Corrupted value corrected at source | **Airtable data owners** | 25 → 0. The load-time mapping is now a no-op. |
| 2026-08-13 | [Applications: 11 incomplete drafts](#applications-11-records-look-like-incomplete-drafts--resolved-2026-08-13) | Drafts completed or removed | **Airtable data owners** | 11 → 0 with both a blank Status and no Partner Account. |
| 2026-08-13 | [Applications: over-length Name / URL](#applications-rows-with-a-name-or-url-too-long-for-salesforce--resolved-2026-08-13-one-left) | Long Application Names and `URL` values shortened | **Airtable data owners** | Name >80: 5 → 0 (nothing truncated any more). `URL` >255: 13 → 0 (nothing blanked). **1 `Launch Deck URL` of 275 chars remains.** |
| 2026-08-13 | [Applications: `ECOMP` mistyped go-live year](#applications-1-row-has-a-mistyped-go-live-year-ecomp--resolved-2026-08-13) | `0202-02-18` → `2020-02-18` | **Airtable data owners** | Date now valid and migrating. Worth confirming 2020 was the intended year (this doc had guessed 2022). |
| 2026-08-13 | [Applications: 2 unusable Ramp Up Approach values](#applications-2-rows-have-an-unusable-ramp-up-approach-value--resolved-2026-08-13) | `"Q1 - FY'23"` and `"146"` cleared | **Airtable data owners** | All 745 populated values are now valid; 0 unusable. |
| 2026-08-13 | [Impediments: "Feature - Citizenship verification" duplicated](#impediments-feature---citizenship-verification-exists-twice--resolved-2026-08-13) | The two records merged into one | **Airtable data owners** | Linked opportunities and blocked-revenue totals no longer split across two records. |
| 2026-08-13 | [Accounts: unmatched rows](#accounts-rows-that-dont-match-an-existing-salesforce-account--172--155) *(partial)* | Ongoing duplicate/merge work in Airtable | **Airtable data owners** | 172 → 155 unmatched, but the *downstream* effect is far larger: Applications blocked 359 → **22**, Opportunities 142 → **62**, Contacts with no agency 390 → **54**, Partner Accounts ~20 → **2**. |
| 2026-08-13 | Migration pipeline (engineering, not an Airtable fix) | Contact ownership now inherits the Account owner; Contact sourcing folds in the Opportunity Contacts table; Partner Portal Team + Admin sourced from the new Issuer Strings table; Account hierarchy bootstrap | Engineering | **8,734 records migrated, up from 6,819 (+28%)**. Contact ownership went from 100% fallback to **1,870 real owners / 0 fallback**. |
| **2026-08-14** | [Accounts: the 12 named duplicate rows](#accounts-rows-that-dont-match-an-existing-salesforce-account--172--155--154-but-see-below) *(the duplicate half of the item)* | All 8 "confirmed duplicates" **and** all 4 "needs confirmation" rows merged into their canonical twin; each twin verified present exactly once | **Airtable data owners** | The longest-standing item on this list. Applications blocked 22 → **13**, Application–Contact links 128 → **77**, Contacts with no agency 54 → **49**, Notes 21 → **7**. ⚠️ Two follow-ons opened: the `Department of Treasury` name collision, and 8 ambiguous generic office names. |
| **2026-08-14** | [The 14 highest-impact Account rows](#follow-up-2026-08-13-the-14-highest-impact-account-rows--13-of-14-resolved-2026-08-14) | 13 of the 14 rows closed — 12 merged away and `Office of Inspector General` now matches | **Airtable data owners** | This was the main worklist on this document. `Department of the Interior` alone was worth **203 Applications**. **Only `Bureau of Consular Affairs` remains**, and both its Opportunities are already `Closed Won`. |
| **2026-08-14** | [Partner Accounts: 5 rows with no working Account link](#partner-accounts-5-rows-have-no-working-link-to-an-account--resolved-2026-08-14) | All 4 unlinked rows linked; `USDT-SSP`'s double link resolved to one Account | **Airtable data owners** | 5 → **0**. Partner Accounts migrated 92 → **97**. |
| **2026-08-14** | [Contacts: "Technical Emails" subscription type](#contacts-technical-emails-isnt-a-valid-subscription-type--resolved-2026-08-14) | Value removed from the Subscription Type field | **Airtable data owners** | 711 → **0**. Nothing dropped on load any more. |
| **2026-08-14** | [Contacts: the same person entered multiple times](#contacts-the-same-person-is-entered-multiple-times--61--12) *(partial)* | Duplicate contact rows consolidated | **Airtable data owners** | Emails on 2+ rows **61 → 12** (-80%). Nothing was blocked either way, but the table now reflects the real number of people far more closely. |
| **2026-08-14** | Migration pipeline (engineering, not an Airtable fix) | Pre-flight now blocks the run unless all nine LDGCRM Flows are active — added after a QA load reported 8,740 records and 0 failures with every Flow switched off and Market Segment blank on 100% of Partner Accounts, Opportunities and Applications | Engineering | **8,831 records migrated**, 0 unexpected failures, and the 12-step load ran end to end **without stopping once** (it halted twice on 2026-08-13). Market Segment verified populated on **every** migrated Partner Account, Opportunity and Application. |

## Already decided, listed here for visibility (not asks)

- Applications' `Pilots`, `Usage Tracker Application Name`, and `Vital Update %` columns: confirmed
  not needed in Salesforce, won't be migrated.
- Applications' `Issuer Strings` column: **the issuer string values themselves** are still not
  migrated — Salesforce's Issuer Strings field holds a single 40-character value, and 776 of the 899
  issuer strings are longer than that (the longest is 130), while 847 Applications have more than one.
  The field's own help text also describes it as one the OEs maintain by hand against ZenDesk and
  GitHub, so it isn't the migration's to fill.
  **Superseded in part, 2026-08-13:** the **Issuer Strings table** *is* now pulled from Airtable and
  *is* part of the migration — it is the only place `Team Name` and `Team UUID` are recorded, and
  those two do migrate onto the Application. See the three Issuer Strings items above.
- Partner Accounts' `Migrated to the partner portal` column: not migrating for now (not permanent).
