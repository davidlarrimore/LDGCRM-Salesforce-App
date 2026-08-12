---
name: sfdx-metadata-sync
description: Use when pulling Salesforce metadata from the gsa-peo sandbox into sfdx/force-app, extending the retrieval manifest, or deploying local metadata changes back to the sandbox with the Salesforce CLI.
---

# Salesforce metadata sync (gsa-peo)

This project has one SFDX project (`sfdx/`) and one target org, alias `gsa-peo`. Metadata flows
both directions through the Salesforce CLI (`sf`) — retrieve from the sandbox into `sfdx/force-app`,
or deploy local changes back out.

## Before anything: confirm the org

```bash
sf org display --target-org gsa-peo
```

If this fails or looks unfamiliar, stop and check with the user before retrieving or deploying —
don't guess at a different org alias.

## Retrieving metadata

Prefer the manifest-driven sync over ad hoc `--metadata` flags, so retrievals stay repeatable:

```bash
pwsh scripts/metadata/Sync-Metadata.ps1
```

This runs `sf project retrieve start -x manifest/package.xml --target-org gsa-peo` from `sfdx/` and
logs a transcript to `logs/metadata/`.

**Extending coverage:** if you need something not yet in `sfdx/manifest/package.xml`, add a
`<members>` entry to the right `<types>` block (or a new `<types>` block for a metadata type not yet
listed — `CustomObject`, `CustomApplication`, `FlexiPage`, `PermissionSet`, `Layout`, and `Flow` are
already present). `<members>*</members>` is safe for a whole type, including when nothing exists yet.

**One-off retrieve** (e.g. investigating something before deciding whether it belongs in the
manifest):

```bash
cd sfdx
sf project retrieve start --metadata "<Type>:<Name>" --target-org gsa-peo
```

## After retrieving

Review what actually came down before treating it as clean:

```bash
git status sfdx/force-app
git diff sfdx/force-app
```

A retrieve can pull in metadata nobody intended to check in (someone else's WIP directly in the
sandbox, unrelated config drift). Don't blindly commit everything a retrieve touches.

## Deploying local changes

Validate before deploying — a deploy writes to the shared sandbox:

```bash
cd sfdx
sf project deploy validate --source-dir force-app --target-org gsa-peo
sf project deploy start    --source-dir force-app --target-org gsa-peo
```

Treat `deploy start` like any other write to shared state: confirm scope with the user first unless
they've already asked for the deploy explicitly.

## Field-level detail (not deployable metadata)

For a full object/field data dictionary (types, required-ness, relationships), use the describe-based
export instead of reading raw metadata XML:

```bash
pwsh scripts/metadata/Get-LDGCRMDataDictionary.ps1
```

Output CSV lands in `logs/metadata/` (gitignored — it's a full sandbox schema dump, not secret, but
still local run output per the repo's logging convention).
