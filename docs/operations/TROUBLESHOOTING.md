# Troubleshooting

Every failure this pipeline has actually produced, what the error text really means, and what to do.

Most Salesforce load errors **name the wrong thing** — they point at a field when the problem is a
user, or at the data when the problem is a file's encoding. That is what this page is for.

---

## Reading the logs

Everything a run produces lands under `logs/`, organised the same way `scripts/` is. It is
**gitignored** because it can carry applicant PII — never commit anything from it.

| Path | What's in it |
| --- | --- |
| `logs/data-migration/<Script>-<timestamp>.log` | Full PowerShell transcript of one run |
| `logs/data-migration/full-load-<timestamp>/` | Restore point, baseline counts, post-load counts |
| `logs/data-migration/notes-load-<timestamp>/` | Created note IDs — the **only** handle on migrated notes |
| `logs/data-migration/rollback-<timestamp>/` | What a rollback deleted and restored |
| `logs/cleanup/sandbox-factory-reset-<timestamp>/` | IDs of everything a reset deleted |
| `logs/metadata/` | Data dictionary exports |

### The review CSVs matter more than the transcript

Every transform writes CSVs for rows it **could not** load, or loaded with a caveat. These are the
actual output of a run — the transcript just narrates it.

| Pattern | Meaning |
| --- | --- |
| `*-skipped-*.csv` | Rows not loaded, with the reason |
| `*-unmatched-*.csv` | Airtable rows that matched no Salesforce record |
| `*-ambiguous-*.csv` | Matched more than one candidate — deliberately **not** guessed |
| `*-unresolved-owner-*.csv` | Owner emails with no active, eligible Salesforce user |
| `*-value-review-*.csv` | Values blanked or dropped because the target field wouldn't take them |
| `*-domain-inferred-account-*.csv` | The only inferred links in the pipeline — worth spot-checking |

**Findings sitting unread in `logs/` are the failure mode those files exist to prevent.** After a
run, read them and fold anything new into
[../data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md](../data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md).

### Getting the detail of a failed Bulk job

The loader writes a JSON result file **only on success**. When a job fails, get the per-row reasons
from the CLI using the job ID printed in the transcript:

```powershell
sf data bulk results --job-id 750cq00000C3JNNAA3 --target-org peodv8dvn
# writes 750...-failed-records.csv and 750...-success-records.csv to the current directory
```

Then group them — a single cause usually explains all of them:

```powershell
Import-Csv 750cq00000C3JNNAA3-failed-records.csv | Group-Object sf__Error |
    Sort-Object Count -Descending | Select-Object Count, Name
```

---

## A step reports "LOAD FAILED" but the counts look right

**Usually expected.** `Invoke-SalesforceLoad.ps1` exits non-zero if *any* row fails, and some steps
have known failures as their correct outcome — most notably `PartnerAccount`, where ~20 of 94 rows
fail because their parent Account is one of the unmatched Airtable rows.

Confirm it's the known cause, then resume past the step rather than re-running it:

```powershell
# Which planned rows didn't land, and do they all trace to an untagged parent Account?
$csv = Import-Csv "data/salesforce-loads/LDGCRM_Partner_Account__c-upsert.csv"
$landed = @{}
(sf data query -q "SELECT LDGCRM_External_ID__c FROM LDGCRM_Partner_Account__c WHERE LDGCRM_External_ID__c != null" --target-org peodv8dvn --json | ConvertFrom-Json).result.records |
    ForEach-Object { $landed[$_.LDGCRM_External_ID__c] = $true }
$acct = @{}
(sf data query -q "SELECT LDGCRM_External_ID__c FROM Account WHERE LDGCRM_External_ID__c != null" --target-org peodv8dvn --json | ConvertFrom-Json).result.records |
    ForEach-Object { $acct[$_.LDGCRM_External_ID__c] = $true }

$missing = @($csv | Where-Object { -not $landed.ContainsKey($_.LDGCRM_External_ID__c) })
$explained = @($missing | Where-Object { -not $acct.ContainsKey($_.'LDGCRM_Account__r.LDGCRM_External_ID__c') })
"missing: $($missing.Count)   explained by an untagged parent Account: $($explained.Count)"
```

