# Setting up to run a migration

Everything you need before you can run anything, assuming **no prior knowledge of this project,
Airtable, or Salesforce CLI tooling**. Work through it top to bottom; the whole thing takes under
an hour, most of which is waiting for someone to grant you Airtable access.

You need three things: the tooling, a connection to a Salesforce org, and an Airtable token. They
are independent — you can do them in any order — but you need all three before a load will run.

---

## What this project actually does, in three sentences

Login.gov's partnership team has been tracking agencies, applications and opportunities in an
**Airtable base**. This project moves that data into **Salesforce**, where it becomes Accounts,
Contacts, Opportunities and a handful of custom objects prefixed `LDGCRM_`. The migration is
**repeatable**: it reads Airtable fresh every time, matches against what's already in Salesforce,
and loads only what's missing or changed — so running it twice does not create duplicates.

You will be working with two systems and a set of PowerShell scripts that talk to both.

---

## 1. Tooling

| Requirement | Why | Check it |
| --- | --- | --- |
| **Windows PowerShell 5.1+** | Every script targets it | `$PSVersionTable.PSVersion` |
| **Scripts allowed to run** | Windows blocks `.ps1` by default — **the first thing that stops you**, see below | `Get-ExecutionPolicy -List` |
| **Salesforce CLI (`sf`)** v2+ | All Salesforce reads and writes | `sf --version` |
| **Node.js 18+** | Only needed for `sfdx/` linting and tests | `node --version` |
| **Git** | Cloning, and `core.longpaths` below | `git --version` |

Install the Salesforce CLI from <https://developer.salesforce.com/tools/salesforcecli> if `sf` is
missing.

**PowerShell 7 (`pwsh`) is not required and not expected.** These scripts are written for Windows
PowerShell 5.1 because that is what the team's machines have — on at least one, installing
PowerShell 7 is blocked by Group Policy. They run fine under `pwsh` if you happen to have it.

### ⚠️ One-time PowerShell setting — do this FIRST, or nothing runs

**Windows blocks PowerShell scripts by default, and the error does not look like a setup problem.**
On a machine that has never run scripts, the very first command in this bundle fails with:

```
.\powershell-scripts\Invoke-FullMigrationLoad.ps1 : File ... cannot be loaded because running
scripts is disabled on this system.
    + FullyQualifiedErrorId : UnauthorizedAccess
```

Nothing is wrong with the bundle, the org or your login. Windows PowerShell 5.1 defaults to
`Restricted`, which refuses to run **any** `.ps1` file. Check what you have:

```powershell
Get-ExecutionPolicy -List
```

All scopes reading `Undefined` means `Restricted` is in force. Fix it once, per user — **no admin
rights needed**:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

If your organisation sets the policy by Group Policy, `MachinePolicy` or `UserPolicy` will show a
value instead of `Undefined` and the command above will not stick. In that case set it for the
current window only, and expect to repeat it every session:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

> ⚠️ **If you got this bundle as a downloaded `.zip`, `RemoteSigned` alone is not enough.** Windows
> marks every file extracted from an internet-downloaded archive, and `RemoteSigned` refuses marked
> scripts unless they are signed. The symptom is the *same* error above, even after setting the
> policy. Clear the mark once, from the bundle root:
>
> ```powershell
> Get-ChildItem -Recurse -Filter *.ps1 | Unblock-File
> ```
>
> This does not apply to a `git clone` — cloned files carry no mark. Check with
> `Get-Item .\powershell-scripts\Common.ps1 -Stream Zone.Identifier`; "stream was not found" means
> you are fine.

### One-time git setting on Windows

Salesforce metadata nests deeply, and this machine's disk mount adds a long prefix to every path,
so file paths can exceed Windows' 260-character limit. If `git` operations under `sfdx/` fail with
`Filename too long`:

```powershell
git config core.longpaths true
```

Already set in this clone's local config; you need it again in a fresh clone.

---

## 2. Connect to a Salesforce org

### Understand the environments first — this is the part people get wrong

Every script takes `-Environment Dev|QA|Full|Prod` and looks the actual org alias up itself from
`powershell-scripts/Common.Orgs.ps1`. **You never pass a Salesforce username or org alias by hand.**

| `-Environment` | Alias | What it is |
| --- | --- | --- |
| `Dev` *(default)* | `peodv8dvn` | Day-to-day development and pipeline testing |
| `QA` | `peodv15dvn` | Full end-to-end migration rehearsal |
| `Full` | `peofl2stgp` | Operations dress rehearsal, immediately before production. **Real Accounts — never rebuilt** |
| `Prod` | `gsa-peo` | **PRODUCTION. Real Login.gov partner data.** |

