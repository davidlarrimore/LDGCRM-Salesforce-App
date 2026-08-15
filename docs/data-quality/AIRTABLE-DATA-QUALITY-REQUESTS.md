# Airtable data quality — open items

> **Who this is for:** whoever owns and maintains the **Airtable base**, plus (in a clearly marked
> section at the end) whoever owns the **Salesforce configuration**.
>
> **You don't need to understand the migration to act on this.** Each item says what's wrong, which
> rows, and what it costs.
>
> **Nothing here requires an engineer.** Every transform re-reads Airtable on each run, so fixing an
> item and asking for a re-run picks up the newly valid records automatically — no code change, no
> deployment.

**This document lists only what is still open.** Resolved items are removed rather than archived — if
something you fixed is no longer here, that is the confirmation it landed.

**Decisions that have been made are not listed here either.** Where the project owner has settled how
something migrates, it is a rule, not a request: see
[TRANSFORMATION-RULES.md → Settled business rules](../engineering/TRANSFORMATION-RULES.md#settled-business-rules--closed-not-open-questions).
That covers derived contact names, the `Launch Level` default, the `None` impediment, portal-team
optionality, contact merging and Partner Portal Admin sourcing — **please don't re-raise those.**

**Measured 2026-08-15** against a fresh Airtable pull and a Dev wipe-and-reload. **That load did not
complete** — it halted at step 5 of 12 on item 3 below, which is new since 2026-08-14.

---

## At a glance

**Five items remain. Three are yours; two are Salesforce-side. Item 3 is blocking and is new.**

| # | Item | Rows | What it costs | Whose call |
| --- | --- | --- | --- | --- |
| 1 | [Accounts with no Salesforce match](#1-accounts-with-no-salesforce-match--92-rows-was-154) | **92** *(was 154)* | ~84 records across 5 objects | **Salesforce**, with 3 Airtable fixes |
| 2 | [Owners with no active Salesforce login](#2-owners-with-no-active-salesforce-login--a-short-confirmation-not-a-defect) | **3 names** | nothing — the fallback owner is working as designed | **Confirm only** |
| 3 | [178 contacts all named "Help Desk"](#3-178-contacts-are-all-named-help-desk--no-longer-blocking-still-worth-fixing) | **178** | ✅ no longer blocks — but 175 identically-named contacts are near-unsearchable | **Airtable** |
| 4 | [Emails in the Name field](#4-three-contacts-are-named-after-an-email-address--3-rows) | **3** | 3 contacts named after an address | **Airtable** |
| 5 | [Small tidy-ups](#5-small-tidy-ups) | various | nothing | **Airtable** |

---

## 1. Accounts with no Salesforce match — 92 rows *(was 154)*

**Down from 154 on 2026-08-14** — the Airtable merges plus a hierarchy repair on our side closed 62 of
them. Airtable has 737 Account rows and **637 now match** a Salesforce Account.

**Re-analysed 2026-08-15, and the earlier framing was wrong.** This was described as "real
organisations with no Salesforce Account at all", implying 154 new Accounts. That is not what the data
shows. **54 of the 92 name a parent agency, and for 51 of them that parent already exists in
Salesforce** — so these are *bureaus and offices that need creating underneath an Account that is
already there*, which is a far smaller and more mechanical job than it looked.

The 92 split four ways, cheapest first:

| Group | Rows | What it actually is | Who fixes it |
| --- | --- | --- | --- |
| **1A** | **42** | Bureau/office whose parent agency **exists in Salesforce** — create it underneath | Salesforce |
| **1B** | **9** | Parent exists but **Airtable spells it differently** — rename the Airtable value | **Airtable** |
| **1C** | **3** | Parent genuinely absent from Salesforce | Salesforce |
| **1D** | **38** | **No parent named in Airtable at all** — needs a parent deciding | **Airtable** |

**What it's holding back (2026-08-15):** 17 Opportunities, 25 Applications, 24 Opportunity Contacts,
16 Notes and 2 Partner Accounts. *(Opportunity was 62 — most of that closed with the merges.)*

Full list: `scripts/logs/data-migration/Account-reconciliation-unmatched-*.csv`.

### 1A. 42 bureaus whose parent agency already exists — create them underneath *(Salesforce)*

**`Bureau of Consular Affairs` is the model for this whole group** — it is a bureau of the Department
of State, Airtable says so in its `Parent` column, and `Department of State` is already a Salesforce
Account. It was previously listed under 1d below as "no match, and never had one", which was
misleading: the *bureau* has no Account, but its *parent* does, so the fix is to create it in the
right place rather than to decide whether it belongs.

The same is true of 41 others. Grouped by the parent they belong under:

| Parent *(exists in Salesforce)* | Bureaus / offices to create |
| --- | --- |
| **Department of State** *(9)* | Bureau of Consular Affairs · Bureau of Arms Control, Verification, and Compliance · Bureau of Global Talent Management · Bureau of Overseas Building Operations · Economic and Business Affairs · Office of Secretary · Office of the Counselor · Office of the Undersecretary for Political Affairs · Office of the Undersecretary for Public Diplomacy and Public Affairs |
| **Department of Defense** *(5)* | Director of Net Assessment · General Counsel of the Department of Defense · Under Secretary of Defense Intelligence · United States Special Operations Command · United States Transportation Command |
| **Department of Justice** *(5)* | Interpol – Washington · Office of Community Oriented Policing Services · Office of Legislative Affairs · Office of the United States Attorneys · U.S. Trustee Program |
| **General Services Administration** *(4)* | Federal Permitting Improvement Steering Council (FPISC) · GSA Board of Contract Appeals · Office of Civil Rights · Office of the Chief Financial Officer |
| **Department of Labor** *(3)* | Office of the Secretary · Office of the Solicitor · Veterans' Employment and Training Service |
| **Office of Personnel Management** *(3)* | Human Resources · Office of Diversity, Equity, Inclusion & Accessibility · Office of Small and Disadvantaged Business Utilization |
| **Social Security Administration** *(3)* | Deputy Commissioner for Hearings Operations · Deputy Commissioner for Human Resources · Office of Civil Rights and Equal Opportunity |
| **Nuclear Regulatory Commission** *(2)* | Executive Director for Operations · Office of the Chief Human Capital Officer |
| **Others** *(8)* | Congress → Senate · Department of Education → Office for Civil Rights · HHS → Office of the Assistant Secretary for Health (OASH) · EPA → Office of General Counsel · NIH → National Institute of Allergy and Infectious Diseases (NIAID) · NSF → Directorate for Engineering · State and Local Government → United States Virgin Islands · VA Central Office → VA Office of Information and Technology (VA OIT) |

**Recommendation:** create these 42 as `Federal` Accounts with the stated parent. It is one batch of
work against a list that is already validated — every parent named here was confirmed present in
Salesforce on 2026-08-15. Doing so also resolves `Under Secretary of Defense Intelligence`, which is
what item 1e's NGA row is waiting on.

### 1B. 9 rows where the parent exists but Airtable spells it differently *(Airtable fix — cheapest item here)*

These looked like missing agencies and are not. The Salesforce Account exists; only the wording
differs, so the match fails on an exact-name comparison.

| Airtable `Parent` says | Salesforce actually calls it | Rows affected |
| --- | --- | --- |
| `Department of Agriculture` | **`U.S. Department of Agriculture`** | 5 |
| `Department of the Treasury` | **`Department of Treasury`** *(no "the")* | 2 |
| `Department of the Interior` | **`Department of Interior`** *(no "the")* | 1 |
| `Udall Foundation` | **`Morris K. Udall and Stewart L. Udall Foundation`** | 1 |

**Recommendation:** change the Airtable `Parent` values to the Salesforce wording. Best
value-for-effort on this list after the Treasury merge — four find-and-replaces recover 9 rows.
*(Alternatively rename the Salesforce Accounts to match Airtable, if the fuller names are preferred —
but that is a change to records this migration does not own.)*

### 1C. 3 rows whose parent really is absent from Salesforce

`Federal Judiciary` (2 rows) and `Legislative Branch` (1). Nothing of either name exists — the closest
matches are `Senate Committee on Judiciary` and a scatter of unrelated "Legislative Affairs" offices.
**Decide:** create the two parent Accounts, or re-point these rows at a parent that does exist.

### 1D. 38 rows with no parent named at all *(Airtable)*

The largest remaining group and the one only you can resolve — Airtable records no `Parent`, so there
is nothing to place them under. Many are genuinely top-level and simply need Accounts creating:

> `U.S. Census Bureau`, `United States Postal Service`, `Bureau of Diplomatic Security`,
> `United States Army Corps of Engineers`, `The Supreme Court of the United States`,
> `United States Courts of Appeals`, `Special Courts: United States Tax Court`,
> `Guam`, `American Samoa`, `Puerto Rico`, `Northern Mariana Islands`,
> `John F. Kennedy Center for the Performing Arts`, `U.S. Commission on Civil Rights`,
> `Council of Inspectors General on Integrity and Efficiency`, …

**Recommendation:** fill in `Parent` where one applies — `U.S. Census Bureau` under Commerce,
`Bureau of Diplomatic Security` under State, `United States Army Corps of Engineers` under Defense —
and they drop into group 1A. The territories and courts are probably top-level and just need Accounts.

### 1a. `Department of Treasury` exists twice — blocks 5 Opportunities *(Airtable fix)*

Two Airtable rows now share this exact name. Only one can match the single Salesforce Account of that
name; the other is orphaned along with its 5 Opportunities.

**What we need:** merge the two rows into one, relinking anything pointing at the loser. **Best
value-for-effort item on this list — 5 Opportunities for one merge.**

### 1b. Three duplicate office rows *(Airtable fix)*

Several agencies each run an office with the same generic name, so `Office of Communications` alone
exists under both OPM and NASA. **The migration now tells them apart using your `Parent` column**, so
this is handled — with one exception it can't resolve:

- **All three `Office of Communications` rows name the same parent (OPM)**, and **both
  `Office of the Director` rows do too.** They therefore describe the same office, and only the first
  can claim the Salesforce record; the rest are reported as duplicates.
- One of the three is also tagged Market Segment `Defense & National Security` while sitting under
  OPM, which looks wrong regardless.

**What we need:** merge them down to one row each.

### 1c. Two offices whose parent agency has no Salesforce Account

`Office of the Deputy Secretary` under *Department of State*, and `Office of the Inspector General`
under *Department of Agriculture*. Salesforce has offices of those names, but not under those
agencies. These belong with the 154 above — either an Account needs creating, or the `Parent` is
wrong.

### 1e. `AmeriCorps` and `National Geospatial-Intelligence Agency` — the `Parent` value is wrong *(Airtable fix)*

**New on 2026-08-15, and caused by a fix on our side, not by you.** Salesforce previously held one
Account of each name; it now holds the two that production actually defines. That is more correct, but
it means the name alone no longer identifies the record, so the migration falls back to your `Parent`
column — and in both cases it doesn't match either candidate:

| Airtable row | Airtable says the parent is | The two Salesforce Accounts actually sit under |
| --- | --- | --- |
| `National Geospatial-Intelligence Agency` | `Under Secretary of Defense Intelligence` | Defense Intelligence Agency · Department of Defense |
| `AmeriCorps` | `AmeriCorps` — **itself** | *(no parent set)* · Department of Labor |

`AmeriCorps` naming itself as its own parent is almost certainly the error. For the NGA row, either
the office under `Under Secretary of Defense Intelligence` needs creating in Salesforce, or the
`Parent` should name one of the two agencies above.

**What it's costing:** 1 Partner Account (`AC`) and 1 (`USDI-NGA`) fail to load, plus whatever hangs
off them. Both return automatically on the next run once the `Parent` is corrected.

*(The former item 1d, `Bureau of Consular Affairs`, is resolved as a question: it is a bureau of the
Department of State, whose Account already exists. It is now the worked example in group 1A.)*

---

## 2. Owners with no active Salesforce login — a short confirmation, not a defect

**Substantially downgraded 2026-08-15.** This was previously the "highest-value item on the list", on
two premises that were both wrong.

**Wrong premise 1 — the mechanism.** It said records with no resolvable owner *inherit the parent
Account's owner*. They do not. That was an earlier draft of the rule, **dropped by the project owner on
2026-08-14**. Every such record now goes to a single named fallback owner, **`peter.marks@gsa.gov`**.
Measured in Dev after the 2026-08-15 load: **360 of 887 Opportunities** and **352 of 1,033
Applications** sit with Peter Marks. There is no service-account inheritance and no `SystemUser
DataLoader` involvement — that whole explanation described a design that no longer exists.

**Wrong premise 2 — that a missing login is a problem.** For anyone who has **left the team, it is the
designed outcome.** Their records transitioning to Peter Marks is exactly what the fallback is for, so
there is nothing to fix and nothing to track. Confirmed 2026-08-15 (project owner): **`hanna.kim@gsa.gov`
and `gabriel.vorleto@gsa.gov` are no longer with the team** — both correctly resolved to Peter Marks,
and neither is an issue.

### This now has a home: the owner roster

**Added 2026-08-15.** Rather than re-litigating this list every load, the answer lives in
**`scripts/reference/salesforce-user-roster.csv`** — one row per record owner, with a single
business-owned column, `ExpectedInSalesforce` (`yes` / `no` / `unknown`).

**It changes no behaviour.** Records still go to their Airtable owner where that person resolves to an
active User, and to Peter Marks where they don't — automatically, as designed. The roster exists only
because the fallback is *correct* for someone who has left and *a provisioning gap* for someone who is
current staff, and **nothing in the run output tells those apart.** Pre-flight reads it in `Full` and
`Prod` only, reports the mismatches, and **never blocks**.

All 17 owners are seeded. `peter.marks` is `yes` (he is the fallback and the load hard-fails without
him) and `gabriel.vorleto` is `no`. **The remaining 15 are `unknown` and need the business's answer.**

For each name below: **is this person current staff?** If yes, an active Salesforce login routes their
records to them. If they have left, **no action — Peter Marks is correct.**

| Person | Opportunities | Salesforce user | Status |
| --- | --- | --- | --- |
| `elizabeth.mays@gsa.gov` | **146** | none | ❓ confirm |
| `gabriel.vorleto@gsa.gov` | 78 | deactivated | ✅ **left the team — no action** |
| `tony.parrilla@gsa.gov` | 15 | none | ❓ confirm |
| `sierra.stewart@gsa.gov` | 8 | none | ❓ confirm |

Also falling back, on Partner Accounts and Meetings rather than Opportunities:
`robert.owens`, `nour.aldimashki`, `goutham.kommanaboyina`, `brianna.naolu` (no user); `trish.nguyen`,
`diondra.humphries`, `becky.badalato`, `matt.pritchard`, `ambuj.neupane` (deactivated); and
`hanna.kim` — ✅ **left the team, no action**.

Salesforce will not assign a record to a deactivated user, so a deactivated account behaves exactly
like a missing one. **A deactivated login is therefore good evidence the person has left**, which
means most of this list probably needs no action at all.

**`elizabeth.mays@gsa.gov` is the one worth answering first** — 146 Opportunities, and no Salesforce
user has ever existed, so unlike the deactivated names there is no signal either way.

*(Sandbox observation — confirm against production before acting.)*
Lists: `Opportunity-unresolved-owner-*.csv`, `PartnerAccount-unmapped-owner-*.csv`.

---

## 3. 178 contacts are all named "Help Desk" — no longer blocking, still worth fixing

> **✅ UNBLOCKED 2026-08-15, from the Salesforce side rather than yours.** These 157 Contacts were
> being rejected by a Salesforce duplicate rule that matched on **first + last name only**. That rule
> now also requires the **email address** to match, so 178 different mailboxes sharing a name no
> longer collide. Re-verified the same day: **1,888 Contacts submitted, 1,888 loaded, 0 failures.**
>
> **The data question is still open, though, and this is the honest position:** nothing was fixed
> about the data. Salesforce now contains **175 Contacts all named "Help Desk"**, which loads fine and
> is close to unusable — searching the CRM for a partner's help desk returns 175 identical names with
> no way to tell which agency any of them belongs to. It has moved from *blocking* to *bad*, which is
> progress, not resolution.

**This was the single blocking item, and it is new since 2026-08-14.** It stopped the 2026-08-15 Dev
load at step 5 of 12 before the rule was changed.

**178 Contact rows now have the exact `Name` "Help Desk"** — 12% of the whole Contacts table. They are
not duplicates of each other: they are 178 *different* mailboxes at different agencies
(`npms@dot.gov`, `ocioclientcenter@dot.gov`, `sfs@opm.gov`, `cbpone@cbp.dhs.gov`, …), each of which
now carries the same name.

**Why that breaks the load.** Salesforce has an org rule rejecting contacts that share a first *and*
last name. 178 rows all named `Help Desk` → first `Help`, last `Desk` → **Salesforce accepted the
first one and rejected 157.** Those 157 people are simply absent from the CRM, and every Application
link and Opportunity role that depended on them is withheld too.

**This looks like it came from fixing the "contacts with no name" item, and we are grateful for the
effort — but this particular fill-in costs more than the blank did.** Rows with no name fell 1,054 →
857 over the same period, and 178 `Help Desk` rows appeared. When the `Name` was blank the migration
derived a distinct name from the email address (`npms@dot.gov` → `npms`), so all 178 loaded
successfully. A shared generic name is the one value that fails where blank succeeded.

**We checked whether these are actually helpful duplicate-suppression, and they are not.** The
reasonable reading is that contacts are being unified at source and Salesforce is now correctly
refusing copies that should never have existed. That is true of the six people in item 5 below — but
not here. Of the 140 rejected rows that carry an email, **139 have an address that appears nowhere
else in Salesforce**; only 1 was a genuine duplicate. They span **78 email domains across 41
agencies** (DHS 18, Interior 15, Transportation 14, Education 9 …). These are different agencies'
help desks, not one help desk recorded 178 times.

**What we need — any one of these works:**

1. **Best: clear the `Name` on all 178.** They are role inboxes, not people. Blank is explicitly
   handled: the address is kept whole and no first name is invented. This restores all 157.
2. **Or make each name distinct and real** — `NPMS Help Desk`, `CBP One Help Desk`, and so on. Names
   that differ from each other load fine.
3. **Or tell us these should not be contacts at all** and we will exclude them.

⚠️ **Please don't apply the same fill-in to the remaining 857 unnamed rows.** Any generic value
repeated across rows will fail the same way. Blank is genuinely better than a shared placeholder here.

### The original 7, still open and unchanged

Separately, these hold a help-desk name in `Name` that is *unique*, so they load — they just read as
staff. Same ask: clear the `Name`, or confirm they should read as people.

| Airtable `Name` | Became |
| --- | --- |
| `UI Claimant Portal Help Desk` | First `UI Claimant Portal Help`, Last `Desk` |
| `EBSA Lost & Found Help Desk Information` | First `EBSA Lost & Found Help Desk`, Last `Information` |
| `Peace Corps Help Desk` | First `Peace Corps Help`, Last `Desk` |
| `FDM Help Desk` | First `FDM Help`, Last `Desk` |
| `Help Desk Independent Study System` | First `Help Desk Independent Study`, Last `System` |
| `Wisconsin UI Help Center` | First `Wisconsin UI Help`, Last `Center` |
| `SSA Help Desk` ×2 | First `SSA Help`, Last `Desk` |

The other ~57 role inboxes were detected from their *email address* (`support@`, `nfrhelpdesk@`) and
handled correctly. Only names in the `Name` field slip through, because that is the one field the
migration is meant to trust.

---

## 4. Three contacts are named after an email address — 3 rows

`shyla.morisetty@dot.gov`, `christopher.villas@cisa.dhs.gov`, `icam-portfolio@gsa.gov` are in the
**`Name`** field. The migration cannot tell these from a real name, so Salesforce ends up with a
contact *called* an email address.

**What we need:** replace with the person's actual name — the `Email` field already holds the address.

---

## 5. Small tidy-ups

None of these block anything or need a decision.

- **Applications: `"Decomissioned"` is misspelled** (should be `"Decommissioned"`, two *m*'s) — used
  on **89 records**. Corrected automatically on load, so nothing is blocked; fixing it at source stops
  it being typed wrong again.
- **Applications: 1 `Launch Deck URL` is 275 characters** (on `medicare.gov`) — over Salesforce's 255
  limit for a URL field, so it is left blank. It's a Google redirect wrapper around a Drive link;
  replacing it with the plain Drive URL fixes it.
- **Impediments: 2 completely empty rows** (`recA9LjxxE56gV73J`, `recXyF5tOHJh07laz`) — no Name,
  Category or Description; the only values are Airtable's own computed rollups. Safe to delete.
- **Issuer Strings: 136 `Team Name` and 137 `Team UUID` cells hold the literal text `#N/A`.** Blocks
  nothing — we transform it to blank — but a cell containing `#N/A` looks filled in, so the table
  reads as 92% complete when the real figure is 77%.
- **Issuer Strings: 7 rows link to no Application**, so whatever team they name has nowhere to land.
  Two look real and may need linking:
  `urn:gov:gsa:openidconnect.profiles:sp:sso:gsa:pmsam` and
  `urn:gov:gsa:openidconnect.profiles:sp:sso:gsa:sam`.
- **Contacts: `Andrea McClain` is paired with `dunia.z.nooristani@dea.gov`.** The name and the email
  don't match each other, so one of the two is wrong.
- **Six people appear under two email addresses, and the second copy is rejected — correctly.**
  Previously recorded here as "handled by the merge rules and needs nothing"; that was wrong, and the
  2026-08-15 load showed why. The migration merges rows sharing an *email*, so two addresses stay two
  rows, and Salesforce's duplicate rule then rejects the second. **The outcome is right** — one person,
  one contact — so nothing is lost and no action is required. Listed only so the rejections are not
  mistaken for a fault:

  | Person | Rejected address | Kept as |
  | --- | --- | --- |
  | Terry L. Harrison | `terry.l.harrison@uscis.dhs.gov` | `terry.harrison@uscis.dhs.gov` |
  | Brian Cooke | `brian.v.cooke@associates.cbp.dhs.gov` | `brian.v.cooke@cbp.dhs.gov` |
  | Sivaram Ghorakavi | `sivaram.ghorakavi@eeoc.gov` | `sivaram.ghorakavi@nlrb.gov` |
  | Joel Schlagel | `joel_schlagel@ios.doi.gov` | `joel.d.schlagel@usace.army.mil` |
  | Jason Ashley | `jason.k.ashley1@uscg.mil` | `jason.ashley@arkansas.gov` |
  | Patrick Newbold | `patrick.newbold@ssa.gov` | `patrick.newbold@cms.hhs.gov` |

  Worth confirming only whether the four who span *two different agencies* have genuinely moved
  employer, in which case the older address may want retiring at source.

---

## Salesforce-side items, for completeness

Recorded so the state of the data is visible in one place. The engineering counterpart is
[SALESFORCE-CHANGE-REQUESTS.md](../engineering/SALESFORCE-CHANGE-REQUESTS.md).

- **Identity platforms — two small gaps.** `CLEAR` (2 records) has no matching Salesforce value, so
  those selections are dropped; adding it to both fields **and** the `Login_gov` record type migrates
  them. And `Ping / Forgerock` lands in a Salesforce value spelled **`Ping/Foregerock`** — an extra
  "e". Airtable's spelling is correct; fixing Salesforce makes the mapping a straight pass-through.
- **Eight vendors Salesforce defines that Airtable no longer offers** — Google CiviForm, ManTech,
  Granicus, Shibboleth, Exostar, Jakobsen Id, Mattr, Idemia. Nothing migrates into them; harmless, but
  worth a look when these picklists are next tidied.
