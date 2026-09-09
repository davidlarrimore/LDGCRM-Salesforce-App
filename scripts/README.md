# scripts/ — Sprint 2

This folder is where Sprint 2's work lives.

## What is here

- **[`docs/deployment.md`](docs/deployment.md)** — the things a change set
  **cannot carry**, and therefore have to be done by hand in every target org.
  Read this before building or receiving a Sprint 2 change set. It leads with the
  `OpportunityContactRole.Role` values, which are deactivated rather than missing
  and will silently corrupt a load if they are not reactivated.
- **[`docs/integration-user.md`](docs/integration-user.md)** — standing up the P3
  Partner Portal API user: the permission set license goes on **before** the
  permission set, because the license is what makes `ApiUserOnly` grantable. None
  of the user-side setup survives a sandbox refresh.

## What used to be here

Through Sprint 1 this was the **operations bundle**: a self-contained PowerShell
pipeline that migrated Login.gov's Airtable base into Salesforce, packaged so the
GSA Salesforce Operations team could drop it into their own repository as a plain
`/scripts` folder and run it against QA, a full sandbox, and finally production.

That migration is done. Sprint 1 shipped to production on 2026-09-08.

The bundle is archived at [`archive/sprint_1_scripts.zip`](../archive/sprint_1_scripts.zip)
— code and operator runbooks only. Its `data/`, `logs/` and `.env` are excluded
from that archive because they are applicant PII and a live Airtable token; the
data itself was moved to [`data/`](../data/) at the repository root and the run
history to [`logs/`](../logs/).

## Where the loading tools went

They were **not** deleted. They were refactored into
[`tools/data-loading/`](../tools/data-loading/) and narrowed to what is still
needed after go-live: rebuilding a **developer sandbox** so the app can be worked
on. Every `-Environment` there is `[ValidateSet("Dev","QA")]`, so UAT, Full and
production are rejected at parameter binding rather than by convention.

## Before you fill this folder

The old bundle carried its own `.gitignore`, and that file — not the repository
root's — was the authority protecting applicant PII. It travelled with the folder
so the protection survived the hand-off to Operations.

**That file is gone with the bundle.** If Sprint 2 puts anything here that writes
data or holds a credential, add the ignore rules in the same change. An output
folder nobody thought about is how PII gets committed.
