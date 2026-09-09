# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Project

This repo holds the **Login.gov Partnerships CRM**, a Salesforce app running in
GSA PEO's org. Sprint 1 migrated the partnership team's Airtable base into it and
**shipped to production on 2026-09-08**. The app is live; the migration is done.

Two kinds of work happen here now:

- **Maintaining the app's metadata** (`sfdx/`) — objects, flows, layouts,
  permission sets. This is the product.
- **Rebuilding a developer sandbox** (`tools/data-loading/`) so the app can be
  worked on against realistic data.

Records created by the original migration carry `LDGCRM_External_ID__c`,
correlating them back to their Airtable source. That field is still the upsert
key for every sandbox load.

## ⚠️ The loading tools are DEV/QA ONLY, and that is enforced

`tools/data-loading/` rebuilds a **developer sandbox**: pull Airtable, reset the
sandbox, load it, throw it away, repeat. It is not a migration pipeline any more
and it does not target production.

Every `-Environment` parameter is `[ValidateSet("Dev","QA")]`, so UAT, Full and
Prod are rejected **at parameter binding** — before a script body runs and before
anything touches an org. That is a structural block, not a convention: it cannot
be argued past, and it fails identically whether someone typed the wrong thing or
retargeted a saved command.

| `-Environment` | Alias | Sandbox | Browser URL |
| --- | --- | --- | --- |
| `Dev` (default) | `peodv8dvn` | PEOdV8DVn | `https://gsa-peo--peodv8dvn.sandbox.lightning.force.com` |
| `QA` | `peodv15dvn` | PEOdV15DVn | `https://gsa-peo--peodv15dvn.sandbox.lightning.force.com` |

**An alias IS the org's own sandbox name**, so it can be checked against the
instance URL and cannot silently drift. `Assert-LdgcrmOrgTarget` runs at the
start of every script: it reads `Organization.IsSandbox` **from the org** (not
from `sf org list`, which reads a local cache — the very thing being verified),
refuses to continue against a production org, and proves the instance URL still
contains the expected sandbox name.

Production (`gsa-peo`) is deliberately absent from the registry. If a
production-side operation is ever needed it belongs in a separate, purpose-built
tool — not behind a widened `ValidateSet` on a script whose job is hard-deleting
records.

**A sandbox refresh invalidates the CLI auth and resets the user's profile.**
Both happened on 2026-09-08: every `sf` call failed with `expired access/refresh
token`, and after re-login the user came back on `GSA Standard Salesforce User`
rather than System Administrator, so every Metadata API call returned
`INSUFFICIENT_ACCESS`. Re-authorize with
`sf org login web --alias peodv8dvn --instance-url https://gsa-peo--peodv8dvn.sandbox.my.salesforce.com`
and check the profile before concluding anything is broken.

## ⚠️ Metadata promotion is by CHANGE SET only

**Do not promote metadata between orgs with `sf project deploy`.** Outbound/
inbound change sets are the only sanctioned path, and the rule is strict (user,
2026-08-13). From this repo, a CLI deploy is permitted for exactly one purpose:
**DELETING corrupted or incorrect metadata.** Anything additive — a new field, a
new picklist value, a new record-type assignment — goes in a change set, even
when the change is obviously correct and even when it is only going to a sandbox.

Practical consequence when something is blocked by missing metadata: **write down
what needs adding and hand it to whoever builds the change set.** Do not "just
deploy it to Dev to unblock testing" — Dev is the source org for change sets, so
anything deployed there silently becomes part of the next promotion whether or
not it was reviewed.

**How it reaches the target org is GSA IT Engineering's process, not this repo's**
(user, 2026-08-17). They deploy via the Salesforce CLI from their own GitHub
repository, using the component set that originates as a change set built in Dev.

Traps worth knowing before touching picklists:

- **A metadata deploy cannot delete a picklist value — it deactivates it**
  (`isActive=false`). The value survives in the value set; only a Setup "Del"
  removes it. Both `sf sobject describe` **and a metadata retrieve** return only
  ACTIVE values, so "absent from the retrieved file" and "absent from the org"
  are *not* the same thing. Confirmed the hard way on 2026-09-08: `Day-to-Day
  POC` and `Senior POC` looked deleted from `ContactRole` by two independent
  sources, and were actually present-but-deactivated.