If those two numbers match, nothing is wrong. If they don't, the unexplained rows are new and worth
investigating.

---

## `OP_WITH_INVALID_USER_TYPE_EXCEPTION: Operation not valid for this user type`

**Meaning:** you tried to make someone the *owner* of a record and their licence type does not
permit owning records. Chatter Free (`UserType = CsnOnly`), portal and community users are perfectly
active and can own nothing.

**Why it's confusing:** the message names neither the field nor the user, so it reads like a
permissions problem with *your* login rather than an ownership problem on specific rows.

**Diagnose:**

```powershell
Import-Csv <job>-failed-records.csv | Group-Object OwnerId | Sort-Object Count -Descending
sf data query -q "SELECT Id, Name, UserType, IsActive, Profile.Name FROM User WHERE Id IN ('005...')" --target-org peodv8dvn --result-format csv
```

**Fix:** owner resolution filters on `UserType = 'Standard'` as well as `IsActive`. If this recurs,
some path is promoting a User Id into an `OwnerId` without that check. Note it has to be checked
**everywhere a User Id becomes an owner**, not just in the shared resolver — a User *lookup* field
may legitimately point at a Chatter user, but ownership is stricter.

---

## `InvalidBatch : Failed to parse CSV. Found unescaped quote`

**Meaning:** almost certainly a **UTF-8 byte-order mark**, not your data.

PowerShell 5.1's `Export-Csv -Encoding UTF8` always writes a BOM. Bulk API reads those three bytes
(`EF BB BF`) as the start of an unquoted first field, hits the opening quote of `"Id"`, and fails
the whole job. The message mentions neither BOM nor encoding.

**Check the first three bytes before looking at the data:**

```powershell
Format-Hex -Path <file>.csv | Select-Object -First 1
# EF BB BF 22 49 64 22  = BOM present, this is your problem
# 22 49 64 22           = clean
```

**Fix:** write Bulk files with `Export-DataLoaderCsv` (in `Common.DataMigration.ps1`), never
`Export-Csv`. Files meant for humans to open in Excel can keep the BOM — it helps there.

---

## `InvalidBatch : Field name not found : <field>`

**Meaning:** the CSV has a column the object doesn't have — usually a field deleted from the org
since the transform was written.

**The trap:** the error names only the **first** missing column. Fix that one and you get an
identical failure on the next. Diff every column in one pass instead:

```powershell
$org = @{}
(sf sobject describe --sobject LDGCRM_application__c --target-org peodv8dvn --json | ConvertFrom-Json).result.fields |
    ForEach-Object { $org[$_.name.ToLower()] = $true }
(Get-Content "data/salesforce-loads/LDGCRM_application__c-upsert.csv" -TotalCount 1) -replace '"','' -split ',' |
    Where-Object { -not $org.ContainsKey((($_ -split '\.')[0] -replace '__r$','__c').ToLower()) }
```

**Fix:** either redeploy the field, or remove it from the transform. If removing, also sweep
`sfdx/force-app` — a deleted field leaves dangling references in layouts, permission sets and report
types that break the next deploy of those components:

```bash
grep -rl "<fieldName>" sfdx/force-app
```

---

## `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST`

**Meaning:** the value isn't allowed on that picklist **for that record type**.

**Why it's confusing:** `sf sobject describe` reports *field*-level picklist values and does **not**
show record-type narrowing. A value can be perfectly valid on the field and still rejected. A 19-row
Opportunity batch once failed 19 of 19 this way, on values verified against the describe output.

