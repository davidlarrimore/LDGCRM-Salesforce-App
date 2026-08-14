# Airtable → Salesforce field transformation rules

> **Who this is for:** engineers writing or changing a transform, and anyone asking "why does this
> field end up like that?" It is a **reference to search, not a document to read end to end** —
> it runs to about 1,900 lines. Jump to the object you care about.
>
> **Read the [General Principles](#general-principle-read-this-before-writing-a-new-transform)
> before writing any new transform.** They are distilled from mistakes that reached a real org, and
> most describe a specific way Salesforce or Airtable will mislead you.
>
> **Not an engineer?** If the source data looks wrong, go to
> [../data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md](../data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md).
> If you need to run a load, go to [../operations/RUNNING-A-LOAD.md](../operations/RUNNING-A-LOAD.md).

This is the authoritative, field-by-field record of how each Airtable table's columns become each
Salesforce object's fields in this migration — every mapping decision, every excluded field, and
every gotcha discovered while building the `Build-*.ps1` transform scripts. When in doubt about why
a script does something a particular way, this is where the reasoning lives.

`CLAUDE.md`'s "Airtable → Salesforce mapping" section has the short cross-object summary (which
table maps to which object, load order); `ARCHITECTURE.md` has the pipeline
architecture and build status. This document is the detail underneath both — add a new `##` section
here every time a `Build-*.ps1` script is built, before considering that chunk done.

## Settled business rules — closed, not open questions

Decisions the project owner has made and **which are not to be re-raised as data-quality asks**. Each
was previously an open item in `AIRTABLE-DATA-QUALITY-REQUESTS.md`; they were moved here on
2026-08-14, because that document now lists only what is still open and these are answered. The
detail for each lives in its object's section below.

| Decision | Confirmed | What it means in the pipeline |
| --- | --- | --- |
| **The owner chain is: authored owner → parent Account's owner → `peter.marks@gsa.gov`** | 2026-08-14 | Applies to Opportunity, Application and the Partner Account owner field. Every step requires `IsActive` **and** `UserType = 'Standard'`. See [the owner chain](#the-owner-chain-three-steps-business-rule-2026-08-14). |
| **A Contact with no name gets one derived from its email** | 2026-08-14 | Split on `.` where present, else the whole local part becomes the surname and no forename is invented. Airtable will not be filling these in — this is the accepted import method, not a workaround. |
| **A blank `Launch Level` defaults to `1 - Very Low Impact`** | 2026-08-14 | 616 Applications. Without it they inherit a formula's else-branch and report 100% launch-complete. |
| **The Impediment named `None` is never created and never linked** | 2026-08-14 | Both the record and its 465 links are excluded. See [the `None` section](#the-impediment-named-none-is-deliberately-excluded). |
| **Partner Portal Admin is the UNION of both sources** | 2026-08-14 | `Contacts.Roles` and Issuer Strings' `Partner Portal Admin Email`. Never the intersection; a silent source is not evidence of absence. |
| **Contacts sharing an email are merged into one record** | 2026-08-14 | The current merge is the accepted method. Rows for the same person under *different* emails stay separate — merging on name would assert two addresses belong to one person. |
| **Issuer strings, portal Team Name and Team UUID are optional** | 2026-08-14 | A missing value is an accepted outcome. `#N/A` becomes blank. The 9 Applications whose issuer strings name two teams stay blank deliberately. |
| **Opportunity → Partner Account is optional and sparse** | 2026-08-14 | Only ~9% can be populated, because the only genuine link is via Applications. The Partner Accounts table's `Opportunities` column is a rollup of the parent Account's, not a real link. |
| **Cases are out of scope** | 2026-08-14 | Partner Accounts' `Escalated User Support Cases` column is ignored; there is no Case object in this design. |
| **Partner Accounts' `Goals` column is not migrated** | 2026-08-14 | No destination field, and none is being added. |
| **Applications' `Pilots`, `Usage Tracker Application Name`, `Vital Update %`** | earlier | Confirmed not needed in Salesforce. |
| **Partner Accounts' `Migrated to the partner portal`** | earlier | Not migrating for now. Not permanent. |
| **The issuer string VALUES themselves are not migrated** | earlier | Salesforce's field holds one 40-character value; most issuer strings are longer and most Applications have several. Its help text describes it as OE-maintained by hand. |

## General principle (read this before writing a new transform)

**Never assume an Airtable column maps to a Salesforce field by name, shape, or the target field's
declared picklist values alone — verify against real data first.** Three ways this has already gone
wrong in this migration:

1. **A column's name can lie about its content.** Accounts' `States + DC/PR` sounds like it holds a
   state name; it's actually a boolean checkbox. Always open the actual JSON in
   `scripts/data/airtable-exports/` and look at real values before assuming.
2. **Salesforce's picklist metadata can lie about what's actually stored.** `Account.Type`'s
   `Federal` record type declares `"Federal Agency"` as a value, but 530 of 588 existing gsa-peo
   Accounts actually use the plain string `"Federal"` (the field isn't restricted, so old loads
   didn't have to conform to the declared set). Query existing Salesforce data
   (`sf data query ... GROUP BY <field>`) to see what convention is *actually* in production use,
   not just what the metadata declares is allowed.
3. **A restricted picklist will reject anything not an exact string match.** Impediments' `Category`
   column uses `"Issue on their end"` and `"Relationship Issue"` in Airtable; the target field
   `LDGCRM_Category__c` is a *restricted* picklist whose only valid values are `"Issue on partner
   end"` and `"Relationship issue"`. A passthrough load of either would fail the whole batch record.
   Restricted picklists need an explicit value map, checked against every distinct value actually
   present in the export (`Group-Object` over the field), not just the couple of examples in a
   sample record.
4. **A field's declared type can lie about how much it holds.** `TextArea` in Salesforce metadata
   means a 255-character cap, identical to a single-line Text field, *not* "long text" — nothing
   about the label ("Description", "Current Status Summary") signals this. Before trusting a
   TextArea-typed field, check the longest real value in the export against 255; if it's close or
   over, that field needs a metadata fix (`LongTextArea`) before loading, not truncation. Two fields
   have hit this so far: Impediment's `Description`/`Talking Point` (255 cap vs. up to 1,210 chars)
   and Partner Account's `Current Status Summary` (255 cap vs. up to 9,590 chars, an ever-appended
   dated log). A plain `Text` field's declared `<length>` can be just as wrong — Partner Account's
   `Agreement Short Name` was `Text(10)` against real values up to 37 characters.
5. **The same Airtable *concept* can be spelled differently in two different tables.** Both the
   Accounts and Partner Accounts tables have a "Market Segment" column, and neither one's values
   match `LDGCRM_Market_Segment__c`'s 5 real names/external IDs in every case, but they mismatch
   *differently* — Accounts uses `"Defense & National Security"`, Partner Accounts uses `"Defense"`
   (the segment's real name, no mapping needed) but `"Finance & Regulation (F&R)"` (does need
   mapping). Don't assume a mapping table built for one table's version of a column applies to
   another table's column of the same name — check each independently. (This one was caught only
   after `Build-AccountReconciliation.ps1` was already built and "working" against a small sample —
   it hadn't actually been loaded yet, so no bad data resulted, but it's a reminder to check a
   transform's *values*, not just that it runs without error, before considering it done.)
6. **A picklist's field-level values are NOT the values a record type will accept, and the API
   enforces the record type's narrower set.** `sf sobject describe` reports the field's full value
   set; if the object has more than one record type, that is not what a load can actually write. An
   Opportunity test batch failed 19/19 on two picklists whose values were "verified" against the
   describe output. When the target object has multiple record types, also read
   `objects/<Object>/recordTypes/<RecordType>.recordType-meta.xml` — and note its `fullName` entries
   are URL-encoded (`,`→`%2C`, `/`→`%2F`, `(`/`)`→`%28`/`%29`, `&`→`%26`, `'`→`%27`), so compare
   decoded values, not raw strings. See the Opportunity section.
7. **A field's declared type doesn't mean it's writable.** `<type>Percent</type>` (or `Number`,
   `Text`, etc.) looks like a plain writable field, but check for a `<formula>` tag before mapping
   anything to it — Application's `LDGCRM_Level_1_Complete_Pct__c`/`Level_3`/`Level_4`/
   `Launch_Checklist_Completion__c` are all formula fields computed from other fields already being
   migrated; writing to them directly fails outright. Same instinct as checking a picklist's
   restricted values or a TextArea's real length — the declared type is necessary but not sufficient
   information before deciding a field is a normal migration target.