- **Renaming a value via `<fullName>` does not rename in place** — it adds the
  new value and deactivates the old one. Check usage first
  (`SELECT <field>, COUNT(Id) FROM <Object> GROUP BY <field>`); a rename is only
  safe at zero.
- **Standard Value Sets cannot travel in a change set at all.** There is no such
  component type in the outbound change set UI. They are Metadata API only, so
  either GSA IT Engineering carries the file in their CLI deployment, or the
  values are added by hand in every org. This bites `OpportunityContactRole.Role`,
  whose values back 80% of the loaded contact roles.

## Repository layout

- **`sfdx/`** — the Salesforce DX project and **the product**.
  `force-app/main/default/` holds retrieved metadata; `manifest/package.xml`
  defines the scope and is the source for change sets. **This is the source of
  truth for the data model — read it directly for exact fields.**
- **`tools/`** — engineering-only. Nothing here ships.
  - `data-loading/` — the dev/QA sandbox loading and factory-reset scripts.
  - `metadata/` — Sync-Metadata, Get-LDGCRMDataDictionary,
    Find-UnexposedLDGCRMFields, Export-ChangeSetInventory.
  - `Backup-AirtableBase.ps1`, `Export-ReportPdf.ps1`, `Test-AccountMatching.ps1`.
- **`data/`** — **gitignored, APPLICANT PII.** `airtable-exports/` (the pulled
  base), `prod-accounts/` (the production Account export), `salesforce-loads/`
  (staged CSVs).
- **`logs/`** — **gitignored.** Run output, one directory per run.
- **`archive/`** — Sprint 1, frozen. `sprint_1_scripts.zip` (code and operator
  runbooks; deliberately no data, logs or `.env`) and `sprint_1_docs.zip`.
- **`scripts/`** — **empty, reserved for Sprint 2.** See its README.
- **`reference/`** — the Salesforce user roster.
- **`docs/`** — engineering documentation. See "Documentation layout".

**`.env` lives at the repository root** and holds the Airtable Personal Access
Token. The root `.gitignore` is now the only thing protecting `data/` and `.env`
— the old `scripts/.gitignore`, which travelled with the operations bundle, is
gone with it. **If you add a new output location, add the ignore rule in the same
change**; an output folder nobody thought about is how PII gets committed.

## Data model

`sfdx/force-app/main/default/objects/` is the source of truth. Custom objects use
the `LDGCRM_` prefix: `LDGCRM_Application__c`, `LDGCRM_Application_Contact__c`,
`LDGCRM_Partner_Account__c`, `LDGCRM_Impediment__c`,
`LDGCRM_Opportunity_Impediment__c`, `LDGCRM_Market_Segment__c`. Standard objects
carrying custom fields: Account, Contact, Opportunity, `OpportunityContactRole`,
Activity (Task/Event).

- **Contact** is the central hub, linked to Opportunity via the standard
  **OpportunityContactRole** junction, and to `LDGCRM_Application__c` via
  `LDGCRM_Application_Contact__c`.
- **`LDGCRM_Application__c`** has a required **Lookup** (not Master-Detail) to
  `LDGCRM_Partner_Account__c`, and an optional Lookup to Opportunity (filtered to
  the `Login_gov` record type).
- **`LDGCRM_Partner_Account__c`** is the Master-Detail child of **Account** (via
  `LDGCRM_Account__c`, filtered to the `Federal` record type).
- **`LDGCRM_Opportunity_Impediment__c`** is a true junction with **two
  Master-Detail relationships**, so both parents must exist first.
  `LDGCRM_Application_Contact__c` by contrast uses two plain **Lookups** — which
  is why it needs a duplicate-check Flow that a Master-Detail junction doesn't.
- **Activity** reaches both Account and Opportunity through the single
  polymorphic `WhatId`. There is no separate custom Account lookup.

**Two API-name typos are real and must be respected:** `LDGCRM_contact__c`
(lower-case `c`) and `LGDCRM_P3_Partner_Portal_Admin__c` (transposed prefix).
Three Flows also carry the transposed `LGDCRM_` prefix — a `LIKE '%DGCRM%'`
search silently misses them, because "LGDCRM" does not contain "DGCRM".

### ⚠️ Nine Flows must be ACTIVE, and inactivity is INVISIBLE to every count

QA was once loaded with 8,740 records and 0 failures while all nine were switched
off. Nothing failed, nothing was withheld, every object count matched — and
Market Segment was blank on 100% of Partner Accounts, Opportunities and
Applications. **Flow activation changes field *contents*, not row counts.**

