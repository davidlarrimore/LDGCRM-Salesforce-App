# `logs/` — engineering tool output

Run output from the scripts in [`../tools/`](../tools/). **Gitignored** except this
file and `.gitkeep`.

This is **not** where the migration pipeline logs. That goes to
[`../scripts/logs/`](../scripts/logs/), inside the Operations bundle, and is
described by [`../scripts/logs/README.md`](../scripts/logs/README.md).

| Folder | Written by |
| --- | --- |
| `tools/` | `Sync-Metadata.ps1`, `Get-LDGCRMDataDictionary.ps1`, `Find-UnexposedLDGCRMFields.ps1`, `Export-ReportPdf.ps1`, `Build-ProdAccountSeed.ps1` |

## Why this is separate from `scripts/logs/`

`scripts/` is handed to the GSA Salesforce Operations team as a self-contained
folder. The metadata scripts are a **development aid** — they exist to build the
app and diagnose problems. Operations does not run them, and this project is not
responsible for pushing or pulling metadata on anyone's behalf: metadata moves
between orgs by **change set only**.

So none of it ships — not the scripts, not their logs, not their CSV output.
Until 2026-08-14 the metadata tooling wrote into `scripts/logs/metadata/`, which
put engineering-only run output (and a log category nothing else used) inside the
folder handed over. That category no longer exists in the bundle; `Get-LogDirectory`
there accepts `cleanup` and `data-migration` only.

## Structure

Same convention as the pipeline: **one folder per run**, named
`<ScriptName>-<yyyyMMdd-HHmmss>/`, holding that run's transcript and any CSV it
produced. `Start-ToolLog` in `tools/Common.Tools.ps1` creates it and publishes it
in `$env:LDGCRM_RUN_DIRECTORY`, so the bundle helpers these scripts still borrow
write into the same folder rather than back inside `scripts/`.