8. **⚠️ A transform that reads the target org can end up reading its OWN previous output — and it
   will look like a success.** This pipeline is re-runnable and queries Salesforce to decide what to
   do, which means anything it wrote last time is waiting to be read back as though it were source
   data. The result is a metric that measures nothing and a rule that silently stops firing.

   It has now cost two features:

   - The Contact name waterfall reported **"970 names recovered from an existing Salesforce
     Contact"** — a number that looked like the migration rescuing real names. It was reading back
     email placeholders *it had written on the previous run*. The true figure was zero. Only wiping
     the org revealed it.
   - Building the email-name derivation, the same step matched first and reduced **597 derived names
     to 172** before anyone noticed, because a placeholder from the last load counts as "already has
     a name".
   - The per-domain name-order learner would have done it a third way: after one load, names this
     script *derived* would testify to the order that produced them, confirming whatever was chosen
     first while the evidence appeared to strengthen every run.

   **Two questions to ask of any org query in a transform:** could this row have been written by
   this pipeline? And if it was, does using it make the output *look* better while making it no
   truer? Where the answer is yes, either exclude the rows structurally (the Contact waterfall skips
   any `LastName` containing `@`) or restrict the query to the authored source (the order-learner
   uses Airtable names only, never Salesforce's).

   The tell, when it does happen, is a **suspiciously helpful number** — a recovery or match rate
   far better than the source data can justify. Treat that as a prompt to ask where the data came
   from, not as good news.

**When writing a lookup or Master-Detail field's value into a CSV, the column header is not the
field's own API name.** Bulk API 2.0 resolves a parent by external ID only when the header uses the
relationship name (replace the field's trailing `__c` with `__r`) followed by `.` and the external ID
field: `LDGCRM_Account__r.LDGCRM_External_ID__c`, not `LDGCRM_Account__c`. A plain field-name header
is instead interpreted as a literal 15/18-character Salesforce Id — writing an Airtable `rec...` ID
under that header wouldn't upsert-via-external-ID, it would just fail as an invalid Id. Confirmed
against Salesforce's own docs: [Relationship Fields in a Header Row
(2.0)](https://developer.salesforce.com/docs/atlas.en-us.api_asynch.meta/api_asynch/relationship_fields_in_a_header_row__2_0.htm).
This was actually wrong in `Build-AccountReconciliation.ps1`'s first version (plain
`LDGCRM_Market_Segment__c` header) — fixed alongside gotcha #5 above, before any real load exercised
it. Every `Build-*.ps1` script's lookup columns should use this `__r.LDGCRM_External_ID__c` form.

When a transform script includes an explicit value-mapping table (like Impediment's `$CategoryMap`),
treat any value that doesn't match the map as a signal to stop and ask a human, not something to
silently blank out and move on from unnoticed — every script here logs unmapped/unmatched values to
a review CSV in `scripts/logs/data-migration/` rather than dropping them silently.

---

## Record ownership (cross-object rule, decided 2026-08-13)

Applies to every object in the migration, so it lives here rather than being repeated per section.
Implemented inside the existing `Build-*.ps1` transforms — there is deliberately **no separate
ownership-backfill script**, because the decision was made alongside a full wipe-and-reload, so
correct owners are produced by the normal load rather than patched on afterwards.

**The rule:** if the Airtable owner has a matching **active** Salesforce User, assign the record to
them; otherwise assign the **named fallback owner**, `peter.marks@gsa.gov` (overridable per run via
`-FallbackOwnerEmail`).

### The fallback is written EXPLICITLY, and that decision was reversed once

The first implementation left `OwnerId` **blank** for fallback rows. Bulk API 2.0 reads an empty
value as "not supplied", so an insert lands on whoever is authenticated and a re-run leaves an
existing owner untouched — which gave idempotency for free.

**That was correct only while the person running the load was the intended owner.** It stopped being
true on 2026-08-13, when it was confirmed that **GSA IT Operations runs this in production**. A blank
`OwnerId` would then have handed thousands of records to whichever engineer ran the job — and since
Account, Contact, Opportunity and the three `LDGCRM_` objects use org-wide-default-restricted sharing
with owner-based rules, ownership decides **who can see the record**, not just whose name is on it.
It was also non-deterministic: the owner depended on who was on shift.

So every transform now resolves `-FallbackOwnerEmail` to a real User Id at run time and writes it
explicitly. `Resolve-FallbackOwnerId` (`Common.DataMigration.ps1`) is the single implementation and
**throws** if the address doesn't match an active User, rather than degrading back to the loading
user — a failed run is strictly better than discovering the wrong ownership afterwards. It resolves
by **email, never a hard-coded Id**, because the Id differs between production and every sandbox.

**⚠️ The trade-off this costs, which is real:** because the fallback is asserted rather than omitted,
**a re-run re-applies it**. A fallback-owned record that someone manually reassigns in Salesforce
will be pushed back to the fallback owner on the next load. The blank-`OwnerId` design preserved such
changes; a named fallback owner cannot. If that becomes a problem, the fix is to query existing
owners per record and skip rows already owned by someone else — deliberately not built, because it
adds a query and a failure mode for a case that hasn't arisen yet.

### The owner chain, three steps (business rule, 2026-08-14)

⚠️ **Superseding the two-step rule below.** Every owned object now resolves its owner in the same order,
and only reaches the named fallback when both earlier steps fail:

1. **The record's own authored owner**, where Airtable records one.
2. **The parent Account's owner** — reached through whatever relationship the object has
   (Application → Partner Account → Account).
3. **`peter.marks@gsa.gov`**, the named fallback.

**Every step tests eligibility, not just existence.** A candidate is skipped unless the User is
`IsActive = true` **and** `UserType = 'Standard'` — see the UserType section below, which is the trap
that only a real load finds. Carrying an ineligible owner forward would swap a clean fallback for a
row that fails the load outright.

Measured on the 2026-08-14 export, immediately after implementing it:

| Object | Step 1 (authored) | Step 2 (Account) | Step 3 (fallback) |
| --- | --- | --- | --- |
| `LDGCRM_Partner_Account__c` (the owner **field**) | 37 | 60 | 2 |
| Opportunity | 515 | 327 | **0** |
| `LDGCRM_application__c` | 682 *(via Partner Account)* | 363 | **0** |

**The fallback is now empty on Opportunity and Application.** That is the rule working, not a bug —
but it is worth being clear about what it means: **265 of those Opportunities inherit
`SystemUser DataLoader`**, a bulk-load service account that owns 48% of production Accounts. Ownership
that *looks* authored and isn't is exactly the concern recorded for Contact below. The project owner
accepted this trade explicitly on 2026-08-14; the real fix stays the missing Salesforce logins.

**Implementing step 2 on Partner Account is what gives Application the chain for free.** Application
inherits `LDGCRM_Partner_Account_Owner__c`, so once that field resolves through the chain, Application
does too. Its own step 2 remains as a safety net for a Partner Account whose owner field is blank or
ineligible.

### Which object takes its owner from where

Figures in the last column are **measured from the completed reload of 2026-08-13** and predate the
three-step chain above — see that table for current splits.

| Object | Owner source | Own owner / fallback (2026-08-13, loaded) |
| --- | --- | --- |
| Opportunity | `Pod Opportunity Lead` (collaborator, scalar — verified 0 of 826 rows are multi-valued), then the Account | **471 / 271** |
| `LDGCRM_application__c` | its Partner Account's `LDGCRM_Partner_Account_Owner__c`, then the Account | **361 / 327** — *revised down from a predicted 511/177, see below* |
| Contact | its resolved Account's `OwnerId` | **1,548 inherited / 0 fallback** — but 1,426 of those inherit `SystemUser DataLoader`; see the warning below |

**⚠️ Application's split was predicted as 511/177 and is actually 361/327.** The difference is 150
records whose Partner Account owner is an **active user who cannot own records** — see the UserType
section immediately below. The predicted figure was computed by a transform that had never been
loaded, so nothing had ever tested whether those owners were *assignable*. Treat any un-loaded
ownership prediction the same way.
| `LDGCRM_Impediment__c` | *none — the Airtable table has no owner column* | 0 / 39 |
| `LDGCRM_Application_Contact__c` | *none — Airtable records the association, not an owner* | 0 / 1,880 |
| Activity/Event (Meetings) | `Meeting Leader` (collaborator) — **not yet built** | 1,315 of 1,845 would resolve |
| `LDGCRM_Partner_Account__c` | **n/a for the RECORD — no `OwnerId`.** Master-Detail child of Account, so Salesforce forces it to follow the Account's owner. Its `LDGCRM_Partner_Account_Owner__c` **lookup** does run the three-step chain, because Application inherits from it | see the chain table |
| `LDGCRM_Opportunity_Impediment__c` | **n/a — no `OwnerId`.** Two Master-Details | — |
| `OpportunityContactRole` | **n/a — no `OwnerId`.** A junction on Opportunity | — |
| Account | **deliberately untouched.** Airtable has no Account owner column, and Accounts pre-date the migration | — |

`LDGCRM_Impediment__c` is the one object whose transform had to *gain* Salesforce access for this:
it was a purely offline Airtable→CSV script, and resolving an email to a User Id needs a query. The
alternative was leaving 39 records on whoever ran the load, so the offline property was traded away
deliberately.

**A counting caveat in the summaries:** each script reports "own owner vs fallback" by comparing
against the fallback Id, so any record whose *genuine* owner happens to be the fallback person is
counted as fallback. `peter.marks@gsa.gov` leads 5 Opportunities, which is why that split reads
471/271 rather than 476/266. Cosmetic, not a data issue.

Application deliberately does **not** use Airtable's `Account Owner` column: on that table it is a
**rollup from the parent Account**, so using it would assert that an agency's account owner
personally owns each individual application. The Partner Account's own owner is the nearest authored
value, and every Application has a required Partner Account.

### Contact: the Account waterfall, and why account-less Contacts are now skipped

Decided 2026-08-13. A Contact with no Account is not loaded at all — two reasons: a blank `AccountId`
makes the FCIC trigger spawn a junk Account, and a contact attached to no agency isn't useful in the
CRM. Ownership depends on it too, since Contacts inherit their Account's owner.

Taken literally that rule was **far more destructive than it looked**: of 827 account-less contacts,
315 were referenced by a real junction, so skipping all of them would have destroyed **457 of 503
OpportunityContactRole rows (91%)**. The fix was not to soften the rule but to resolve more Accounts,
via a link that was already in the source data and simply wasn't being used.

Resolution order, strongest evidence first (the first three are **authored links**, not inference):

| # | Path | Contacts resolved |
| --- | --- | --- |
| 1 | Airtable's own `Contacts.Account` column | 965 |
| 2 | Application → Partner Account → Account | 151 |
| 3 | **Opportunity Contact → Opportunity → Account** *(added 2026-08-13)* | **399** |
| 4 | `.gov` email domain, inferred | 38 |
| — | none — **skipped, not loaded** | 390 |

**Path 3 is the one that matters.** Opportunity Contacts come from a separate Airtable table with no
Account column, so those people were the bulk of the account-less population — but every row links to
an Opportunity, and the Opportunities table carries `Account Record ID`. Adding that hop resolves 492
of 520 Opportunity Contact rows and cut the downstream cost of the skip rule from 457 lost
OpportunityContactRole rows to **22**, with **0** Application-Contact rows lost either way.

Watch the column name: **`Opportunity Record ID (from Opportunities)`**, not `Opportunity Record ID`
— the latter is the row's OWN id (0 of 520 are real Opportunity ids), the same trap documented in the
OpportunityContactRole section.

### Path 4 is the only inference in this pipeline, and it is hedged three ways

Learned from contacts that already resolved via an authored link, never from the domain string
itself. Three guards, each of which the raw version fails:

1. **`.gov` only.** `gmail.com` maps to exactly one Account in this data (one contact), so an
   unguarded "unambiguous domain" rule would sweep personal addresses onto that agency.
2. **The domain must map to exactly one Account.** `gsa.gov` spans 4 and is excluded by this alone.
3. **Minimum supporting evidence** (`-DomainInferenceMinSupport`, default 3). At 1, `usda.gov` would
   claim 19 contacts on the strength of a *single* known example, and `usdoj.gov` 7 on one.

Every inferred link is written to `scripts/logs/data-migration/Contact-domain-inferred-account-<ts>.csv`.
`-DisableDomainInference` turns the whole path off.

**It is barely worth having, and that is worth recording.** Before path 3 existed it would have
recovered ~95 contacts; afterwards it recovers **38**, because the authored links already reach
nearly everything recoverable. It is kept only because a recovered Account is a contact that loads
instead of being skipped — and it is the first thing to switch off if an inferred link ever puts a
contact on the wrong agency.

### ⚠️ Contact ownership WAS demonstrated on 2026-08-13, and it confirms the concern exactly

**This section previously said Contact ownership could not be demonstrated in the sandbox. That is
no longer true, and the result matters for decision D2.** The Account bootstrap now seeds owners from
the production export, so the full reload of 2026-08-13 produced the real distribution:

| Contact owner after the reload | Contacts | Share |
| --- | --- | --- |
| `SystemUser DataLoader` | **1,426** | **92%** |
| `Dave Larrimore` (the loading user) | 122 | 8% |

**Predicted 92%, observed 92%.** The inheritance rule works exactly as designed and produces exactly
the outcome the analysis warned about: nine in ten migrated Contacts owned by a data-loader service
account. Ownership-based reporting, "my records" views and owner-based sharing rules on Contact are
therefore near-meaningless as loaded — not because the rule misfires, but because the Account
ownership it inherits from carries almost no information.

This is now an evidenced decision rather than an argument, and it is the strongest available input to
D2 in [`RELOAD-QA-CHECKLIST.md`](../operations/RELOAD-QA-CHECKLIST.md): keep the rule, drop the inheritance in
favour of the named fallback, or inherit only from real people. **No code change is proposed here —
the rule was confirmed as-is on 2026-08-13 and this is evidence for revisiting it, not a decision to
change it.**

### Historical note: why it could not be demonstrated before

The Account bootstrap loads Accounts **Name and parent hierarchy only, no owner**, so nearly every
Account in the Dev sandbox is owned by whoever ran it. Contacts faithfully inherit their Account's
owner — and that owner is the loading user in almost every case, making the result indistinguishable
from the fallback. That is why the Contact summary reads "1,553 inherited / 0 fallback" while telling
you almost nothing.

**The bootstrap now does seed Account owners** (added 2026-08-13) via `Resolve-SalesforceOwnerIdsByName`,
since the export names owners by *display name* rather than email. A display name is a weaker join
than an email — not unique, not stable, not an identifier — so it carries the same active-only and
refuse-to-guess-on-duplicates guards; both fire on real data (`Matthew Taylor` matches two Users in
Dev, `SNA JTScholz` two). Owners are set **only on insert**, never on an Account that already exists.

That makes the sandbox faithful to production, which is the point of a rehearsal — but read the next
paragraph before expecting it to make Contact ownership *useful*.

**More importantly, production Account ownership may not be worth inheriting at all.** Measured from
the real export:

| Account owner in production | Accounts | Share |
| --- | --- | --- |
| `SystemUser DataLoader` | 651 | 48% |
| `SNA MSadi` | 607 | 44% |
| 12 named individuals | 111 | 8% |

**92% of production Accounts are owned by a data-loader service account or a single user**, so
"Contacts inherit their Account's owner" would put ~92% of Contacts under one of those two — which
looks like real ownership while carrying no information. The rule was confirmed as-is on 2026-08-13
after this was raised. Worth revisiting if ownership-based reporting turns out to be misleading.

**The `SNA ` prefix is settled: those are real people, not service accounts** — `SNA MSadi` →
`mahendar.sadineni@gsa.gov`, `SNA YMekonnen` → `yonathan.mekonnen@gsa.gov`, `SNA NALohning` →
`nicholas.lohning@gsa.gov`, `SNA JTScholz` → `jennifer.scholz@gsa.gov`. All 14 owner names in the
export match a real User. Most are inactive in Dev (including `SNA MSadi`, who owns 607 production
Accounts), so a large share of bootstrapped Accounts still falls back to the loading user there.
Their production status is unverified — production isn't authorized on this machine.

`SystemUser DataLoader` is worth noting separately: an **active service account owning 651 production
Accounts**. That is a working precedent for running production loads as a dedicated integration user
rather than an individual's login — the recommendation recorded above.

### ⚠️ `IsActive` does NOT mean "can own a record" — the trap that only a real load finds

**Found 2026-08-13, on the first load that ever wrote `OwnerId`.** It is the single most transferable
lesson from the ownership work, and no amount of reading metadata would have caught it.

`Resolve-SalesforceOwnerIds` filtered owners to `IsActive = true`, which is necessary but **not
sufficient**. `Shaunte Brown` is an *active* User on the **`GSA Chatter Free User`** profile —
`UserType = CsnOnly`. Chatter Free, portal and community users **cannot own** standard or custom
object records at all. The resolver returned a real, active, perfectly valid-looking User Id, the
CSV looked correct, and Salesforce rejected **150 of 688 Applications** at load time:

```
OP_WITH_INVALID_USER_TYPE_EXCEPTION : Operation not valid for this user type
```

**That message names no field and no user.** It reads like a permissions or profile problem on the
*running* user, not an owner problem on 150 specific rows — which is what makes it expensive to
diagnose. The route to the answer is to group the failed rows by `OwnerId` and query
`SELECT UserType, Profile.Name FROM User WHERE Id IN (...)`; 150 of 150 shared one owner.

Both resolvers now require **`UserType = 'Standard'`**. Of the 14 distinct owners this migration
assigns, 13 already qualified and exactly one did not, so the fix costs nothing real — that owner's
records now take the fallback owner correctly. **This org has ~2,637 Chatter-only users**, so the
exposure was never incidental, and a different environment will have a different set: re-check
rather than assuming Dev's single case is the only one.

The same gap existed in `Resolve-SalesforceOwnerIdsByName`, which assigns `Account.OwnerId` during
the bootstrap, and was fixed alongside it.

**The general principle, which is General Principle #2 again in a new costume:** a field that
*accepts* a User Id does not accept *every* User Id. Ownership has eligibility rules that live on
the User, not on the field being written, and `sf sobject describe` shows none of them.

### Resolving an email to a User: three traps, all silent

`Resolve-SalesforceOwnerIds` in `Common.DataMigration.ps1` is the **single** implementation. It
replaced a hand-rolled version inside `Build-PartnerAccountLoad.ps1` that had three defects, each of
which produced a *wrong owner* rather than an error:

1. **No `IsActive` filter.** Salesforce refuses to *assign* a record to an inactive user
   (`INACTIVE_OWNER_OR_USER`), even though existing records may legitimately still be owned by one.
   An inactive match is therefore not a match — it has to fall back. Real in this data: 7 of the 40
   distinct Meeting Leaders resolve only to a deactivated User.
2. **Duplicate emails were last-write-wins.** `moncef.belyamani@gsa.gov` has **two** User records in
   gsa-peo, one active and one inactive; a plain hashtable assignment in query order could land on
   either. Filtering to active resolves that case; genuinely ambiguous addresses (2+ *active* users)
   are reported for review instead of being picked silently.
3. **Only the `.invalid` form was queried.** Sandbox refreshes append `.invalid` to every user's
   Email — but **not every user carries it**: accounts created since the last refresh have a plain
   address (verified: `howard.miller@gsa.gov`, `jeremy.curcio@gsa.gov`, `rahul.kamarouthu@gsa.gov`).
   Querying only the suffixed form under-matched real, matchable owners. Querying **both** forms is
   also what lets this code run unchanged against production, where no suffix exists.

Same family as General Principle #2 — the metadata/convention you expect is not necessarily what the
org actually contains, so query it.

### The unresolvable owners are a data-quality ask, not a code problem

Two people block ownership in **three** places at once, which makes provisioning them the single
highest-leverage fix on the ownership item: `elizabeth.mays@gsa.gov` (157 Opportunities + 182
Meetings + Partner Accounts) and `tony.parrilla@gsa.gov` (15 + 50 + Partner Accounts). See
`AIRTABLE-DATA-QUALITY-REQUESTS.md`.

---

## Notes (BUILT and loaded — final chunk)

> **Status: built and loaded.** `Build-NotesLoad.ps1` + `Invoke-NotesLoad.ps1`. **716 notes created
> and attached in both Dev and QA**, 0 failures. Loads over REST, not Bulk — `ContentNote.Content` is
> a binary field that Bulk 2.0 CSV refuses. The text below describes the design; it was written before
> the chunk was built and the reasoning still holds.

Freeform/journal-style Airtable columns that don't belong in a dedicated Salesforce field aren't
dropped — they become **`ContentNote`** records (confirmed via the Account layout's
`RelatedContentNoteList` related list: gsa-peo uses Enhanced Notes, not the legacy `Note` object),
attached to the migrated parent record via `ContentDocumentLink`. This has to be the **last** chunk
built, after every other object's records exist in gsa-peo — a Note can't attach to a parent record
that hasn't been created yet.

**Scope decision (2026-08-12, user-confirmed): forward-only, not retroactive.** Fields already
migrated as dedicated Salesforce fields — Partner Account's `Current Status Summary` (despite being
structurally an ever-appended dated log, exactly the shape this chunk is meant for) and Impediment's
`Description`/`Talking Point` — **stay as dedicated fields, unchanged**. This chunk only covers
note-like columns that don't have anywhere else to go. Don't revisit the already-built objects'
field mappings because of this.

**Mechanically different from every other chunk so far**: `ContentNote.Content` is a base64-encoded
body, and attaching a note to a record is a second object (`ContentDocumentLink.LinkedEntityId`) —
not a single-object CSV upsert like every `Build-*.ps1` script so far. Figure out the exact load
mechanics (Bulk API CSV with a base64 `Content` column is supported, but untested here yet) when
this chunk actually gets built.

### Candidate fields, re-derived from the data (2026-08-13)

The earlier list was written from a partial look at Partner Accounts. Re-derived properly by
inventorying **every** column across all eight pulled tables, measuring text length and distinct-value
ratio, then cross-checking each against what the transforms actually write. Two changes came out of
it — one addition, one removal — which is why the "re-derive per table" instruction exists.

**Method, worth repeating for any future pass:** a column is a Notes candidate only if it is
(a) genuinely unmapped, (b) long-form, and (c) *mostly unique* across rows. Distinct-value ratio is
what separates prose from a controlled vocabulary, and it is not obvious from reading a sample.

| Column | Rows | Max chars | Distinct | Verdict |
| --- | --- | --- | --- | --- |
| Application `Notes` | 380 | 1,715 | mostly unique | **Note** |
| Application `IdV Upgrade Notes` | 95 | 159 | mostly unique | **Note** |
| Application `Launch Notes` | 86 | 6,992 | mostly unique | **Note** |
| Partner Account `Tasks` | 51 | 1,844 | 49 of 51 | **Note — newly found, was not in the old list** |
| Partner Account `Account Description` | 10 | 564 | 10 of 10 | **Note** |
| Partner Account `Known Blockers` | 92 | short | **17 of 92** | **NOT a note** — see below |
| Partner Account `Goals` | 100 | short | **9 of 100** | **NOT a note** — controlled vocabulary |
| Partner Account `Escalated User Support Cases` | 14 | 718 | — | **Still an open question** — points at an Airtable table this migration doesn't pull |

**`Known Blockers` was demoted, and it matters.** The old list called it a "moderate candidate". The
data says otherwise: 17 distinct values across 92 rows, and **42 of those 92 (46%) are literally
`"None"` or `"N/A"`** — the same placeholder-for-nothing pattern as the Impediment record named
`None` that this migration deliberately excludes. Loading those as notes would assert a blocker
exists on 42 Partner Accounts whose data says the opposite.

Its *real* values (`Feature - IAL2`, `Unresponsive`, `Agreement Alignment`, `Okta integration`) are
also conspicuously **Impediment-shaped** — `Unresponsiveness` is already the highest-volume genuine
Impediment in the base. Worth asking whether `Known Blockers` should become
`LDGCRM_Opportunity_Impediment__c`-style links rather than a picklist or a note. Not decided here.

`Goals` is confirmed as a controlled vocabulary (9 distinct across 100 rows) — a multi-select
picklist candidate, not a note, exactly as the earlier open question suspected.

**Meetings is excluded from this list entirely** — its note-like columns (`Summary` 1,561 rows,
`Notes` 377, `Agenda` 570, `Action Items` 1,572) are deferred with the rest of that object. But see
the warning below: if Meetings resolves to "attach unmatched meetings as notes", this chunk grows by
up to ~1,800 records and stops being small.

### Mechanics: `ContentNote` cannot be upserted

Confirmed against the org, and it shapes the whole chunk: **`ContentNote` has 0 custom fields and 0
external ID fields, and cannot be given any** — it is a Files object, not an ordinary sObject. Its
only createable fields are `Title`, `Content`, `OwnerId`, `SharingPrivacy` and the audit fields.

That puts it in the same class as `OpportunityContactRole`: **there is no upsert key, so idempotency
has to be read-then-diff.** Query the notes already linked to each parent record, key them on
`(LinkedEntityId, Title)`, and insert only what's missing. That composite works precisely *because*
the agreed design is one note per (record, source-field): `Title` carries the field label, so the
pair is naturally unique.

**It is also a genuinely multi-step load**, unlike every other chunk here, which is why
`Invoke-SalesforceLoad.ps1` can't drive it alone:

1. Insert `ContentNote` (`Title`, `Content`).
2. **Correlate the inserted rows back to their Ids** from the Bulk API success results, then query
   those notes for their `ContentDocumentId` — the link object references the *document*, not the
   note.
3. Insert `ContentDocumentLink` (`ContentDocumentId`, `LinkedEntityId`, `ShareType`, `Visibility`).

Step 2 is the awkward one and the reason this needs its own orchestration script, closer in shape to
`Invoke-AccountBootstrap.ps1` than to a `Build-*.ps1` transform.

### ⚠️ Proof of concept, 2026-08-13 — and the two things it disproved

One real note was created end to end against Dev to prove the mechanism before any automation was
trusted. It worked — the note is attached to the `SL_MD` Partner Account, the unmanaged trigger
accepted the link, `ShareType='I'` / `Visibility='InternalUsers'` were both valid, and the body
stored real `<br>` tags with no escaping bug.

It also killed two assumptions that the (now-disabled) `Invoke-NotesLoad.ps1` was built on. Neither
would have shown up before a live insert:

1. **Bulk API cannot load `ContentNote` at all.** `Content` is a binary/base64 field, and Bulk API 2.0
   CSV ingest rejects it outright:
   `InvalidBatch : Binary field Content is only supported for content types ZIP_XML and ZIP_CSV`.
   Every other chunk in this pipeline loads via `sf data import bulk`; this one **cannot**. The
   working path is REST, which accepts base64 as an ordinary JSON string.
2. **`ContentNote` has no `ContentDocumentId` field.** The three-step sequence above is really two
   steps: the note's **own Id is the ContentDocument Id** (it appears in `ContentDocument` with
   `FileType = 'SNOTE'`). Querying for `ContentDocumentId` fails with *"No such column"*. Feed the Id
   returned by the create straight into `ContentDocumentLink.ContentDocumentId`.

`Build-NotesLoad.ps1` is unaffected — its staging file, including the base64 encoding, is correct as
written. Only the loader needs rebuilding, against `POST /composite/sobjects` (200 records per call,
so ~3 calls for 537 notes) rather than Bulk.

**The general lesson, which has now cost two objects:** an object's *load mechanism* deserves the same
small-batch proof as its field mappings. `OpportunityContactRole` could not be upserted;
`ContentNote` cannot be bulk-loaded. Both were found by trying, not by reading metadata.

Other mechanics to get right:

- **`Content` is base64**, and Enhanced Notes expect an HTML-ish body — so the value must be
  HTML-escaped and have newlines converted to `<br>` **before** base64-encoding, and escaped *first*
  or the generated tags get escaped too. Same trap already documented for Opportunity's three `Html`
  fields.
- **`OwnerId` is createable**, so the record-ownership rule applies here as well: inherit from the
  parent record where sensible, otherwise the fallback owner.
- **`ShareType = 'I'`, `Visibility = 'InternalUsers'`** (decided 2026-08-13). `'I'` is *Inferred* —
  access to the note follows access to the record it hangs off, which is exactly what was asked for.
  `Visibility` is deliberately **not** `'AllUsers'`: this org has 5 active Guest users and 2,637
  Chatter-only users, and these notes carry internal commentary about partners.

### The layout has to carry the related list, and that is checked per object

A note can load perfectly and still be **invisible**, because whether users ever see it depends on the
parent's page layout carrying `RelatedContentNoteList`. Checked per object on 2026-08-13 rather than
generalised — and the generalisation was wrong:

| Layout | Before | After |
| --- | --- | --- |
| `LDGCRM_application__c` | `RelatedContentNoteList` + `RelatedNoteList` | unchanged |
| `LDGCRM_Partner_Account__c` | **neither** | `RelatedContentNoteList` **added and deployed** |
| Account (Federal) | `RelatedContentNoteList` | unchanged |
| Opportunity | `RelatedNoteList` only (legacy) | unchanged — not a note target today |

**144 of the 537 notes target Partner Account**, whose layout had no note related list of any kind.
The earlier "gsa-peo uses Enhanced Notes" decision was verified against the **Account** layout and
carried across to the other objects without re-checking — the same generalisation trap this document
warns about for picklists and field types. Deployed as a metadata-only change with
`--test-level NoTestRun`, per the org-wide FCIC Apex compile error.

**This layout gap is NOT a reason to fall back to the legacy `Note` object.** That was considered
(legacy `Note.ParentId` does support both targets, and it would collapse the load to a single insert
and dodge the trigger described below) and rejected: a missing related list is a one-line metadata
fix, and letting it drive the choice of platform technology would trade a permanent step backwards
for a temporary inconvenience. Enhanced Notes stay.

Note that Application's layout also still carries the legacy `RelatedNoteList`. Harmless — it will
simply show an empty "Notes & Attachments" list, since nothing writes legacy `Note` records.

### ⚠️ An unmanaged trigger on `ContentDocumentLink` gates the whole load

Found 2026-08-13 by the standing "check the live org before loading a new object" rule — it is not in
this repo, because the manifest is LDGCRM-scoped. This is the second time that rule has caught
something load-breaking, after `GSA_FCIC_ContactTrigger`.

`ContentDocumentLinkTrigger` → `ContentDocumentLinkTriggerHelper.beforeInsert` queries
`UserRecordAccess` for the **running user** against every `LinkedEntityId` and rejects the row if they
lack **Edit** access:

> *"You do not have permission to attach a file to this record. Please cancel this request"*

Three consequences, all of which shaped `Invoke-NotesLoad.ps1`:

1. **The kill switch is inert — do not rely on it.** The helper looks bypassable via
   `Trigger_Settings__mdt.ContentDocumentLinkTrigger.isActive__c`, and that record exists and is
   `true`. But `IsDisabled()` sets a flag and its `if (!isTriggerActive) { return; }` returns from
   *itself*, not from the trigger; `ContentDocumentTriggerDispatcher.Run` then calls `beforeInsert`
   unconditionally. Setting the metadata to `false` changes nothing. (Unlike FCIC's
   `TriggerControls__c`, which genuinely works.)
2. **Whoever runs the load must have Edit access to every parent record** — Partner Accounts and
   Applications, both org-wide-default-restricted. This is another reason the production run needs a
   deliberate, adequately-permissioned integration user rather than whoever is on shift.
3. **A missing access row throws rather than rejects.** The trigger does
   `!recordAccessMap.get(cdl.LinkedEntityId)` with no null check, so a `LinkedEntityId` absent from
   `UserRecordAccess` yields a null `Boolean` and an unhandled `NullPointerException` — failing the
   **whole batch**, not one row.

`Invoke-NotesLoad.ps1` therefore **preflights edit access on every parent and stops before creating
anything** if any record fails. That ordering matters: notes are created in step 1 and linked in step
3, so a step-3 failure leaves notes that exist, are attached to nothing, and have no external ID to
find them by.

**Heuristic for Title/Body (proposed, not yet implemented or user-confirmed in detail)**: one
`ContentNote` per (record, note-type-field) that has content, not one note merging multiple fields —
each Airtable "type" of note (Account Description, Known Blockers, etc.) stays its own distinct note
rather than being concatenated together, per the user's explicit instruction that each note's
original "type" has to be considered in how it's presented. `Title` carries the type label (e.g.
`"Known Blocker"`, `"Account Description"`); `Body` is the field's value close to verbatim. Revisit
this once real candidate fields across every table are inventoried — a single global heuristic may
not fit every table's shape (e.g. a dated running-log field, if one turns up elsewhere, likely needs
splitting into one note per dated entry rather than one note for the whole log — same idea already
flagged for `Current Status Summary` above, deliberately not applied there per the forward-only
scope decision, but worth reconsidering for other tables' equivalent fields when they're built).