Three before-save Flows assign `LDGCRM_Market_Segment__c` automatically from the
related Account, cascading down the hierarchy, so **load scripts must never set
that field themselves** on Partner Account, Opportunity or Application — only
Account's is set directly. The rest implement duplicate-record checks on the two
junctions, Partner Account re-parent cascades, and status/blocked-revenue
rollups.

**A Flow's version number is a PER-ORG counter and means nothing across orgs.**
Only active-vs-latest *within* one org is a meaningful comparison. Flows can also
arrive from a change set **inactive**.

## Airtable

`tools/data-loading/Get-AirtableExport.ps1` pulls from the REST API into
`data/airtable-exports/<Table>.json`, **overwriting each run** — it is a
current-state mirror, and that is the intent. **Do not snapshot Airtable**
(user, 2026-08-17): always load the latest pull. If an export looks stale,
re-pull rather than reaching for an older copy, and expect counts to move.

The pull is a **backup of the whole base**: all 22 tables, of which 10 are read
by the transforms. `$DefaultTables` marks each `Migration` or `Backup`. A
`Migration` label is **load-bearing** — `Get-AirtableTablePath` opens
`<Label>.json` by that exact string. `-MigrationOnly` pulls just the 10.

Because that list is hardcoded, a table added to the base later would never be
pulled and nothing would say so. After every pull the script asks
`GET /v0/meta/bases/{baseId}/tables` what the base actually holds and reports
anything it missed. It runs *after* the data is written and is **never fatal**:
it needs `schema.bases:read`, and a token that pulls every record perfectly well
may still be unable to list tables.

`tools/Backup-AirtableBase.ps1` runs the same pull and zips it to
`dist/airtable-backup-<timestamp>.zip`. Those archives answer *what the base held
on that date*; **a load still reads `data/airtable-exports/`.** Never extract an
old archive over that folder to reproduce an older count.

**Authentication** is a Personal Access Token (`pat...`, not the removed `key...`
API keys), needing `data.records:read` plus `schema.bases:read`, explicitly
granted to this base. Sent as `Authorization: Bearer <token>`.

**REST shape:** table **IDs** are used, not names — a rename silently 403s a
name-based request, and Airtable returns 403 identically for "no permission" and
"doesn't exist". Pagination is 100 records/page via `offset`. Rate limit is
5 req/sec per base; the script paces ~250ms and retries `429` after 30s.

**An export can go stale in ways that change a column's SHAPE, not just its
values.** Airtable converted Opportunities' identity-platform columns from linked
records to plain multi-selects; a transform written for one shape reads the other
as garbage. `Build-OpportunityLoad.ps1` therefore **hard-fails** rather than
silently dropping 453 values. Copy that pattern: when a column's shape is
load-bearing, assert it and fail loudly.

## ⚠️ Before mapping a column, confirm the target field is OURS

