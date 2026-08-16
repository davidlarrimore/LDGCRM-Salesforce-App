# Migration backlog

> **Who this is for:** engineers picking up the next piece of work, and anyone asking "is this
> already known?" Each item records the decisions it still needs, not just the task.

**Work that is agreed but not yet built.** Built work is removed from this file rather than marked
done — git carries the history, per-object build status lives in
[ARCHITECTURE.md](ARCHITECTURE.md), field-level detail in
[TRANSFORMATION-RULES.md](TRANSFORMATION-RULES.md), and overall readiness in
[PRODUCTION-READINESS.md](../PRODUCTION-READINESS.md).

Ordered roughly by value, not by effort.

---

## 1. Meetings (~1,850 Airtable rows, 0 loaded) — approach changed, now blocked on a spike

**Status: deferred by decision, and no longer a straight transform.** It now depends on an org
configuration change that sits outside this repo. **A reload should proceed without Meetings.**

### Why the original approach was rejected

Airtable records a meeting **date only** — no start time, no end time, no duration. Salesforce Events
require both. Every option for closing that gap invents data: a fixed 09:00 start would have had
1,604 meetings all claiming to begin at 9am, and even an all-day event asserts a shape the source
never recorded.

**The decision: don't synthesize the time — get the real one.**

### The agreed approach

1. **Stand up Einstein Activity Capture (EAC)** so users' actual Google Calendar events sync into
   Salesforce and associate themselves with Salesforce records.
   *(Correct product name: **Einstein Activity Capture**. Searching for "Einstein Activity Monitor"
   finds nothing — worth knowing before anyone opens a ticket.)*
2. **Match each Airtable Meeting to the real calendar event** it describes, using fuzzy criteria
   across date, organizer, attendees and subject.
3. **Enrich the matched event** with what Airtable holds and a calendar entry doesn't — `Summary`,
   `Action Items`, `Agenda`, `Notes`, `Meeting Type` — rather than creating a duplicate meeting.

The real calendar supplies the times; Airtable supplies the meaning. Neither is fabricated.

---

### ⚠️ Prerequisite spike — do this before designing anything further

**One unknown determines whether the rest of this plan is buildable at all**, and it must be answered
against the actual org rather than from documentation:

> **Do EAC-captured events exist as standard `Event` records, or in Einstein Activity Capture's own
> data store?**

EAC has historically stored captured activity in a separate store surfaced through the Activity
Timeline, **not** as standard `Event` sObjects. If that holds here, the events are not reliably
queryable via SOQL, and the entire matching design below — which assumes we can query candidate
events — needs rethinking. If they do land as standard `Event` records, the design works as written.

Also confirm, in the same spike:

- **Retention window.** How far back does captured activity persist? This data spans
  **2024-02-05 → 2026-08-13**: 125 meetings in 2024, 931 in 2025, 548 in 2026. A 24-month window
  loses most of 2024; a 6-month window loses nearly everything.
- **Backfill vs forward-only.** Does connecting a calendar import history, or only capture from
  setup onward? If forward-only, **no historical meeting will ever match** and this approach only
  helps meetings held after go-live.
- **Licensing**, and which users are actually covered.

### ⚠️ A hard coverage ceiling that exists regardless of the spike

EAC syncs **per user, from that user's connected calendar**. A meeting can only be matched if its
organizer has an active Salesforce user with a connected calendar.

From the ownership analysis: **1,315 of 1,845 meetings have a Meeting Leader who resolves to an
active Salesforce User.** The remaining 530 are led by people who are deactivated or have no user at
all. **Those meetings can never sync**, because there is no calendar to connect. That is a ceiling of
roughly **71%**, before any matching accuracy is considered — and provisioning those users raises this
ceiling as well as fixing record ownership.

---

### Matching design (proposed)

**Signals Airtable actually provides**, verified against the export:

| Signal | Coverage | Quality |
| --- | --- | --- |
| `Date` | 1,604 / 1,845 | Exact day. The natural blocking key. |
| `Meeting Leader` | 1,622 | **Structured** — collaborator object with a real email. Strongest signal; maps to the calendar organizer. |
| `Internal Attendees` | 1,279 | **Structured** — array of collaborator objects with emails. Excellent for attendee-overlap scoring. |
| `Topic` | 1,845 | Free text, always present. |
| `Meeting Name` | 1,633 | Free text, closest thing to a calendar subject. |
| `External Attendees` | 1,015 | **Inconsistent free text** — some rows are RFC-style `"Name" <email>` lists, others are bullet lists of bare names with no address at all. Parse opportunistically; treat as a weak signal only. |
| `Accounts Record ID` / `Opportunity Record ID` | 1,522 / 792 | Contextual confirmation against the event's `WhatId`. |

**Proposed algorithm:**

1. **Block on date** — candidate events on the same calendar day (allow ±1 day for timezone drift).
   This alone reduces the search space enormously and is cheap.
