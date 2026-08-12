# data/

Local-only inputs for the Airtable -> Salesforce migration, gitignored (see root `.gitignore`)
because they can contain PII from Login.gov applicants.

- `airtable-exports/` — one JSON file per Airtable table (`<Table>.json`), written by
  `scripts/data-migration/Get-AirtableExport.ps1`, which pulls straight from the Airtable REST API.
  Each run overwrites these in place — they reflect current Airtable state, not a history of past
  pulls. Requires `AIRTABLE_API_KEY`/`AIRTABLE_BASE_ID` in the repo-root `.env` (copy `.env.example`).
- `mappings/` — Data Loader field-mapping files (`.sdl`) and any other object/field mapping docs
  used to drive loads.

Only `.gitkeep` and this `README.md` are tracked in git; everything else here is local to your machine.
