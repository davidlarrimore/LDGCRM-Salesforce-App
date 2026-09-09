# `data/prod-accounts/` — the production Account export

Drop the PEO Accounts report export here. **Dev and QA only.**

## What this is for

The migration does **not** create Accounts. Every other object hangs off Account,
but Accounts pre-date the migration, so `Build-AccountReconciliation.ps1`
*matches* existing Accounts rather than inserting new ones.

That works in production and in a Full sandbox, where the Accounts are already
there. It does nothing at all in Dev or QA, which are empty developer sandboxes
with no Account universe to attach to — so a rehearsal there would load a few
thousand records against nothing.

`Invoke-AccountBootstrap.ps1` fills that gap by rebuilding the Account names and
their parent hierarchy from the file in this folder.

> **Dev and QA only, enforced in code.** `-Environment` on that script accepts
> nothing else. A Full sandbox is a copy of production, so its Accounts *are*
> the real records the migration reconciles onto — replacing them with a stale
> export would invalidate the very rehearsal it was meant to support. See
> `Test-LdgcrmAccountRebuildAllowed` in `powershell-scripts/Common.Orgs.ps1`.

## What to put here

Any export of the PEO Accounts report, in any of three formats:

| Format | Notes |
| --- | --- |
| `.csv` | Salesforce report → Export → **Details Only**. The safest choice. |
| `.xlsx` | A real Excel workbook. Read directly; Excel does **not** need to be installed. |
| `.xls` | Salesforce report → Export → **Formatted Report**. Despite the extension this is an HTML table, which is what the current file is. |

**The filename does not matter.** The newest file in this folder wins, and the
format is detected by reading the file's first bytes, not its extension — see
`Get-ProdAccountExportFormat`. If several files are present the pipeline prints
all of them and says which it chose, so a leftover copy is visible rather than
silently preferred.

One format is **not** supported: a genuine pre-2007 binary `.xls`. If you get an
error saying so, open it and re-save as `.xlsx` or `.csv`.

## Required columns

Resolved by header name, not position, so column order is free:

```
Account Name · Parent Account · Account Level · Account Record Type
Account Owner · Level 1 Account · Level 2 Account · Level 3 Account
```

A missing column fails immediately and prints the header row it actually found.

Two things about this data worth knowing before you trust it:

- **`Parent Account` is authoritative; the Level 1/2/3 columns are not.** They
  disagree on 4 of 1,369 rows, and those 4 are the interesting ones — 3 name
  themselves as their own parent, and 1 sits deeper than the deepest ancestor
  column. The Level columns are kept only to disambiguate duplicate names.
- **There is an `Account ID` column and it is unusable.** It is misaligned in
  the report: the same Id appears on unrelated rows (378 collisions across
  1,369). The parser deliberately does not return it, so nothing can key off it.

## Why nothing here is committed

This folder's contents are gitignored. The export is a full list of federal
agency Accounts and their record owners — it belongs in the org, not in a Git
repository. Only this README and `.gitkeep` are tracked, so **a fresh clone
will not have the export and the bootstrap will not be offered** until someone
puts one here. That is intended: it has to be requested and handed over
deliberately.
