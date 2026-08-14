# Airtable data quality — open items

> **Who this is for:** whoever owns and maintains the **Airtable base**, plus (in a clearly marked
> section at the end) whoever owns the **Salesforce configuration**.
>
> **You don't need to understand the migration to act on this.** Each item says what's wrong, which
> rows, and what it costs. Work top down; the list is ordered by impact.
>
> **Nothing here requires an engineer.** Every transform re-reads Airtable on each run, so fixing an
> item and asking for a re-run picks up the newly valid records automatically — no code change, no
> deployment.
>
> Developers looking for the technical mapping decisions want
> [TRANSFORMATION-RULES.md](../engineering/TRANSFORMATION-RULES.md) instead.

**This document lists only what is still open.** Resolved items are removed rather than archived —
if something you fixed is no longer here, that is the confirmation it landed. Progress against a
specific load attempt is tracked in
[`scripts/docs/RELOAD-QA-CHECKLIST.md`](../../scripts/docs/RELOAD-QA-CHECKLIST.md), and the
per-run detail lives in the run's own `SUMMARY.txt`.

**Everything below was measured on 2026-08-14** against a fresh Airtable pull and a complete sandbox
wipe-and-reload (8,831 records migrated, 0 unexpected failures).

---

## At a glance

| # | Item | Airtable rows | What it costs | Whose call |
| --- | --- | --- | --- | --- |
| 1 | [Accounts with no Salesforce match](#1-accounts-that-dont-match-a-salesforce-account--154-rows) | **154** | 62 Opportunities, 13 Applications, 77 App–Contact links, 34 Opportunity Contacts, 7 Notes, 2 Partner Accounts | mostly **Salesforce** |
| 2 | [Owners with no active Salesforce login](#2-owners-with-no-active-salesforce-login) | 247 people | 332 Opportunities land on a stand-in owner | **Salesforce / business** |
| 3 | [Contacts with no name](#3-contacts-with-no-name--1054-of-1535) | **1,054** | 592 names are guesses; 314 are a login stub; 45 don't migrate | **Airtable** |
| 4 | [Applications with no Launch Level](#4-applications-with-no-launch-level--621-rows) | **621** | a default is assumed on your behalf | **Airtable** |
| 5 | [The `None` impediment](#5-what-does-the-impediment-named-none-mean--465-links) | 1 row, 465 links | deliberately not migrated | **Airtable** |
| 6 | [Partner Portal Admins recorded twice](#6-partner-portal-admins-are-recorded-in-two-places-that-disagree) | 202 disagreements | nothing — both are honoured | **Airtable** |
| 7 | [Contacts with neither name nor email](#7-contacts-with-neither-a-name-nor-an-email--31-rows) | **31** | 31 don't migrate | **Airtable** |
| 8 | [Two live Applications with no Partner Account](#8-two-live-applications-have-no-partner-account-link) | **2** | 2 don't migrate | **Airtable** |
| 9 | [Priority Type has nowhere to land](#9-priority-type-has-nowhere-to-land-in-salesforce) | 545 values | field stays empty | **Salesforce** |
| 10 | [Smaller cleanup items](#smaller-cleanup-items) | various | little or nothing | **Airtable** |

---

## Blocking — these records can't migrate until something changes

### 1. Accounts that don't match a Salesforce Account — 154 rows

**This is the largest remaining item, and most of it is no longer an Airtable problem.**

Matching works by ID first, then by exact name. Airtable has 747 Account rows; 585 match a Salesforce
Account. The other 154 do not — and having merged away every duplicate previously listed, what is
left is overwhelmingly **real organisations that have no Salesforce Account at all**:

> `U.S. Census Bureau`, `United States Postal Service`, `Bureau of Diplomatic Security`,
> `United States Army Corps of Engineers`, `The Supreme Court of the United States`,
> `United States Courts of Appeals`, `Special Courts: United States Tax Court`,
> `Guam`, `American Samoa`, `Puerto Rico`, `Northern Mariana Islands`, `United States Virgin Islands`,
> `John F. Kennedy Center for the Performing Arts`, `U.S. Commission on Civil Rights`,
> `Council of Inspectors General on Integrity and Efficiency`, `Udall Foundation`, …

**What we need — mainly a Salesforce decision, not an Airtable edit.** For most of the 154 the
Airtable row is correct and the question is whether an Account should be created in Salesforce. Until
one exists, there is nothing for these records' Opportunities and Applications to attach to.

Full list: `scripts/logs/data-migration/Account-reconciliation-unmatched-*.csv`.

**Three sub-items *are* Airtable fixes, and they are worth doing:**

#### 1a. `Department of Treasury` exists twice — blocks 5 Opportunities

Two Airtable rows now share this exact name. Only one can match the single Salesforce Account of that
name; the other is orphaned along with its 5 Opportunities.

**What we need:** merge the two rows into one, relinking anything pointing at the loser. **Best
value-for-effort item on this list — 5 Opportunities for one merge.**

#### 1b. 8 rows use a generic office name shared by several agencies

Eight rows are named after a sub-office so generic that Salesforce holds two or more Accounts with
that exact name, under different parent agencies. The migration will not guess between them.

| Airtable row | Its `Parent` | Salesforce has this name under |
| --- | --- | --- |
| `Office of Communications` ×3 | Office of Personnel Management | OPM **and** NASA |
| `Office of the Director` ×2 | Office of Personnel Management | OPM, NSF, CDC |
| `Departmental Management` | Department of Education | Education **and** Justice |
| `Office of the Deputy Secretary` | Department of State | HUD, Labor — **not** State |
| `Office of the Inspector General` | Department of Agriculture | DoD, DoT, OPM, SSA — **not** USDA |

**Six of these eight are fixed on our side, not yours.** Your `Parent` column already says which
agency each office belongs to, and the migration now matches on **name + parent agency** rather than
name alone — so the first three rows above resolve without anyone choosing between candidates.

**Two things we still need from you:**

- ⚠️ **Three rows are duplicates of each other.** All three `Office of Communications` rows name the
  same parent (OPM), and both `Office of the Director` rows do too. Once we match on parent, they
  would all land on the *same* Salesforce Account and overwrite one another. **These need merging
  down to one row each.** (One of the three is also tagged Market Segment
  `Defense & National Security` while sitting under OPM, which looks wrong on its face.)
- **The last two rows aren't ambiguous, they're missing.** `Office of the Deputy Secretary` under
  *Department of State* and `Office of the Inspector General` under *Department of Agriculture* have
  no Salesforce counterpart under that parent at all. They belong with the 154 above — a Salesforce
  Account needs creating, or the parent is wrong.

#### 1c. `Bureau of Consular Affairs` — no Salesforce match, and never had one

Blocks 1 Partner Account, 2 Applications and 2 Opportunities. Both Opportunities are already
`Closed Won`, so this is low urgency. **Decide one of:** create the Account, point the row at an
existing parent (Department of State), or confirm it is fine left unmigrated.

### 7. Contacts with neither a name nor an email — 31 rows

Nothing identifies these people, so they cannot be created as contacts and are skipped entirely.
Salesforce requires a last name, and there is no address to derive one from.

**What we need:** a name or an email on each, or confirmation they can be dropped.

### 8. Two live Applications have no Partner Account link

A Partner Account is required in Salesforce, so an Application without one cannot migrate. **8 rows**
have no link — but 6 are marked `Decomissioned` and are accepted as retired. **These two are not:**

| Application | Status |
| --- | --- |
| **`DOJ JMD`** | `Partner Pause` |
| **`TSA News – Mobile Application`** | `Move to Production Request` |

**What we need:** a Partner Account link on these two, or confirmation they are retired after all.

*(The 6 retired ones, for reference: `CBP I'm Ready`, `SAMS (CBP)`, `GSA Federal Advisory Committee
Act Training`, `CCP Truck Staging`, `SPEARS Opportunity Portal | HUD Section 3 Opportunity Portal`,
`Army Contract Writing System's (ACWS) Vendor Self Service (VSS)`. No action needed.)*

---

## Quality — these records migrate, but the data going in is wrong, guessed, or incomplete

### 3. Contacts with no name — 1,054 of 1,535

**The single biggest data-quality gap in the base.** Salesforce requires a last name, so where
Airtable has none the migration **derives one from the email address** rather than putting a raw
address in the surname field:

| What the migration could do | Contacts |
| --- | --- |
| Recovered a plausible **first and last name** from the address | **592** |
| Only the local part was usable (`jwoolf`, `crdavis1`) — no defensible split | **314** |
| Nothing to work with — no name *and* no email | **45** (see item 7) |

**A derived name is a good guess, not a fact.** A nickname, a married name or an unusual address
produces the wrong name, and nobody looking at Salesforce can tell the difference. **Every derived
name is a name you did not choose.**

Roughly 116 of the nameless rows look like **service or shared mailboxes** rather than people —
`enterpriseservicedesk@dol.gov`, `warcit@usgs.gov`, `FEMA-EMI-LCMS@fema.dhs.gov`.

**What we need — two separate decisions:**

1. **For real people:** names filled in, ideally as a first/last convention rather than one free-text
   field. **The 314 whose address has no split point are the priority** — the migration can do
   nothing useful with those, whereas the 592 at least get a plausible name.
2. **For service/shared mailboxes:** should they be Contacts at all? A help-desk address isn't a
   person, and forcing it into a Contact record will always look wrong. Options worth discussing: a
   dedicated record type, a naming convention, or storing them somewhere other than Contact.

Full list in the run directory's `Contact-name-review-*.csv`.

#### 3a. 7 help-desk names became "people" in Salesforce

Where the `Name` field holds a **help-desk or team name rather than a person**, the migration takes
it at its word and splits it into a first and last name — it has no way to tell `Help Desk` from a
real name. Salesforce now contains contacts called:

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
is meant to trust what you wrote. Same underlying decision as item 3.2 above.

#### 3b. 3 rows hold an email address in the `Name` field

`shyla.morisetty@dot.gov`, `christopher.villas@cisa.dhs.gov`, `icam-portfolio@gsa.gov`. The migration
cannot tell these from a real name, so Salesforce ends up with a contact *called* an email address.

**What we need:** replace with the person's actual name — the `Email` field already holds the address.

### 4. Applications with no Launch Level — 621 rows

Nothing is blocked, but this one quietly caused a **wrong number in Salesforce**, which is worth
explaining because it isn't obvious.

Salesforce calculates a "Launch Checklist Completion %" from the Launch Level. With the level empty,
the calculation falls through to its default and reports the application as **100% complete**. Before
this was handled, **607 migrated Applications reported themselves fully launch-complete** while their
underlying checklist was at most 78% done.

**We now default a blank Launch Level to `1 - Very Low Impact`** on load (project owner's decision),
which fixed the wrong number. So nothing is broken today.

**What we need — nothing urgent, but:** that default is *an assumption we are making on your behalf*,
and once it is in Salesforce it looks identical to a real value. For any application where the level
is genuinely known, filling it in is better than our guess.

Levels currently in use: 1 (354 rows), 3 (34), 4 (29), 2 (12), 5 (8).

### 5. What does the impediment named `None` mean? — 465 links

**The biggest open question on the Impediments table.** One impediment is named `None`, has no
Description and no Talking Point, and is linked to **465 opportunities** (263 "blocked" + 202
"requested") — more than five times any real impediment.

It reads as a placeholder people select to mean *"this opportunity has no impediment"*. If that's
right, migrating it would be actively misleading: it would record hundreds of opportunities as being
impeded when the data means the opposite, and because Salesforce automatically totals blocked revenue
per impediment, `None` would top any "biggest blockers" report with a meaningless multi-million
figure.

**We are currently not migrating it.** Reversing that takes a single setting, no code change.

**What we need:** confirmation of what `None` means. If it means "no impediment", the cleanest fix is
to remove those links in Airtable and delete the record.

**Related, and dependent on this:** **7 opportunities are marked as both blocked *and* requested** for
the same impediment. Salesforce stores one severity per link, so we record these as **Blocker** (the
more severe reading). This was 122 before the `None` exclusion suppressed 115 of them — so it only
truly closes once `None` is resolved. List:
`scripts/logs/data-migration/OpportunityImpediment-severity-conflict-*.csv`.

### 6. Partner Portal Admins are recorded in two places that disagree

Who administers an application in the partner portal is recorded **twice**, and the two don't match:

1. **`Roles` on the Contacts table** — a contact whose Roles include `Partner Portal Admin`.
2. **`Partner Portal Admin Email` on the Issuer Strings table** — names the admin per issuer string.

Salesforce has a single checkbox for this, so both feed it. **We use both** — someone is an admin if
*either* source says so, never only where they agree. Neither is treated as more correct.

| | Pairs |
| --- | --- |
| Both sources agree | **883** |
| `Roles` says admin, Issuer Strings doesn't name them | **116** |
| Issuer Strings names them, `Roles` doesn't say admin | **86** |

**The 86 are the ones worth your attention.** In every one of those cases the person **isn't recorded
as a contact on that application at all** — 34 people across 68 applications. We create the missing
link for them, since a portal admin plainly *is* a contact on that application, but the gap is real:
the Contacts table is missing 86 genuine relationships.

**Good news:** all admin email addresses match a contact that exists in Airtable, so nobody is lost.
That is checked every run and reported if it stops being true.

**What we need — two things, neither urgent:**

1. **A spot-check of the 116**, where someone's Roles say Partner Portal Admin but they aren't named
   as the admin on any of that application's issuer strings. Some will have handed the role over, in
   which case the Role is stale and worth clearing.
2. **Longer term, pick one place to record this.** Two sources for one fact will keep drifting. The
   Issuer Strings column is the more precise (it's per application; a Role applies to every
   application on that contact at once) — but that's your call.

Full detail: `scripts/logs/data-migration/ApplicationContact-admin-source-*.csv`.

---

## Smaller cleanup items

Not blocking anything. Listed so they don't get lost.

- **Contacts: 12 email addresses appear on 2+ rows.** The migration merges rows sharing an email into
  one contact, so nothing is lost — but the table overstates the number of real people.
  `joseph.manke@onrr.gov`, `shyla.morisetty@dot.gov`, `cameron.dixon@cisa.dhs.gov`,
  `katie.jaworski@gsa.gov`, `_dl_esimssofederation@treasury.gov`,
  `csc_it_services_helpdesk@ios.doi.gov`, `asktheboard@ccb.gov`, `ace.om.cmbuilds@cbp.dhs.gov`,
  `colin_dale@ao.uscourts.gov`, `karen.trebon@gsa.gov`, `warcit@usgs.gov`, `joel.moeller@usitc.gov`.
- **Contacts: 5 people appear twice under two different email addresses.** We identify a person by
  email, so each loads as its own contact and Salesforce's duplicate rule then rejects the second.
  **This is deliberate** — merging on name would assert that two addresses belong to one person, and
  guessing wrong attaches someone's history to an address they no longer use.

  | Person | The two addresses | Looks like |
  | --- | --- | --- |
  | **Linda Peters** | `peters.linda.j@dol.gov` + `peters.linda@dol.gov` | same person, two formats |
  | **Brian Platz** | `brian_platz@ios.doi.gov` + `brian.p.platz@gmail.com` | work and personal |
  | **Erica Eveland** | `evelande@sec.gov` + `ericaeeveland@maximus.com` | agency and contractor |
  | **Andrea McClain** | `andrea.d.mcclain@dea.gov` + `dunia.z.nooristani@dea.gov` | ⚠️ **name and email don't match** — one of these is wrong |
  | **HELP DESK** | `hceperaton-moodle@hq.dhs.gov` + `warcit@usgs.gov` | two different shared mailboxes sharing a name |

  **What we need:** for each, confirm one person or two. If one, keep the current address and remove
  the other. `Andrea McClain` is the one that looks like genuinely mismatched data rather than a
  duplicate.
- **Applications: `"Decomissioned"` is misspelled** (should be `"Decommissioned"`, two *m*'s) — used
  on **89 records**. Corrected automatically on the Salesforce side, so nothing is blocked, but fixing
  it at source stops it being typed wrong again.
- **Applications: 1 `Launch Deck URL` is 275 characters** (on `medicare.gov`) — over Salesforce's
  255 limit for a URL field, so it is left blank. It's a Google redirect wrapper around a Drive link;
  replacing it with the plain Drive URL fixes it.
- **Impediments: 2 completely empty rows** (`recA9LjxxE56gV73J`, `recXyF5tOHJh07laz`) — no Name,
  Category or Description; the only values are Airtable's own computed rollups. Look like accidental
  blank rows. Safe to delete; they don't migrate either way.
- **Issuer Strings: 136 `Team Name` and 137 `Team UUID` cells hold the literal text `#N/A`** — a
  spreadsheet artifact. **This blocks nothing** (we transform it to blank, and 0 Applications hold
  `#N/A` in Salesforce), but a cell containing `#N/A` looks filled in, so the table reads as 92%
  complete when the real figure is 77%.
- **Issuer Strings: 7 rows link to no Application**, so whatever team they name has nowhere to land.
  Two look real and may need linking:
  `urn:gov:gsa:openidconnect.profiles:sp:sso:gsa:pmsam` and
  `urn:gov:gsa:openidconnect.profiles:sp:sso:gsa:sam`.

---

## Not Airtable — for the Salesforce configuration owner

These are recorded here so the state of the data is visible in one place. **No action is needed from
the Airtable data owners.** The engineering counterpart is
[SALESFORCE-CHANGE-REQUESTS.md](../engineering/SALESFORCE-CHANGE-REQUESTS.md).

### 2. Owners with no active Salesforce login

Records are assigned to their real owner where that person has an active Salesforce user. Where they
don't, the record falls back to a stand-in owner. Nothing is lost or blocked — but the record doesn't
appear under the right person's name, and because these objects use **owner-based sharing**, ownership
also decides who can see them.

**247 distinct owner emails do not resolve**, which puts **332 of 842 Opportunities (~39%)** on the
fallback owner — the single largest "owner" in the org. 50 Partner Account owners are unresolved too.

Two distinct situations needing different answers:

- **No Salesforce user at all:** `elizabeth.mays@gsa.gov`, `tony.parrilla@gsa.gov`,
  `sierra.stewart@gsa.gov`, `robert.owens@gsa.gov`, `nour.aldimashki@gsa.gov`,
  `goutham.kommanaboyina@gsa.gov`, `brianna.naolu@gsa.gov`.
- **User exists but is deactivated:** `gabriel.vorleto@gsa.gov`, `trish.nguyen@gsa.gov`,
  `diondra.humphries@gsa.gov`, `becky.badalato@gsa.gov`, `hanna.kim@gsa.gov`,
  `matt.pritchard@gsa.gov`, `ambuj.neupane@gsa.gov`. Salesforce won't assign records to a deactivated
  user, so these behave the same as missing.

**What we need:** for each person, either confirm they're current staff who need an active login, or
name who their records should be reassigned to.

*(Sandbox observation — confirm against production before acting.)*

Lists: `Opportunity-unresolved-owner-*.csv`, `PartnerAccount-unmapped-owner-*.csv`.

### 9. Priority Type has nowhere to land in Salesforce

Airtable's `Priority Type` values are all reasonable and are staying as they are. The hold-up is on
the Salesforce side: the target field, **Level of Priority**, offers only `Low`, `Medium`, `High`, so
there is nowhere for them to go. **The field is therefore not migrated at all.**

**545 Opportunities carry a value:** `Strategic` (263), `N/A` (157), `High Volume` (72),
`IdV Upgrade` (38), `Leadership Escalation` (15).

**What we need:** the values added to `LDGCRM_Level_of_Priority__c` **and assigned to the `Login_gov`
record type** (a value the record type omits is rejected at load even when the field defines it), plus
a decision on whether `Low`/`Medium`/`High` stay alongside them — they describe a different thing (how
important an opportunity is) than Priority Type does (why it's a priority).

⚠️ **Do not map this to `priority_type__c`.** That field has a matching label but belongs to a
different application (TTS OTCRM) sharing this org.

### Identity platform picklists — two small gaps

Both identity-platform columns migrate correctly. Two Salesforce-side tidy-ups remain:

- **`CLEAR`** (2 records) has no matching Salesforce value, so those selections are dropped. We
  deliberately did *not* file it under a similar-looking vendor — CLEAR is its own company. Adding it
  to both fields **and** the `Login_gov` record type migrates them.
- **`Ping / Forgerock`** migrates into a Salesforce value spelled **`Ping/Foregerock`** — an extra
  "e". Airtable's spelling is correct; worth fixing in Salesforce, after which the mapping becomes a
  straight pass-through.

Salesforce also still defines eight vendors Airtable no longer offers (Google CiviForm, ManTech,
Granicus, Shibboleth, Exostar, Jakobsen Id, Mattr, Idemia). Harmless, but worth a look when these
picklists are next tidied.

---

## Open questions — need a decision, not just a fix

- **Opportunity → Partner Account is only populable for ~9% of Opportunities.** The Partner Accounts
  table shows an `Opportunities` list that looks comprehensive (961 entries across 469
  Opportunities), **but it is a roll-up of the parent Account's Opportunities, not a link recorded on
  the Partner Account.** All 8 Partner Accounts under Department of Defense show the same identical
  50 Opportunities. The only place a genuine link exists is on **Applications**, which reference both
  — yielding **82 Opportunities** with an unambiguous Partner Account.

  **What we need:** confirmation this is expected — i.e. that a Partner Account is only meaningfully
  tied to an Opportunity once an Application connects them. If Opportunities are *supposed* to carry
  one earlier, it needs recording somewhere real, because the roll-up can't supply it.

  Four Partner Accounts don't fit the pattern and may indicate data issues: `USDT-SSP`, `GSA-IAE`,
  `GSA-OIT`, `GSA-OROS`.
- **"Escalated User Support Cases" on Partner Accounts** links to records that aren't in any of the
  10 Airtable tables this migration reads. Is there a separate Cases/Support Tickets table that should
  be included, or is this column safe to ignore?
- **Partner Accounts' "Goals" column** — short repeated values (`Add Identity Verification`,
  `Increase Adoption`) with no destination on the Salesforce side. Not blocking, but if this matters
  it needs either a dedicated field or a decision to leave it out.

---

## Already decided — listed so they aren't re-raised

- **Issuer strings, partner-portal Team Name and Team UUID are optional** (business rule 2026-08-14).
  A missing value is an acceptable outcome. 691 Applications carry a portal team; the rest are blank,
  which is fine. The **9 Applications whose issuer strings name two different teams** are left blank
  deliberately — there is no defensible tie-break — and the **18 carrying the team on only some rows**
  migrate correctly.
- **The issuer string values themselves are not migrated.** Salesforce's field holds one 40-character
  value; most issuer strings are longer and most Applications have several. Its help text also
  describes it as maintained by hand by the OEs.
- Applications' `Pilots`, `Usage Tracker Application Name` and `Vital Update %`: confirmed not needed.
- Partner Accounts' `Migrated to the partner portal`: not migrating for now (not permanent).
- **Blank `Launch Level` falls through to 100% completion** in Salesforce's formula — accepted as-is
  by the project owner on 2026-08-14, since the load-time default resolves it.
