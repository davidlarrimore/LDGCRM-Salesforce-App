# Airtable data quality requests

This is a running list of things in the Airtable base that are blocking, or would improve, the
migration into Salesforce — written for whoever owns/maintains the Airtable data, not developers.
If you're a developer looking for the technical mapping decisions instead, see
[TRANSFORMATION-RULES.md](TRANSFORMATION-RULES.md).

**This list grows as more tables get migrated** (Contacts, Opportunities, and a few others haven't
been reviewed yet as of 2026-08-13) — it isn't the final/complete list, just everything found so far.

## Blocking — these records can't migrate until fixed

Salesforce requires certain fields to always have a value (e.g. every Partner Account must be linked
to an Account, every Application must be linked to a Partner Account). Airtable rows missing that
link get skipped rather than guessed at. None of these are broken on the Salesforce side — they need
a decision or a data fix in Airtable.

### Accounts: 172 rows don't match an existing Salesforce Account

Airtable has 757 Account rows; Salesforce already has 588. When we tried to match them up (by ID
first, then by exact name), 172 Airtable rows didn't match anything. Full list:
`logs/data-migration/Account-reconciliation-unmatched-*.csv` (ask engineering for the latest one).

One concrete example: **`Depart of Homeland Security`** looks like a typo'd duplicate of an Account
that's already in Salesforce under its correct name.

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

### Follow-up (2026-08-13): the same duplicate/unmatched Accounts also block Opportunities, not just Partner Accounts and Applications — full impact below