This org hosts **FCIC** and **TTS OTCRM**, which label their fields in the same
business vocabulary. **A matching field *label* is not evidence of anything —
check the `LDGCRM_` prefix.** Opportunity carries both `priority_type__c`
("Priority Type", TTS OTCRM's) and `LDGCRM_Level_of_Priority__c` (ours); the
Airtable column is called `Priority Type`, so the exact label match points
straight at the wrong field. **If the best label match is un-prefixed, stop and
ask** — writing another app's field is worse than migrating nothing.

Since go-live the org also has un-prefixed `Level_of_Priority__c`,
`Opportunity_Type__c` and `Status__c` **exposed on the `Login_gov` record type**,
duplicating ours by label. Ours all still exist. The trap is closer than it was.

Related traps, each learned the hard way:

- **A column name may not describe its content.** `States + DC/PR` is a checkbox
  distinguishing state from federal Accounts, mapping to standard `Type` as
  `"State"` / `"Federal"` — confirmed against existing org data, not assumed.
- **A restricted picklist rejects anything outside its values.** Impediment's
  free-text `Category` needs an explicit map, not passthrough.
- **Not every column has a destination.** Airtable-side rollups and Salesforce
  roll-up summary fields (`LDGCRM_Blocked_Revenue__c`) reject direct writes.
- **Check for a `<formula>` tag before writing to any calculated-looking field.**
  Application's `LDGCRM_Level_1_Complete_Pct__c` and friends declare
  `<type>Percent</type>`, identical to a writable field, but are formulas.
- **"Not in any export" is far weaker than "not in Airtable."** Check
  `GET /v0/meta/bases/{baseId}/tables` before declaring a field sourceless.

**Record-type picklist restrictions ARE enforced by the Bulk API, and
`sf sobject describe` does not show them.** A 19-row test batch once failed 19/19
with `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST` on values the describe reported as
valid — because describe reports *field*-level values only. When an object has
more than one record type, also read
`objects/<Object>/recordTypes/<RecordType>.recordType-meta.xml`, whose `fullName`
entries are URL-encoded (`,`→`%2C`, `/`→`%2F`, `&`→`%26`). **Always prove a new
object's picklist assumptions with a small test batch.**

**On every object, `LDGCRM_External_ID__c` is `externalId=true` but
`unique=false`** — Salesforce will not reject a duplicate at the database level.
Upserts are safe; anything that inserts, or edits the field by hand, can silently
create duplicates.

**`OpportunityContactRole.LDGCRM_External_ID__c` has `externalId=false` and
CANNOT be changed** — Salesforce forbids External ID fields on that object
entirely. It is therefore the one object loaded by **INSERT + read-then-diff**
rather than upsert.

See `docs/engineering/TRANSFORMATION-RULES.md` for the full field-by-field rules.

## ⚠️ EVERY read is scoped to the record types we own

Standing rule, user-stated 2026-08-24: **"we should not care about data in record
types that are not ours, PERIOD."** This org is shared with FCIC and TTS OTCRM,
whose records outnumber ours by roughly a thousand to one in a full sandbox.

**The owned set is defined once**, in `Get-LdgcrmOwnedRecordTypes`
(`Common.DataMigration.ps1`). Never hard-code it anywhere else:

| Object | Ours |
| --- | --- |
| Account | `Federal` |
| Contact | `Federal`, `GSA` |
| Opportunity | `Login_gov` |
| `OpportunityContactRole` | via `Opportunity.RecordType.DeveloperName` |
| every `LDGCRM_` object | wholly ours — **no filter** |

`Get-LdgcrmOwnedRecordTypeClause -SObject <name>` returns the SOQL fragment (an
empty string means "no restriction required", never "unknown"). Callers AND it
into their own SOQL — there is deliberately **no query-rewriting helper**,
because splicing a `WHERE` into arbitrary SOQL breaks on the first `ORDER BY`.

**Counting: use `Get-SalesforceRecordCount`, never
`@(Invoke-SalesforceQuery -Soql "SELECT Id FROM X").Count`** — `sf data query`
caps at 50,000 rows, so the latter cannot see past it. `-Scope Owned|All` is
mandatory, so org-wide has to be typed and therefore justified.

**This is a correctness rule, not a performance one.** The Account transforms
build a **name index**, and `GSA_FCIC_ContactTrigger` names its junk Accounts
**after the person** — so an unscoped pool means matching agency names against
~1.5M person names, and a collision makes the transform conclude an Account
already exists and not create it. That is invisible in every count a run
produces.

**Two deliberate exceptions:** `Save-RestorePoint`'s external-ID capture is NOT
scoped (the external ID is itself an ownership marker and the more conservative
filter — under-collecting would let a rollback delete a pre-existing record), and
the FCIC junk-Account check uses `-Scope All` (it asks whether *our* load leaked
into *their* record type).

**A record with NO record type is excluded** by every clause, since
`RecordType.DeveloperName IN (...)` is false for a null. Correct under the
policy, but it is a *decision* — revisit it first if untyped PEO records appear.

## PowerShell

### ⚠️ PowerShell is the language of this repo. Do not reach for Python.

**Everything here is PowerShell — automation, transforms, one-off analysis,
throwaway checks. There is no Python and none is wanted.** Do not write a `.py`
helper "just for this bit" or shell out to `python` to parse JSON. Use
`ConvertFrom-Json`, `Import-Csv`, `Group-Object`, `Compare-Object` and `foreach`.

This is a hard convention. It keeps one language, one set of helpers, one logging
convention and one confirmation-gate pattern across the repo. The same goes for
**ad-hoc analysis during a session**, so anything worth keeping can be lifted
into `tools/` unchanged.

Target **Windows PowerShell 5.1** (`#Requires -Version 5.1`; no `pwsh` on these
machines, and installing it is blocked by Group Policy on at least one). Avoid
PS6+ syntax: `??`, `?.`, ternary `?:`, `ConvertFrom-Json -AsHashtable`,
`ForEach-Object -Parallel`, multi-argument `Join-Path`.

### Traps that have actually cost time here

All of these fail *quietly* or blame the wrong thing:

- **Never redirect a native command's stderr** (`2>&1`, `2>$null`) on `sf`, `git`
  or `powershell`. PS 5.1 wraps each stderr line in an ErrorRecord, so the CLI's
  harmless "update available" banner becomes a `NativeCommandError` that kills
  the script — and the error points at the line that ran the command, not the
  redirect. `sf`'s output is captured anyway.
- **`Export-Csv -Encoding UTF8` writes a BOM**, and the Bulk API rejects the file
  with *"Found unescaped quote"*. Use `Export-DataLoaderCsv`, which writes UTF-8
  **no-BOM**. Its parameter is `-InputObject`, not `-Rows`.
- **Never count CSV records with `Get-Content`/`Measure-Object -Line`.** Rich-text
  fields legally span physical lines — this once reported 1,017 records against a
  real 94. Use `@(Import-Csv $path).Count`.
- **`@($text | ConvertFrom-Json).Count` is 1 for a JSON array of any size.**
  PS 5.1 writes the array to the pipeline as ONE object. **Assign first, then
  count.** It fails in the worst way: a backup once reported "22 tables, 22
  records" with every row reading `1`, a perfectly plausible number.
- **`$json.records` on an array of pages returns N nulls, not N records.** Member
  enumeration over an array whose elements lack the property yields `$null` each,
  so `.Count` looks right and `[0]` is null. Inspect the shape first.
- **`return ,$Array` and a caller's `@()` are mutually exclusive.** The leading
  comma stops PowerShell unrolling a returned collection, and is required when
  returning a `List<T>` the caller assigns bare — but combined with `@()` you get
  a one-element array *containing* the array, and `.Count` silently becomes 1.
  **Plain array + caller wraps in `@()` → return it bare.** State which contract
  a function has in its help block.
- **`@($list)` throws `Argument types do not match` when the list was built with
  `New-Object`.** PS 5.1 cannot bind `@( )` to a **PSObject-wrapped
  `List[object]`**; `[System.Collections.Generic.List[object]]::new()` is not
  wrapped. **The wrapper is the trigger, not the type** — and every *other*
  operation on the wrapped list works, which is why nothing hints at it. **Always
  build a `List[object]` with `::new()`.**
- **`powershell.exe -File` CANNOT PASS AN ARRAY, and two of the three ways of
  trying lose data silently.** `-P "a" -P "b"` throws; `-P "a,b"` binds ONE
  element (the literal `"a,b"`); `-P "a" "b"` binds ONE element and **discards
  the second in silence**. Only the first says anything. **Plural values cross a
  process boundary in a JSON file**, never as repeated arguments.
- **A here-string (`@'…'@`) does not reliably bind as a single argument to a
  native command.** `git commit -m @'…'@` once split on an apostrophe and turned
  the message body into pathspecs. Write the message to a file and use
  `git commit -F`.
- **`Get-Content -Raw` WITHOUT `-Encoding` silently corrupts UTF-8 files that
  have no BOM.** PS 5.1 falls back to the system ANSI codepage, so every em dash
  and arrow is mis-decoded; writing it back bakes the damage in. This mangled 14
  files in one bulk replace — and *only* the BOM-less ones, which is why it
  looked random. **Any script that reads a file and writes it back must pass
  `-Encoding UTF8`** (or use `[System.IO.File]::ReadAllText` with an explicit
  encoding). Note this cuts both ways: `powershell.exe` also decodes a BOM-less
  `.ps1` as ANSI, so a repair script containing the characters it hunts for will
  not parse — write that kind of tool in pure ASCII with regex `\u` escapes.
- **`XmlDocument.Save()` adds a UTF-8 BOM** that breaks OOXML and metadata XML.

### Conventions

Every script dot-sources `tools/data-loading/Common.ps1` and uses its helpers
rather than inventing new output locations:

- **`Get-LdgcrmRoot`** — the **repository root**. All of `data/`, `logs/`,
  `.env` and `reference/` hang off it. (It returned the *bundle* root while this
  code lived in `scripts/`; it now resolves two levels up from
  `tools/data-loading/`.)
- `Get-LogDirectory -Category <cleanup|data-migration>` — ensures and returns
  `logs/<category>/`.
- `Start-ScriptLog` / `Stop-ScriptLog` — opens a transcript and returns a shared
  timestamp for the run's other output. Pair them in a `finally` so the
  transcript closes even on early `exit`.

**Everything one run produces goes in ONE directory**:
`logs/<category>/<ScriptName>-<timestamp>/`. `Start-ScriptLog` publishes it in
`$env:LDGCRM_RUN_DIRECTORY` and `Get-LogDirectory` returns it, so child processes
inherit it. **Never reintroduce a per-script subfolder.**

That directory holds one report, **`SUMMARY.txt`**. Three things about it are
load-bearing:

- **"Withheld" is not a load error, and it is usually the bigger number.**
  Transforms skip rows whose parent isn't loaded — those rows are never
  *submitted*, so the Bulk API says nothing and the step reports success. Any
  "how much loaded?" question must account for both.
- **Section 2 covers only rows Salesforce REJECTED; "WHY IT STOPPED" covers a
  step that failed without submitting anything.** A step that died before
  reaching the Bulk API leaves section 2 reading "(none)" — exactly what a clean
  run looks like. **The absence of the child's transcript is the diagnosis.**
- **Every file is named after the STEP, not the object** (`-StepName`), because
  several steps load the same object and object-named files destroyed each
  other's transcripts, leaving a survivor that looked complete.

**Do not add a hard-coded expected count anywhere**: it is wrong the moment
Airtable is fixed, and this repo has already killed one check that cried wolf.

## Operational gotchas

- **The repo's metadata is NOT a complete picture of what fires in this org.**
  `manifest/package.xml` is deliberately LDGCRM-scoped, so automation belonging
  to the other apps is invisible to any amount of careful reading of
  `force-app/`. Always check the live org for triggers, duplicate rules and flows
  before loading a new object:
  `sf data query --use-tooling-api -q "SELECT Name, Status, TableEnumOrId FROM ApexTrigger WHERE TableEnumOrId = '<Object>'"`
  - **`GSA_FCIC_ContactTrigger`** (unmanaged, FCIC) fires on every Contact insert
    and creates a junk Account — named after the person, on the
    `FCIC_Individual` record type — for **every Contact inserted with a blank
    `AccountId`**.
  - **`purecloud.ContactWebHookv1`** (managed, Genesys) also fires on Contact
    insert. Its body returns `(hidden)`, so **what it does is unknowable from
    here**, and it has no kill switch. User-confirmed inert in Dev.
  - **`OTCRM_Contact_Duplicate`**, an org-level duplicate rule that once cost 167
    Contacts in a single run. The load switches it off via a metadata round-trip
    and **decides whether to proceed on a verifying re-query, never on the
    deploy's own success report**. TTS OTCRM is defunct (user, 2026-08-15), so
    this needs no cross-team sign-off.
- **The FCIC app ships a supported kill switch.** `TriggerControls__c` has one
  record per object with an `On__c` flag the trigger checks first. Passing
  `-DisableTriggerControl "Contact"` captures the value, switches it off, and
  restores it in a `finally` with a **verifying re-query** — so it is restored
  even when the load throws, which it has.
- **Any `sf project deploy validate`, or a deploy that runs tests, currently
  fails org-wide** on a pre-existing Apex compile error in
  `GSA_FCIC_AC_Manual_InitialBatch` (`Variable does not exist: metadata`).
  Salesforce compiles *all* Apex before running any test, so one broken class
  cascades across the org regardless of what you are deploying. For metadata-only
  changes use `--test-level NoTestRun`. This is not a fix — a deploy that
  includes Apex is still blocked until the FCIC owner repairs that class.
- **`sf project retrieve start` must run from inside `sfdx/`** — it needs
  `sfdx-project.json` in the working directory.
- **A targeted `-m "RecordType:<Object>.<RT>"` retrieve is LOSSY** — it once
  returned 4 of 33 `<picklistValues>` blocks and would have silently deleted the
  other 29. Retrieve `-m "CustomObject:<Object>"` instead. **After any retrieve,
  check `git diff --stat`** and confirm the change is confined to what you
  expected. To inspect an org without touching `force-app/`, retrieve to a
  scratch dir: `--target-metadata-dir <scratch> --unzip`.
- **A retrieve never DELETES local files.** Components removed from the org stay
  in `force-app/` looking current. The tell is the file's timestamp: everything
  the org returned is rewritten, so anything *not* rewritten by the run is a
  candidate for "exists here, not in the org".
- **`sf sobject describe` can serve a stale or incomplete answer.** The Tooling
  API's `FieldDefinition` gives the truthful one. Seen on 2026-09-08: describe
  omitted four `LDGCRM_application__c` fields that the Metadata API had just
  retrieved from the same org.
- **A field delete only hard-blocks on a FORMULA reference.** Layout,
  permission-set FLS and report-type columns are cascaded away automatically.
  And **`sf project deploy start --metadata-dir` silently ignores a destructive
  manifest** — it reports "Succeeded" having deployed 0 components. Use
  `--manifest` + `--post-destructive-changes`, and check
  `numberComponentsDeployed`, not just the status.
- **Broad wildcard retrieves (e.g. `CustomApplication:*`) pull the entire org.**
  Prefer the manifest or a change-set/package-name retrieve.
- **Retrieving a change set's contents:** a change set's **Name** works as an
  unmanaged package name —
  `sf project retrieve start --package-name "<Change Set Name>"`. An inbound
  change set is **not** retrievable from the receiving org; it answers
  `INVALID_CROSS_REFERENCE_KEY`, indistinguishable from a typo.
- **Long paths:** if git operations on `sfdx/force-app` fail with
  `Filename too long`, `git config core.longpaths true` is already set — retry.
  For non-git deletion use `robocopy <empty-dir> <target> /MIR` rather than
  `Remove-Item -Recurse`.

## sfdx/ commands

Run from inside `sfdx/`:

- `sf project retrieve start -x manifest/package.xml --target-org peodv8dvn` —
  or `tools/metadata/Sync-Metadata.ps1` from the repo root, which wraps it with
  discovery and logging.
- `npm run lint` — ESLint over `aura`/`lwc` JS.
- `npm test` / `npm run test:unit` — `sfdx-lwc-jest`. Single file:
  `npx sfdx-lwc-jest path/to/file.test.js`.
- `npm run prettier` / `npm run prettier:verify`.
- Husky's `pre-commit` runs `lint-staged`.

**`Sync-Metadata.ps1` scans only types already present in the manifest**, so
removing a type removes it from the discovery report too. Its discovery step
reports every non-`LDGCRM_` component in the org for manual review — around 1,086
of them, which is expected noise from the other apps. Confirmed non-LDGCRM
components live in `tools/metadata/ldgcrm-manifest-ignore.json`.

**⚠️ Its discovery step warns per type but still concludes "No new LDGCRM-named
components found" and exits 0 when every type failed to list.** That is a green
result from a scan that checked nothing — seen when the sandbox user lacked
Metadata API access. Read the warnings, not just the conclusion.

## Documentation layout

| Path | Audience | Contents |
| --- | --- | --- |
| `docs/engineering/` | People **changing** the app | `ARCHITECTURE.md`, `TRANSFORMATION-RULES.md`, `BACKLOG.md`, `PRODUCTION-CHANGE-SET-INVENTORY.md` |
| `docs/data-quality/` | The **data owners** | Airtable and Salesforce Account cleanup asks |
| `archive/sprint_1_docs.zip` | History | Sprint 1's docs as they stood at go-live |

### ⚠️ EVERY document records what is TRUE NOW, not how it got there

Standing convention, user-stated 2026-08-15. Completed work, resolved items and
superseded status are **deleted — not struck through, not archived in a "Resolved
log", not marked ✅.** Git carries the history; per-run detail lives in that run's
`SUMMARY.txt`.

The reason is the one that forced the original reversal: closed items outnumber
open ones within days, and a reader then has to work out which is which.

Re-measure the survivors in the same change, so every number describes today.

**The one exception is a RULE.** A business or transformation rule stays after it
is implemented, because it describes how the system must behave rather than what
happened. Those live in `docs/engineering/TRANSFORMATION-RULES.md` and must not
be deleted as "completed" — deleting one invites it being re-litigated.

## Skills

Project skills in `.claude/skills/` load automatically when relevant:
`sfdx-metadata-sync`, `sfdx-sandbox-ops`, `sfdx-data-migration`.