---

## Account

**Source:** Airtable `Accounts` table (757 rows as of 2026-08-12).
**Target:** Salesforce `Account`, `Federal` record type only (no other record type is used, and
this migration never changes `RecordType`).
**Script:** `Build-AccountReconciliation.ps1`. **Mode: UPDATE, not upsert or insert.**

### Why Account is different from every other object in this migration

Every other object here is *created* by this migration (upsert-on-external-ID is safe because the
Salesforce record only exists because Airtable said so). Accounts are the opposite: they already
exist in Salesforce independently of Airtable — someone else created and has been managing them —
and in production most don't yet carry `LDGCRM_External_ID__c` at all. There is no reliable
external ID to upsert against yet, so this script's job is to *find* the matching existing Account
and backfill three fields onto it, never to create a new Account. Airtable rows with no confident
match are a decision for a human (see `CLAUDE.md`'s `Depart of Homeland Security` typo example),
not something the script auto-resolves.

### Matching algorithm

1. **External ID match** — if the Airtable row's `id` (`rec...`) already equals some existing
   Account's `LDGCRM_External_ID__c`, that's the match. No further logic needed.
2. **Exact Name match (fallback)** — among Accounts that do *not* yet have an external ID, look for
   one whose `Name` exactly matches the Airtable row's `Name` (case-insensitive, trimmed).
   - Zero candidates → **unmatched**, written to `Account-reconciliation-unmatched-<ts>.csv`. Not
     auto-created as a new Account.
   - Exactly one candidate → matched; claimed (removed from the candidate pool) so a second
     Airtable row with the same Name can't also match it.
   - More than one candidate → **ambiguous**, written to `Account-reconciliation-ambiguous-<ts>.csv`
     with all candidate Salesforce IDs listed. Not guessed at.
3. A matched Account is only added to the update file if something would actually change (external
   ID needs setting, Market Segment differs, or Type differs) — already-correct rows are counted but
   not re-written.

### Field mapping

| Airtable field | Salesforce field | Transformation rule |
| --- | --- | --- |
| `id` (= `Accounts Record ID`) | `LDGCRM_External_ID__c` | Direct passthrough, only on matched rows. |
| `Name` | *(not written)* | Used only as the matching key in step 2 above — this script never overwrites `Account.Name`. |
| `Market Segment` (plain text, e.g. `"Infrastructure"`) | `LDGCRM_Market_Segment__c` (lookup, CSV column `LDGCRM_Market_Segment__r.LDGCRM_External_ID__c` — see General Principle above) | Value-mapped, **not** direct passthrough (fixed 2026-08-12 — see gotcha below): `"Defense & National Security"` → `"Defense"`, `"Finance (Regulation & Compliance)"` → `"Finance & Regulation"`, `"State & Local (SLTT)"` → `"State & Local"`; `"Benefits"`/`"Infrastructure"` already match and pass through unchanged. Works because `LDGCRM_Market_Segment__c.LDGCRM_External_ID__c` stores the segment **name**, not its Airtable `rec...` ID (the one deliberate exception to the external-ID-passthrough convention — see `CLAUDE.md`). The 5 real Market Segments are loaded by `Build-MarketSegmentLoad.ps1` as step 1 of the pipeline (added 2026-08-14), so every mapped value resolves. **They must be RESOLVABLE, not merely present** — the match is on the external ID, so segments carrying no external ID resolve nothing and leave Market Segment blank org-wide with no error. |
| `States + DC/PR` (boolean checkbox) | `Type` (standard picklist field) | `"State"` if checked, `"Federal"` if unchecked/absent. **Not a literal boolean-to-text cast** — confirmed by querying gsa-peo's existing `Type` distribution (`GROUP BY Type, RecordType.Name`): 54 Accounts already `Type="State"`, 530 already `Type="Federal"` (the plain string, not the `Type` picklist's nominal `"Federal Agency"` value — see General Principle #2 above), closely matching the ~52 Airtable rows with the checkbox set. Does not touch `RecordType` — every Account, State or Federal `Type`, uses the `Federal` record type. |

### Known data-quality gotchas

- **Sandbox Account count is a moving target, not a fixed baseline.** It moved from 531 to 588
  within the same day this migration work started (2026-08-12) — other people/processes touch this
  data. Don't hardcode a count anywhere; always re-query.
- **Airtable (757 rows) is not 1:1 with Salesforce (588 Accounts).** As of the last run, 343 rows
  matched and needed an update, 242 matched and were already current, and 172 had no match at all
  (0 were ambiguous, though 4 Airtable rows share a duplicate Name, so ambiguity is possible on a
  future run against different data). Never assume every Airtable Account row has, or should get, a
  Salesforce counterpart.
- **`LDGCRM_External_ID__c` is deliberately `unique=false`/`required=false`** on Account (unlike
  every other object, where tightening this is a live consideration) specifically so this
  reconciliation pass isn't blocked by the unmatched rows. Don't tighten it until reconciliation is
  fully resolved.
- **The Market Segment mapping above was a real bug in this script's first version**, caught only
  after the fact by comparing its output against gsa-peo's actual Market Segment records (not caught
  by running the script, since it "worked" without erroring — it just silently produced values that
  wouldn't have resolved on load). No harm done since Account had never actually been loaded yet at
  that point, but it's why every `Build-*.ps1` script's *values*, not just its exit code, need
  checking against real Salesforce data before considering it done. Also fixed the CSV header itself,
  which was the plain `LDGCRM_Market_Segment__c` field name instead of the `__r.LDGCRM_External_ID__c`
  relationship form required for external-ID resolution (see General Principle above) — this would
  have failed the load outright (invalid Id) rather than merely mismatching, so it likely would have
  been caught at load time regardless, but the value bug would not have been.

---

## Partner Account

**Source:** Airtable `Partner Accounts` table (99 rows as of 2026-08-12; the export file is named
`Partner Accounts.json` but the Airtable table's current display name is "Partners" — see
`CLAUDE.md`'s Airtable API section on why the pull keys off table ID, not name).
**Target:** `LDGCRM_Partner_Account__c`.
**Script:** `Build-PartnerAccountLoad.ps1`. **Mode: upsert on `LDGCRM_External_ID__c`**, but it
still queries Salesforce once (to resolve `Account Owner` — see below) unlike Impediment's fully
offline transform.

### Why this needs Account loaded first

`LDGCRM_Account__c` is a true **Master-Detail** to Account (not a plain Lookup — every Partner
Account requires a parent Account at insert time, and Salesforce enforces this). The CSV resolves
that parent via `LDGCRM_Account__r.LDGCRM_External_ID__c` (see General Principle above), which only
works once the referenced Account's `LDGCRM_External_ID__c` is actually populated in gsa-peo — i.e.
`Build-AccountReconciliation.ps1`'s output must be loaded first. Checked before building this script:
of the 76 distinct parent Accounts these 99 rows reference, 63 already carry the right external ID in
gsa-peo; the remaining 13 need the Account backfill loaded first.

### Market Segment is NOT set by this script — it's Flow-derived

`LDGCRM_Partner_Account_Before_Save_Create_Update_Market_Segment` (a before-save Flow, fires on new
Partner Accounts) already sets `LDGCRM_Market_Segment__c` automatically from
`$Record.LDGCRM_Account__r.LDGCRM_Market_Segment__r.Id` — copied straight from the linked Account's
own Market Segment. The first version of this script *did* set it directly (with its own value map,
mirroring Account's fix), which the user caught and corrected: don't populate a field an existing
Flow already owns, even correctly, since it's redundant (the Flow would overwrite it on insert
regardless) and needlessly reintroduces the value-mapping risk that bit `Build-AccountReconciliation.ps1`.
**This is not Partner-Account-specific** — Opportunity
(`LDGCRM_Opportunity_Before_Save_Assign_Account_and_Market_Segment`, from `$Record.Account.LDGCRM_Market_Segment__r.Id`)
and Application
(`LDGCRM_Application_Before_Save_Assign_Market_Segment`, from
`$Record.LDGCRM_Partner_Account__r.LDGCRM_Account__r.LDGCRM_Market_Segment__r.Id`) have the same
kind of before-save Flow deriving Market Segment from their related Account. **Neither of those
not-yet-built transform scripts should set `LDGCRM_Market_Segment__c` either** — check for a
before-save Flow on the target object before assuming a field needs populating directly, the same way
you'd check a picklist's restricted values or a field's actual length.

### Field mapping

| Airtable field | Salesforce field | Transformation rule |
| --- | --- | --- |
| `id` (= `Partner Account Record ID`) | `LDGCRM_External_ID__c` | Direct passthrough — the upsert key. |
| *(none — see gotcha below)* | `Name` (required `nameField`) | Sourced from `Agreement Short Name`, not a dedicated Name column (there isn't one) — see gotcha below. |
| `Agreement Short Name` | `LDGCRM_Agreement_Short_Name__c` (`Text`, length extended 10→50 — see gotcha below) | Direct passthrough — same value as `Name` above. |
| `Account Record ID` (linked, single value expected) | `LDGCRM_Account__c` (Master-Detail, CSV column `LDGCRM_Account__r.LDGCRM_External_ID__c`) | Direct passthrough of the linked Account's `rec...` ID. Rows with zero or more-than-one linked Account are skipped — see gotcha below. |
| `Active Account Folder` | `LDGCRM_Active_Accounts_Folder_URL__c` (`Url`) | Direct passthrough — checked all 75 non-blank values are genuine URLs first. |
| `Agency Summary` | `LDGCRM_Partner_Summary_URL__c` (`Url`) | Direct passthrough **only when the value looks like a URL** (`^https?://`) — matches this field's own description ("A link to the agency/partner summary documentation…") despite the misleading Airtable column name. 7 of 87 non-blank values are placeholder text (`"N/A"`, `"Not available"`, a bare state name like `"State of Wyoming"`) instead of real links — left blank rather than written into a URL field. |
| `Current Status Summary` | `LDGCRM_Current_Status_Summary__c` (`TextArea`→`LongTextArea`, length 131,072 — see gotcha below) | Direct passthrough. |
| `Initial Agreement Date` | `LDGCRM_Initial_Agreement_Date__c` (`Date`) | Direct passthrough — Airtable's `YYYY-MM-DD` format matches Bulk API's expected Date format exactly. |
| `Market Segment` | *(not written — see "Market Segment is NOT set by this script" above)* | Deliberately excluded: a before-save Flow already derives `LDGCRM_Market_Segment__c` from the linked Account. |
| `Account Complexity` | `LDGCRM_Partner_Account_Complexity__c` (restricted picklist) | Direct passthrough — all 5 distinct Airtable values checked against the field's 10 allowed values; all matched exactly, no map needed. |
| `Account Health` | `LDGCRM_Partner_Account_Health__c` (restricted picklist) | Direct passthrough — all 5 distinct values checked; all matched exactly. |
| `Account Owner` (object with `.email`) | `LDGCRM_Partner_Account_Owner__c` (Lookup to `User`) | **Resolved to a real Salesforce `Id`, not external-ID passthrough** — `User` has no external ID field to hang a relationship-header resolution on, so this is the one lookup in this script handled like Account's Owner-style reconciliation instead of a plain CSV passthrough. See gotcha below for the email-matching mechanics. |
| `Account Priority Level` | `LDGCRM_Partner_Account_Priority__c` (restricted picklist) | Direct passthrough — all 3 distinct values matched exactly. |
| `Login.gov Service Type` | `LDGCRM_Service_Type__c` (restricted picklist) | Direct passthrough — both distinct values used (`Authentication`, `Identity Verification`) matched exactly out of the field's 4 allowed values. |
| `Status` | `LDGCRM_Status__c` (restricted picklist) | Direct passthrough — all 3 distinct values matched exactly. |

### Fields deliberately excluded (no destination, or feed a different object/chunk)

Roughly 30 Airtable columns have no home on this object: rollup/computed counts (`# of Applications`,
`Account Health Score`, `IdV Application Count*`, `Months Since Last Meeting (from Account)`, etc.),
Airtable's own change-tracking columns (`(c) Account Health Change Date`, `(c) Current Status Summary
Updated`, …), and linked-record columns that drive *other* objects/chunks rather than this one
(`Contacts Record ID`, `Applications Record ID`, `Opportunities`, `Partner Portal Admin Confirmed` —
the last feeds `LDGCRM_Application_Contact__c`'s Partner Portal Admin flag per `CLAUDE.md`, not this
object). None of these were assumed-and-skipped without checking — each was confirmed to have no
corresponding field on `LDGCRM_Partner_Account__c` before being left out.

A handful of these — `Account Description`, `Known Blockers`, and possibly `Goals` — aren't
"no destination forever," they're candidates for the deferred **Notes** chunk (see the "Notes"
section above) or a not-yet-decided dedicated field. `Escalated User Support Cases` looks like a
linked-record column pointing at an Airtable table this migration doesn't currently pull at all —
flagged there as its own open question, not assumed to be a Notes candidate.

### Known data-quality gotchas

- **No Name column exists in Airtable for this table**, but `LDGCRM_Partner_Account__c.Name` is
  required. Two real candidates existed: `Tag` (Airtable's actual primary/title field, e.g.
  `"general_services_admin"` — but a snake_case slug, and missing on 9 of 99 rows) and `Agreement
  Short Name` (e.g. `"GSA-OSI"`, human-readable, present and non-duplicated on all 99 rows). Chose
  `Agreement Short Name` — a deliberate, user-confirmed decision, not a default guess, precisely
  because this table breaks the general pattern (every other table so far has had an obvious Name
  source).
- **Two fields were too short for real data, both fixed via `sfdx-metadata-sync` before this script
  was written** (same category as Impediment's fields, see General Principle #4):
  `LDGCRM_Agreement_Short_Name__c` was `Text(10)` against real values up to 37 characters (24 of 99
  rows affected — extended to `Text(50)`); `LDGCRM_Current_Status_Summary__c` was a 255-char
  `TextArea` against values up to 9,590 characters, an ever-appended dated log that will keep growing
  — converted to `LongTextArea` at 131,072 (Salesforce's max, not just 32,768 like Impediment's
  fields, specifically because this field's content only grows over time).
- **5 of 99 rows skipped for missing/ambiguous parent Account**: 4 have no linked Account at all (all
  `Inactive`/placeholder agreements — `USDT(inactive)`, `DOD-AFRL-Bifrost - placeholder`, `USACE`,
  `DOD-ARMY-CAC (INACTIVE AGREEMENT)`); 1 (`USDT-SSP`) links to *two* Accounts, and Master-Detail only
  supports one parent. All 5 written to `PartnerAccount-skipped-<ts>.csv` for human review rather than
  guessed at.
- **A real bug was caught while building this script's parent-Account check**: PowerShell's `@($null)`
  produces a **1-element array containing `$null`, not an empty array** — the first version wrapped
  the raw Airtable field in `@()` before checking `.Count -eq 0`, which meant the 4 rows with no
  parent Account at all silently passed the "missing" check (count was 1, not 0) and would have been
  written to the upsert CSV with a blank Master-Detail parent reference instead of being skipped. Only
  the genuinely multi-valued row was caught correctly. Fixed by checking `-not $RawValue` **before**
  wrapping in `@()`. Worth remembering for any future transform that checks a linked-record array's
  presence/count.
- **Owner email matching needed a sandbox-specific transform**: gsa-peo appends `.invalid` to every
  User's `Email` (standard Salesforce sandbox behavior, confirmed by querying `User` directly — a
  plain email match against the 7 distinct Airtable owner emails returned zero results until this was
  accounted for). Matched by querying `Email IN (<airtable-email>.invalid, ...)` and stripping the
  suffix back off to build the lookup key. 5 of 7 emails matched an active User; the other 2
  (`elizabeth.mays@gsa.gov`, `tony.parrilla@gsa.gov`) match no User at all in gsa-peo — those rows'
  owner is left blank (the field isn't required) and written to
  `PartnerAccount-unmapped-owner-<ts>.csv` for review, rather than the whole row being skipped.

---

## Opportunity

**Source:** Airtable `Opportunities` table (928 rows, **72 distinct columns** as of 2026-08-13 — note
the first record only exposes ~35 keys, since Airtable omits empty fields per record; enumerate keys
across *all* rows, not just `[0]`, or you'll silently miss half the table).
**Target:** `Opportunity`, `Login_gov` record type.
**Script:** `Build-OpportunityLoad.ps1`. **Mode: upsert on `LDGCRM_External_ID__c`.** Queries
Salesforce read-only for the Login_gov RecordTypeId and the reconciled Account set.
**Loaded 2026-08-13: 742/742 succeeded, 0 failures** (after a 21-row test batch caught a blocker —
see below).

### The record type silently blocks picklist values — and the API DOES enforce it

**This is the most important finding on this object, and it contradicts a common assumption.** A
19-row test batch failed 19/19 with `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST` on two fields whose
values were verified valid at *field* level:

| Field | Airtable needs | Login_gov record type exposed |
| --- | --- | --- |
| `LDGCRM_Opportunity_Type__c` | `OM - New Agreement` (433), `AM - Account Growth` (272), `AM - Renewal` (9) | only 5 generic TTS values (`New Business`, `Add-on/Mod`, `Follow-on`, `Renewal`, `Winback`) |
| `LDGCRM_Likely_Service_Level_Needed__c` | `Basic IdV` (232), `Authentication Only` (170), `Enhanced IdV (IAL2)` (82) | only `IdV, Auth-only` — a value that appears nowhere in Airtable |

**Lesson: `sf sobject describe` reports a picklist's FIELD-level values, which is not the set a given
record type will accept.** Checking the describe output — the habit that worked for every other
object — is *not sufficient* when the target has more than one record type. Read
`objects/<Object>/recordTypes/<RecordType>.recordType-meta.xml` too, and remember its `fullName`
entries are URL-encoded (`,`→`%2C`, `/`→`%2F`, `(`/`)`→`%28`/`%29`, `&`→`%26`, `'`→`%27`) so a naive
string compare against field values will report false mismatches.

**Resolution (user-confirmed 2026-08-13): expose the 6 missing values on the Login_gov record type**
rather than dropping the fields or redirecting to the standard `Type` field. Justification, in order
of weight:
1. **This object's own revenue formula proves intent**:
   `LDGCRM_Est_Annual_Revenue_fully_ramped__c` = `MAX(IF(ISPICKVAL(LDGCRM_Opportunity_Type__c, "OM - New Agreement"), 30000, 0), …)`.
   The formula is keyed on a value the record type wouldn't allow anyone to select — self-evidently a
   record-type configuration gap, not a deliberate restriction. Verified post-load: 467 Opportunities
   now compute a non-zero revenue, which would have been 0 had the values gone to the standard `Type`
   field instead (the formula doesn't read `Type`).
2. The 3 service-level values are byte-identical to what `LDGCRM_application__c.LDGCRM_Service_Level__c`
   already uses in production.

Deployed via `sf project deploy start --metadata "RecordType:Opportunity.Login_gov" --test-level NoTestRun`
and **re-verified by re-running the identical test batch, which then passed 21/21** — not assumed from
a successful deploy.

### Three required standard fields, and only one has a complete source

`Name`, `StageName`, and `CloseDate` are required by the platform (the Login.gov business process
defines **no default stage**, so `StageName` must be supplied explicitly on every insert).

- **`Name` ← `Opportunity Name`** — present on all 928 rows, max length 100 against the standard 120
  cap. No handling needed.
- **`StageName` ← `Status`** — a clean passthrough: all 7 Airtable values (`Identified`,
  `Prospecting`, `Qualified`, `Scoped`, `Agreements`, `Closed Won`, `Closed Lost`) are exactly the 7
  stages in the Login.gov business process. **28 rows have a blank Status and are skipped** — they
  cannot load. Do **not** also map `Status` onto `LDGCRM_Status__c`: that field's Login_gov record
  type strips the six values that overlap, and it's a different concept (a granular sales-motion
  status, not a stage).
- **`CloseDate` ← a documented 3-step fallback.** Only 199 of 928 rows have `Est. Go Live`, and the
  gap is structural rather than sloppy: 524 of 531 `Identified` opportunities have none, because a
  go-live date isn't estimated until a deal qualifies. Since the field is mandatory, the script falls
  back `Est. Go Live` → `(c) Last Status Change Date` → `Created`, **always a real date from the
  record's own history, never invented**, and writes every fallback row to
  `Opportunity-closedate-fallback-<ts>.csv` (576 rows on the first load) so nobody mistakes these for
  real forecast dates. `Est. Go Live` is *also* mapped independently to
  `LDGCRM_Estimated_Go_Live_Date__c`, so the genuine estimate is never conflated with the synthesized
  CloseDate.

### Rich text fields need escaping AND `<br>` — they are Html, not LongTextArea

`LDGCRM_Current_Status_Summary__c`, `LDGCRM_Recent_Conversations__c` and
`LDGCRM_Estimate_Rationale__c` are **`Html`** (rich text) fields. This inverts the Impediment lesson,
where the fix was choosing LongTextArea *over* Html — here the fields are already Html, and writing
plain text into them loses data two ways:
1. **Bare `<`/`>`/`&` are parsed as markup.** 7 `Recent Conversations` values contain
   `<https://…>` autolinks that would vanish entirely, and 63 values across the three fields contain a
   bare `&`. Escaped first (`&`→`&amp;`, `<`→`&lt;`, `>`→`&gt;`).
2. **Newlines don't render.** All 559 `Recent Conversations` values and 119 `Current Status Summary`
   values are multi-line dated logs that would collapse into one unreadable paragraph. Newlines become
   `<br>` — **after** escaping, never before, or the generated tags get escaped too.

### Field mapping

| Airtable field | Salesforce field | Transformation rule |
| --- | --- | --- |
| `id` | `LDGCRM_External_ID__c` | Passthrough — the upsert key. |
| `Opportunity Name` | `Name` | Passthrough. |
| `Status` | `StageName` | Passthrough; row skipped if blank. |
| *(derived)* | `RecordTypeId` | The `Login_gov` RecordTypeId, queried at runtime. **Must be set explicitly** — Opportunity has two active record types, unlike `LDGCRM_application__c` which has one and could rely on the default. |
| `Est. Go Live` → `(c) Last Status Change Date` → `Created` | `CloseDate` | 3-step fallback, see above. |
| `Account Record ID` (linked array) | `AccountId` (CSV column `Account.LDGCRM_External_ID__c`) | `@(...)[0]`. Rows whose Account isn't reconciled in gsa-peo are **skipped**, not blanked — an unresolvable lookup fails the whole row. |
| `Opportunity Type` | `LDGCRM_Opportunity_Type__c` | Passthrough — after the record-type fix above. |
| `Focus Level` | `LDGCRM_Focus_Level__c` (restricted) | **Leading-token map**: Airtable embeds the review cadence in the label (`"High (2 month update)"`, `"Backlog (12 month update)"`); Salesforce stores just `Highest`/`High`/`Backlog`/`Developing`. Same shape as Application's Ramp Up Approach rule. |
| `Priority Type` | `LDGCRM_Level_of_Priority__c` (restricted) | **NOT MIGRATED — blocked, not excluded.** The field defines only `Low`/`Medium`/`High`; Airtable's 7 values are none of those. Needs the values added before it can load. See below. **462 of 742** rows waiting. |
| `Likely Service Level Needed` | `LDGCRM_Likely_Service_Level_Needed__c` | Passthrough — after the record-type fix above. |
| `Technical Readiness` | `LDGCRM_Technical_Readiness__c` (restricted) | `@(...)[0]` — a 1-element array. All 7 distinct values match the picklist exactly. |
| `Estimate source` | `LDGCRM_Estimate_Source__c` (restricted) | Passthrough — both values match exactly. |
| `Demographic Served` | `LDGCRM_Demographic_Served__c` (multiselect) | Array whose elements are themselves semicolon-joined (`"General Population; Gov?t Employees"`) — split on `;`, map, re-join. See the apostrophe note below. **No picklist expansion needed**, unlike Application: all 6 Airtable values map to the field's existing 6. |
| `Existing Identity Platforms` | `LDGCRM_Existing_Identity_Platforms__c` (multiselect, restricted) | Explicit map, `;`-joined. Was blocked as a linked-record column; Airtable converted it to a multi-select. See below. |
| `Alternative Identity Platforms` | `LDGCRM_Alternative_Identity_Platforms__c` (multiselect, restricted) | Same map as Existing — the two Salesforce value sets are identical. See below. |
| `Est. Go Live` | `LDGCRM_Estimated_Go_Live_Date__c` | Passthrough of the genuine estimate (distinct from CloseDate). |
| `Est. Annual IdV Users (fully ramped)` | `LDGCRM_Est_Annual_Idv_Users__c` | Passthrough. |
| `Est. Annual Auth-only Users (fully ramped)` | `LDGCRM_Est_Annual_Auth_Only_Users__c` | Passthrough. |
| `Est. Auth-only Avg Active Months` | `LDGCRM_Est_Auth_Only_Avg_Active_Months__c` | Passthrough. |
| `Est. First Year Ramp %` | `LDGCRM_Est_First_Year_Ramp__c` (`Percent`, scale 0) | **×100.** Airtable stores a 0–1 fraction (`0.5`); Salesforce Percent fields take the raw 0–100 number over the API. Rounded to a whole number since the field's scale is 0. This is the conversion that was moot on Application because every Percent field there was a formula — here it is live. |
| `App Description` | `LDGCRM_App_Description__c` | Passthrough — **after a metadata fix**, see below. |
| `Current Status Summary` | `LDGCRM_Current_Status_Summary__c` (`Html`) | Escape + `<br>`, see above. |
| `Recent Conversations` | `LDGCRM_Recent_Conversations__c` (`Html`) | Escape + `<br>`. |
| `Estimate rationale` | `LDGCRM_Estimate_Rationale__c` (`Html`) | Escape + `<br>`. |
| `Cost Estimate URL`, `Summary URL`, `Sandbox URL` | matching `Url` fields | Shared helper: strip Airtable's angle-bracket autolink wrapper (`<https://…>`), drop `N/A`/`None`/`TBD` placeholders, require `^https?://`, and blank anything over the 255-char platform cap. |

**The `Gov?t Employees` apostrophe trap (three different characters, one concept):**
- Airtable literally stores **`Gov?t Employees`** — an ASCII `?` (U+003F), on 25 rows. Confirmed *not*
  an export artifact: 82 curly apostrophes survive intact elsewhere in the same JSON file, so the
  corruption is in Airtable itself (logged in `AIRTABLE-DATA-QUALITY-REQUESTS.md`).
- `Opportunity.LDGCRM_Demographic_Served__c` (the target) uses a **straight** apostrophe `Gov't Employees` (U+0027).
- `Opportunity.Demographic_Served__c` (deprecated, not touched) uses a **curly** `Gov’t Employees` (U+2019).
- `LDGCRM_application__c`'s Global Value Set uses **`Gov't Employees (Contractors)`** — a different
  string again. **Do not share a Demographic mapping table between Application and Opportunity.**

### Identity platforms: a blocked column that unblocked itself, and the stale-export trap

Both columns used to hold `rec...` IDs pointing at an Airtable table this migration doesn't pull, so
they were documented as unresolvable. **Airtable has since converted both to plain multi-selects**
holding vendor names, which is what the two Salesforce restricted multipicklists wanted all along.
The conversion was lossless — the per-value counts are byte-identical before and after (272 tags on
Existing, 181 on Alternative), which is what confirmed the `rec...` IDs and the names are the same
data rather than a re-entry.

**The transferable lesson is that a "blocked, needs upstream work" finding has a shelf life.** This
one resolved itself with no code change on our side and no notification — it was only found by
re-reading the base schema. `GET /v0/meta/bases/{baseId}/tables` reports each field's `type`, so
re-checking it is cheap; a column that was `multipleRecordLinks` when a rule was written may not be
one now. Worth doing before writing a workaround for any column this file calls blocked.

**22 of the 25 distinct vendor names match Salesforce exactly. The three that don't are all
Salesforce-side problems, not Airtable data quality:**

| Airtable | Salesforce | Tags | Handling |
| --- | --- | --- | --- |
| `Ping / Forgerock` | `Ping/Foregerock` | 6 | Mapped. Spacing differs *and* the Salesforce value misspells ForgeRock (the vendor Ping Identity acquired). Correct the Salesforce value, after which this becomes a pass-through. |
| `Sign-in with Google` | `Sign-In with Google` | 1 | Mapped. Capitalisation only. |
| `CLEAR` | *(no value)* | 2 | **Dropped and flagged**, deliberately not filed under a near-neighbour — CLEAR is a distinct IdV vendor. Needs adding to both fields *and* the `Login_gov` record type. |

451 of 453 tags migrate. Salesforce also defines 8 values Airtable no longer offers (`Google
CiviForm`, `ManTech`, `Granicus`, `Shibboleth`, `Exostar`, `Jakobsen Id`, `Mattr`, `Idemia`) —
leftovers from the old linked table. Nothing writes to them; harmless.

Both fields are restricted, so an unmapped tag fails the **whole row** at the Bulk API, not just the
field — hence dropping rather than passing through. All 25 values were verified present on the
`Login_gov` record type, not just on the field, per this object's own record-type lesson.

**`Assert-IdentityPlatformsResolved` fails the build against a pre-conversion export.** A stale
`Opportunities.json` still holds `rec...` IDs, which match nothing in the map — so without the guard
the run would "succeed" while quietly dumping all 453 tags into the value-review CSV, and the failure
would read as an Airtable data problem rather than an out-of-date file on disk. The guard detects the
`rec` + 14-char shape and names the fix (`Get-AirtableExport.ps1 -Tables Opportunities`). This is the
general pattern for any transform whose source column changed type: **make the old shape a loud
failure, not a silent zero.**

### A metadata fix that WAS ours to make (unlike Name/Url)

`LDGCRM_App_Description__c` was `TextArea` with no `<length>` — the 255-char trap, hit for the third
time in this migration (after Impediment's Description/Talking Point and Partner Account's Current
Status Summary). 95 of 379 values exceed it, up to 1,711 chars. Deployed as `LongTextArea`
(32768/6 lines) before the load. Confirmed plain LongTextArea was right, not `Html`: the 17 values
matching an HTML-tag pattern are all angle-bracket-wrapped URLs (`<https://…>`), not markup.
**Contrast with `Name` (80) and `Url` (255) on Application, which are platform hard limits with no
`<length>` override** — always determine which kind you're facing before reaching for a metadata fix.

### Fields deliberately excluded

| Field | Why |
| --- | --- |
| `LDGCRM_Market_Segment__c` | Before-save Flow `LDGCRM_Opportunity_Before_Save_Assign_Account_and_Market_Segment` derives it from `Account.LDGCRM_Market_Segment__r` on create and on any `AccountId` change. Verified post-load: all 742 populated. |
| `LDGCRM_Status_Summary_Modified_Datetime__c` | Owned by a before-save Flow that stamps it whenever `LDGCRM_Current_Status_Summary__c` changes. Any migrated value is stomped on the next update touching the summary, so writing it produces a misleading timestamp. |
| `LDGCRM_Days_Since_Last_Activity__c`, `LDGCRM_Est_Annual_Revenue_fully_ramped__c`, `LDGCRM_Est_First_Year_Revenue__c`, `LDGCRM_Status_Summary_Indicator__c` | Formula fields. The two revenue ones compute *from* the estimate fields this script does set, so Airtable's own revenue columns aren't migrated — they recompute themselves. |
| `priority_type__c` | **Do not write this field.** Un-prefixed, owned by TTS OTCRM, and shared with the `TTS_OTCRM_Opportunity` record type. Its *label* is "Priority Type", identical to the Airtable column name — which is exactly what makes it a trap. Airtable's Priority Type belongs in `LDGCRM_Level_of_Priority__c`; see below. |
| `LDGCRM_Partner_Account__c` | **Structural mismatch — deliberately left blank pending a team decision, not an oversight.** See the dedicated analysis below. |
| `Requested Features`, `Current Blockers`, `Opportunity Status Changes`, `Meetings`, `Opportunity Contacts`, `Applications` | Linked-record arrays that drive other objects/chunks (Meetings, OpportunityContactRole) or reference untracked tables. |
| `Market Segment`, `Market Segment (from Account Name)`, `(c) *` rollups, `Created By`, `Updated?`, `Months in Status`, `Meeting Count`, `(legacy data) *` | Airtable-side rollups/computed/system columns, or superseded by the Flow-derived Market Segment. |

### Priority Type: the right field is `LDGCRM_Level_of_Priority__c` — MIGRATING as of 2026-08-14

**Status: migrating in Dev. 371 of 842 Opportunities carry a value.** ⚠️ **Other orgs need the
picklist promoted by change set first** — see the unblocking note below.

**The target is `LDGCRM_Level_of_Priority__c` (user-confirmed). Do not write `priority_type__c`.**
`priority_type__c` is un-prefixed, belongs to TTS OTCRM, and is assigned to the
`TTS_OTCRM_Opportunity` record type as well as `Login_gov`. Its **label is "Priority Type"** —
character-for-character the Airtable column name — which is precisely why it is easy to pick by
mistake. This repo did pick it by mistake, briefly, on 2026-08-13.

> **Generalise this.** The `LDGCRM_` prefix convention is the ownership signal in this org, not the
> label. A field whose label matches an Airtable column name is *weaker* evidence than a field whose
> API name carries the prefix, because the shared apps in this sandbox (TTS OTCRM, FCIC) label their
> fields in the same business vocabulary. Same family of error as General Principle #7: the surface
> appearance of a field is not its identity. When two candidate fields exist, **ask** — the cost of
> confirming is a message; the cost of guessing is a wrong-field load into another app's data.

**What used to block it:** `LDGCRM_Level_of_Priority__c` is `restricted=true` and defined exactly
three values — `Low`, `Medium`, `High` — none of which Airtable uses. A restricted picklist rejects
anything outside its defined values, so every row carrying a Priority Type would have failed with
`INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST`.

### ✅ UNBLOCKED 2026-08-14 — what was done, and the two decisions inside it

The field was changed **in Dev** and verified both ways (live describe *and* a metadata retrieve,
because `sf sobject describe` hides inactive values):

- **Four values added** to the field and assigned to the **`Login_gov` record type**:
  `Strategic`, `High Volume`, `IdV Upgrade`, `Leadership Escalation`.
- **`Low`/`Medium`/`High` retired.** 0 Opportunities used any of them, so nothing was lost. Note a
  metadata deploy **cannot delete** a picklist value — they are now `isActive=false` and remain in
  the value set until someone clicks **Del** in Setup.
- **`N/A` is deliberately NOT a Salesforce value.** Airtable's 157 `N/A` rows map to **blank**: it is
  how Airtable says the field does not apply, and a priority literally called "N/A" reads as data
  while meaning the absence of it. This is the one entry in `$PriorityTypeMap` whose value is `""`.

**Result:** 371 of 842 Opportunities carry a value — `Strategic` 249, `High Volume` 70,
`IdV Upgrade` 38, `Leadership Escalation` 14. Every value in the load file was cross-checked against
what the org accepts before loading.

> ⚠️ **This was a `sf project deploy` to Dev, which the standing change-control rule forbids for
> additive metadata.** It was done at the project owner's explicit request so the change could be
> picked up into an outbound change set (2026-08-14). **Dev only** — QA, Full and Prod still need it
> promoted by change set, and until they have it, loading this field there fails every affected row.

> ⚠️ **Side effect worth knowing: `TTS_OTCRM_Opportunity` lost its assignment for this field.** That
> record type only exposed `High`, so deactivating it left the block empty and Salesforce removed it
> (33 → 32 picklist blocks on that record type). Harmless — 0 records use the field, and the field is
> `LDGCRM_`-owned; it appears on the TTS record type only because the field was **renamed** into this
> app from an earlier life (project owner, 2026-08-14). Flagged because it is another app's record
> type changing as a consequence of ours.

**A new Airtable value is dropped and reported, never passed through.** The field is restricted, so
one unknown value fails the whole row. `$PriorityTypeMap` going stale is the likeliest cause of that:
Airtable held **seven** distinct values on 2026-08-13 and **five** on 2026-08-14 — the two `HISP` ones
were deleted from the field with no change on either side. Read `Opportunity-value-review-*.csv` after
every run.

> ### ⚠️ Re-check a picklist map against the Airtable SCHEMA, not the export
>
> **Counting distinct values in the export only finds choices somebody has already used.** A choice
> that is *defined but not yet selected* is invisible that way, and the first record to use it gets
> silently dropped — which for a restricted Salesforce picklist is the difference between a dropped
> tag and a failed row.
>
> The field's own definition is authoritative. It needs the PAT's `schema.bases:read` scope, which is
> separate from `data.records:read`:
>
> ```
> GET https://api.airtable.com/v0/meta/bases/{baseId}/tables
>   → .tables[name='Opportunities'].fields[name='Priority Type'].options.choices
> ```
>
> Checked that way on 2026-08-14: exactly five choices are defined, and the field is a `singleSelect`,
> so a row can never carry two. The data-level count happened to agree here — but only because the
> `HISP` values had been deleted outright rather than merely abandoned. **It agreed by luck, not by
> method.** The same reasoning applies to every `$…Map` in these transforms.

### `LDGCRM_Partner_Account__c`: sparse, but structurally fine — and a lesson in not trusting a rollup

Raised 2026-08-13 by the user ("did you link up the partner account to the opportunity?"). The answer
was no, and chasing it produced **a wrong intermediate conclusion worth recording, because the way it
was wrong is a repeatable trap.**

**The Airtable Opportunities table has no Partner Account column at all**, so there is nothing to map
directly. (An earlier version of this script's header wrongly claimed the column *existed but was
empty*. Reading a non-existent property in PowerShell returns `$null`, indistinguishable from an
empty column unless you enumerate the actual key set — a distinct failure mode from the `@($null)`
trap, and the reason the wrong claim survived review.)

The Partner Accounts table *does* have an `Opportunities` column — 961 links over 469 Opportunities,
which looks like a rich, authoritative relationship. **It is not one.** Counting those links
per-Opportunity suggested 146 Opportunities were each claimed by up to 8 different Partner Accounts,
which was written up (briefly, and incorrectly) as a many-to-many structural mismatch requiring a
junction object.

**What it actually is:** a roll-up of the Opportunities belonging to the Partner Account's *parent
Account*. Proven by comparing each Partner Account's `Opportunities` set against the set of
Opportunities whose own `Account Record ID` points at that same Account:

| Result | Partner Accounts |
| --- | --- |
| `Opportunities` list is an **exact match** for the parent Account's Opportunity set | **72** |
| Strict subset of it | 0 |
| Contains something not on the parent Account | 4 (`USDT-SSP` — the known two-Account row; `GSA-IAE`, `GSA-OIT` off by one; `GSA-OROS` 9 vs 4) |

Hence the "8 Partner Accounts claiming one Opportunity" signal: all 8 DOD Partner Accounts share one
parent Account, so all 8 roll up the identical 50 Opportunities — several of them named
`(placeholder)` or `(INACTIVE AGREEMENT)`. **The giveaway was that all 8 had byte-identical
Opportunity lists and the exact same count.** A real many-to-many relationship doesn't produce
identical sets across unrelated records; a rollup does.

**Lesson: before treating a linked-record column as an authored relationship, check whether it's
derivable from a parent.** Airtable lookup/rollup fields arrive over the API as ordinary arrays of
`rec...` IDs — structurally indistinguishable from a directly-authored link. The test that settles it
is cheap: compare the set against what the parent would produce. Same family of mistake as trusting a
column *name* (General Principle #1) or a field's declared *type* (#7) — here it was trusting a
column's *shape*.

**Conclusion (user-confirmed 2026-08-13): the single Lookup is the right structure; there is simply
much less linkage than the Airtable views imply.** The only genuinely authored Opportunity → Partner
Account path is via **Applications**, which reference both: 82 Opportunities, every one unambiguous
(zero conflicts), 66 with both sides present in gsa-peo today. That is ~9% of the 928 Airtable
Opportunities — the real coverage, versus the 469 the rollup appeared to offer. No junction object,
no schema change.

**Implemented inside `Build-OpportunityLoad.ps1`, not as a separate pass.** It was briefly built as a
standalone script (`Build-OpportunityPartnerAccountLink.ps1`, since deleted) on the reasoning that it
sources from a different table. **That was a code-organization argument, not a technical dependency,
and it was wrong to split on it** — the user caught it by asking whether a full clean run would
include the linkage automatically. It wouldn't have: an operator would have had to remember an extra
step, and forgetting it would leave every Opportunity's Partner Account silently blank.

There is no ordering obstacle: **Partner Accounts load before Opportunity** (see the load order in
`ARCHITECTURE.md`), so the lookup resolves during the same load, and the derivation only needs the
local Applications JSON export — not Applications loaded into Salesforce. Verified by consolidating
and re-running: identical 66 links, 742/742 succeeded.

**The distinction worth carrying forward:** a second pass is only justified when the data genuinely
cannot resolve in one — Application's `LDGCRM_Broker_App_Parent__c` qualifies (self-referential, its
parents are in its own batch, proven to fail). "The source is a different table" does not qualify.

The transform still collects the *full* set of Partner Accounts per Opportunity rather than taking
the first match, so if two Applications ever disagree the row is left blank and flagged to the review
CSV instead of being silently resolved to whichever came first. Currently 0 such conflicts; 6 more
Opportunities have a known Partner Account that isn't loaded yet and fill in on a re-run.

### Load results (2026-08-13)

742 of 928 rows loaded; **742/742 submitted rows succeeded**. Verified post-load: all 742 have the
Account lookup resolved, all 742 have Market Segment populated by the Flow, and 467 compute a
non-zero revenue. The 186 not loaded:

| Reason | Rows | Resolution |
| --- | --- | --- |
| Account not reconciled in gsa-peo | 142 | The duplicate/unmatched Airtable Account problem — fix the Accounts and re-run. |
| No Status (StageName required) | 28 | Needs a Status in Airtable. |
| No Account link in Airtable at all | 16 | Needs an Account link in Airtable. |

Re-running `Build-ApplicationLoad.ps1` afterward dropped its blank-Opportunity-link count from 92 to
7 and the reload wrote those links (85 Applications now linked to an Opportunity).

---

## OpportunityContactRole

**Source:** Airtable `Opportunity Contacts` (520 rows).
**Target:** `OpportunityContactRole`.
**Script:** `Build-OpportunityContactRoleLoad.ps1`. **Mode: INSERT with a read-then-diff — the only
object in the pipeline that cannot be upserted.**
**Loaded 2026-08-13: 515 rows, 0 failures.**

### The documented `externalId` fix does not exist

`CLAUDE.md` recorded this object as "blocked on an `sfdx-metadata-sync` fix
(`OpportunityContactRole.LDGCRM_External_ID__c` needs `externalId=true`)". **That fix is impossible.**
Deploying it fails:

> `Fields on Opportunity Contact Role do not support the property Is External Identifier.`

Salesforce does not permit External ID fields on this object at all, so
`sf data upsert bulk --external-id` can never work against it. The field is left at `false` with a
comment recording why, so nobody retries it. It is still *populated* (`<airtableRowId>|<role>`) purely
for traceability.

**Idempotency instead comes from a read-then-diff**, the same shape `Build-AccountReconciliation.ps1`
uses for Account: query what already exists, key it on `(OpportunityId, ContactId, Role)`, and emit an
insert file containing only what's missing. Proven: after loading a 12-row test batch, the full re-run
reported exactly `12 already in the org` and inserted the remaining 503.

### Two column traps, one of which cost a whole failed run

1. **`Opportunity Record ID` on this table is the row's OWN id, not a link.** Every other table in
   this migration follows the convention that `<X> Record ID` *is* the link to X. Here it inverts:
   **0 of 520** of its values are real Opportunity ids, and every one equals the row's own `.id`. The
   real link is **`Opportunity Record ID (from Opportunities)`** (520/520 valid) — a lookup column
   Airtable names after its source. Using the obvious-looking column skipped all 520 rows.
2. **There is no Contact link at all** — just a name string and an email. 348 of 520 rows name people
   who appear nowhere in the Contacts table. Those people are created as Contacts by
   `Build-ContactLoad.ps1`, which folds this table in as a second source (see the Contact section);
   this script re-derives the same grouping via `Get-AirtableContactGroups` to find each row's
   surviving Contact, then resolves that external ID to a real Salesforce Id.

### One record per role (user-confirmed)

62 rows carry 2+ `Contact Type` values while `Role` holds one, so **each type becomes its own
record**. Verified on the test batch that Salesforce permits multiple roles for the same contact on
the same opportunity — `Ken` on `CIA - Vendor Portal ID26` correctly holds all three.

**`IsPrimary` behaves per-contact, not per-role.** Salesforce allows one primary contact role per
Opportunity, so the script sets the flag on at most one row per Opportunity — the highest-precedence
role (`Decision Maker` > `Senior POC` > `Day-to-Day POC`). Confirmed in the output CSV: exactly one
`true` per pair. **Salesforce then propagates it** to that contact's other role rows on the same
opportunity, so all three of Ken's rows read `IsPrimary=true`. That is correct — the contact *is* the
primary — not a bug in the transform.

### The Role picklist was extended rather than mapped

`Contact Type` uses `Day-to-Day POC` (405) and `Senior POC` (82); only `Decision Maker` matched the
existing picklist. `Role` is unrestricted, so both would have loaded as ad-hoc values. User-confirmed
decision: **add them properly** rather than map them onto approximate existing values, keeping the
picklist authoritative and the source meaning intact.

They live in the **StandardValueSet named `ContactRole`** — *not* `OpportunityContactRole`, which does
not exist as an entity (`Entity of type 'StandardValueSet' named 'OpportunityContactRole' cannot be
found`). Note also that listing org metadata of type `StandardValueSet` returns **nothing** for this
org, so the name can't be discovered that way. `Role.field-meta.xml` has no `<valueSet>` block at all,
so deploying the *field* carries none of this. Added to `manifest/package.xml`. **For a change set,
the component is type `Standard Value Set`, name `ContactRole`** — and standard value sets are
historically unreliable in change sets, so the values may need adding manually in the target org.

### Field mapping

| Airtable | Salesforce | Rule |
| --- | --- | --- |
| `Opportunity Record ID (from Opportunities)` | `OpportunityId` | Resolved to a real Id — **not** the similarly-named decoy column. |
| *(row → merged Contact)* | `ContactId` | Via `Get-AirtableContactGroups`, then external ID → real Id. |
| `Contact Type` | `Role` | One record per value. |
| `Primary` | `IsPrimary` | At most one per Opportunity; Salesforce propagates across that contact's roles. |
| *(row id + role)* | `LDGCRM_External_ID__c` | Traceability only — **cannot** be an upsert key. |

### Load results

| | Count |
| --- | --- |
| Airtable rows | 520 |
| **Loaded** | **515** (12 test batch + 503) |
| — Day-to-Day POC / Decision Maker / Senior POC | 338 / 111 / 66 |
| — flagged `IsPrimary` | 361 (after Salesforce's propagation) |
| Skipped — Opportunity or Contact unresolved | 83 |

---

## Opportunity Impediment (junction)

**Source:** the Airtable `Impediments` table's two linked-record columns — **not** a table of its own.
**Target:** `LDGCRM_Opportunity_Impediment__c`, a true junction with **two Master-Detail**
relationships (Impediment and Opportunity), so **both parents are required**.
**Script:** `Build-OpportunityImpedimentLoad.ps1`. **Mode: upsert on a COMPOSITE
`LDGCRM_External_ID__c`** (`<impedimentExtId>|<opportunityExtId>`), same pattern and rationale as the
Application Contact junction.
**Loaded 2026-08-13: 267 of 267 succeeded, 0 failures.**

### The severity lives in *which column* an Opportunity appears in

There is no severity field in Airtable. The column is the value:

| Airtable column | `LDGCRM_Severity__c` |
| --- | --- |
| `Opportunities blocked` | `Blocker` |
| `Opportunities requested` | `Impediment` |

`LDGCRM_Severity__c` is a **required** restricted picklist (`Impediment` / `Blocker`), so every row
must resolve to exactly one — which is a problem, because **122 pairs appear in both columns**.
User-confirmed rule (2026-08-13): **`Blocker` wins.** It's the more severe value and the one that
drives the Blocked Revenue roll-up, so recording the pair as blocked is the safer, more visible
choice. Every conflict is written to `OpportunityImpediment-severity-conflict-<ts>.csv` regardless.

### The Impediment named "None" is deliberately excluded

**This is the significant data decision on this object.** One Airtable Impediment is literally named
`None`, with an **empty Description and Talking Point**, and it carries **263 blocked + 202 requested
links — 465 in total, over 5× more than any real impediment** (the next highest is `Unresponsiveness`
at 86). It reads unmistakably as a placeholder meaning *"no impediment"*.

Loading it would have been actively wrong in two ways:
1. It asserts those Opportunities **are** impeded, the opposite of what the data means.
2. `LDGCRM_Blocked_Revenue__c` on the junction is set by an after-save Flow and **rolls up to the
   Impediment**, so `None` would have surfaced at the top of any "most blocking impediment" report
   with a meaningless multi-million-dollar figure.

It accounted for **297 of the 564 otherwise-loadable pairs (53%)** and **115 of the 122 severity
conflicts** — so excluding it also removed most of the ambiguity.

**⚠️ SETTLED 2026-08-14: the Impediment RECORD is not created either.** Until then only its *links*
were excluded, so the org carried an impediment named `None` that nothing pointed at — a record whose
only purpose was to be ignored. The project owner's decision is that it should not exist at all, so
`Build-ImpedimentLoad.ps1` now skips the row as well (37 ready, was 38).

Excluding the record makes the junction exclusion **structural rather than a second rule that has to
agree**: with no parent Impediment, a junction row for it cannot be created even if that filter were
removed. Both scripts take the same `-PlaceholderImpedimentName` parameter and **must always be
given the same value**; setting it to `""` in one place only would produce links to a parent that
does not exist.

This is no longer an open question for the Airtable data owners — it is a settled business rule.
Deleting the Airtable row remains optional tidy-up on their side and changes nothing here.

Verified post-load that the roll-up now shows genuine figures — `Feature - Solution to proof 16+
users` at $20.5M, `Feature - Foreign Passport IDV` at $20.1M — which is exactly the reporting `None`
would have swamped.

### Field mapping

| Airtable | Salesforce | Rule |
| --- | --- | --- |
| *(composite)* | `LDGCRM_External_ID__c` | `<impedimentExtId>\|<opportunityExtId>` — the upsert key, 35 chars against a 50 cap. |
| Impediment `id` | `LDGCRM_Impediment__c` (CSV `LDGCRM_Impediment__r.LDGCRM_External_ID__c`) | **Master-Detail, required.** |
| Opportunity `rec...` from either column | `LDGCRM_Opportunity__c` (CSV `LDGCRM_Opportunity__r.LDGCRM_External_ID__c`) | **Master-Detail, required.** |
| *(which column)* | `LDGCRM_Severity__c` | Required; `Blocker` wins on conflict. |

**Not written:** `Name` (AutoNumber, `OIID-{00000}`); **`LDGCRM_Blocked_Revenue__c`** — owned by the
after-save Flow `LGDCRM_Opportunity_Impediment_Before_Save_Update_Blocked_Revenue` (note the
misleading filename: its `triggerType` is actually `RecordAfterSave`), which sets it from the parent
Opportunity's estimated revenue when severity is `Blocker` and the Opportunity isn't `Closed Won`,
and 0 otherwise. Confirmed working on the test batch before the full load: a `Blocker` on an open
Opportunity got $30,000, an `Impediment` got 0.

### Load results

| | Count |
| --- | --- |
| Raw (Impediment, Opportunity) links | 783 |
| — dropped as the `None` placeholder | 465 |
| Distinct pairs from real Impediments | 311 |
| **Loaded (both Master-Detail parents present)** | **267 / 267** |
| — severity `Blocker` / `Impediment` | 243 / 24 |
| Skipped — Opportunity not loaded | 44 |
| Severity conflicts resolved to `Blocker` | 7 |

Also found: **`Feature - Citizenship verification` exists as two separate Airtable Impediment rows** —
a duplicate worth flagging to the data owners.

---

## Application Contact (junction)

**Source:** the Airtable `Contacts` table's `Applications Record ID (from Applications)` column —
**not** a table of its own.
**Target:** `LDGCRM_Application_Contact__c`, the Application↔Contact junction (two plain Lookups, not
Master-Detail).
**Script:** `Build-ApplicationContactLoad.ps1`. **Mode: upsert on a COMPOSITE `LDGCRM_External_ID__c`.**
**Loaded 2026-08-13: 1,880 of 1,880 succeeded, 0 failures.**

### The composite external ID is the whole design

A before-save Flow (`LDGCRM_ApplicationContact_BeforeSave_NewRecordDuplicateCheck`) enforces one row
per Application+Contact and **throws a hard blocking error** —
`"This Contact has already been assigned to this Application"` — on any duplicate. It has **no
bypass**: no permission check, no custom setting, no variables. It fires on **100% of inserts** (no
entry criteria).

Two properties of that Flow make source-side deduplication mandatory rather than optional:
1. **It only fires on `Create`.** An upsert resolving to an update never sees it.
2. **Intra-batch duplicates slip straight through.** Its Get Records reads *committed* database
   state, so two identical rows inside the same Bulk API batch both pass the check and both insert.
   **The Flow is not a safety net.**

So this object's `LDGCRM_External_ID__c` is the composite key
**`"<contactExternalId>|<applicationExternalId>"`** (35 chars against the field's 50). That makes
uniqueness *structural*: the upsert key itself cannot produce a second row for the same pair, so
re-running is idempotent and the Flow never has a duplicate to reject. Verified in the output CSV —
1,880 rows, 1,880 distinct external IDs, 1,880 distinct (contact, application) pairs.

### It reads Airtable's raw Contact ROWS, not the merged Contacts

`Build-ContactLoad.ps1` merges Airtable rows sharing an email into one Contact (see the Contact
section). But the per-association detail — *which* Applications, and *which* Roles — lives on the
individual **row**, not on the merged person. So this script iterates the raw rows and maps each onto
its surviving Contact through `Get-AirtableContactGroups`, the same shared helper
`Build-ContactLoad.ps1` uses, so the two cannot drift.

That merge is exactly what creates the duplicate risk: **2,797 raw (row, Application) pairs collapse
to 2,764 distinct (Contact, Application) pairs — 33 collisions**, each of which would have been a
Flow rejection. The Partner Portal Admin flag is OR-ed across every source row feeding a pair.

### Partner Portal Admin has TWO sources, and one of them creates associations

**The Applications table's `Partner Portal Admin` column is not one of them.** Filled on 875 rows, it
looks like the obvious source and is **unusable**: a flattened roll-up of all the linked contacts'
Roles, *not positionally aligned* with `Contacts Record ID` — the two arrays differ in length on
**709 of 875 rows**:

```
App rec09x50mFdLT5MI6 [SIMS]
   Contacts Record ID  (2): reccHQOPwOeBs2DsG, recaDs5hblOUAUwni
   Partner Portal Admin(8): PAG POC | Program POC | Threat Intel POC | Partner Portal Admin
```

There is no way to tell which contact a given entry refers to, so using it would assign the flag
essentially at random. Same family of trap as the Partner Accounts `Opportunities` rollup (see the
Opportunity section): **a linked-record column that looks authoritative but is derived.**

The two real sources:

| Source | What it is | Pairs asserted |
| --- | --- | --- |
| **a)** `Contacts.Roles` contains `Partner Portal Admin` | Per-association, because Airtable duplicates contact rows per association. The original source. | 999 |
| **b)** Issuer Strings' `Partner Portal Admin Email` | **Added 2026-08-13.** Names the admin per issuer string; each issuer string links to its Application(s). | 968 |

They agree on **882** pairs. Each sees some the other doesn't — **117** Roles-only, **86**
Issuer-Strings-only. **The flag is their UNION**, not their intersection: both are authored data, and
dropping a flag because the other source is silent would discard real information on the strength of
an inference. Provenance for every flag is written to
`scripts/logs/data-migration/ApplicationContact-admin-source-*.csv` (`BOTH` / `Contacts.Roles only` /
`Issuer Strings only`), because after a union nobody can otherwise answer "why is this person an
admin?".

#### The 86 matter far more than the number suggests

**None of them had a junction row at all.** They are 34 people administering 68 Applications that the
Contacts table never associates them with — e.g. a DOL admin on `State of Alaska Unemployment
Insurance`. So source (b) does **not** merely set a flag on rows that already exist; it **creates
associations**. Treating it as flag-only — the obvious reading of "the admin flag has a second
source" — would have silently lost the association entirely rather than merely mislabelling it.

Per the project owner (2026-08-13): a Partner Portal Admin **should be** an Application Contact with
the checkbox checked. That makes creating the row the correct behaviour, not a liberty.

Matching is by **email**, through the same `Get-CleanContactEmail` that built the merged Contacts, so
an address that is dirty in Airtable (embedded name/phone, stray whitespace) resolves identically on
both sides. All 239 admin emails currently match a Contact; any that don't are reported rather than
dropped, since an admin who isn't a Contact can't be given a junction row at all.

**Watch the collision arithmetic.** The summary derives "collisions collapsed by the Contact merge"
as (raw pairs − distinct pairs). That is only meaningful against pairs the *Contacts* table produced,
so the count is snapshotted **before** the Issuer Strings pass — otherwise the 86 added pairs
understate the collisions. Likewise the admin breakdown covers *all* pairs including skipped ones, so
it deliberately does **not** sum to the in-the-load figure; the summary says so, because two admin
totals that don't reconcile otherwise read as a bug.

### Field mapping

| Airtable | Salesforce | Rule |
| --- | --- | --- |
| *(composite)* | `LDGCRM_External_ID__c` | `<contactExtId>\|<applicationExtId>` — the upsert key. |
| Contact row → merged Contact | `LDGCRM_contact__c` (CSV `LDGCRM_contact__r.LDGCRM_External_ID__c`) | **Required.** Note the lower-case `c` in `contact`. |
| `Applications Record ID (from Applications)` | `LDGCRM_Application__c` (CSV `LDGCRM_Application__r.LDGCRM_External_ID__c`) | Optional in metadata, but always set here — see the blank-Application warning below. |
| `Roles` contains `Partner Portal Admin` | `LGDCRM_P3_Partner_Portal_Admin__c` | Checkbox. **Note the transposed `LGDCRM_` prefix** — a typo baked into the deployed metadata, and the single most likely CSV-header failure on this object. |

**Not written:** `Name` (the nameField is an **AutoNumber**, `LDGAC-{0000}` — supplying it errors);
`LDGCRM_Email__c`, `LDGCRM_P3_Team_UUID__c`, `LDGCRM_P3_Partner_Portal_Team_Name__c` (all three are
formula fields pulling from the parents); `RecordTypeId` (the object has no record types). Every
other `Roles` value (`Technical POC` 667, `Program POC` 304, `Help Desk POC` 224, `Exec POC` 49,
`PAG POC` 37, `ConMon Attendee` 29, `Archive` 26, `Threat Intel POC` 18, `UX POC` 1) has **no field
on this object** and is not migrated.

**A latent Flow bug worth knowing:** `LDGCRM_Application__c` is `required=false`, so a row with a
blank Application makes the Flow's filter `Application == null AND Contact == <id>`, which matches
any *other* Application-less row for that Contact and wrongly blocks it. This script always sets an
Application (pairs are generated *from* the Applications list), so it can't hit this — but a future
loader that allows blank Applications would.

### Load results

**What actually loaded on 2026-08-13** (kept as the record of that run, not as a target to reproduce):

| | Count |
| --- | --- |
| Raw (Airtable row, Application) pairs | 2,797 |
| Distinct (Contact, Application) pairs | 2,764 |
| — collisions collapsed by the Contact merge | 33 |
| **Loaded (both sides present)** | **1,880 / 1,880** |
| Skipped — Application not loaded | 849 |
| Skipped — Contact not loaded | 31 |
| Skipped — neither | 4 |
| Flagged Partner Portal Admin | 666 |

**⚠️ Re-baselined later the same day** — after the Airtable re-pull *and* the addition of Issuer
Strings as a second admin source. Do not treat the figures above as pass/fail:

| | Count |
| --- | --- |
| Raw (Airtable row, Application) pairs | 2,747 |
| Distinct pairs from the Contacts table | 2,741 |
| — collisions collapsed by the Contact merge | 6 |
| — **associations added by Issuer Strings** | **86** |
| Total distinct pairs | 2,827 |
| **Ready for upsert** | **1,779** |
| Skipped — a side isn't loaded | 1,048 |
| Flagged Partner Portal Admin (in the load) | 573 |
| — of which Issuer Strings supplied the association | 42 |

The skipped rows are overwhelmingly Applications withheld by the unreconciled-Account data-quality
issue. **They need no code change** — re-running after those Accounts are fixed picks them up.

Also worth noting for any future cleanup: `LDGCRM_contact__c` has `deleteConstraint = Restrict`, so a
Contact cannot be deleted while junction rows point at it. This is the same class of blocker that
left one Account undeletable during the 2026-08-13 rebuild.

---

## Contact

**Source:** Airtable `Contacts` table (1,599 rows, 47 columns as of 2026-08-13).
**Target:** `Contact`, **`Federal`** record type — or **`GSA`** for anyone with an `@gsa.gov` address
(98 contacts). User-confirmed: this migration creates only those two; the `FCIC_Duplicate`,
`FCIC_Individual` and `TTS_Individual` record types belong to other apps and are never used.
**Script:** `Build-ContactLoad.ps1`. **Mode: upsert on `LDGCRM_External_ID__c`.**
**Loaded 2026-08-13: 1,483 of 1,487 submitted rows succeeded.**

### Rows are MERGED, not 1:1 — Airtable is missing a junction

This is the only object so far where one Airtable row does not become one Salesforce record.

Airtable has no person↔Application junction, so **the same human is entered once per association**:
one row carries their name and roles, the others are stubs with a blank `Name` and a different
`Applications` list. 47 of the 61 duplicate-email groups differ precisely by that list:

```
drucker.scott.d@dol.gov  (4 rows)
  recWvXp8co…  name=[Scott Drucker]  Apps=0   roles=Program/Technical/Exec POC
  recaDs5hbl…  name=[]               Apps=51  roles=Technical POC/Partner Portal Admin
  rec0NtgOi1…  name=[]               Apps=1   roles=[]
  recjUTf9Zw…  name=[]               Apps=1   roles=[]
```

Salesforce **has** that junction (`LDGCRM_Application_Contact__c`), so migrating 1:1 would import a
workaround the target schema doesn't need and split one person into up to four Contacts. Rows sharing
a cleaned email are therefore merged: **1,599 rows → 1,532 Contacts**, and merging alone recovers a
real name for 34 rows that had none.

Two groups are deliberately **not** merged:
- **Name conflicts (12 rows).** Where a shared email carries two different names, auto-merging would
  silently discard an identity. Three are the same person spelled differently (`Bennet Lohr` /
  `Bennett Lohre`; `Moye Xzavier` / `Xzavier Moye`), but two are **genuinely shared mailboxes serving
  different teams** — `enterpriseservicedesk@dol.gov` is both "EBSA Lost & Found Help Desk
  Information" and "ENT BPMS Contact Center". Left separate and flagged.
- **Rows with no usable email** — nothing to match on.

**The merge logic lives in `Get-AirtableContactGroups` in `Common.DataMigration.ps1`, not in this
script.** That is deliberate: the Application-Contact junction chunk must map *every* Airtable
Contact record ID onto whichever Contact actually got created. If it re-derived the grouping itself
the two implementations could drift and the junction would point at Contacts that don't exist. The
script also emits `scripts/data/salesforce-loads/Contact-identity-map.csv` (every source record ID → its
surviving Contact) as a direct input to that chunk.

### `LastName` is required and mostly absent — a documented waterfall

Only 491 of 1,599 rows have a `Name`. The waterfall (extended 2026-08-13 with email derivation):

| Step | Result |
| --- | --- |
| 1. Airtable `Name` (including a merged sibling's) | 973 |
| 2. `FirstName`/`LastName` from an existing Salesforce Contact matched on email | 0 — see the guard below |
| 3. **Derived from the email address** — a real first *and* last name | **597** |
| 4. Email local part as `LastName` where no split is defensible | 317 |
| 5. Role/shared mailbox — local part kept, never split | 56 |
| 6. Neither name nor email → **skipped** | 45 |

Step 2 is the behaviour **production** needs, where real Contacts already exist. Every row from
steps 2–4 goes to `Contact-name-review-<ts>.csv`; step 5 gets its own
`Contact-role-mailbox-<ts>.csv`.

Airtable names split on the **last** space, keeping multi-word forenames intact (`Krishna-Priya
Mandala` → `Krishna-Priya` / `Mandala`); single-token names go entirely into `LastName`, the
required side.

### Deriving a name from the email address (built 2026-08-13)

Before this, 970 contacts (62% of the load) went in with a raw address in `LastName` —
`aaron.greenwell@tspi.net` as a surname. Most of those addresses encode a real name. **597 now get a
genuine first and last name.**

Every rule below was derived by measuring the actual 970-row population, not assumed.

| Rule | Rows | Behaviour |
| --- | --- | --- |
| Role / shared mailbox | 56 | **Never split.** `LastName` = local part verbatim |
| DoD affiliation suffix | 56 | Strip trailing `.civ` / `.mil` / `.ctr`, then re-apply |
| `first.M.last` | 47 | Drop the single-letter middle token |
| `first.last` | 440 | Split — **order decided by the domain**, see below |
| `first_last` | 61 | Split on underscore |
| No separator (`jwoolf`) | 242 | No defensible split; local part as `LastName` |
| Other / ambiguous | 68 | Same |

**Measured accuracy, as a holdout** against the 358 contacts whose real name is already known:
**85.2% exact on both names**, 7.3% surname-right. Of the 27 non-matches, **none are ordering
errors** — 10 are cases where *Airtable's* name is reversed, 8 are spelling differences, 6 are
shared or reassigned mailboxes, 3 carry decoration. In several the derived name is **better than the
authored one**: `jason.cortezzo@ssa.gov` is filed in Airtable as "Jason Cotezzo", and
`robert.fink@spr.doe.gov` as "Robert Fink, CISSP (Contractor)".

#### ⚠️ Name order is a per-agency convention, not a constant

The obvious rule — `a.b@` means first.last — is wrong for real partners. Measured against the 490
Airtable contacts carrying both a Name and an Email:

| Domain | first.last | last.first |
| --- | --- | --- |
| `dol.gov` | 1 | **16** |
| `pbgc.gov` | 5 | 7 |
| `epa.gov` | 0 | 2 |
| `octo.us` | 0 | 2 |
| everywhere else | 235 | 27 overall |

`batchelet.doug@dol.gov` is Doug Batchelet. A blanket first.last rule reverses **44** of the 970,
concentrated in one major partner agency.

`Get-EmailNameOrderByDomain` therefore learns the order per domain, requiring `-NameOrderMinSupport`
(default 3) one-sided examples before trusting a domain and defaulting to first.last otherwise —
the same reasoning as the `.gov` Account-domain inference. `epa.gov` and `octo.us` have only 2
examples each and so stay on the default; they will flip themselves once a third real name appears.

#### ⚠️ Hyphen is NOT a separator, and that was checked rather than assumed

It looks like an obvious third separator alongside `.` and `_`. The data says the opposite: of 20
hyphenated local parts, nearly all are **role inboxes** — `e-filing`, `tracs-helpdesk`,
`benefits-notify`, `eere-exchangesupport`, `hsin-helpdesk`. Splitting on hyphen invents a person
called "Tracs Helpdesk".

Worse, a hyphen appears legitimately **inside** a surname: `smitha_singi-reddy` is Smitha
Singi-Reddy. So hyphens are **preserved, never split on** — splitting would both fabricate people
and break real names.

#### ⚠️ Two circularity guards, because this rule can feed itself

This is the same trap as the "970 names recovered from Salesforce" figure that turned out to be the
transform reading back its own placeholders — and building this feature reintroduced it twice before
the guards went in.

1. **The waterfall ignores existing Contacts whose `LastName` contains `@`.** Those are placeholders
   from an earlier run of this very script. Without the guard, 713 of 1,553 contacts took their name
   from the org — and because step 2 matches before step 3, it *suppressed the derivation entirely*
   (172 derived instead of 597).
2. **The order-learner uses Airtable-authored names ONLY**, never Salesforce Contacts. After one
   load with these rules the org contains names this script derived; feeding those back would
   confirm whichever order was chosen first regardless of correctness, and the evidence would look
   stronger every run while being entirely circular.

Note the learner still inherits *Airtable's* own name-order errors — `puneet.garg@octo.us` is filed
as "Garg Puneet", which registers as last.first evidence when the address is really first.last. That
is another argument for the minimum-support floor rather than trusting one or two examples.

`-DisableEmailNameDerivation` turns the whole thing off, reverting to the address-as-`LastName`
behaviour. It is the first thing to reach for if a derived name is ever seen on the wrong person.

#### Role and shared mailboxes are flagged, not named

56 addresses are inboxes rather than people — `support@`, `tracs-helpdesk@`, `fmcsa_api@`,
`waso_youth_partner_portal@`. They keep the local part as `LastName` with no invented forename, and
land in `Contact-role-mailbox-<ts>.csv` so the data owners can decide whether they belong in the CRM
as Contacts at all. That question is genuinely open — they are referenced by Opportunity Contact
Roles and Application junctions, so skipping them outright would cost those links.

### Account linkage matters more here than usual — it suppresses junk Accounts

Normally an unresolvable optional lookup is just blanked. On Contact it has a side effect: the
unrelated **FCIC Apex trigger creates a junk `FCIC_Individual` Account for every Contact inserted
with a blank `AccountId`** (see `CLAUDE.md`'s Operational gotchas). So every Account link recovered
is one less polluted Account.

Airtable's `Account` column covers most rows. Where it's missing or points at an unreconciled
duplicate Account, the script falls back through the contact's Applications —
**Application → Partner Account → Account** — which is not a guess but a real chain already present
in the source data:

| Account link source | Contacts |
| --- | --- |
| Airtable `Account` column | 971 |
| Recovered via Application → Partner Account → Account | **145** |
| None — FCIC trigger would spawn an Account | 371 |

The fallback cut junk-Account exposure from 516 to 371. Of the remaining 371, roughly 233 *do* have
an Airtable Account link that simply isn't reconciled — **fixing the duplicate-Account data quality
issue fixes these Contacts too, for free, on a re-run.**

The real load used `-DisableTriggerControl "Contact"` and created **zero** junk Accounts (org total
held at 1,350).

### Field mapping

| Airtable field | Salesforce field | Rule |
| --- | --- | --- |
| `Contact Record ID` (`id`) | `LDGCRM_External_ID__c` | The surviving row's ID for a merged group. |
| `Name` | `FirstName` / `LastName` | Split on last space; waterfall above. |
| `Email` | `Email` | Cleaned — see below. |
| `Phone` | `Phone` | Passthrough, capped at 40. |
| `Title` | `Title` | Passthrough, capped at 128. |
| `Notes` | `Description` | Passthrough (LongTextArea, 32,000). |
| `Account` | `AccountId` (`Account.LDGCRM_External_ID__c`) | With the Application fallback above. |
| `Partner Account Record ID` | `LDGCRM_Partner_Account__c` | Blanked if unresolvable. |
| `Subscription Type` | `LDGCRM_Subscription_Type__c` | Restricted multiselect — see below. |
| *(derived from email)* | `RecordTypeId` | `GSA` for `@gsa.gov`, else `Federal`. |
| `Roles` | *(not written)* | Describes a person's relationship to an Application → belongs on `LDGCRM_Application_Contact__c`. |

**`Email` needed real cleaning** (`Get-CleanContactEmail`, shared): 285 values carry stray
whitespace, 28 embed a name and/or phone alongside the address
(`Dave Martin (David.Martin@onrr.gov -303.231.3797)`), 3 look like two addresses, and 2 carry a
trailing non-ASCII character. The cleaned lower-cased address doubles as the merge key.

**`Subscription Type` is mostly unmappable — deliberately.** `LDGCRM_Subscription_Type__c` allows
only `Newsletter Recipient` and `Technical POC`. Airtable's dominant value **`Technical Emails`
(716 rows)** matches neither and is **not** auto-mapped onto `Technical POC`: a subscription
preference and a role are different concepts, and guessing would invent role data. Dropped and logged
for a human decision.

**Only one formula field exists** (`Source_Detail_Formula__c`) and it is excluded. Unlike Opportunity
and Partner Account there are **no Flows on Contact**, so no field is Flow-owned — but see the
Operational gotchas about what *is* there instead.

### The 4 failures: an org-level duplicate rule

`DUPLICATES_DETECTED` on First + Last name, from a duplicate rule that is **not in this repo** (same
blind spot as the triggers). All four are data-quality tells rather than migration bugs — two have a
`LastName` that doesn't match their email (`Charagundla` on `zhijun.wang@…`, `Mundy` on
`christine.zagrobelny@…`), one is the `HELP DESK` shared mailbox, one genuinely duplicates an
existing Contact. Written up for the data owners.

---

## Impediment

**Source:** Airtable `Impediments` table (41 rows as of 2026-08-12).
**Target:** `LDGCRM_Impediment__c`.
**Script:** `Build-ImpedimentLoad.ps1`. **Mode: upsert on `LDGCRM_External_ID__c`** (standard
convention — Impediment has no lookups to other objects, so it's created fresh like any other
non-Account object, and this script never queries Salesforce at all).

### Field mapping

| Airtable field | Salesforce field | Transformation rule |
| --- | --- | --- |
| `id` (= `Impediments Record ID`) | `LDGCRM_External_ID__c` | Direct passthrough — the upsert key. |
| `Name` | `Name` (the object's required Text `nameField`, not autonumber) | Direct passthrough. Rows with no `Name` are **skipped**, not loaded with a placeholder — see gotchas below. |
| `Category` (free text) | `LDGCRM_Category__c` (**restricted** picklist, 3 values) | Explicit value map, not passthrough — see gotchas below. |
| `Description` | `LDGCRM_Description__c` (**LongTextArea** as of 2026-08-12 — see gotcha below) | Direct passthrough. Blank on 17 of 41 rows — that's fine, the field isn't required. |
| `Talking Point` | `LDGCRM_Talking_Point__c` (**LongTextArea** as of 2026-08-12 — see gotcha below) | Direct passthrough. Blank on 25 of 41 rows — fine, not required. |
| `Opportunities blocked`, `Opportunities requested` (linked-record arrays) | *(not handled by this script)* | Drive `LDGCRM_Opportunity_Impediment__c` junction rows in a later chunk, which needs Opportunity loaded first. Splitting these into one junction row per linked Opportunity happens there, not here. |

### Fields deliberately excluded (no destination, or destination forbids writes)

| Airtable field | Why excluded |
| --- | --- |
| `Blocked revenue`, `Requested revenue`, `Blocked Annual IdV users`, `Opportunities blocked (count)`, `Opportunities requested (count)` | No corresponding Salesforce field at all — these are Airtable-side rollups/computed columns. |
| *(Salesforce-side)* `LDGCRM_Blocked_Revenue__c` | A roll-up **Summary** field (`sum` of `LDGCRM_Opportunity_Impediment__c.LDGCRM_Blocked_Revenue__c`) — Salesforce computes this automatically from junction records and rejects direct writes to it. Populating the junction (a later chunk) populates this for free. |

### Category value map (restricted picklist)

| Airtable `Category` value | Salesforce `LDGCRM_Category__c` value | Notes |
| --- | --- | --- |
| `Product / Feature request` | `Product / Feature request` | Exact match already. |
| `Relationship Issue` | `Relationship issue` | Case differs (`Issue` vs `issue`) — a restricted picklist match is case-sensitive, so this would otherwise fail. |
| `Issue on their end` | `Issue on partner end` | Wording differs entirely, same underlying meaning. |

Any Airtable `Category` value not in this table is **not** silently dropped: the row still loads
(with `LDGCRM_Category__c` left blank, since the field isn't required) but is also written to
`Impediment-unmapped-category-<ts>.csv` for human review. As of the last run, all 39 loadable rows'
Category values matched this table (0 unmapped).

### Known data-quality gotchas

- **2 of 41 Airtable rows are entirely empty** — no `Name`, `Category`, `Description`, `Talking
  Point`, or Opportunity links, just zeroed-out rollup numbers. These look like accidental blank
  rows in Airtable, not real Impediments. Skipped (written to
  `Impediment-skipped-<ts>.csv`) rather than loaded with an invented Name, since `Name` is a
  required field with no sensible default here.
- **`LDGCRM_Category__c` is restricted** — confirmed by reading the field's metadata
  (`valueSet><restricted>true</restricted>`) *and* by checking the one existing test record in
  gsa-peo (`Test Impediment`, `Category = "Product / Feature request"`), which validated that string
  as the real, exact value Salesforce expects before trusting the mapping table above.
- **`TextArea` in Salesforce metadata does NOT mean "long text."** `LDGCRM_Description__c` and
  `LDGCRM_Talking_Point__c` were originally declared `<type>TextArea</type>` with no `<length>` —
  that's the plain "Text Area" field type, capped at **255 characters**, same as a single-line Text
  field just rendered as a multi-line box. It looks identical to `LongTextArea` in the UI and in a
  casual metadata read, and nothing about the field label ("Description", "Talking Point") signals
  the cap. The first real load attempt (2026-08-12) failed 13 of 39 rows with `STRING_TOO_LONG` —
  real partner-facing talking points and descriptions in Airtable run 500-1,500+ characters, well
  past 255. Fixed by deploying both fields as `LongTextArea` (`length=32768`, `visibleLines=6` — the
  data itself only needs ~1,200 chars max, so this is standard Salesforce headroom, not a size fitted
  to the content) via `sfdx-metadata-sync`, confirmed first that the Airtable source has no HTML
  markup to preserve (checked every Description/Talking Point value for tags/entities — zero found;
  what looked like `<br>` and `&quot;` in the Bulk API's *error message* for the failed rows turned
  out to be Salesforce's own error-text escaping of embedded newlines/quotes, not anything present in
  the source data or the generated CSV), so `LongTextArea` was the right call over `Html`
  (Rich Text). **Lesson: before building a transform against a TextArea-typed field, check its
  `<length>` — if there isn't one, or it's ≤255, verify against the longest real value in the
  Airtable export before assuming the field can hold it.**
- **Deploying this fix hit an unrelated org-wide blocker**: any `sf project deploy validate` (which
  runs tests) currently fails across the *entire* gsa-peo org due to a pre-existing Apex compile
  error in an unrelated FCIC-app class, unrelated to this migration. See `CLAUDE.md`'s "Operational
  gotchas" section — this will block any future metadata deploy that runs tests, not just this one.

---

## Application

**Source:** Airtable `Applications` table (1,064 rows as of 2026-08-13; 78 columns).
**Target:** `LDGCRM_application__c`, `LDGCRM_Application` record type (the object's only active
record type — "Master Login.gov Record Type" per its own description, so every migrated row uses
it; no record-type decision logic needed here, unlike Account's Federal-vs-State split).
**Script:** `Build-ApplicationLoad.ps1`. 55 Salesforce custom fields on this object; this is the
largest/most complex table mapped so far, investigated carefully before writing any code per the
user's explicit request. Built 2026-08-13; its **first real load attempt failed 1,045 of 1,047 rows**
— see the post-mortem section below for all four causes and what changed as a result. The script now
also queries Salesforce for the set of Partner Accounts that actually exist before writing its CSV
(it is no longer a purely offline transform), so rows whose parent Partner Account is missing are
skipped up front rather than submitted as guaranteed Bulk API failures.

### Demographic Served — picklist expansion (heavily documented per explicit request)

**The problem:** Airtable's `Demographic Served` (multi-value) uses 32 distinct categories across
913 of 1,064 records (85.8% of all Applications; 1.39 categories per tagged record on average, up to
7 on one record). `LDGCRM_Demographic_Served__c` is a `MultiselectPicklist` backed by the
**`Demographic_Served` Global Value Set**, which originally had only 6 values: `Federal Employees`,
`General Population`, `Gov't Employees (Contractors)`, `Government Employees (Military)`, `Non-USC`,
`Veterans`. Only 4 of Airtable's 32 categories matched a picklist value exactly; loading as-is would
have silently dropped tagging on 400 of the 913 tagged records (43.8%).

**Step 1 — ruled out "these are just old/unused categories."** Cross-referenced every category
against its Active-status rate and median Application go-live year, looking for a pattern where a
category skews toward old/decommissioned applications (which would suggest it was abandoned):

| Category (top 10 by volume) | Records | % of all Applications | % Active | Median go-live year |
| --- | --- | --- | --- | --- |
| General Population | 428 | 40.2% | 82.0% | 2023 |
| Federal Employees | 338 | 31.8% | 78.1% | 2023 |
| Contractors | 156 | 14.7% | 67.9% | 2022 |
| Agency Staff | 119 | 11.2% | 92.4% | 2022 |
| State & Local Employees | 31 | 2.9% | 93.5% | 2024 |
| Grantees | 28 | 2.6% | 67.9% | 2023 |
| Banking Organization | 18 | 1.7% | 50.0% | 2023 |
| Employers | 16 | 1.5% | 93.8% | 2023 |
| Educators | 15 | 1.4% | 86.7% | 2023 |
| Agency Customers | 12 | 1.1% | 100% | 2023 |

The remaining 22 categories (1–10 records each) spanned go-live years 2019–2026 with no consistent
skew toward old/inactive records — low volume alone didn't correlate with obsolescence, so a
volume-based cutoff (e.g. "only categories over 1% usage") would have been arbitrary, not justified.

**Step 2 — the actual signal was recency of last use, not volume or median year.** For each
category, found the most recent Application go-live date (falling back to Estimated Go-Live Date for
applications not yet launched) it appears on, checked as of 2026-08-12:

| Category | Records | Most recent go-live | Months since last use |
| --- | --- | --- | --- |
| Brokers | 1 | 2019-07-18 | 84.8 |
| Health Care Workers | 4 | 2021-03-11 | 65.0 |
| First Responders | 2 | 2022-08-22 | 47.7 |
| Veterans* | 7 | 2023-04-13 | 40.0 |
| Retirees - General Population | 3 | 2023-11-01 | 33.3 |
| Travelers | 3 | 2024-05-21 | 26.7 |
| Small Business Owners | 3 | 2024-07-18 | 24.8 |
| International Users | 5 | 2024-07-18 | 24.8 |
| Active Duty Military | 7 | 2024-08-01 | 24.3 |
| *(everything else — 23 categories)* | | | ≤ 17.2 |

\* `Veterans` is one of the 6 original picklist values, so it required no schema action regardless
of this finding — noted for completeness, not acted on.

These 8 categories (excluding `Veterans`) hadn't been used in 18+ months (several not in 2+ years),
a real recency cutoff distinct from volume — e.g. `Students` (10 records) and `Minors 13-18` (2
records) are both low-volume *and* recently used (within 3.6 months), while `Active Duty Military`
(7 records, comparable volume) hasn't been used in over 2 years. This is the basis actually acted on.

**Decision (user-confirmed 2026-08-12): expand the Global Value Set to the 24 categories used within
the last 18 months; leave the 8 stale ones out.** Estimated data-loss impact: ~28 records (2.6% of
all Applications) whose only Demographic Served tag falls in the 8 excluded categories — a
substantially smaller and better-justified gap than the original ~400-record estimate.

**Implementation:**
- `sfdx/force-app/main/default/globalValueSets/Demographic_Served.globalValueSet-meta.xml` — added
  19 new `customValue` entries (the 24 recent categories minus the 4 that already existed as exact
  matches: `Federal Employees`, `General Population`, `Government Employees (Military)`, `Veterans`).
- `Airtable's "Contractors" (156 records) maps to the existing "Gov't Employees (Contractors)"
  value, not a new value.` Chosen over creating a separate `Contractors` value because no Salesforce
  data exists yet under either label (Application hasn't been loaded), and having two
  near-identical values (`Contractors` and `Gov't Employees (Contractors)`) side by side in a
  picklist a user has to choose from would be confusing. This is the one part of the mapping that's
  a judgment call rather than a direct string match — documented here in case it turns out
  `Gov't Employees (Contractors)` was intended to mean something narrower than Airtable's
  `Contractors`.
- `LDGCRM_application__c/recordTypes/LDGCRM_Application.recordType-meta.xml` — the record type
  restricts which Global Value Set members are actually selectable (a separate `picklistValues`
  block listing only 6 `fullName`s originally); added the same 19 values here too, or they'd exist
  in the value set but not be assignable on this record type. Salesforce's RecordType metadata
  encodes special characters in `fullName` (`&` → `%26`, as seen on the pre-existing `Gov%27t
  Employees %28Contractors%29` entry) — used `State %26 Local Employees` accordingly.
- Deployed via `sf project deploy start --metadata "GlobalValueSet:Demographic_Served"
  --metadata "RecordType:LDGCRM_application__c.LDGCRM_Application" --test-level NoTestRun`
  (NoTestRun for the same pre-existing FCIC-blocker reason as every other deploy this session).
  Verified live via `sf sobject describe` afterward — 25 total values present in gsa-peo, not just
  assumed from a successful deploy.

**The 8 excluded categories are not gone forever** — if a later reporting need requires them, add
them to the Global Value Set (and this record type's picklist) the same way. Airtable rows tagged
only with an excluded category should have that tag dropped, not the whole row skipped — this is a
per-value filter, not a row-level skip like a missing required lookup.

### Opportunity has a *different* Demographic Served field — separate analysis needed later

Flagged mid-investigation (user prompt) and checked before finalizing the above, specifically so this
decision wouldn't need redoing: Opportunity has **two** demographic fields, and neither is this
migration's concern today:
- `Opportunity.Demographic_Served__c` — explicitly labeled **"Demographic Served (Deprecated)"**,
  `"Originally created for TTS OTCRM - Login.gov Opportunities"`, its own independent 5-value
  picklist (`Foreign Nationals`, `General Population`, `Gov't Employees`, `Non-USC`, `Veterans`).
  Not touched by this migration under any circumstance.
- `Opportunity.LDGCRM_Demographic_Served__c` — the current one, but it does **not** reference the
  shared `Demographic_Served` Global Value Set edited above. It has its own independent inline
  6-value list (same 6 as Application originally had, except its "contractors" value is spelled
  `Gov't Employees`, not `Gov't Employees (Contractors)`). **Editing the Global Value Set above did
  not affect this field.**

A quick check of Airtable's `Opportunities` table's own `Demographic Served` column (928 rows) shows
a much smaller, largely-matching set already (`General Population`, `Federal Employees`,
`Government Employees (Military)`, `Non-USC`, plus semicolon-joined combinations like `General
Population; Gov't Employees`) — encouraging, but this needs its own full recency/volume analysis the
same way Application's did, not an assumption that it's fine, when the Opportunity chunk is built.

### Field mapping

Grouped by shape rather than listed as one flat table, given the size (55 fields).

**Identifiers / lookups:**

| Airtable field | Salesforce field | Transformation rule |
| --- | --- | --- |
| `id` (= `Applications Record ID`) | `LDGCRM_External_ID__c` | Direct passthrough — the upsert key. |
| `Name` | `Name` | Direct passthrough — unlike Partner Account, Applications has a real, complete (`0` missing) `Name` column. 9 duplicate-name groups exist but aren't a problem (this is upsert-on-external-ID, not name-matching). |
| `Partner Account Record ID (from Partner Agreement)` | `LDGCRM_Partner_Account__c` (**required** Lookup, CSV column `LDGCRM_Partner_Account__r.LDGCRM_External_ID__c`) | Direct passthrough. Required — rows with no linked Partner Account can't load. 17 of 1,064 rows have none, written to `Application-skipped-<ts>.csv`. Investigated individually (not assumed) rather than batch-excluded — see the dedicated subsection right after this table. |
| `Opportunity Record ID` | `LDGCRM_Opportunity__c` (optional Lookup, filtered to Opportunity's `Login_gov` record type, CSV column `LDGCRM_Opportunity__r.LDGCRM_External_ID__c`) | Direct passthrough when present. Optional — blank is fine. Needs Opportunity loaded first to resolve (not built yet), same dependency shape as Partner Account needing Account. |
| `Broker App Parent` | `LDGCRM_Broker_App_Parent__c` (self-Lookup to `LDGCRM_application__c`) | **Not written by this script — deferred to a second pass.** Holds a single `rec...` ID pointing at another Application (confirmed by sampling). Same-batch external-ID resolution was assumed workable when this table was first written; the 2026-08-13 load **disproved that** — all 68 rows carrying this field failed even though the parent Application was in the same CSV. Needs its own follow-up upsert after every Application row exists in the org. See the post-mortem section above. |
| `Parent Application` | *(not written)* | Redundant display-text rollup of `Broker App Parent`'s Name (e.g. `"Microsoft Azure Platform (MS AAD)"`) — not a separate relationship, excluded. |
| `Broker App Children` | *(not written)* | Reverse rollup of `Broker App Parent` (which Applications point at this one) — computed from the other side, excluded. |
| `Market Segment (from Agreement)` | *(not written)* | `LDGCRM_Application_Before_Save_Assign_Market_Segment` (before-save Flow) already derives `LDGCRM_Market_Segment__c` from `LDGCRM_Partner_Account__r.LDGCRM_Account__r.LDGCRM_Market_Segment__r` — see `CLAUDE.md`. Same rule as Partner Account. |

#### The 17 rows with no Partner Account are two different populations, not one

Investigated individually (user's request, after noticing Airtable's own UI didn't obviously show
rows missing a Partner Account — a reminder that Airtable's UI can show rollup/lookup views that
don't match what the raw API export actually contains) rather than assumed to all be the same kind
of "bad data":

- **6 are genuinely decommissioned**: `CBP I'm Ready`, `SAMS (CBP)`, `GSA Federal Advisory Committee
  Act Training`, `CCP Truck Staging`, `SPEARS Opportunity Portal | HUD Section 3 Opportunity Portal`,
  `Army Contract Writing System's (ACWS) Vendor Self Service (VSS)` — all `Status = "Decomissioned"`
  (the same misspelling mapped elsewhere), several with `Actual Go-Live Date` back to 2018–2022.
  **User-confirmed (2026-08-13): reasonable to exclude these permanently** — retired applications
  whose Partner Account link was apparently dropped as part of decommissioning, not worth chasing
  down a historical link for.
- **11 are the opposite of stale — active drafts**: `DOL - ICAM`, `HHS OIG` (×3 separate records),
  `HHS`, `SSA Secure Online Services`, `Test Application`, `MyTravelGov`, `DOL EBSA` (×2). All have
  **blank `Status`, no dates, and were created within the last ~7 weeks** as of 2026-08-12 (several
  within the last 8 days) — these read as records someone is actively typing into Airtable right
  now, not old/abandoned data. `Test Application` fits the same "in-progress, not yet real" pattern.
  **Not excluded permanently** — re-run `Build-ApplicationLoad.ps1` closer to the actual production
  load date to pick up whichever of these get a real Partner Account link (and Status) by then,
  rather than assuming today's snapshot is final. This is why the script re-reads the current
  Airtable export every run instead of caching a decision per record.

**Booleans derived from presence, not a literal value** (Airtable omits the field entirely when
unchecked — these are true Airtable checkboxes and map straightforwardly, present→`true`):
`Account Manager Approved`, `Agreement Finalization Email Sent`, `Customer Support Meeting Deemed
Unnecessary`, `Finalized Application Details`, `Fraud Meeting Deemed Unnecessary`, `IdV Upgrade?`,
`Confirmed pre-launch or launch day activities`, `Launch Day Activities Completed`, `Launch
Coordinators Kick-off Call`, `Launch Kick-off Meeting Unnecessary`, `Launch Tested`, `Launch to
Production Completed by OE`, `Marketing/Comms Strategy`, `Requested Contact Center Reporting`,
`Security Meeting Deemed Unnecessary`, `Coordinated Optional Follow-up Tech Sync`, `UX Meeting
Deemed Unnecessary` → their correspondingly-named `LDGCRM_*__c` Checkbox fields.

**Booleans derived from presence of a *linked-record* column, not a literal checkbox** (confirmed by
sampling — values are `rec...` IDs pointing at the not-yet-migrated Meetings table, or in Security
Meeting's case, freeform meeting-name text): `Customer Support Meeting`, `Fraud Meeting`, `Launch
Kick-off Meeting`, `UX Meeting`, `Security Meeting` → `LDGCRM_Customer_Support_Meeting__c`,
`LDGCRM_Fraud_Meeting_Held__c`, `LDGCRM_Launch_Kickoff_Meeting_Held__c`, `LDGCRM_UX_Meeting_Held__c`,
`LDGCRM_Security_Meeting__c`. **Deliberately not resolving which specific meeting** (user-confirmed)
— true if the Airtable column has any value, blank otherwise. No attempt to link the actual Meeting
record; there's no field on Application for that relationship anyway.

**Booleans derived from an explicit two-valued text field** (not presence-based — the column is
always populated with one of two strings): `Broker Application` (`"Yes"`/`"No"`, 936 No / 50 Yes) →
`LDGCRM_Broker_Application__c`; `Launch Risk` (only ever blank or the single value `"At Risk"`, 622
records) → `LDGCRM_Launch_Risk__c` (true when the value is present/equals `"At Risk"`).

**Picklists needing an explicit value map** (checked every distinct value against the target's
actual allowed set before assuming passthrough — see General Principle):

| Airtable field | Salesforce field | Transformation rule |
| --- | --- | --- |
| `Status` | `LDGCRM_Status__c` (restricted picklist) | 7 of 8 distinct values match exactly. `"Decomissioned"` (89 records, one *m*) → `"Decommissioned"` (correct spelling, matches the record type's actual value) — a spelling-drift gotcha, same category as Impediment's Category fix. |
| `Ramp Up Approach` | `LDGCRM_Ramp_Up_Approach__c` (restricted picklist: `Gradual`/`Immediate`/`Spikes`) | Airtable's values are verbose labels with the real value as a leading word, e.g. `"Gradual Level 2: Low Impact < 350K users"` → map by taking the leading `Gradual`/`Immediate`/`Spikes` token, not the whole string. 2 records (`"Q1 - FY'23"`, `"146"`) have no extractable value — left blank on load. **User-confirmed (2026-08-13): acceptable as-is** — this looks like old data on an otherwise solid picklist field, and the Salesforce field is optional, so nulling these 2 rows rather than guessing is fine; no further review needed. |
| `Launch Level` | `LDGCRM_Launch_Level__c` (restricted picklist, 5 values) | Airtable stores bare numbers (`"1"`–`"5"`); map to the full label (`"1"` → `"1 - Very Low Impact"`, … `"5"` → `"5 - Very High Impact"`). |
| `Demographic Served` | `LDGCRM_Demographic_Served__c` (multiselect) | See dedicated section above — this is the big one. |
| `Service Level` | `LDGCRM_Service_Level__c` (restricted picklist) | Already an exact match on all 3 distinct values (`Authentication Only`, `Basic IdV`, `Enhanced IdV (IAL2)`) — direct passthrough, no map needed. |

**Direct passthrough (Text/URL/Date/Number, values already compatible):**
`Actual Go-Live Date`, `Current Go Live Date` → their `Date` fields (Airtable `YYYY-MM-DD` matches
Bulk API's expected format); `# of Estimated Annual IdV Transactions`, `# of
Estimated Monthly Active Users` → their `Number` fields; `Completed Customer Support Survey`,
`Completed Fraud Survey`, `Completed Security Survey`, `Launch Checklist URL`, `Launch Deck URL` →
their `Url` fields (checked all 5 for the same `"TBD"`-placeholder issue found on `URL`/
`Description` — 0 occurrences across all of them, so no filter needed here).

**Not mapped — also formula fields, same lesson as the Percent fields above:**
`LDGCRM_Opportunity_Lead__c` (`HYPERLINK` formula pulling `LDGCRM_Opportunity__r.Owner`'s name) and
`LDGCRM_Opportunity_Stage__c` (`TEXT(LDGCRM_Opportunity__r.StageName)`) both looked like plain `Text`
fields — a type that's normally always safe to write to — but are entirely computed from the linked
Opportunity once `LDGCRM_Opportunity__c` is set. Airtable's `Opportunity Lead` and `Opportunity
Status` columns are excluded from the transform entirely, not mapped. (These two stay blank until
Opportunity is loaded and the Application's `LDGCRM_Opportunity__c` lookup actually resolves — same
dependency as the lookup itself, not a new one.)

**Passthrough with a placeholder filter** (checked real values before assuming clean data — see
General Principle): `URL` and `Description` both use the literal placeholder `"TBD"` (with a
trailing newline) on a meaningful minority of rows (32 of 944 non-blank `URL` values; 30 of 1,026
non-blank `Description` values) — treat `"TBD"`-prefixed values as blank rather than loading the
literal placeholder text, same pattern as Partner Account's non-URL `Agency Summary` filter.

### Load history (2026-08-13): three attempts, 1,045 failures → 688/688 clean — full post-mortem

**Final state: 688 of 688 submitted rows loaded successfully, 0 failures.** Verified post-load that
all 688 resolved their Partner Account lookup and all 688 had `LDGCRM_Market_Segment__c` populated by
the before-save Flow (confirming the "never set Market Segment directly" rule). Of the 1,064 Airtable
rows, 359 were deliberately withheld pending Airtable Account fixes and 17 have no Partner Account at
all — those load on a re-run once the data is corrected, no code change needed.

Getting there took three attempts. Every failure is catalogued below, because most of these causes
generalize to the objects still to be built.

**Attempt 1 — 1,045 of 1,047 rows failed:**

| Error | Rows | Cause |
| --- | --- | --- |
| `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST` on Service Level | 521 | **A real bug in this script.** See below. |
| `INVALID_FIELD` — Partner Account FK not found | 343 | Expected: parent Partner Account never loaded (its own parent Account is unresolved). Data-quality gap, not a code bug. |
| `INVALID_FIELD` — Opportunity FK not found | 99 | Expected: Opportunity isn't built/loaded yet. |
| `INVALID_FIELD` — Broker App Parent FK not found | 68 | **Disproved an assumption this document previously recorded as "likely fine."** See below. |
| `STRING_TOO_LONG` on Name / URL | 14 | Salesforce platform hard limits. See below. |

**Attempt 2 — 686 of 688 succeeded.** Two rows exposed gaps in the attempt-1 fixes, both worth noting
because each was a *narrow* fix where a general one was needed:

| Error | Rows | Cause |
| --- | --- | --- |
| `STRING_TOO_LONG` on Launch Deck URL | 1 | The attempt-1 fix length-checked only `LDGCRM_URL__c` — the field that happened to have obviously long values — leaving the object's five *other* `Url` fields unguarded. Now every Url field runs through one shared `Resolve-UrlValue` helper driven by a field table. **Lesson: when a platform limit bites one field, fix it for every field of that type on the object, not just the one that failed.** |
| `FIELD_INTEGRITY_EXCEPTION` on Actual Go-Live Date | 1 | One row carries `0202-02-18` — a mistyped `2022`. Every date value in the export is validly *formatted* `YYYY-MM-DD`, so a format check passes it; the year is simply not a real date Salesforce accepts. Now range-checked (1900–2100) via `Resolve-DateValue`. **Lesson: correct format ≠ sane value — the same instinct as checking a picklist's actual values rather than trusting its type.** |

**Attempt 3 — 688 of 688 succeeded, 0 failures.**

**1. `Service Level` was a 1-element array, not a scalar — the `System.Object[]` trap.** Airtable
returns `Service Level` as a linked-record-style array (`["Authentication Only"]`) even though it
reads as a plain single-select in the Airtable UI and its *values* all matched the target picklist
exactly. The transform passed `$Row.fields.'Service Level'` straight through, and PowerShell's CSV
export stringified the array as the literal text `System.Object[]`, which the restricted picklist
rejected on every row that had a value. **The pre-build investigation checked the field's distinct
values but not its JSON shape** — which is exactly why it slipped through: `Group-Object` over an
array-valued field still reports the inner strings, so the values "looked" clean. Fixed with the same
`@(...)[0]` unwrap used for every genuine linked-record field. **Every other direct-passthrough field
on this object was then re-checked for the same shape (`-is [array]`); Service Level was the only
one.** Lesson, and it's a new one for this migration: checking a field's *values* isn't enough —
check its *shape* (`$value -is [array]`) before treating any Airtable field as a scalar passthrough,
even one that looks like a simple single-select. A stringified `System.Object[]` in a load CSV is the
tell.

**2. Self-referential lookups do NOT resolve within a single upsert batch.** This document previously
recorded, on the `Broker App Parent` row of the field-mapping table, that same-batch external-ID
resolution was "likely fine since Bulk API resolves external-ID references after all rows in a batch
are inserted, but worth verifying when the script is built rather than assumed." **Verified: it's
false.** All 68 rows carrying a `Broker App Parent` failed with `Foreign key external ID ... not found
... in entity LDGCRM_application__c`, even though the referenced parent Application was in the same
CSV. `LDGCRM_Broker_App_Parent__c` is therefore no longer written by this script at all — it needs a
**second pass** re-upserting only `LDGCRM_External_ID__c` + the parent reference, after every
Application row exists in the org (see `ARCHITECTURE.md`'s Load order). Applies to any future
self-referential lookup in this pipeline, not just this one.

**3. `Name` (80) and `Url` (255) are Salesforce platform hard limits, not fixable field metadata.**
Unlike Impediment's `TextArea`→`LongTextArea` fix and Partner Account's `Text(10)`→`Text(50)`
extension — both genuine metadata shortcomings this migration corrected — these two can't be raised:
a custom object's `nameField` is capped at 80 characters by the platform (no `<length>` override
exists for it) and `Url`-type fields are fixed at 255. 5 rows exceeded the Name cap (truncated to 80
and flagged) and 9 exceeded the URL cap (left blank rather than truncated — a cut-off URL is a broken
URL, whereas a cut-off name is still recognizable). Both go to
`Application-overlength-<ts>.csv` for human review, and both are written up in
`AIRTABLE-DATA-QUALITY-REQUESTS.md` asking for shorter canonical values at the source. **Lesson: when
a length limit bites, check whether it's a field setting we control or a platform limit before
reaching for a metadata fix** — the earlier TextArea/Text cases in this migration made "just extend
the field" feel like the default answer, and it isn't always available.

**4. An "optional" lookup still fails the whole row if it points at something nonexistent.** The 99
Opportunity-FK failures are worth stating explicitly because the field-mapping table below describes
`LDGCRM_Opportunity__c` as optional and says "blank is fine" — true, but blank is not the same as
*populated with an unresolvable reference*. Bulk API rejects the entire record, not just the
offending field. This is why Opportunity is now documented as a hard prerequisite for Application in
the load order, despite the lookup being nominally optional.

### The Level 1 checklist now scores the partner-portal team (changed 2026-08-14)

`LDGCRM_Level_1_Complete_Pct__c` counts nine items and divides by nine. The ninth used to be
`LDGCRM_PP_Issuer_Strings__c` — a deprecated field this migration never populates — so **every
migrated Application forfeited that item by construction**. Measured ceiling: 78% (7 of 9), with 0
of 1,026 able to reach 100%.

The fix swapped the *reference* rather than removing the item:

```
- IF(ISBLANK(LDGCRM_PP_Issuer_Strings__c), 0, 1)
+ IF(ISBLANK(LDGCRM_P3_Team_UUID__c),      0, 1)
```

**The denominator stays 9**, which is what makes this cheaper than the originally-specified change.
`LDGCRM_Launch_Checklist_Completion__c` weights each level by its item count and hard-codes those
counts (`*9`, `/16`, `/20`); had Level 1 gone to 8 items, all three would have needed editing too.
Swapping the reference leaves that formula untouched.

Verified after the change: ceiling moved **78 → 89**, all **681** Applications with a Team UUID score
the item, and **0** without one can reach 100%.

**⚠️ This couples a launch-checklist metric to migration output.** The item was previously inert;
it now depends on the portal team resolving. Consequences to keep in mind:

- An Application whose team stops resolving **silently loses a checklist point** — the score drops
  with no error anywhere.
- The 9 Applications whose issuer strings name two different teams are left blank deliberately, so
  they cap at 8 of 9.
- This sits in mild tension with the 2026-08-14 rule that the portal team is **optional**. That is
  intended: the checklist measures launch progress, not record validity. A missing team is a valid
  record that has not completed one checklist item.

### Six fields are actually formula fields — don't write to them

`LDGCRM_Launch_Checklist_Completion__c`, `LDGCRM_Level_1_Complete_Pct__c`,
`LDGCRM_Level_3_Complete_Pct__c`, and `LDGCRM_Level_4_Complete_Pct__c` all declare
`<type>Percent</type>` in metadata, indistinguishable at a glance from a normal writable Percent
field — but each also has a `<formula>` tag: they're computed automatically from the very
Checkbox/URL fields already being migrated (e.g. `LDGCRM_Level_1_Complete_Pct__c` = count of 9
specific checkboxes/fields being true or non-blank, divided by 9). `LDGCRM_Opportunity_Lead__c` and
`LDGCRM_Opportunity_Stage__c` are the same trap wearing a `Text` type instead of `Percent` —
computed from the linked Opportunity's Owner/StageName once `LDGCRM_Opportunity__c` is set.
Salesforce rejects direct writes to formula fields outright, regardless of declared type. Airtable's
matching columns (`Checklist Completion %`, `Level 1+ Complete %`, `Level 3+ Complete %`, `Level 4+
Complete %`, `Opportunity Lead`, `Opportunity Status`) are **excluded entirely** — not mapped, not
filtered, just not referenced in the transform at all. Once the underlying checkboxes/URLs/
Opportunity lookup load correctly, these compute themselves; loading them independently would have
failed the batch outright (a much louder failure than the TextArea-length issue, which at least
loaded the *other* columns on the same row). This also made a percent-unit question moot for the
Percent fields: Airtable stores these as 0–1 fractions (e.g. `0.111` for what Airtable displays as
`11.11%`) while Salesforce Percent fields expect the raw
0–100 number via the API — would have needed a ×100 conversion if any Percent field here had been
genuinely writable, but none are, so it never came up. **Lesson: check for a `<formula>` tag before
mapping *any* field that looks like a plain calculated/aggregate value (Percent, Number, even Text)
— "the type looks normal" isn't the same as "it's writable," the same way `<type>TextArea</type>`
without a length doesn't mean "255 characters is enough" (see General Principle #4).**

### Two fields were migrated until 2026-08-13, then dropped when the org removed them

`# of Estimated Annual IdV Transactions` → `LDGCRM_num_est_annual_idv__c` and `# of Estimated
Monthly Active Users` → `LDGCRM_Est_Monthly_Active_Users__c` loaded successfully on 2026-08-12
(688/688). Both target fields were then **deleted from the Dev org as no longer wanted**, so the
mappings were removed from `Build-ApplicationLoad.ps1` and both `field-meta.xml` files deleted from
`sfdx/force-app`. This cost 519 and 612 populated values respectively — a deliberate scope
reduction, not a data-quality problem, and **not** something to raise with the Airtable owners.

**Two things worth carrying forward from how this surfaced.**

First, **the error names only the first missing column.** Bulk API rejected the entire 688-row batch
with:

```
InvalidBatch : Field name not found : LDGCRM_num_est_annual_idv__c
```

Fixing that one field alone would have produced the identical failure on the second. When a load
dies this way, diff **every** CSV column against `sf sobject describe` in one pass rather than
chasing the error field by field:

```powershell
$org = @{}; (sf sobject describe --sobject <Object> --target-org <alias> --json | ConvertFrom-Json).result.fields |
    ForEach-Object { $org[$_.name.ToLower()] = $true }
(Get-Content <csv> -TotalCount 1) -replace '"','' -split ',' |
    Where-Object { -not $org.ContainsKey((($_ -split '\.')[0] -replace '__r$','__c').ToLower()) }
```

Second, **deleting a field leaves references behind in eight other metadata files.** The two fields
appeared in the Application layout, all three PermissionSets, and four ReportTypes. Removing only
the `field-meta.xml` would leave dangling `<field>` entries that break the next deploy of those
components — so a field removal means sweeping `layouts/`, `permissionsets/` and `reportTypes/` too.
`grep -rl <fieldName> sfdx/force-app` finds them all.

### Launch Level defaults to 1 — because blank is not neutral here

**Decided 2026-08-13 by the project owner.** 621 of 1,056 Airtable Applications record no Launch
Level. The obvious handling — leave it blank, it's optional — is **wrong**, and the reason is a good
example of a downstream formula changing what "empty" means:

`LDGCRM_Launch_Checklist_Completion__c` is a `CASE` on `LDGCRM_Launch_Level__c` whose **else value is
`1`** (= 100%). A blank level matches none of the five cases and falls through to *fully
launch-complete*. Measured on the 2026-08-13 reload before the fix: **607 of 1,026 migrated
Applications reported 100% complete**, while their own `Level 1 Complete %` topped out at 78%.

So a blank Launch Level does not produce a missing number — it produces a **confidently wrong** one,
on 59% of the object. The transform now writes `"1 - Very Low Impact"` when Airtable has none.

Why level 1 specifically: it is the lowest, and levels 1 and 2 both compute completion from
`LDGCRM_Level_1_Complete_Pct__c` alone, so the reported figure becomes that record's real Level 1
progress rather than a placeholder. After reloading: **records reporting 100% went 607 → 0**, maximum
now a genuine 90%.

**Two things to keep in mind:**
- **The default is invisible afterwards.** A defaulted level looks identical to an authored one in
  Salesforce. The count is reported at build time (`Launch Level DEFAULTED to 1`) and that is the only
  record of it.
- **It protects migrated records, not the org.** Anything created later with a blank level still
  reports 100%. The formula fix is CR-3 in
  [SALESFORCE-CHANGE-REQUESTS.md](SALESFORCE-CHANGE-REQUESTS.md).

A value that is present but outside 1–5 is also defaulted rather than blanked — same reasoning — but
written to a review CSV so an unexpected value cannot hide inside the default. 0 rows hit that today.

### Partner portal team — the source was in a table nobody was pulling

**Added 2026-08-13.** `LDGCRM_P3_Partner_Portal_Team_Name__c` and `LDGCRM_P3_Team_UUID__c` were
recorded in this document, twice, as having **no Airtable source at all** — "confirmed by searching
every Airtable column name for `revenue`/`uuid`/`team`/`portal`." That conclusion was wrong, and the
reason it was wrong is the transferable part:

> **The search covered every column of the Applications table. The data was in a different table —
> one that `Get-AirtableExport.ps1` did not pull, so it was invisible to any amount of careful
> searching of the exports on disk.**

`Issuer Strings` (`tbl8XAxD4G5uBEPMk`, 901 rows) carries `Team Name` and `Team UUID`, and was added
to the export by PR #1. **When a Salesforce field looks sourceless, check the base's full table list
(`GET /v0/meta/bases/{baseId}/tables`) before concluding it is populated by another system** — the
exports on disk are a subset of the base by construction, and "not in any export" is a much weaker
statement than "not in Airtable." The same caution applies to Partner Accounts' `Escalated User
Support Cases`, still an open question for exactly this reason.

**Airtable stores this one level down from where it belongs.** The partner-portal team is a property
of the **Application** (user-confirmed 2026-08-13). Airtable records it on each **issuer string**
instead, so it is duplicated across every issuer string an Application has — and **every copy is
supposed to be identical**. Salesforce stores it once, on the Application.

So this is a **de-duplication, not a merge of distinct facts**: read the one value the copies agree
on, write the Application once. That framing is what decides the handling of disagreement — a set
that doesn't agree is duplicated data that has *drifted*, i.e. a defect to fix at source, never a
signal that an Application legitimately has two teams.

**The ingestion rules, in full.** These are also written up in plain language for the Airtable owners
in [AIRTABLE-DATA-QUALITY-REQUESTS.md](../data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md) ("how the
migration currently reads this table") — **keep the two in step**, since that version is what the data
owners are being asked to agree with.

| # | Rule | Implemented by |
| --- | --- | --- |
| 1 | Team Name / Team UUID / Partner Portal Admin Email are read from the Issuer Strings table. | `Import-AirtableTable -Label "Issuer Strings"` |
| 2 | The Application is written once, from the value its issuer strings agree on. | `Get-PortalTeamByApplication` returns one entry per Application |
| 3 | `#N/A` is a value, not an empty — strip it before anything else. | `Get-CleanIssuerStringValue` |
| 4–7 | Agreement handling — see the table below. | `Get-PortalTeamByApplication` |
| 8 | Team name over the field's length → blank the name, keep the UUID, report. | length check against the **live** `describe` length, not a literal |
| 9 | Issuer strings with no Application link are ignored and counted. | `$OrphanIssuerStrings` |
| 10–11 | `Partner Portal Admin Email` marks the person an admin on the Application, **creating the junction row if absent**. | `Build-ApplicationContactLoad.ps1` — see the Application Contact section |
| 12 | Issuer string values themselves are never written. | no `LDGCRM_PP_Issuer_Strings__c` column |

Measured across the 2026-08-13 export (901 issuer strings → 887 distinct Applications):

| Rule | Outcome | Applications | Handling |
| --- | --- | --- | --- |
| 4 | Identical team on **every** issuer string | **678** | Migrated. Clean. |
| 5 | Team on **some** issuer strings, blank/`#N/A` on others | **18** | Migrated (unambiguous) + `INCOMPLETE` review row. |
| 6 | **Two different Team UUIDs** | **9** | Both fields left blank + `CONFLICT` review row. |
| 7 | No Team UUID anywhere | 182 | Nothing to carry over. Not reported. |

Rule 6 is the only one that loses data. Rule 5 is the one most likely to be misread as a failure —
it is not; those 18 Applications get the correct team.

The 9 are a genuine source defect — one Airtable Application whose issuer strings carry two different
teams, typically a dev/test string under one and a prod string under another. **There is no
defensible tie-break** (first-wins would silently pick whichever issuer string sorted first), so both
fields are skipped and reported, per the standing rule against inventing values to improve a count.

The 18 change **nothing** about the load — the team is unambiguous, so those Applications get the
right value. They are reported anyway because under the "every copy identical" rule the blanks are
*missing copies*, not absent data. Both kinds share one review CSV
(`Application-portal-team-review-*.csv`) with an `Issue` column separating them, so the 9 that block
something are not buried among the 18 that don't.

Two further shape notes: **7 issuer strings link to no Application**, so their team reaches nothing;
and **2 rows are entirely empty** (no issuer string, no team). The empty ones are labelled in the
review CSV rather than rendered as a blank cell — an unexplained empty cell in a report reads as a
bug in the report.

Two shape facts worth keeping:
- **`#N/A` is a literal string in this table**, not an Airtable empty — 136 Team Names and 137 Team
  UUIDs carry it. Unfiltered it would write the text `#N/A` into Salesforce as if it were a team.
  `Get-CleanIssuerStringValue` strips it. It is unambiguous: every `#N/A` is 4 characters against a
  real UUID's 36, and the length histogram has exactly two buckets (4 and 36) with nothing between.
- **Team UUID ↔ Team Name is exactly 1:1** across all 368 distinct UUIDs — 0 violations in either
  direction — so the pair resolves together. The field help text says to trust the UUID when they
  disagree ("The name can be modified"); in this data they never do, so that rule is a guard, not a
  live code path.

#### ✅ `unique=true` blocked the load until 2026-08-14 — resolved, and the guard remains

**Both fields are now `unique=false` and `Text(255)`** (they were `unique=true`, `Text(50)`). The
widening also cleared the six team names that were too long for the old field. **681 Applications
carry a portal team in Dev and in QA**, loaded with 0 failures.

The problem it fixed: `unique=true` models **one portal team owning at most one Application**, and
the source data flatly contradicts it — a team owns many by design. Across the 696 resolvable
Applications, **104 Team UUIDs were shared by 2+ Applications, covering 442 of them** —
`DOI - FWS - ECOS` alone owns 54, `DOI - IBC - Quicktime` 39, `Education ICAM Team` 20. Writing those
columns against a unique field failed the majority of the load with `DUPLICATE_VALUE`.

**The runtime guard is still in the script and should stay.** It reads both fields' definitions at
run time via `Get-SalesforceFieldMetadata` and, while either is unique, **omits the two columns from
the CSV entirely** rather than failing the whole Application load over two columns nothing else
depends on. That is what let the pipeline keep running while the change set was pending, and it is
what will catch `Unique` being re-introduced in any org — the run prints a red
`PARTNER PORTAL TEAM COLUMNS WITHHELD` block if it ever fires again.

Omitted, not blanked — deliberately. An empty column in an upsert file **clears** whatever is already
in the org, so writing empty strings would actively destroy data the Partner Portal may have put
there.

**For the change set:** set `Unique = false` on `LDGCRM_P3_Partner_Portal_Team_Name__c` and
`LDGCRM_P3_Team_UUID__c` on `LDGCRM_application__c`. Neither is an External ID and nothing keys on
them. After it lands, a plain re-run populates both — no code change, same contract as the Opportunity
lookup.

One further metadata ask, lower priority and independent of the above: **6 distinct team names exceed
the 50-char field length** (longest 75), affecting **8 Applications** — `GSA Financial Management
Services - Payment, WebVendors, Fedpay` alone covers three. Those load with a UUID and a blank name
rather than a truncated one — a truncated team name reads as real while not matching the portal.
Widening the field fixes it.

#### `LDGCRM_PP_Issuer_Strings__c` is not migrated — and is now DEPRECATED

Pulling the table did **not** unblock the issuer-string field itself. It is `Text(40)`, single-valued
and unique, against a source where **776 of 899 issuer strings exceed 40 characters** (longest 130)
and **847 Applications have more than one**. Its own help text describes it as a field the OEs
maintain by hand against ZenDesk/GitHub. Three independent reasons, any one sufficient.

**Superseded 2026-08-13:** the project owner confirmed this data is not being migrated and **the
field is to be retired entirely.** That is not a plain delete — see **CR-2** in
[SALESFORCE-CHANGE-REQUESTS.md](SALESFORCE-CHANGE-REQUESTS.md):

- `LDGCRM_Level_1_Complete_Pct__c` counts it as **1 of 9** checklist items. Since the migration never
  populates it, every migrated Application forfeits that item — a hard ceiling of 89%, with an
  observed maximum of **78%** across 1,026 records. Salesforce also blocks deleting a field a formula
  references, so the formula must be edited first (→ `/8`).
- `LDGCRM_Launch_Checklist_Completion__c` then has to change too, because it hard-codes each level's
  **item count** as a weight (`*9`, `/16`, `/20` → `*8`, `/15`, `/19`). This is the non-obvious part:
  dropping one checklist item silently changes a second metric.
- Plus 4 report types, 3 permission sets and 1 layout.

**Nothing in this pipeline changes when it goes** — no transform ever wrote it.

### Fields with no destination — the full inventory (as requested)

Every Airtable column not covered above, and why:

**Feed a different chunk, not this object:** `Agreement Contacts`, `Contacts Record ID`, `Email
(from Agreement Contacts)` (all drive `LDGCRM_Application_Contact__c`); `Partner Portal Admin`
(drives a checkbox on `LDGCRM_Application_Contact__c` specifically — **not** a field on Application
itself; user-confirmed this is where it now lives, contacts junction chunk, not here).

**Rollups/lookups from a parent record, redundant with data already on that parent:** `Account`,
`Account Owner`, `Department` (from Account/Partner Account); `Est. Go Live (Opportunity)`, `Initial
Agreement Size (from Opportunity)` (from Opportunity); `Most Recent PoP End Date`, `Most Recent PoP
Start Date` (from Partner Account, same fields already excluded there for the same reason).

**Airtable system/computed metadata, not real data:** `Created By`, `Last Modified`, `Updated?`,
`Count (Issuer Strings)`.

**Freeform/journal-style — deferred `ContentNote` candidates** (per the Notes chunk, see above in
this document): `Notes` (a literal Notes column — the strongest possible candidate), `Launch Notes`,
`IdV Upgrade Notes`.

**No Salesforce field found at all — genuinely unmapped, not just deferred:**
- `Issuer Strings` — the **issuer-string values** are still not migrated, now for measured rather
  than assumed reasons (`Text(40)` single-valued against 776 over-length and 847 multi-valued rows;
  OE-maintained by hand) — see "Partner portal team" above. ⚠️ **Superseded in part 2026-08-13:** the
  linked table *is* now pulled, and `Team Name` / `Team UUID` from it **do** migrate onto the
  Application. The old note that this "links to a table this migration doesn't pull" is no longer
  true.
- `Pilots` — short categorical values (`No Pilots` 754, `IPP` 23, `Unemployment Insurance Pilot` 8,
  `FCC Pilot` 3, `Biometric` 3, `Disaster Pilot` 1). No dedicated field exists. **User-confirmed
  (2026-08-13): not migrating this field** — closed, not just deferred.
- `Migrated to the partner portal` (boolean, 296 `True`) — no matching field found; likely
  owned/set by the Partner Portal system directly rather than sourced from this migration.
  **User-confirmed (2026-08-13): fine not to have this for now** — not a permanent "never," just not
  a current priority, so don't read this as fully closed the way Usage Tracker/Vital Update % are.
- `Usage Tracker Application Name` — a different external system's app name (Login.gov's usage
  analytics tool), not a Salesforce concept. **User-confirmed (2026-08-13): does not need to
  transfer** — closed, not just deferred.
- `Vital Update %` — no matching field found despite the Percent shape; not the same thing as
  `Checklist Completion %` or the `Level N+ Complete %` fields (those all have their own distinctly-
  named Airtable source columns already mapped above). **User-confirmed (2026-08-13): does not need
  to transfer** — closed, not just deferred.

**Salesforce fields with no Airtable source at all:** `LDGCRM_Annual_Revenue_Amount__c` only. No
Airtable column resembling `revenue` exists on any pulled table; presumed populated by another system.
That remains an assumption rather than a confirmed fact — worth checking with whoever owns the Partner
Portal integration before treating it as settled.

> ⚠️ **Corrected 2026-08-13.** This inventory previously listed
> `LDGCRM_P3_Partner_Portal_Team_Name__c` and `LDGCRM_P3_Team_UUID__c` here too — twice, once as
> "not yet confirmed" and once as "confirmed by searching every Airtable column name." **Both do have
> an Airtable source**, in the `Issuer Strings` table, which simply wasn't being exported. The search
> that produced the wrong answer only ever covered the Applications table's own columns. See
> "Partner portal team — the source was in a table nobody was pulling" above; the lesson is to check
> the base's table list, not just the exports on disk, before declaring a field sourceless.