2. **Require organizer agreement** — Airtable `Meeting Leader` email = the event's organizer/owner.
   Treat this as a near-hard gate rather than a score component; two different people's meetings on
   the same day are not the same meeting.
3. **Score the remainder**, weighted:
   - internal-attendee email overlap (Jaccard) — the highest-signal fuzzy component, since both
     sides are structured emails;
   - subject similarity (`Meeting Name` / `Topic` vs event subject), normalized and token-based;
   - `WhatId` agreement with Airtable's Account / Opportunity;
   - parsed external-attendee overlap where addresses exist.
4. **Auto-link only unambiguous, high-confidence matches.** One candidate clearly above threshold →
   link. Two plausible candidates → **review CSV, not a guess.** This follows the rule the rest of
   this pipeline already runs on: load what is genuinely clean, report the rest.
5. **Idempotency** — stamp the matched event with the Airtable `Meeting Record ID` in
   `LDGCRM_External_ID__c` so re-runs match rather than duplicate.

**Thresholds must be tuned against real synced data, not guessed in advance.** Expect the first pass
to be run in report-only mode and the weights adjusted from its output.

### Open question: what happens to meetings that never match

Likely the majority, given the coverage ceiling and retention limits. Needs a decision — this is the
main thing to settle once the spike reports back:

- **(a) Don't migrate them.** Cleanest, loses ~2 years of meeting summaries and action items.
- **(b) Attach them as Notes** to their Account or Opportunity. Preserves `Summary` / `Action Items`
  / `Agenda` verbatim without pretending a calendar event existed. Fits naturally with the existing
  Notes chunk and needs no invented times — **currently the most attractive option.**
- **(c) Create an all-day Event as a fallback.** Returns to the fabrication this decision rejected,
  but only for records that would otherwise be lost.

### Decisions that apply to whatever record ultimately carries the meeting

- **`Meeting Type` doesn't fit the field.** `LDGCRM_Meeting_Type__c` is a **single-value restricted
  picklist**; Airtable's is a **multi-select** whose values largely don't match. 566 meetings carry a
  value with no valid target (`General Follow Up` 465, `Internal` 37, `Contact Center` 30,
  `Informal Sync` 20, `Renewals` 14) and `Launch meeting` differs from `Launch Meeting` only by case.
  83 rows carry two or more types. Reads as a config gap — the same shape as the `Login_gov`
  record-type fix — but splitting `General Follow Up` between Salesforce's `BD Ad-hoc Follow Up` and
  `AM Ad-hoc Follow Up` is a human call, not a guess.
- **241 meetings have no date at all** (230 marked `(Past)`). These cannot be matched by date and
  cannot become an Event; they are the strongest candidates for option (b) above.
- **287 link to neither an Opportunity nor an Account.**

### Also worth knowing before building it

Activity is shared with the unrelated FCIC and CTI apps (its field list carries `CTI_*` and
`Template_*` columns) and `TriggerControls__c` has a record for **`Task`** — so **check the live org
for Event/Task triggers before the first load**, per the standing rule that burned the Contact load.

---

## 2. Is Contact ownership worth carrying into production? — open decision

Contacts inherit their Account's owner, which is built and working. The open question is whether the
result is *useful*.

**Measured in Dev: 92% of Contacts end up owned by `SystemUser DataLoader`.** The rule works exactly
as designed and produces ownership data that carries almost no information, because in production 92%
of Accounts are owned by that service account or by one individual — so inheritance concentrates
Contacts under one of those two.

It also cannot be meaningfully verified in a sandbox: the Account bootstrap loads name and hierarchy
only, so nearly every sandbox Account is owned by the loading user and Contacts inherit *that*. The
production export names Account owners by display name rather than email, so the bootstrap cannot
easily be made to seed them either.

**Why this matters beyond reporting:** Account, Contact, Opportunity and the three `LDGCRM_` objects
all have org-wide-default-restricted sharing with owner-based sharing rules, so owner is not cosmetic
— it decides who can see the record.

**Decision needed:** keep Contact ownership as-is, or stop inheriting and leave Contacts on the
fallback owner. Revisit if ownership reporting proves misleading in the Full sandbox.

---

## 3. Report on pipeline progress, not just record counts

**Status:** partially addressed; keep current whenever a stakeholder report is written.

A stakeholder report should show how far the **automated loading process** has been built, not only
how many records exist — the goal is a repeatable pipeline the Operations team can run, not a
one-time data dump. Cover pull → transform → load → verify, and say which objects are automated end
to end versus which still need a human step.

---

## 4. Re-running after Airtable cleanup

**No engineering work required** — recorded here so nobody builds something for it.

Every transform re-reads Airtable and re-queries Salesforce, so fixing the items in
[`AIRTABLE-DATA-QUALITY-REQUESTS.md`](../data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md) and
re-running picks up the newly-valid records automatically. **The unplaced Accounts — long the largest
single lever — are resolved**; 690 of 719 Airtable rows match and 9 were created, and the rest cost
nothing.
