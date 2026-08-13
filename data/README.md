# data/

Local-only inputs for the Airtable -> Salesforce migration, gitignored (see root `.gitignore`)
because they can contain PII from Login.gov applicants.

- `airtable-exports/` — one JSON file per Airtable table (`<Table>.json`), written by
  `scripts/data-migration/Get-AirtableExport.ps1`, which pulls straight from the Airtable REST API.
  Each run overwrites these in place — they reflect current Airtable state, not a history of past
  pulls. Requires `AIRTABLE_API_KEY`/`AIRTABLE_BASE_ID` in the repo-root `.env` (copy `.env.example`).
- `mappings/` — Data Loader field-mapping files (`.sdl`) and any other object/field mapping docs
  used to drive loads.
- `salesforce-loads/` — CSVs staged for the Data Loader CLI, written by the `scripts/data-migration/
  Build-*.ps1` transform scripts (see `docs/engineering/ARCHITECTURE.md` for the full pipeline,
  or `docs/operations/RUNNING-A-LOAD.md` if you just need to run one).
  Regenerated from the current Airtable export each time a `Build-*` script runs — not hand-edited.
- `peo-prod-accounts-<yyyy-MM-dd>.xls` — a production Account export from a Salesforce report.
  **Despite the extension it is an HTML table, not a binary Excel file** (a browser "Export" from
  Salesforce), and it is parsed as such. Source for `Invoke-AccountBootstrap.ps1`, which rebuilds an
  org's Account names + parent hierarchy; `scripts/cleanup/Invoke-SandboxFactoryReset.ps1` offers to run that
  when this file is present. **The filename pattern matters** — it is glob-matched and the newest
  date wins, so dropping in a fresher export is all it takes to refresh the source. Renamed from
  `PEO PROD Accounts 07162026 (1).xls` on 2026-08-13.

Only `.gitkeep` and this `README.md` are tracked in git; everything else here is local to your machine.