**Fix:** when an object has more than one record type, also read
`sfdx/force-app/main/default/objects/<Object>/recordTypes/<RecordType>.recordType-meta.xml`. Its
`fullName` entries are URL-encoded — `,`→`%2C`, `/`→`%2F`, `(`→`%28`, `&`→`%26`, `'`→`%27`.

**Always prove a new object's picklist assumptions with a small test batch before a full load.**

---

## `Foreign key external ID ... not found`

**Meaning:** a lookup points at a record that isn't in the org.

Two distinct causes:

1. **Wrong load order** — the parent hasn't loaded yet. Bulk API rejects the **whole row**, not just
   the unresolvable lookup, so an "optional" lookup that dangles costs you the entire record. Run
   the steps in order.
2. **A self-referential lookup in the same batch.** Bulk API does **not** resolve an external-ID
   reference between two rows of the same file, even though both are present. This is exactly why
   `LDGCRM_Broker_App_Parent__c` is a separate second pass that must run *after* the main Application
   load.

---

## `DUPLICATES_DETECTED`

**Meaning:** an org-level duplicate rule rejected the record. On Contact there is a rule matching on
first + last name that rejects a handful of rows every run (~4–5 of ~1,550).

Expected and documented. It is not in this repo's metadata — the manifest is scoped to this app, so
other teams' rules are invisible to any amount of reading `sfdx/force-app`.

---

## Junk Accounts appear after a Contact load

**Cause:** another application in this org (FCIC) has a Contact trigger that creates an Account
named after the person for every Contact inserted with a blank `AccountId`.

**Fix:** load Contact with `-DisableTriggerControl "Contact"`, which the orchestrator does
automatically.

**Verify with a delta, not a total** — some orgs permanently carry junk Accounts from earlier
testing, so the count never returns to zero:

```powershell
sf data query -q "SELECT COUNT() FROM Account WHERE RecordType.DeveloperName = 'FCIC_Individual'" --target-org peodv8dvn
```

Compare against the figure from before the load — `Invoke-FullMigrationLoad.ps1` records it in
`full-load-<ts>/fcic-junk-baseline.txt`.

**Afterwards, always confirm the switch went back on.** Leaving it off silently breaks another
team's app:

```powershell
sf data query -q "SELECT Name, On__c FROM TriggerControls__c WHERE Name = 'Contact'" --target-org peodv8dvn
```

---

## The factory reset fails to delete one Account

**Cause:** pre-existing test data hangs off it. Deleting the Account would cascade into records the
reset is explicitly designed never to touch, and a restricted lookup blocks it. **The platform is
protecting test data — this is correct behaviour.**

