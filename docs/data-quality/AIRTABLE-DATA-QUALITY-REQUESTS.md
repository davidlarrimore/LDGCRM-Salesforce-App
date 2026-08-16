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

**Measured 2026-08-15 (evening)** against a fresh full Airtable pull (731 Accounts, 1,514 Contacts,
904 Opportunities, 1,058 Applications) and a full Dev wipe-and-reload.

**Thank you for the 25 Accounts added on the evening of 15 August.** They are the reason the
"unmatched" number below went up rather than down, and that is genuinely good news: every one of
them names a parent, and **20 of the 25 turned out to name an office Salesforce already holds** under
a slightly different name. Those are ours to link up, not yours to fix.

**Nothing here is blocking.** That load completed end to end: **9,079 records, 2 failures, 0
unexpected.** Everything below improves how much of Airtable reaches the CRM, or how usable it is
once there — none of it stops a migration running.

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

**Two items remain, and only one has an Airtable half.**

| # | Item | Rows | What it costs | Whose call |
| --- | --- | --- | --- | --- |
| 1 | [Accounts with no Salesforce match](#1-accounts-with-no-salesforce-match--54-rows) | **54** | ~130 records across 6 objects | **Salesforce**, with **11** Airtable fixes |
| 2 | [`Gov Employees` is not a Salesforce value](#2-gov-employees-is-not-a-salesforce-value--23-opportunities) | **23** | 23 Opportunities lose a tag | **Salesforce** |

---

## 1. Accounts with no Salesforce match — 54 rows

Airtable has **731 Account rows and 677 now match** a Salesforce Account. An Account that cannot be
matched strands everything hanging off it, so this is still the biggest lever.

**What it's holding back:** roughly **130 records** — Opportunities, Applications, Contacts,
Opportunity Contacts, Notes and Partner Accounts — all of which return automatically on the next run
once the Account resolves. No code change needed.

### ⚠️ Most of this is NOT an Airtable problem

We checked all 54 against the real production Account list. The split:

| | Rows | Whose job |
| --- | --- | --- |
| **Already in Salesforce under a different name** | 28 | **Ours** — we link them by ID, no rename needed |
| Genuinely missing, need creating | 5 | Salesforce config |
| Two plausible Salesforce Accounts, needs a decision | 5 | Salesforce config |
| Salesforce hierarchy gaps (same name, no parent set) | 4 | **Ours** |
| **Airtable fixes** | **12 rows, 11 tasks** | **You** — listed below |

**Why so many "different name" cases:** Salesforce tells same-named offices apart by adding an agency
suffix — `Office of the General Counsel - NRC`, `Office of Civil Rights - GSA`, `Human Resources -
OPM`. Airtable stores the plain office name plus a `Parent`. **Neither is wrong**, so please don't
rename anything to match — we link the two by ID instead.

The full mapping is in `docs/engineering/ACCOUNT-MATCHING-WORKLIST.md`.

### The 11 Airtable fixes we need

> **These were sent to Erin as a standalone task list on 2026-08-15.** This section is the same
> content — keep the two in step if either changes.

**Merging means moving the links first.** The record marked *keep* is the one Salesforce is already
matched to, so it has to be the survivor. Move any linked Applications, Opportunities, Contacts and
Partner Accounts off the deleted row before deleting it.

#### 1–9. Two records that should be one

| # | Office | Keep | Delete |
| --- | --- | --- | --- |
| 1 | Chief Digital and Artificial Intelligence Office | `rec802WasnesQnDG5` *(parent: DoD)* | `recx5JEtm1UNKYTvv` |
| 2 | Court Services And Offender Supervision Agency | `rec5u4n3I2qUwBIpD` | `recED7NXwBdseQ4Ku` |
| 3 | Deputy Commissioner for Operations | `recZC9gVe1flfEuS6` | `recem3YiYxbZSoRzD` |
| 4 | Executive Office of the President | `rec08GXIp2rdepQDz` | `recRMU3Wi8mQAzaoy` |
| 5 | U.S. Supreme Court | `rec2zHGPBiRvXlDtX` *(parent: Federal Judiciary)* | `recbletJk3eCCDz0T` |
| 6 | Under Secretary for Nuclear Security | `recRUUclzfaGB7JEK` | `recbyMnp1lAeSyUW1` |
| 7 | Under Secretary for Political Affairs | `recblHXP4ksIvadDR` | `recljbZfwsRVDBTmx` **and** `recI56mitt6T1JvJV` |
| 8 | U.S. Tax Court | `recmHTalRWAChHW9u` | `recaIpw4URTgPYINx` **and** `rec3f05eVwFfswnOq` |
| 9 | Natural Resources and Environment *(USDA)* | `recYlXu3NMSGYWo2Y` | `recOTuuxYnWwBq9Fs` |

ℹ️ **Same name is not by itself a duplicate** — several agencies legitimately run an `Office of the
General Counsel`. These are duplicates because the **parent matches too**.

Three carry an extra detail worth reading:

- **Item 7** — `recI56mitt6T1JvJV` has an **invisible leading space** in its name.
- **Item 8** — `rec3f05eVwFfswnOq` has a **pipe character** in its name, two names typed into one
  cell. *Salesforce holds this court twice as well*; we are merging that side.
- **Item 9 is a mis-edit, not a duplicate of the obvious kind.** `recOTuuxYnWwBq9Fs` is the **USDA**
  mission area, but its **Name** was changed to `Environment and Natural Resources Division` — a
  **Department of Justice** division. The renamed row then took DOJ's Salesforce record, locking out
  the correct DOJ row. Airtable already holds the right USDA record, so this is a merge rather than a
  rename. **Leave `recxmAuYgs0XGRIsJ` alone** — it is correct and matches on its own once this is gone.

#### ⚠️ 10. `Office of the Secretary - DOC` has the wrong `Parent`

`rectgYLhIB07cBFXC` is named `Office of the Secretary - DOC` (Commerce) but its `Parent` reads
**`U.S. Department of Agriculture`**. Salesforce holds this office under **Department of Commerce**.

**Fix: set `Parent` to `Department of Commerce`.**

> Items 9 and 10 are the same mistake twice — a request to change one field applied to the other,
> both landing on a Commerce/Agriculture confusion. Worth a second pair of eyes, and worth wording
> future asks to name the field explicitly.

#### 11. Rename `United States Virgin Islands` → `Territory of Virgin Islands`

`reccouuBTMQSBuZqz`. Salesforce calls it `Territory of Virgin Islands`; confirmed the same entity, and
here the Salesforce name is simply the better one. **This is the only rename we are asking for** — see
the note above about not renaming to match Salesforce generally.

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
