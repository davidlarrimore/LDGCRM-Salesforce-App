# Reference data

Small, hand-maintained files that the pipeline **reads but never writes**, and that must travel with
the bundle. Unlike `data/` and `logs/` — which are gitignored because they hold Login.gov partner and
applicant data — everything here is tracked, because it is business configuration that needs
reviewing, versioning and shipping.

---

## `salesforce-user-roster.csv`

**Who owns it:** the business — the Partnerships team, not engineering.
**What it is for:** telling the pipeline, ahead of a load, which record owners are *expected* to have
a Salesforce account in the target org.

### It changes nothing about how records are assigned

This is the important thing to understand before editing it. **The roster is visibility, not
control.** The ownership rules are unchanged and are not configurable here:

- A record goes to its Airtable owner where that person resolves to an **active** Salesforce User.
- Where they don't — no account, deactivated, or wrong `UserType` — it goes to the **fallback owner**
  (`peter.marks@gsa.gov`), automatically, exactly as designed.

That happens whether or not a name appears in this file, and whatever `ExpectedInSalesforce` says.
Nothing here can reassign a record, block a load, or change a business rule. Its only job is to turn
a silent outcome into a stated one: *you told us these six people would have accounts, and two of
them don't — here is what that will cost before you run it.*

### Columns

| Column | Meaning |
| --- | --- |
| `Email` | The Airtable collaborator address. **The key** — must match Airtable exactly, lower case. |
| `Name` | Display name, for humans reading the file. Not used for matching. |
| `ExpectedInSalesforce` | `yes` · `no` · `unknown`. **The one column the business fills in.** |
| `Notes` | Free text — why, who confirmed it, when. |

**`ExpectedInSalesforce` answers one question: will this person have an active Salesforce account in
the org being loaded?**

- **`yes`** — they are current staff and should own their own records. If they turn out to be absent,
  pre-flight says so loudly, because that is a provisioning gap someone can still fix.
- **`no`** — they have left, or are not getting an account. **This is a complete answer, not a gap.**
  Their records going to the fallback owner is the intended outcome, and pre-flight will confirm it
  quietly rather than nagging.
- **`unknown`** — nobody has said yet. Pre-flight lists these so the file can be finished; it does not
  treat them as a problem.

### Where it is checked, and where it is not

Pre-flight reads this **only for `-Environment Full` and `Prod`**, and it is a **warning, never a
block**.

It is deliberately skipped for **Dev and QA**: those are developer sandboxes seeded from partial
refreshes, so there is no expectation that the Partnerships team have logins there at all. Checking
would produce a page of warnings on every development run, which is how a check stops being read.

### Keeping it current

Pre-flight also reports **owners present in Airtable but missing from this file**, so the roster
cannot quietly go stale as Airtable adds people. When that appears, add the row and ask the business
for its `ExpectedInSalesforce` value.

Seeded 2026-08-15 from the `Pod Opportunity Lead` (Opportunities) and `Account Owner` (Partner
Accounts) collaborator columns — the only two Airtable fields that feed record ownership.

**Completed 2026-08-15 by Erin Duffy**, who answered all 15 outstanding names in one pass. The file
now stands at **15 `yes`, 2 `no`, 0 `unknown`** — so pre-flight's "still marked unknown" warning
should not appear again, and if it does, someone has added a row without asking the business for its
value. The two rows Erin did not cover were already settled and were left alone:
`gabriel.vorleto@gsa.gov` (`no`, confirmed by the project owner) and `peter.marks@gsa.gov` (`yes`,
the fallback owner).

⚠️ **A complete roster is not the same as a clean one.** Every `yes` is now an assertion the pipeline
will test at the first `Full` or `Prod` pre-flight, and each one that turns out to have no active
Salesforce User becomes a named provisioning gap. **Expect that list to be non-empty** — the roster
having no blanks left is what makes those gaps visible, not evidence there are none.

**Record counts are deliberately not stored here.** They move with every Airtable pull, and a tracked
file carrying stale numbers is worse than one carrying none. Pre-flight prints the current count next
to each name, read live from the Airtable export.