**But the script treats a partial delete as fatal**, stops, and **withholds the Account bootstrap**
(deliberately: bootstrapping on top of a half-deleted org corrupts the next run's preflight counts).

**Fix at source rather than excluding the Account.** Find what the surviving Account is a parent of
and re-point those test records at a test Account:

```powershell
sf data query -q "SELECT Id, Name FROM Contact WHERE AccountId = '<the account id>'" --target-org peodv8dvn --result-format csv
sf data query -q "SELECT Id, Name FROM LDGCRM_Partner_Account__c WHERE LDGCRM_Account__c = '<the account id>'" --target-org peodv8dvn --result-format csv
```

The error text names the blocking child records. Note the chain may not be the one the message
suggests — on 2026-08-13 the error named *application contacts* but the actual link ran through
**Contact**.

Then run the bootstrap by hand:

```powershell
powershell scripts/data-migration/Invoke-AccountBootstrap.ps1 -Environment Dev -Confirmation "BOOTSTRAP"
```

---

## Airtable returns 403

**Airtable returns 403 for both "no permission" and "table doesn't exist or isn't visible."** The two
are indistinguishable from the response, so work through the causes in order:

1. **The token lacks a scope.** Needs `data.records:read`; add `schema.bases:read` for metadata
   lookups. See [SETUP.md](SETUP.md#step-2--create-a-personal-access-token).
2. **The token isn't granted access to the base.** PATs are scoped per base/workspace, not
   account-wide.
3. **A table was renamed.** This has actually happened — "Partner Accounts" became "Partners" and
   broke a name-keyed pull. `Get-AirtableExport.ps1` uses **table IDs** rather than names for exactly
   this reason, since names are user-editable. If a table was added or removed, update
   `$DefaultTables` in that script.
4. **The token is the deprecated kind.** It must start with `pat`, not `key`.

List what the token can actually see (needs `schema.bases:read`):

```powershell
$env:AIRTABLE_API_KEY = "pat..."
Invoke-RestMethod -Uri "https://api.airtable.com/v0/meta/bases/appCPBIq0sFQUZUSY/tables" `
    -Headers @{ Authorization = "Bearer $env:AIRTABLE_API_KEY" } |
    Select-Object -ExpandProperty tables | Select-Object id, name
```

---

## Airtable returns 429

Rate limit: **5 requests/second per base**. `Get-AirtableExport.ps1` paces requests ~250 ms apart and
retries once with a 30-second backoff. If you see it repeatedly, something else is hitting the same
base concurrently.

---

## `sf project deploy` fails on Apex unrelated to this app

**Cause:** a pre-existing Apex compile error elsewhere in the org (`GSA_FCIC_AC_Manual_InitialBatch`,
part of an unrelated app sharing the sandbox). Salesforce compiles *all* Apex in the org before
running any tests, so one broken class fails every deploy that runs tests, regardless of what you
are deploying.

**Workaround for metadata-only changes, on a sandbox:**

```powershell
sf project deploy start --test-level NoTestRun --target-org peodv8dvn
```

This does **not** fix the underlying problem. A deploy that includes Apex, or must run tests for any
other reason, stays blocked until whoever owns that app fixes the class.

---

## `InvalidProjectWorkspaceError` on retrieve

`sf project retrieve start` must run **from inside `sfdx/`** — it needs `sfdx-project.json` in the
working directory. Or use `scripts/metadata/Sync-Metadata.ps1` from the repo root, which wraps it.

---

## `Filename too long` on git operations

Windows' 260-character path limit, hit by deeply nested Salesforce metadata.

```powershell
git config core.longpaths true
```

For non-git deletion of such paths, use `robocopy <empty-dir> <target> /MIR` rather than
`Remove-Item -Recurse`, which doesn't reliably handle them.

---

## A count looks wrong and nothing errored

Take it seriously — this is how most real defects in this pipeline were found.

Specific things that have produced plausible-but-wrong numbers:

- **PowerShell array handling.** `ConvertFrom-Json` emits a JSON array as a **single** pipeline item
  in PS 5.1, so `@($json | ConvertFrom-Json).Count` returns `1` regardless of how many records came
  back. Assign to a variable first, then wrap. The `@()` caller convention used everywhere else
  cannot repair a collapse that happened upstream of it.
- **A transform reading back its own previous output.** Contact name recovery looked like it was
  recovering 970 real names; it was reading placeholders it had written on an earlier run. Wiping
  the org revealed the true figure.
- **A stale CSV.** A transform that produces no rows leaves the previous run's file in place. The
  orchestrator now refuses to count or load a file its transform didn't just write.
- **Counting against zero instead of a baseline.** Some things (junk Accounts, pre-existing test
  records) never return to zero. Measure deltas.

---

## Still stuck

| Question | Where |
| --- | --- |
| What should this field map to? | [../engineering/TRANSFORMATION-RULES.md](../engineering/TRANSFORMATION-RULES.md) |
| Why is the pipeline built this way? | [../engineering/ARCHITECTURE.md](../engineering/ARCHITECTURE.md) |
| Is this a known source-data problem? | [../data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md](../data-quality/AIRTABLE-DATA-QUALITY-REQUESTS.md) |
| Is this already on the list to fix? | [../engineering/BACKLOG.md](../engineering/BACKLOG.md) |
