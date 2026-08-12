# data/

Local-only inputs for the Airtable -> Salesforce migration, gitignored (see root `.gitignore`)
because they can contain PII from Login.gov applicants.

- `airtable-exports/` — raw exports pulled from Airtable, ahead of transformation/loading.
- `mappings/` — Data Loader field-mapping files (`.sdl`) and any other object/field mapping docs
  used to drive loads.

Only `.gitkeep` and this `README.md` are tracked in git; everything else here is local to your machine.
