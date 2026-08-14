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

**Measured 2026-08-14** against a fresh Airtable pull and a complete sandbox wipe-and-reload
(8,831 records migrated, 0 unexpected failures).

---

## At a glance

**Six items remain. Two are yours; four are Salesforce-side.**

| # | Item | Rows | What it costs | Whose call |
| --- | --- | --- | --- | --- |
| 1 | [Accounts with no Salesforce match](#1-accounts-with-no-salesforce-match--154-rows) | **154** | ~193 records across 5 objects | **Salesforce**, with 2 small Airtable fixes |
| 2 | [Owners with no active Salesforce login](#2-owners-with-no-active-salesforce-login--247-people) | **247 people** | ownership is inherited, not authored | **Salesforce / business** |
| 3 | [Priority Type has nowhere to land](#3-priority-type-has-nowhere-to-land--545-opportunities) | **545 values** | field stays empty | **Salesforce** |
| 4 | [Help-desk names became people](#4-seven-help-desk-names-became-people--7-contacts) | **7** | 7 contacts look like staff | **Airtable** |
| 5 | [Emails in the Name field](#5-three-contacts-are-named-after-an-email-address--3-rows) | **3** | 3 contacts named after an address | **Airtable** |
| 6 | [Small tidy-ups](#6-small-tidy-ups) | various | nothing | **Airtable** |

---

## 1. Accounts with no Salesforce match — 154 rows

**The largest remaining item, and most of it is not an Airtable problem.**

Matching works by ID first, then exact name. Airtable has 747 Account rows; **585 match** a Salesforce
Account. The other 154 do not — and with every previously-listed duplicate now merged, what remains is
overwhelmingly **real organisations that have no Salesforce Account at all**:

> `U.S. Census Bureau`, `United States Postal Service`, `Bureau of Diplomatic Security`,
> `United States Army Corps of Engineers`, `The Supreme Court of the United States`,
> `United States Courts of Appeals`, `Special Courts: United States Tax Court`,
> `Guam`, `American Samoa`, `Puerto Rico`, `Northern Mariana Islands`, `United States Virgin Islands`,
> `John F. Kennedy Center for the Performing Arts`, `U.S. Commission on Civil Rights`,
> `Council of Inspectors General on Integrity and Efficiency`, `Udall Foundation`, …

**What we need — mainly a Salesforce decision.** For most of the 154 the Airtable row is correct and
the question is whether an Account should be created in Salesforce. Until one exists there is nothing
for these records' Opportunities and Applications to attach to.

**What it's holding back:** 62 Opportunities, 13 Applications, 77 Application–Contact links,
34 Opportunity Contacts, 7 Notes and 2 Partner Accounts.

Full list: `scripts/logs/data-migration/Account-reconciliation-unmatched-*.csv`.

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

### 1d. `Bureau of Consular Affairs` — no Salesforce match, and never had one

Blocks 1 Partner Account, 2 Applications and 2 Opportunities. Both Opportunities are already
`Closed Won`, so this is low urgency. **Decide one of:** create the Account, point the row at
`Department of State`, or confirm it is fine left unmigrated.

---

## 2. Owners with no active Salesforce login — 247 people

Records are assigned to their real owner where that person has an active Salesforce user. **247
distinct owner emails do not resolve.**

Nothing is lost or blocked — as of 2026-08-14 those records inherit **the parent Account's owner**
rather than a generic stand-in. But that has a consequence worth stating plainly: **265 Opportunities
now inherit `SystemUser DataLoader`**, a bulk-load service account that owns 48% of production
Accounts. Their ownership *looks* real and isn't. Because these objects use **owner-based sharing**,
ownership also decides who can see them.

Two distinct situations needing different answers:

- **No Salesforce user at all:** `elizabeth.mays@gsa.gov`, `tony.parrilla@gsa.gov`,
  `sierra.stewart@gsa.gov`, `robert.owens@gsa.gov`, `nour.aldimashki@gsa.gov`,
  `goutham.kommanaboyina@gsa.gov`, `brianna.naolu@gsa.gov`.
- **User exists but is deactivated:** `gabriel.vorleto@gsa.gov`, `trish.nguyen@gsa.gov`,
  `diondra.humphries@gsa.gov`, `becky.badalato@gsa.gov`, `hanna.kim@gsa.gov`,
  `matt.pritchard@gsa.gov`, `ambuj.neupane@gsa.gov`. Salesforce won't assign records to a deactivated
  user, so these behave the same as missing.

**What we need:** for each person, either confirm they're current staff who need an active login, or
name who their records should be reassigned to. **This is the only thing that turns inherited
ownership back into authored ownership.**

*(Sandbox observation — confirm against production before acting.)*
Lists: `Opportunity-unresolved-owner-*.csv`, `PartnerAccount-unmapped-owner-*.csv`.

---

## 3. Priority Type has nowhere to land — 545 Opportunities

**Not an Airtable problem — no action needed from the Airtable data owners.** Your values are fine
and are staying as they are.

The target field, **`LDGCRM_Level_of_Priority__c`**, still defines only `Low`, `Medium`, `High`.
Re-verified in Dev on 2026-08-14 **two ways**, because `sf sobject describe` can hide picklist values:
the live describe and the field's metadata file agree on three values.

The field is `restricted = true`, so writing an undefined value **fails the entire row** — all 545.
The migration therefore deliberately does not write it.

**545 Opportunities carry a value:** `Strategic` (263), `N/A` (157), `High Volume` (72),
`IdV Upgrade` (38), `Leadership Escalation` (15). *(Down from seven distinct values — the two `HISP`
ones are gone.)*

**What we need:**
1. The five values added to `LDGCRM_Level_of_Priority__c`, **and**
2. assigned to the **`Login_gov` record type** — a value the record type omits is rejected at load
   even when the field defines it, and this has already cost one failed batch here.
3. A decision on whether `Low`/`Medium`/`High` stay alongside them. They describe a different thing
   (how important an opportunity is) than Priority Type does (why it's a priority).

Once both are in place the data migrates on the next run with a one-line change.

⚠️ **Do not map this to `priority_type__c`.** That field has a matching label but belongs to a
different application (TTS OTCRM) sharing this org.

---

## 4. Seven help-desk names became "people" — 7 contacts

Where the `Name` field holds a **help-desk or team name rather than a person**, the migration takes it
at its word and splits it into a first and last name — it has no way to tell `Help Desk` from a real
name. Salesforce now contains contacts called:

| Airtable `Name` | Became |
| --- | --- |
| `HELP DESK` | First `Help`, Last `Desk` |
| `UI Claimant Portal Help Desk` | First `UI Claimant Portal Help`, Last `Desk` |
| `EBSA Lost & Found Help Desk Information` | First `EBSA Lost & Found Help Desk`, Last `Information` |
| `Peace Corps Help Desk` | First `Peace Corps Help`, Last `Desk` |
| `FDM Help Desk` | First `FDM Help`, Last `Desk` |
| `Help Desk Independent Study System` | First `Help Desk Independent Study`, Last `System` |
| `Wisconsin UI Help Center` | First `Wisconsin UI Help`, Last `Center` |

**This is only these 7.** The other 57 role inboxes were detected from their *email address*
(`support@`, `nfrhelpdesk@`) and handled correctly — the address is kept whole and **no first name is
invented**. These 7 slipped through because the role name is in the `Name` field, where the migration
is meant to trust what you wrote.

**What we need:** either clear the `Name` on these 7 so they're treated as role inboxes like the other
57, or confirm they should read as people.

---

## 5. Three contacts are named after an email address — 3 rows

`shyla.morisetty@dot.gov`, `christopher.villas@cisa.dhs.gov`, `icam-portfolio@gsa.gov` are in the
**`Name`** field. The migration cannot tell these from a real name, so Salesforce ends up with a
contact *called* an email address.

**What we need:** replace with the person's actual name — the `Email` field already holds the address.

---

## 6. Small tidy-ups

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
  don't match each other, so one of the two is wrong. *(The other four people appearing under two
  addresses are handled by the merge rules and need nothing.)*

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
