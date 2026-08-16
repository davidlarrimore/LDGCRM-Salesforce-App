# `data/`

Local-only inputs and staged output for the Airtable → Salesforce migration. **Gitignored** — see
`../.gitignore`, which lives in this bundle so the rule travels with the folder — because these
files can contain PII from Login.gov applicants and partner contacts.

- `airtable-exports/` — one JSON file per Airtable table (`<Table>.json`), written by
  `powershell-scripts/Get-AirtableExport.ps1`, which pulls straight from the Airtable REST API.
  **All 22 tables in the base, not just the 10 the load reads** — the pull doubles as a backup of
  the base. Each run overwrites these in place: they reflect current Airtable state, not a history
  of past pulls, so copy the folder elsewhere if you need to keep a particular snapshot. Requires
  `AIRTABLE_API_KEY`/`AIRTABLE_BASE_ID` in this bundle's `.env` (copy `.env.example`, which is
  beside it and documents how to get a token).
- `prod-accounts/` — the production Account export that `Invoke-AccountBootstrap.ps1` rebuilds a
  **Dev or QA** sandbox's Account tree from. Any of `.xls`, `.xlsx` or `.csv`; the filename does not
  matter and the newest file wins. **See [`prod-accounts/README.md`](prod-accounts/README.md)** —
  it covers the required columns, why the format is detected by reading the file rather than
  trusting the extension, and why this never happens in a Full sandbox or production.
- `salesforce-loads/` — load-ready CSVs written by the `powershell-scripts/Build-*.ps1` transforms and
  consumed by `Invoke-SalesforceLoad.ps1`. Regenerated from the current Airtable export every time a
  `Build-*` script runs — **never hand-edited**, because the next run overwrites them. See
  `../docs/RUNNING-A-LOAD.md` if you just need to run a load.
> **There is no `mappings/` folder** (removed 2026-08-14). It was a placeholder for Data Loader GUI
> `.sdl` field-mapping files, from before this pipeline settled on the `sf` CLI. It was always empty
> and nothing ever read it — **the field mapping lives in the `Build-*.ps1` transforms themselves**,
> which is the only copy and the one under version control. Don't recreate it.

Only `.gitkeep` and the `README.md` files here are tracked. Everything else is local to your machine
and must stay that way.
