---
name: sfdx-metadata-sync
description: Use when pulling Salesforce metadata from a GSA PEO org (Dev sandbox by default) into sfdx/force-app, extending the retrieval manifest, or deploying local metadata changes back to the sandbox with the Salesforce CLI.
---

# Salesforce metadata sync

This project has one SFDX project (`sfdx/`) and five registered environments (Dev/QA/UAT/Full/Prod — see `scripts/powershell-scripts/Common.Orgs.ps1`; the Dev sandbox alias is `peodv8dvn`). Metadata flows
both directions through the Salesforce CLI (`sf`) — retrieve from the sandbox into `sfdx/force-app`,
or deploy local changes back out.

## Before anything: confirm the org

```bash
sf org display --target-org peodv8dvn
```

If this fails or looks unfamiliar, stop and check with the user before retrieving or deploying —
don't guess at a different org alias.

## Retrieving metadata

Prefer the manifest-driven sync over ad hoc `--metadata` flags, so retrievals stay repeatable:

```powershell
powershell tools/metadata/Sync-Metadata.ps1
```

This runs `sf project retrieve start -x manifest/package.xml --target-org peodv8dvn` from `sfdx/` and
logs a transcript to `logs/metadata/`.

**Extending coverage:** if you need something not yet in `sfdx/manifest/package.xml`, add a
`<members>` entry to the right `<types>` block (or a new `<types>` block for a metadata type not yet
listed — `CustomObject`, `CustomApplication`, `FlexiPage`, `PermissionSet`, `Layout`, and `Flow` are
already present). `<members>*</members>` is safe for a whole type, including when nothing exists yet.

**One-off retrieve** (e.g. investigating something before deciding whether it belongs in the
manifest):

```bash
cd sfdx
sf project retrieve start --metadata "<Type>:<Name>" --target-org peodv8dvn
```

**Retrieving an Outbound Change Set's exact contents:** Change Sets have no direct Metadata/Tooling
API or `sf` support for listing/querying their component list, and a Setup UI Change Set detail page
can't be fetched (it's behind an authenticated browser session). But a change set's **Name** (the
label, not the Setup URL's ID) works as an unmanaged package name for retrieval:

```bash
cd sfdx
sf project retrieve start --package-name "<Change Set Name>" --target-org peodv8dvn
```

This retrieves into a **new folder named after the package** (e.g. `sfdx/<Change Set Name>/main/default/`),
not into `force-app/`. Merge it in (`robocopy <src>\main\default force-app\main\default /E` handles
this repo's long paths better than `Copy-Item -Recurse`), delete the now-empty source folder, and
regenerate/hand-check `manifest/package.xml` against the merged result before committing.

## After retrieving

Review what actually came down before treating it as clean:

```bash
git status sfdx/force-app
git diff sfdx/force-app
```

A retrieve can pull in metadata nobody intended to check in (someone else's WIP directly in the
sandbox, unrelated config drift). Don't blindly commit everything a retrieve touches.

**Wildcard retrieves (`CustomApplication:*`, `Layout:*`, etc.) pull the entire org**, not just this
app — every standard Salesforce app and every unrelated custom app/layout/flow comes down too. Prefer
the manifest or a change-set/package-name retrieve instead. If a wildcard retrieve does bring in
out-of-scope noise, it'll show up as untracked (`??`) entries in `git status` — confirm nothing tracked
changed, then `git clean -fd -- sfdx/force-app` to drop the untracked noise before merging in the parts
you actually want.

**Long paths:** this environment's disk mount adds a long internal prefix to every path, so retrieved
metadata (deeply nested object/field files, verbose flow/layout names) can exceed Windows' 260-character
path limit. If `git` reports `Filename too long` on `sfdx/force-app`, run
`git config core.longpaths true` and retry; for plain file deletion (not through git), use
`robocopy <empty-dir> <target> /MIR` instead of `Remove-Item -Recurse`.

## Deploying local changes

Validate before deploying — a deploy writes to the shared sandbox:

```bash
cd sfdx
sf project deploy validate --source-dir force-app --target-org peodv8dvn
sf project deploy start    --source-dir force-app --target-org peodv8dvn
```

Treat `deploy start` like any other write to shared state: confirm scope with the user first unless
they've already asked for the deploy explicitly.

## Field-level detail (not deployable metadata)

For a full object/field data dictionary (types, required-ness, relationships), use the describe-based
export instead of reading raw metadata XML:

```powershell
powershell tools/metadata/Get-LDGCRMDataDictionary.ps1
```

Output CSV lands in `logs/metadata/` (gitignored — it's a full sandbox schema dump, not secret, but
still local run output per the repo's logging convention).
