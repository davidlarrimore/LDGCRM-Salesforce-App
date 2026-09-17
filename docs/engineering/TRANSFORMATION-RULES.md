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
| **An issuer string is recorded once PER APPLICATION it is linked to** | 2026-09-17 | Issuer strings move between Applications — deprecated on A, active on B — and the team never updated Airtable when they did. So the same text legitimately appears under several Applications, and `LDGCRM_Issuer_String__c` stays a **Master-Detail child of Application**. |
| **The issuer string text is NOT unique** | 2026-09-17 | Follows from the rule above. Do not add a uniqueness constraint or a duplicate rule on `LDGCRM_Issuer_String__c.LDGCRM_Issuer_String__c`. |
| **Issuer String has NO external ID** | 2026-09-17 | The only data on the record is the string itself. The load is an **insert**, not an upsert, so a re-run must clear the object first. This is the one `LDGCRM_` object without `LDGCRM_External_ID__c`. |
| **An issuer string with no linked Application, or no text, is not loaded** | 2026-09-17 | 7 Airtable rows. A Master-Detail child cannot exist without a parent, and the text field is required. **Not a data-quality ask.** |

## Issuer String (`LDGCRM_Issuer_String__c`)

**Source:** the Airtable `Issuer Strings` table (932 rows in the frozen 2026-09-02 export).
**Target:** one record per (issuer string, Application) pair.

### Object design

| Field | Type | Notes |
| --- | --- | --- |
| `Name` | Auto Number, `ISID-{00000}`, label *Issuer String ID* | Carries no data. The string does not live here, because a Text Name field is capped at 80 characters and 14 issuer strings are longer. |
| `LDGCRM_Issuer_String__c` | Text(200), required, not unique | The longest single issuer string is 104 characters. |
| `LDGCRM_Application__c` | Master-Detail → `LDGCRM_application__c` | Reparentable, so a string can be moved when it changes Application. |

`LDGCRM_application__c.LDGCRM_PP_Issuer_Strings__c` (Text(40), unique, one per Application) is the
field this object replaces. It is deleted from Dev and still exists in production, where it has to
be removed by a destructive change.

### Field mapping

| Airtable column | Salesforce field | Rule |
| --- | --- | --- |
| `Issuer String` | `LDGCRM_Issuer_String__c` | Copied as-is. |
| `Applications` (linked record IDs) | `LDGCRM_Application__c` | **Fan out:** one Salesforce record per linked Application, resolved through the Application's `LDGCRM_External_ID__c`. |

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
| (issuer string, Application) pairs | 1,047 |
| — pairs whose Application is not loaded (Release 1 withholds 6 Decommissioned Applications with no Partner Agreement) | 6 |
| **Records to load** | **1,041** |

55 issuer strings link to more than one Application — one to 18, one to 16.

### Not yet decided

The export contains these; no rule covers them yet, so a transform must not quietly "fix" them.

- **Two issuer strings in one cell.** `reckIt2XZDEoSWqCN` (130 characters) is
  `…gsa:fs_formio_test_portal` and `…gsa:datagov-production-catalog` joined by a space. It fits in
  200 characters, so it would load as one wrong value.
- **Trailing whitespace.** `rec7Usadt3uDDznbD` is `'cisa-partner-dev.oktapreview.com '`.
- **An en dash.** `recvSpDq6lz2FqeNS` contains `USGS_–_National_Digital_Trail_Data_Portal`. Whether that
  is what is registered or a typing error is unknown.
- **The same string twice under the same Application.** 2 pairs. The fan-out would create two
  identical records on one Application.
