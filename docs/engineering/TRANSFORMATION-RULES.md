# Transformation rules — Release 2

> **Who this is for:** engineers writing or changing a Release 2 transform, and anyone asking "why
> does this field end up like that?"
>
> **This document holds Release 2 rules only.** Release 1's rules — every Airtable → Salesforce
> mapping for Account, Partner Account, Opportunity, OpportunityContactRole, Opportunity Impediment,
> Application Contact, Contact, Impediment, Application and Notes, plus the record-ownership chain
> and the general principles for writing a transform — are archived as
> `engineering/TRANSFORMATION-RULES.md` inside `archive/sprint_1_docs.zip`. The
> `tools/data-loading/Build-*.ps1` scripts still implement those rules, and their comments point
> there.

A **rule** stays in this document after it is implemented, because it describes how the system must
behave rather than what happened. Add a `##` section for each object before considering its
transform done.

## Settled business rules — closed, not open questions

| Decision | Confirmed | What it means |
| --- | --- | --- |
| **The issuer string text IS unique** | 2026-09-18 | One record per distinct string, across the whole object. `LDGCRM_Issuer_String__c.LDGCRM_Issuer_String__c` carries `unique=true` and `caseSensitive=false`, so the constraint is enforced by the database and case-insensitively. |
| **An issuer string is recorded ONCE, not once per Application** | 2026-09-18 | Follows from uniqueness, and replaces the earlier per-Application rule. A string linked to several Applications in Airtable becomes **one** record under **one** Application. `LDGCRM_Issuer_String__c` remains a **Master-Detail child of Application**, and Master-Detail is reparentable, so the string moves rather than being duplicated. Which Application a multi-Application string parents to is **not yet decided** — see below. |
| **Issuer String has NO external ID** | 2026-09-17 | The only data on the record is the string itself. The load is an **insert**, not an upsert, so a re-run must clear the object first. This is the one `LDGCRM_` object without `LDGCRM_External_ID__c`. |
| **An issuer string with no linked Application, or no text, is not loaded** | 2026-09-17 | 7 Airtable rows. A Master-Detail child cannot exist without a parent, and the text field is required. **Not a data-quality ask.** |

## Issuer String (`LDGCRM_Issuer_String__c`)

**Source:** the Airtable `Issuer Strings` table (932 rows in the frozen 2026-09-02 export).
**Target:** one record per distinct issuer string.

### Object design

| Field | Type | Notes |
| --- | --- | --- |
| `Name` | Auto Number, `ISID-{00000}`, label *Issuer String ID* | Carries no data. The string does not live here, because a Text Name field is capped at 80 characters and 14 issuer strings are longer. |
| `LDGCRM_Issuer_String__c` | Text(200), required, **unique**, case-insensitive | The longest single issuer string is 104 characters. |
| `LDGCRM_Application__c` | Master-Detail → `LDGCRM_application__c` | Reparentable, so a string can be moved when it changes Application. |

`LDGCRM_application__c.LDGCRM_PP_Issuer_Strings__c` (Text(40), unique, one per Application) is the
field this object replaces. It exists in **every** org, including Dev, where it is labelled
*Issuer Strings (Deprecated)*: a deletion in a sandbox does not survive that sandbox's next refresh,
so only a production destructive change removes it for good. Deleting it is a post-deployment step
per `scripts/docs/deployment.md`, and a metadata retrieve keeps writing the field file back until
the org it reads from has dropped it — keep that file out of `force-app/` and out of any commit.

### Field mapping

| Airtable column | Salesforce field | Rule |
| --- | --- | --- |
| `Issuer String` | `LDGCRM_Issuer_String__c` | Copied as-is. Two Airtable rows may carry the same text; they collapse to one record. |
| `Applications` (linked record IDs) | `LDGCRM_Application__c` | **One parent, not a fan-out.** A row linking several Applications still produces one record, parented to a single Application resolved through its `LDGCRM_External_ID__c`. Which one is not yet decided. |

No other column on the table is written to this object. `Team Name`, `Team UUID` and
`Partner Portal Admin Email` feed Application and Application Contact under the Release 1 rules.

### What the export produces

| | Count |
| --- | --- |
| Airtable rows | 932 |
| — no linked Application | 6 |
| — no issuer string text | 2 |
| — rows excluded (one row is both) | **7** |
| Rows that load | 925 |
| Distinct issuer string values among them | 923 |
| — values whose only Application is not loaded (Release 1 withholds 6 Decommissioned Applications with no Partner Agreement) | 5 |
| **Records to load** | **918** |

Dev holds 918 Issuer String records, which is this figure.

55 rows link to more than one Application — one to 18, one to 16. Those rows produce **one** record
each, so the 1,047 (issuer string, Application) pairs in the export are not a record count and never
were reachable under the uniqueness rule.

### Not yet decided

The export contains these; no rule covers them yet, so a transform must not quietly "fix" them.

- **Which Application a multi-Application string parents to.** 55 rows link to more than one, and
  uniqueness allows only one record, so the transform must pick a parent. Nothing in the export says
  which link is current — that is precisely what the team stopped maintaining. Picking silently
  (first link, lowest ID) would bury the choice in code.
- **Two issuer strings in one cell.** `reckIt2XZDEoSWqCN` (130 characters) is
  `…gsa:fs_formio_test_portal` and `…gsa:datagov-production-catalog` joined by a space. It fits in
  200 characters, so it would load as one wrong value.
- **Trailing whitespace.** `rec7Usadt3uDDznbD` is `'cisa-partner-dev.oktapreview.com '`. Trimming it
  is not cosmetic under a unique constraint: it decides whether the value collides with another.
- **An en dash.** `recvSpDq6lz2FqeNS` contains `USGS_–_National_Digital_Trail_Data_Portal`. Whether that
  is what is registered or a typing error is unknown.
- **The same text on two Airtable rows.** 2 values —
  `urn:gov:gsa:openidconnect.profiles:sp:sso:nara:era-prod` and
  `https://myttbaccount.ttb.gov/realms/myTTB`. Uniqueness collapses each pair to one record, so the
  losing row's Application link is dropped rather than recorded.