While tracing why 1,045 of 1,047 Application records failed to load, every failure that involved a
missing Partner Account traced back to one of 15 Airtable Account rows that either duplicate an
existing Salesforce Account under different wording, or have no Salesforce match at all. These aren't
just blocking Partner Accounts — the **same** rows are also the direct parent of **87 Opportunity
records** (checked against the current Airtable Opportunities export), **60 of which are still open**
(`Identified`/`Prospecting`/`Qualified`/`Agreements`), not closed/stale. This is materially bigger
than the original 13-row spot-check suggested, and it's sitting under active pipeline, not just
historical records. Full impact per Account row (Partner Accounts and Applications counted against
what's in gsa-peo/prepped today; Opportunities counted against the Airtable export, since that
object hasn't been built/loaded yet):

| Airtable Account row (unresolved) | Status | Salesforce match | Partner Accounts blocked | Applications blocked | Opportunities blocked (open / closed) |
| --- | --- | --- | --- | --- | --- |
| `Department of the Interior` | Confirmed duplicate | `Department of Interior` | 1 | **203** | 10 (10 open / 0 closed) |
| `General Service Administration` | Confirmed duplicate | `General Services Administration` | 2 | 65 | 20 (12 open / 8 closed) |
| `Technology Transformation Services (TTS)` | Confirmed duplicate | `Technology Transformation Services` | 2 | 24 | 0 |
| `National Institute of Standards and Technology` | Needs confirmation | `National Institute **for** Standards and Technology` | 1 | 17 | 8 (8 open / 0 closed) |
| `Department of the Treasury` | Needs confirmation (see the USDT-SSP entry above) | `Department of Treasury` (no "the") | 1 | 8 | 17 (10 open / 7 closed) |
| `Department of Agriculture` | Needs confirmation | `U.S. Department of Agriculture` | 2 | 6 | 14 (10 open / 4 closed) |
| `Office of Inspector General` (the `HHS-OIG` Partner Account's parent) | Ambiguous — see below | none confidently | 1 | 3 | 0 |
| `U.S. International Development Finance Corporation` | Needs confirmation | `International Development Finance Corporation` | 1 | 3 | 2 (2 open / 0 closed) |
| `Army` | Confirmed duplicate | `Department of the Army` | 4 | 5 | 8 (4 open / 4 closed) |
| `Navy` | Confirmed duplicate | `Department of the Navy` | 2 | 3 | 0 |
| `Bureau of Consular Affairs` | Genuinely missing | none | 1 | 2 | 2 (0 open / 2 closed) |
| `United States House of Representatives` | Confirmed duplicate | `U.S. House of Representatives` | 1 | 1 | 2 (1 open / 1 closed) |
| `U.S. Office of Special Counsel` | Confirmed duplicate | `Special Counsel` | 1 | 1 | 1 (1 open / 0 closed) |
| `Air Force` | Confirmed duplicate | `Department of the Air Force` | 1 | 1 | 3 (2 open / 1 closed) |

All but two of these rows (`United States House of Representatives`, created 2024-01-23;
`Office of Inspector General`, created 2023-08-30) were created on **2023-06-21** — the original
Airtable base's bulk-import date. These are longstanding structural duplicates baked in from day one,
not recent data-entry mistakes, so fixing them shouldn't disrupt anyone's active work.

**What we need, in priority order by impact:**

1. **The 8 confirmed duplicates above** — for each, merge the orphan row into its already-linked twin
   (`Army`→`Department of the Army`, `Navy`→`Department of the Navy`, `Air Force`→`Department of the
   Air Force`, `General Service Administration`→`General Services Administration`, `Technology
   Transformation Services (TTS)`→`Technology Transformation Services`, `United States House of
   Representatives`→`U.S. House of Representatives`, `U.S. Office of Special Counsel`→`Special
   Counsel`, `Department of the Interior`→`Department of Interior`): relink every Partner
   Account/Opportunity currently pointing at the orphan row to the twin instead, then delete the
   orphan. **`Department of the Interior` alone is blocking 203 Application records** — by far the
   single highest-impact fix available in this whole list.
2. **Confirm whether these are the same entity, just worded differently** (a prefix/wording
   difference, not yet verified as true duplicates the way the 8 above are): `National Institute of
   Standards and Technology` vs. `National Institute for Standards and Technology`; `Department of
   Agriculture` vs. `U.S. Department of Agriculture`; `U.S. International Development Finance
   Corporation` vs. `International Development Finance Corporation`; `Department of the Treasury` vs.
   `Department of Treasury`. If confirmed, same merge/relink/delete treatment as #1.
3. **`Office of Inspector General`** (blocks the `HHS-OIG` Partner Account and 3 Applications) — not a
   simple merge. Salesforce already has two similarly-named Accounts, `Office of Inspector General`
   and `Office of Inspector General - HHS`, but both are already claimed by *other* Airtable rows —
   neither is available as an unclaimed match for this one. Needs a human decision: is this genuinely
   HHS's Office of Inspector General (in which case it likely needs renaming to disambiguate from
   whichever other agency's OIG already claimed the generic name), a duplicate of one of the two
   already-claimed rows, or a real separate Account?
4. **`Bureau of Consular Affairs`** — genuinely no Salesforce match found. Both of its 2 linked
   Opportunities are already `Closed Won`, so lower urgency than everything else on this list, but
   still needs a decision: new Account, or safe to leave unmigrated.

**Not something the migration pipeline is working around.** Per an explicit decision (2026-08-13): the
migration will not silently guess at or auto-merge Account matches, no matter how confident the guess.
Every Partner Account, Application, and (once built) Opportunity row that depends on one of these
unresolved Accounts will simply be skipped or fail to load until the underlying Account data is fixed
in Airtable — that's expected, by-design behavior, not a bug the pipeline should route around. This
list is what unblocks them.

### Partner Accounts: 5 rows have no working link to an Account

- **No Account linked at all** (4 rows, all marked `Inactive`): `USDT(inactive)`,
  `DOD-AFRL-Bifrost - placeholder`, `USACE`, `DOD-ARMY-CAC (INACTIVE AGREEMENT)`. These look like
  placeholder/retired agreements — confirm whether they should be deleted from Airtable, linked to
  the correct Account, or just left as-is (they simply won't migrate either way).
- **Linked to two Accounts at once** (1 row): `USDT-SSP`, linked to both `Internal Revenue Service`
  (already correctly matched in Salesforce) and `Department of the Treasury` (itself a likely
  duplicate of Salesforce's `Department of Treasury` — see the Account duplicate table further down
  this document). A Partner Account can only belong to one Account in Salesforce — needs a decision on
  which one is correct (or whether this should actually be two separate Partner Account records) —
  and separately, whichever one is correct, `Department of the Treasury` still needs the duplicate
  question resolved either way.

### Partner Accounts: 2 account owners aren't in Salesforce

`elizabeth.mays@gsa.gov` and `tony.parrilla@gsa.gov` are listed as the Account Owner on several
Partner Account records, but neither has an active Salesforce User account in `gsa-peo`. Affects
several Partner Account rows (owner field left blank on those until this is resolved).

**What we need:** confirm whether these are current GSA staff who need a Salesforce login, or former
staff whose records should be reassigned to someone else.

### Applications: 11 records look like incomplete drafts, not ready to migrate

These all have a blank Status, no Partner Account link, and no other data filled in — and were
**created within the last ~7 weeks** (several just 8 days before this was written), so they read as
records someone started entering and hasn't finished, not old/stale data:

| Name | Created |
| --- | --- |
| `DOL - ICAM` | 2026-06-25 |
| `HHS` | 2026-06-25 |
| `HHS OIG` (two separate records with this exact name) | 2026-06-25 |
| `HHS-OIG` | 2026-06-25 |
| `SSA Secure Online Services` | 2026-08-04 |
| `MyTravelGov` | 2026-08-04 |
| `DOL EBSA` (two separate records with this exact name) | 2026-06-25 |
| `Test Application` | 2026-01-26 |

The four HHS-named rows in particular were all created within about 35 minutes of each other on
2026-06-25 — worth checking whether some of these are accidental duplicates of the same intended
record rather than four separate applications.

**What we need:** either finish entering these (Status + linked Partner Account, at minimum) before
the next migration pass, or confirm they should stay as drafts for now — we'll re-check this table
closer to the actual migration date rather than assuming today's snapshot is final.
`Test Application` in particular looks like a scratch/test record — probably safe to delete outright.

### Applications: 14 rows have a Name or URL too long for Salesforce

Found during the first real Application load attempt (2026-08-13). These are **Salesforce platform
hard limits**, not something we can raise by changing a field setting — unlike a few earlier cases in
this migration where a too-short field genuinely was ours to fix:

- **5 rows: Application Name is over 80 characters.** *(Count is from the first load pass; a later
  pass found 14 total over-length values across Name and all URL fields.)* Salesforce caps every custom object's Name
  field at 80 characters, with no way to extend it. We're **truncating these to 80 characters** on
  load and flagging them, e.g. `Office of Minority and Women Inclusion (OMWI)'s Supplier Diversity
  Business Management System (SDBMS)` and `CISA Firmware Analysis and App Vetting Execution (FAAVE)
  (aka Mobile App Vetting (MAV))`.
- **14 rows: a URL is over 255 characters** (13 in the `URL` column, 1 in `Launch Deck URL`).
  Salesforce caps URL-type fields at 255 characters, also not extendable. A truncated URL wouldn't
  work, so we're **leaving these blank** rather than loading a broken link. Most are very long
  OAuth/SSO authorization URLs with large query strings (one DHS Okta URL runs over 1,200
  characters); the `Launch Deck URL` case is a Google redirect wrapper around a Drive link, where the
  underlying Drive URL would fit fine on its own.

**What we need:** for the 5 long names, a shorter official name or accepted abbreviation would be
better than our automatic truncation (which just cuts at 80 characters and may cut mid-word). For the
9 long URLs, a shorter canonical landing-page URL would be better than a full OAuth authorization
link — those long links are usually session/flow-specific anyway and aren't durable as a record of
"where this application lives." Full list in
`logs/data-migration/Application-overlength-*.csv` (ask engineering for the latest).

### Applications: 1 row has a mistyped go-live year (`ECOMP`)

`ECOMP` has an **Actual Go-Live Date of `0202-02-18`** — almost certainly meant to be `2022-02-18`.
Salesforce rejects the record outright rather than storing an impossible year, so this field is
currently being loaded blank. Its Current Go Live Date (`2026-03-02`) is fine.

**What we need:** correct the year in Airtable. This is the only date of its kind — every other date
value across both go-live columns (1,565 values) is valid.

### Applications: 2 rows have an unusable "Ramp Up Approach" value

Values `"Q1 - FY'23"` and `"146"` don't match any real Ramp Up Approach (`Gradual`/`Immediate`/
`Spikes`) — look like the wrong data got entered into this field. Low priority (the Salesforce field
is optional, so these two records will migrate fine with it left blank), but worth a quick fix in
Airtable if there's a real value that belongs there.

### Opportunities: 28 records have no Status, so they can't migrate

Salesforce requires every Opportunity to have a stage, and there's no sensible default to invent, so
these 28 are skipped. All were created on **2026-07-22** within the same batch, and most also have no
Account link — they read as an unfinished bulk import. Examples: `DOC - OSSD(Office of Solution`
(name looks truncated mid-word), `TSA CFMS (Certified Facility Management System)`,
`eNativeTrust Family Portal`, `CA - LACERA`, `US Coast Guard`, `Service`, `DOL OUIM Expansion (legacy`
(also truncated), `DHS-Trusted Traveler Programs`.

**What we need:** set a Status (and ideally an Account link) on these, or confirm they're abandoned
drafts we should ignore. Full list in `logs/data-migration/Opportunity-skipped-*.csv`.

### Opportunities: 16 records have no Account link

Same situation as the Partner Accounts above — an Opportunity with no Account can't get its Market
Segment either (Salesforce derives that from the Account automatically). Skipped rather than loaded
half-connected.

### Opportunities: 142 more are blocked by the duplicate-Account problem

These point at Airtable Account rows that don't match a Salesforce Account — the same issue described
at the top of this document. **They will migrate automatically once those Accounts are resolved**, no
further work needed on the Opportunity records themselves.

### Opportunities: 729 records have no estimated go-live date

Salesforce requires a Close Date on every Opportunity. Only 199 of 928 have an `Est. Go Live` value —
and the gap is understandable rather than sloppy: 524 of 531 `Identified` opportunities have none,
because a go-live date isn't estimated until a deal qualifies. To load at all, we fall back to the
record's last status-change date, then its created date. **These are not real forecast dates** and
shouldn't be read as such in Salesforce reporting until a genuine estimate exists.

**What we need:** nothing blocking — but any opportunity that's far enough along to have a realistic
go-live estimate would be more useful in Salesforce with `Est. Go Live` filled in. We re-read this
every run, so filling them in later automatically corrects the Close Date. Affected records are
listed in `logs/data-migration/Opportunity-closedate-fallback-*.csv`.

### Opportunities: "Gov?t Employees" has a corrupted apostrophe

25 records have the Demographic Served value **`Gov?t Employees`** — a literal question mark where an
apostrophe should be (`Gov't`). We confirmed this is genuinely stored that way in Airtable, not a
glitch in our export (other curly apostrophes in the same data come through fine). We map it to the
correct `Gov't Employees` on load, so nothing is blocked.

**What we need:** fix the value in Airtable so it stops propagating. It likely came from a paste out
of a system that couldn't handle the apostrophe.

### Opportunities: the "Priority Type" field can't be migrated

Airtable's Priority Type values (`Strategic`, `High Volume`, `IdV Upgrade`, `Leadership Escalation`,
`HISP - High/Low Volume`, `N/A`) are all reasonable, but the matching Salesforce field is
misconfigured — on the Login.gov record type it offers only a single nonsense option that is all six
labels jammed into one string. This is a Salesforce configuration issue, not an Airtable data issue.

**What we need:** a decision from whoever owns the Salesforce config on whether Priority Type should
be usable on Login.gov opportunities. Until then this field isn't migrated. (564 records have a value.)

### Opportunities: identity-platform columns point at an untracked table

`Existing Identity Platforms` (259 records) and `Alternative Identity Platforms` (176 records) link to
a separate Airtable table that isn't part of the nine this migration reads, so we can't resolve them
to the vendor names Salesforce expects. Same open question as Partner Accounts'
`Escalated User Support Cases` below.

## Recommended cleanup — not blocking, but worth doing

- **Impediments: 2 completely empty rows** (`recA9LjxxE56gV73J`, `recXyF5tOHJh07laz`) — no Name,
  Category, Description, or anything else filled in. Look like accidental blank rows. Safe to delete
  from Airtable; they won't migrate either way.
- **Applications: `"Decomissioned"` is misspelled** in the Status field (should be
  `"Decommissioned"`, two *m*'s) — used on 89 records. We're correcting this automatically on the
  Salesforce side, so it's not blocking anything, but fixing the spelling at the source in Airtable
  would prevent it from being typed wrong again in the future.
- **Applications: 6 records marked `Decomissioned` have no Partner Account link**: `CBP I'm Ready`,
  `SAMS (CBP)`, `GSA Federal Advisory Committee Act Training`, `CCP Truck Staging`, `SPEARS
  Opportunity Portal | HUD Section 3 Opportunity Portal`, `Army Contract Writing System's (ACWS)
  Vendor Self Service (VSS)`. These are being treated as retired/historical and won't migrate — no
  action needed unless there's a reason to preserve them, in which case they'd need a Partner Account
  link added.

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
  of the 9 Airtable tables this migration currently pulls from — is there a separate Cases/Support
  Tickets table that should be included in the migration, or is this column safe to ignore?
- **Partner Accounts' "Goals" column** — short repeated values (`Add Identity Verification`,
  `Increase Adoption`, etc.) with no destination on the Salesforce side yet. Not blocking anything,
  but if this data matters going forward, it needs either a dedicated field or a decision to leave it
  out.

## Already decided, listed here for visibility (not asks)

- Applications' `Pilots`, `Usage Tracker Application Name`, and `Vital Update %` columns: confirmed
  not needed in Salesforce, won't be migrated.
- Applications' `Issuer Strings` column: confirmed not needed in Salesforce.
- Partner Accounts' `Migrated to the partner portal` column: not migrating for now (not permanent).
