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
optionality, contact merging, Partner Portal Admin sourcing, the decommissioned Applications and the
`Gov Employees` → `Federal Employees` rename — **please don't re-raise those.**

**Measured 2026-08-16** against a fresh full Airtable pull (719 Accounts, 1,514 Contacts, 904
Opportunities, 1,058 Applications) and a full Dev wipe-and-reload.

---

## 🎉 There are no open Airtable asks

**The Account matching work is finished.** Of **719** Airtable Account rows, **690 match** an existing
Salesforce Account and **9 were created** by the migration. The remaining 20 need no action: 18 carry
no Opportunities, Partner Accounts or Applications, so by the project owner's standing rule they cost
nothing, and the last 2 were resolved on the Salesforce side.

**Thank you** — the merges, the `Office of the Secretary - DOC` parent fix and the Virgin Islands
rename all landed, and they are the reason this section is empty.

The one item left needs a change in **Salesforce**, not in Airtable. It is recorded below so the
state of the data is visible in one place.

---

## ⚠️ This list holds only what COSTS RECORDS

**Standing rule, project owner 2026-08-15.** An item earns a place here only if it stops a row
reaching Salesforce, gets it withheld, or attaches it to the wrong parent. Cosmetic findings — a
Contact named after its email address, `#N/A` in a Team Name, an Application whose issuer strings
only partly agree — are **not** asks, because the record loads correctly regardless. They were being
re-reported every run, which buried the items that do cost records.

The test before adding anything: **name the records that do not reach Salesforce because of it.** If
the answer is none, it does not belong here.

---

## 1. `CLEAR` is not a Salesforce value — 2 Opportunities

Airtable's `Alternative Identity Platforms` offers **`CLEAR`**, which has no matching Salesforce
value, so the selection is dropped on **2 Opportunities**. The records load fine, they just arrive
without that platform listed.

**This is a Salesforce fix, not an Airtable one.** `CLEAR` is a real, distinct identity-verification
vendor, so it is deliberately not filed under a near-neighbour. Adding it to
`LDGCRM_Alternative_Identity_Platforms__c` **and** to the `Login_gov` record type migrates both on
the next run.

> ⚠️ Both halves are needed. A value added to the field but not assigned to the record type still
> fails — record-type picklist narrowing is enforced on load and is invisible to the usual tooling.

---

## Also worth a look, but costing nothing

**Eight vendors Salesforce defines that Airtable no longer offers** — Google CiviForm, ManTech,
Granicus, Shibboleth, Exostar, Jakobsen Id, Mattr, Idemia. Nothing migrates into them; harmless, but
worth tidying when these picklists are next touched.

---

## The Salesforce side has its own list

| Document | Holds |
| --- | --- |
| [SALESFORCE-ACCOUNT-CLEANUP.md](SALESFORCE-ACCOUNT-CLEANUP.md) | **Data** defects — duplicate and misfiled Accounts in the production org, to be worked after the migration |

**Config** changes only a change set can make are no longer tracked as a list — every one that
blocked a load has landed. Raise a new one with the Salesforce config owner directly.
