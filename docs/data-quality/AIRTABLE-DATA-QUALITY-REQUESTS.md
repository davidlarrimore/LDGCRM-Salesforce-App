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

**Measured 2026-08-15** against a fresh Airtable pull (709 Accounts, 1,515 Contacts, 904
Opportunities, 1,058 Applications) and a full Dev wipe-and-reload.

**Nothing here is blocking.** That load completed end to end: **9,079 records, 2 failures, 0
unexpected.** Everything below improves how much of Airtable reaches the CRM, or how usable it is
once there — none of it stops a migration running.

---

## What changed since the last measurement

Real progress, and it is worth seeing before the open list:

| | Then | Now |
| --- | --- | --- |
| Accounts with no Salesforce match | 92 | **23** |
| `Department of Treasury` duplicated (cost 5 Opportunities) | open | **fixed** |
| `Office of Communications` triplicated | 3 rows | **1 duplicate left** |
| `Decomissioned` misspelt on the Application status picklist | 89 records | **fixed** — `Status` now spells it correctly on 96 |
| A 275-character `Launch Deck URL` | 1 | **fixed** — the longest URL is now 214 |
| Completely empty Impediment rows | 2 | **fixed** — deleted |
| Contacts rejected by Salesforce's duplicate rule | 167 | **0** — the rule is switched off by the load now |

**The owner-login item is gone entirely.** It has a proper home now:
`scripts/reference/salesforce-user-roster.csv`, which the business completed on 2026-08-15. Pre-flight
reads it before every Full or Prod load and reports anyone whose records will not reach them.

---

## ⚠️ This list holds only what COSTS RECORDS

**Standing rule, project owner 2026-08-15.** An item earns a place here only if it stops a row
reaching Salesforce, gets it withheld, or attaches it to the wrong parent. Cosmetic findings — a
Contact named after its email address, `#N/A` in a Team Name, an Application whose issuer strings
only partly agree — are **not** asks, because the record loads correctly regardless. They were being
re-reported every run, which buried the items that do cost records.