> Production is deliberately **not authorized** on development machines. If `sf org list` shows it,
> something is wrong — stop and ask.

An alias here is always **the sandbox's own name**, which is what lets the scripts cross-check it:
`Assert-LdgcrmOrgTarget` runs at the start of every script, asks the org for its own identity, and
refuses to continue if it disagrees with the registry. That closes the gap where a local alias
silently points somewhere else — an alias is just a pointer on your laptop, so the only trustworthy
statement about what it points at comes from the org on the other end.

### Authenticate

Log in **at the sandbox's own My Domain URL**, not the generic `test.salesforce.com`. The browser
then lands on exactly the org the alias claims, so the alias cannot be attached to the wrong
sandbox:

```powershell
# Dev
sf org login web --alias peodv8dvn `
    --instance-url https://gsa-peo--peodv8dvn.sandbox.my.salesforce.com

# QA
sf org login web --alias peodv15dvn `
    --instance-url https://gsa-peo--peodv15dvn.sandbox.my.salesforce.com
```

Verify — the `Instance Url` in the output must match the table above:

```powershell
sf org display --target-org peodv8dvn
```

Optionally make Dev the default so bare `sf` commands work without `--target-org`:

```powershell
sf config set target-org peodv8dvn
```

### Check who you are, because it decides record ownership

```powershell
sf org display user --target-org peodv8dvn
```

