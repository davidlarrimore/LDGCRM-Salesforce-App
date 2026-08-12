# logs/

Run output from `scripts/`, gitignored (see root `.gitignore`) because it can contain PII pulled
from the sandbox or Airtable. Structure mirrors `scripts/`:

- `metadata/` — transcripts and CSVs from `scripts/metadata/*.ps1`
- `cleanup/` — transcripts and exported-ID/summary CSVs from `scripts/cleanup/*.ps1`
- `data-migration/` — transcripts and Data Loader logs from `scripts/data-migration/*.ps1` (once added)

Only `.gitkeep` and this `README.md` are tracked in git; everything else here is local to your machine.