**Decisions already taken are not re-raised either.** Over-long URLs, contacts under two addresses,
and the unlinked issuer strings are settled or parked; they live in
[TRANSFORMATION-RULES.md → Settled business rules](../engineering/TRANSFORMATION-RULES.md#settled-business-rules--closed-not-open-questions).

The test before adding anything: **name the records that do not reach Salesforce because of it.** If
the answer is none, it does not belong here.

---

## At a glance

**Two items remain.**

| # | Item | Rows | What it costs | Whose call |
| --- | --- | --- | --- | --- |
| 1 | [Accounts with no Salesforce match](#1-accounts-with-no-salesforce-match--34-rows) | **34** | ~130 records across 6 objects | **Salesforce**, with ~10 Airtable fixes |
| 2 | [`Gov Employees` is not a Salesforce value](#2-gov-employees-is-not-a-salesforce-value--23-opportunities) | **23** | 23 Opportunities lose a tag | **Salesforce** |

---

## 1. Accounts with no Salesforce match — 34 rows

**Down from 92.** Airtable has **709 Account rows and 675 now match** a Salesforce Account. This is by
far the biggest remaining lever: an Account that cannot be matched strands everything hanging off it.

**What it's holding back right now:** 15 Opportunities, 20 Applications, 63 Contacts, 18 Opportunity
Contacts, 12 Notes and 2 Partner Accounts — about **130 records**, all of which return automatically
on the next run once the Account resolves. No code change needed.

The 34 split two ways.

### 1A. 23 rows match no Salesforce Account at all

**11 of these name a parent that already exists in Salesforce**, so they are bureaus and offices that
need creating *underneath* an Account that is already there — mechanical, not a research job:

| Airtable row | Parent named |
| --- | --- |
| `U.S. Tax Court \| US Tax Court` | Federal Judiciary |
| `Senate` | Congress |
| `Office of the General Counsel` | Nuclear Regulatory Commission |
| `Office of the Secretary` | Department of Labor |
| `Bureau of Global Talent Management` | Department of State |
| `Office of the Undersecretary for Public Diplomacy and Public Affairs` | Department of State |
| `Bureau of Overseas Building Operations` | Department of State |
| `Office of the Undersecretary for Political Affairs` | Department of State |
| `Economic and Business Affairs` | Department of State |
| `Office of the Secretary - DOC` | Department of Commerce |
| `United States Virgin Islands` | State and Local Government |

ℹ️ **Six of the eleven are State Department bureaus.** Creating those six underneath the existing
`Department of State` Account clears more than half this group in one sitting.

⚠️ **`U.S. Tax Court | US Tax Court` has a pipe character in its name** — that looks like two names
merged into one cell. Worth fixing at source whichever way this goes.

**The remaining 12 name no parent at all**, so someone has to decide where each belongs before it can
be created:

`Udall Foundation` · `Court Services And Offender Supervision Agency` · `USA.gov` · `Recreation.gov` ·
`Executive Office of the President` · `Amtrak` · `U.S. Supreme Court` ·
`Conference of State Bank Supervisors` · `U.S. Digital Service` · `Federal Judiciary` ·
`Chief Digital and Artificial Intelligence Office` · `DC Pre-trial Services`

ℹ️ **`Federal Judiciary` is worth doing first** — it is also the parent named by `U.S. Tax Court`
above, so creating it clears two rows.

### 1B. 11 rows match more than one Salesforce Account, so the migration refuses to guess

**4 are duplicate Airtable rows** — two Airtable rows describing one real office. Only the first can
claim the Salesforce record; the second is stranded. **Merge them down to one row each:**

`Under Secretary for Nuclear Security` · `Deputy Commissioner for Operations` ·
`Office of Communications` · `Environment and Natural Resources Division`

**7 have a generic name several agencies reuse**, and the `Parent` column does not pick out either
candidate:

| Airtable row | Parent named | Problem |
| --- | --- | --- |
| `Office of the Inspector General` | Department of Agriculture | **4** Salesforce Accounts share this name |
| `Office of the Director` *(×2 rows)* | Office of Personnel Management | 2 share the name — and these two Airtable rows are themselves duplicates |
| `Office of the Administrator` | National Aeronautics and Space Administration | 2 share the name |
| `Office of the Deputy Secretary` | Department of State | 2 share the name |
| `AmeriCorps` | **`AmeriCorps` — itself** | almost certainly the error; a row cannot be its own parent |
| `National Geospatial-Intelligence Agency` | Under Secretary of Defense Intelligence | the two candidates sit under *Defense Intelligence Agency* and *Department of Defense* |

**What we need:** for the generic names, a `Parent` value that names the agency the office actually
belongs to. `AmeriCorps` naming itself is the cheapest fix on this page.

Full list: `scripts/logs/data-migration/Account-reconciliation-unmatched-*.csv` and
`…-ambiguous-*.csv`.

---

## 2. `Gov Employees` is not a Salesforce value — 23 Opportunities

Airtable's `Demographic Served` on Opportunities uses **`Gov Employees`**, which is not one of the six
values the Salesforce field allows. The tag is dropped on **23 Opportunities** — the records load
fine, they just arrive without that classification.

**This is a Salesforce fix, not an Airtable one.** Adding `Gov Employees` to
`LDGCRM_Demographic_Served__c` **and** to the `Login_gov` record type migrates all 23 on the next run.

> ⚠️ Both halves are needed. A value added to the field but not assigned to the record type still
> fails — record-type picklist narrowing is enforced on load and is invisible to the usual tooling.

---

## Removed 2026-08-15, and why

Kept briefly so nobody re-adds them. All were on this list and none of them costs a record.

| Was listed as | Why it is gone |
| --- | --- |
| `Andrea McClain` paired with the wrong email | **Fixed at source.** Now `andrea.d.mcclain@dea.gov`, and Dunia Nooristani is a separate contact with her own address. It was reported stale — carried forward without re-measuring. |
| 2 empty Impediment rows | **Deleted at source**, confirmed against the current pull: 38 rows, 0 empty. |
| `"Decomissioned"` misspelt on 89 Applications | **Fixed at source** — `Status` now spells it correctly on 96. |
| A 275-character `Launch Deck URL` | **Settled decision** — the link is being stored outside Salesforce. |
| 3 contacts named after an email address | **Cosmetic.** The contact loads, with the right address and links. |
| 136 `#N/A` cells in Issuer Strings | **Cosmetic.** Transformed to blank on load. |
| 7 Issuer Strings with no Application | **Parked by the business** — possibly partner-portal test entries; provenance being checked before deletion. Nothing depends on them. |
| 18 Applications with a partly-filled portal team | **Cosmetic.** The agreed value wins and migrates correctly. |
| 5 non-URL and 3 over-long URL values | **Settled decision** — blanked rather than truncated. |
| 6 people under two email addresses | **Deferred by the business** pending confirmation of the current address from each account owner. |

---

## Salesforce-side items, for completeness

Recorded so the state of the data is visible in one place. The engineering counterpart is
[SALESFORCE-CHANGE-REQUESTS.md](../engineering/SALESFORCE-CHANGE-REQUESTS.md).

- **`Gov Employees`** — item 2 above, the largest of these at 23 Opportunities.
- **Identity platforms — two small gaps.** `CLEAR` (2 records) has no matching Salesforce value, so
  those selections are dropped; adding it to both fields **and** the `Login_gov` record type migrates
  them. And `Ping / Forgerock` lands in a Salesforce value spelled **`Ping/Foregerock`** — an extra
  "e". Airtable's spelling is correct; fixing Salesforce makes the mapping a straight pass-through.
- **Eight vendors Salesforce defines that Airtable no longer offers** — Google CiviForm, ManTech,
  Granicus, Shibboleth, Exostar, Jakobsen Id, Mattr, Idemia. Nothing migrates into them; harmless, but
  worth a look when these picklists are next tidied.