This matters more than it looks. Records whose owner cannot be resolved from Airtable are assigned
to a **named fallback owner**, and some operations (notably attaching notes) require *your* user to
have edit access to every parent record. Running a production load under a personal login makes an
individual engineer the owner of records they have no relationship to. See
[RUNNING-A-LOAD.md](RUNNING-A-LOAD.md#who-ends-up-owning-the-records).

### Authorizing a new environment

If you are standing up an org the registry doesn't know about yet, add it to
`powershell-scripts/Common.Orgs.ps1` **first**, then authenticate. The registry is what the identity
check compares against; an org that isn't in it can only be reached via `-OrgAlias`, which
deliberately bypasses those checks and should be a last resort.

---

## 3. Get Airtable access

Three steps, and the first one needs someone else, so start it early.

### Step 1 — Get admin access to the base

You need an **admin account on the Login.gov CRM Airtable base**. Request it from the
**Login.gov CRM team — Peter Marks or Erin Duffy**.

### Step 2 — Create a Personal Access Token

Airtable removed the old `key...` API keys in February 2024. What you need now is a **Personal
Access Token (PAT)**, which starts with `pat...`.

1. In Airtable, click your **profile avatar** (top right) → **Builder hub**
2. Go to **Personal access tokens** → **Create new token**
3. Give it a name you'll recognise, e.g. `login-gov-crm-migration`
4. Add **both** of these scopes:

   | Scope | What it allows |
   | --- | --- |
   | `data.records:read` | See the data in records |
   | `schema.bases:read` | See the structure of a base — table names, field types |

5. Under **Access**, grant **All resources** (all current and future bases in all current and
   future workspaces). You can only grant access to bases you already have access to, which is why
   step 1 comes first.
6. Copy the token **immediately** — Airtable shows it once and never again.

> **Both scopes are needed, and for different things.** `data.records:read` is what the pull
> actually uses. `schema.bases:read` does two jobs: it lets you look up table IDs and names via the
> metadata API when a table gets renamed — which has already happened once here (see
> [TROUBLESHOOTING.md](TROUBLESHOOTING.md#airtable-returns-403)) — and it powers the pull's
> **coverage check**, which reports any table in the base the export is not backing up.
>
> Without the second scope the pull still works and still writes every table it knows about. What
> you lose is the check that the list is still complete, so a table added to the base later would go
> unbacked-up silently. The run says so rather than pretending it checked.

### Step 3 — Fill in `.env`

Copy the template and fill in your token and the base ID:

```powershell
Copy-Item .env.example .env
```

Then edit `.env`:

```
AIRTABLE_API_KEY=pat...your token here...
AIRTABLE_BASE_ID=appCPBIq0sFQUZUSY
```

`appCPBIq0sFQUZUSY` is the Login.gov CRM base. It is not a secret — base IDs appear in the browser
URL whenever the base is open — but **the token is**, and `.env` is gitignored for that reason.
Never commit it.

> The variable is named `AIRTABLE_API_KEY` for historical reasons. The **value is a PAT**, not an
> API key. If yours starts with `key`, it is the deprecated kind and will not work.

### Verify it works

```powershell
.\powershell-scripts\Get-AirtableExport.ps1 -Tables "Impediments"
```

A single small table. If it writes `data/airtable-exports/Impediments.json` you are connected. If
you get a `403`, read [TROUBLESHOOTING.md](TROUBLESHOOTING.md#airtable-returns-403) — Airtable
returns 403 for both "no permission" and "table doesn't exist", so the two look identical.

---

## 4. Understand where files go

Two directories are **gitignored** because their contents can carry personally identifiable
information about Login.gov applicants sourced from Airtable. Do not commit anything from them.

| Directory | Contents |
| --- | --- |
| `data/airtable-exports/` | Raw Airtable pull, one JSON file per table (all 22 — it backs up the whole base, not just the 10 the load reads), **overwritten every pull** |
| `data/salesforce-loads/` | Load-ready CSVs produced by the transforms |
| `logs/data-migration/` | Run transcripts, review CSVs, restore points |
| `logs/cleanup/` | Records deleted by a factory reset — the only audit trail of what went |

---

## 5. The Contact duplicate rule — the load switches it off for you

**There is nothing to do here.** This section exists so the change isn't a surprise, because the
load makes a permanent configuration change to the org on your behalf.

**What happens.** Pre-flight finds every **active Contact duplicate rule**, switches it off, then
switches off the matching rules behind it. It does this in **every environment, production
included**, and it **does not put them back**.

**Why.** `OTCRM_Contact_Duplicate` matches Contacts on **first + last name only**, both exact. That
is not an identity test — there are a thousand people named Robert Smith — and it silently rejects
real people. On the 2026-08-15 Dev load it cost **167 Contacts**, and every junction keyed on those
people was short by the same names. It rejects rather than merges, and the load still reports
success, so nothing in the run output tells you it happened.

**How it does it**, since no API switches a duplicate rule off directly: it retrieves the rule *from
the org it is loading*, changes one line, and deploys it *straight back to that same org*. Nothing
moves between orgs and no definition changes — it is the same kind of action as `-ActivateFlows`
pointing an org at a flow version it already has.

> ### ⚠️ They stay off. Do not switch them back on
>
> This is **not** like the FCIC `TriggerControls__c` bypass, which the loader captures, flips and
> restores in a `finally` block — that one is borrowed for a single step and put back. These are a
> permanent change to the org's configuration, decided 2026-08-15. Turning them back on will stop
> the next load until it switches them off again.

**If it fails**, pre-flight blocks the run and tells you — it decides on a re-query of the org, not
on whether the deploy claimed success. You can always do it by hand instead:

1. **Setup → Duplicate Rules → OTCRM Contact Duplicate Rule → Deactivate**
2. **Setup → Matching Rules → OTCRM Contact Matching Rule → Deactivate**

That order is not optional — Salesforce will not deactivate a matching rule while an active
duplicate rule consumes it.

**Verify:**

```powershell
sf data query -q "SELECT DeveloperName, IsActive FROM DuplicateRule WHERE SobjectType='Contact'" --target-org <alias>
sf data query --use-tooling-api -q "SELECT DeveloperName, RuleStatus FROM MatchingRule WHERE SobjectType='Contact'" --target-org <alias>
```

Every Contact duplicate rule should read `IsActive: false`. The matching rules are inert once no
active duplicate rule uses them, so pre-flight only *warns* if one is still `Active` — but the
agreed end state is both switched off.

> **These rules belong to TTS OTCRM, not to this app** — they are un-prefixed and predate this
> migration. **TTS OTCRM is defunct** (project owner, 2026-08-15): the app is on its way out and all
> of its metadata and rules will eventually be removed. So there is no team to clear this with and no
> live users behind the rule; deactivating it is removing a blocker to Login.gov CRM going live, in
> every environment including Prod. Recorded so this reads as a decision rather than something nobody
> thought to ask about.

---

## You're ready — prove it

Everything above is verified by one read-only command. Run it before you trust any of it:

```powershell
.\powershell-scripts\Test-LdgcrmReadiness.ps1 -Environment Dev -AllEnvironments
```

It checks your `.env` and token shape, that every Airtable table was pulled and has rows, which orgs
you can actually reach, who you are in the target org, and that every field the load writes exists
and is writable there. It writes nothing and fixes nothing — each finding names the command that
would. Ends in `READY.` or `NOT READY.`

`-AllEnvironments` probes all four orgs; Full and Prod reporting "not authorized here" is expected on
most machines, and is INFO rather than a failure.

Then go to **[RUNNING-A-LOAD.md](RUNNING-A-LOAD.md)**.

If you are doing a full wipe-and-reload of a sandbox rather than a normal load, go to
[RELOAD-QA-CHECKLIST.md](RELOAD-QA-CHECKLIST.md) instead — it is the same pipeline with a great deal
more verification around it.
