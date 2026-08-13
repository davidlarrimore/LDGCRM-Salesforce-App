# Shared helpers for the Airtable -> Salesforce data-migration scripts
# (scripts/data-migration/Build-*.ps1). Dot-source both this file and
# scripts/common/Common.ps1 from any script in this category:
#   . (Join-Path $PSScriptRoot "..\common\Common.ps1")
#   . (Join-Path $PSScriptRoot "Common.DataMigration.ps1")
#
# Targets Windows PowerShell 5.1 (no PowerShell 7-only syntax: no ??, ?., ternary
# ?:, -AsHashtable, -Parallel, or multi-argument Join-Path).

function Get-AirtableExportPath {
    <#
        Resolves the path to a single table's pulled JSON export
        (data/airtable-exports/<Label>.json), as written by
        Get-AirtableExport.ps1. Does not read the file.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    return Join-Path (Join-Path (Get-RepoRoot) "data\airtable-exports") "$Label.json"
}

function Import-AirtableTable {
    <#
        Reads data/airtable-exports/<Label>.json and returns the array of
        Airtable records (each a PSCustomObject with .id, .createdTime,
        .fields). Throws a clear error pointing at Get-AirtableExport.ps1
        if the export hasn't been pulled yet.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $Path = Get-AirtableExportPath -Label $Label

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "No Airtable export found for '$Label' at $Path. Run scripts/data-migration/Get-AirtableExport.ps1 first."
    }

    # PS 5.1's ConvertFrom-Json has no -Depth parameter (PS6+ only) but
    # defaults to a max depth of 100, well beyond these records' nesting.
    return @(Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}

function Get-SalesforceLoadDirectory {
    <#
        Ensures/returns data/salesforce-loads/, where transform scripts
        write the CSVs staged for the Data Loader CLI. Gitignored under
        the same data/** rule as airtable-exports/ and mappings/.
    #>
    $LoadDir = Join-Path (Get-RepoRoot) "data\salesforce-loads"

    if (-not (Test-Path -LiteralPath $LoadDir)) {
        New-Item -ItemType Directory -Path $LoadDir -Force | Out-Null
    }

    return $LoadDir
}

function Export-DataLoaderCsv {
    <#
        Writes objects to CSV in a form the Data Loader CLI can read
        reliably: UTF-8 *without* a byte-order mark. PowerShell 5.1's
        Export-Csv -Encoding UTF8 always writes a BOM, which some Data
        Loader CLI versions choke on (a leading BOM gets treated as part
        of the first column header), so this writes manually instead.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ($InputObject.Count -eq 0) {
        throw "Export-DataLoaderCsv: refusing to write an empty CSV to $Path (Data Loader needs at least a header row - pass an explicit empty-with-columns object if that's really intended)."
    }

    $CsvLines = $InputObject | ConvertTo-Csv -NoTypeInformation
    $Utf8NoBom = New-Object System.Text.UTF8Encoding $false

    [System.IO.File]::WriteAllLines($Path, $CsvLines, $Utf8NoBom)
}

function Invoke-SalesforceQuery {
    <#
        Runs a SOQL query via `sf data query --json` and returns the
        result's record array (empty array if none). Read-only - safe to
        call outside the sfdx-sandbox-ops confirmation gate, which only
        applies to writes/deletes.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Soql,

        [Parameter(Mandatory = $true)]
        [string]$OrgAlias,

        [string]$ApiVersion = "67.0"
    )

    $RawResult = & sf data query `
        --target-org $OrgAlias `
        --api-version $ApiVersion `
        --query $Soql `
        --json

    if ($LASTEXITCODE -ne 0) {
        throw "Salesforce CLI query failed (exit $LASTEXITCODE): $Soql"
    }

    $JsonResult = $RawResult | ConvertFrom-Json

    if ($JsonResult.status -ne 0) {
        $ErrorMessage = $JsonResult.message

        if ([string]::IsNullOrWhiteSpace($ErrorMessage)) {
            $ErrorMessage = "Unknown Salesforce CLI error."
        }

        throw $ErrorMessage
    }

    if ($null -eq $JsonResult.result.records) {
        return @()
    }

    # CALLER CONTRACT: always wrap the call site in @(), e.g.
    #     $Rows = @(Invoke-SalesforceQuery -Soql ... -OrgAlias ...)
    # PowerShell unwraps a single-element array back to a bare scalar when a
    # function returns it through the output stream, so an unwrapped caller
    # doing $Rows.Count on a genuinely single-row result silently gets $null
    # (hit 2026-08-13 on a RecordType lookup that legitimately matched one row).
    #
    # This was first "fixed" with Write-Output -NoEnumerate, which traded one
    # failure mode for a worse one: -NoEnumerate emits the array as a SINGLE
    # object, so any caller following the idiomatic @() convention got a
    # nested 1-element array wrapping the real results - .Count == 1 no matter
    # how many rows came back, with no error. That silently reported "1 Partner
    # Account exists" against 74 real rows (caught 2026-08-13 only because the
    # number was obviously wrong). Returning normally + @() at every call site
    # is correct in all three cases (0 rows, 1 row, many) and is idempotent, so
    # it can't be double-applied by mistake.
    return $JsonResult.result.records
}

function Get-CleanContactEmail {
    <#
        Airtable's Contacts.Email column is dirty in three ways that all have
        to be handled before the value can be used as a match key or written to
        Salesforce's Email field:
          - 285 values carry leading/trailing whitespace
          - 28 embed a name and/or phone alongside the address, e.g.
            "Dave Martin (David.Martin@onrr.gov -303.231.3797)"
          - 2 carry a trailing non-ASCII character
        Returns the bare address in lower case, or "" if none can be found.
        Lower-cased deliberately: this doubles as the identity key for merging
        duplicate Contact rows, and Salesforce external-ID matching is
        case-insensitive anyway.
    #>
    param($Value)

    if (-not $Value) { return "" }

    $Text = "$Value".Trim()
    # Strip characters that are never part of an address but do appear
    # wrapped around one in this data.
    $Text = $Text -replace '[<>()]', ' '

    # First token that looks like an address wins.
    if ($Text -match '([A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,})') {
        return $Matches[1].Trim().ToLower()
    }

    return ""
}

function Get-AirtableContactGroups {
    <#
        Collapses Airtable Contact rows into one group per real person.

        WHY THIS EXISTS AND WHY IT'S SHARED: Airtable has no person-to-
        Application junction, so the same human is entered once per
        association - one row carries their name and roles, the others are
        stubs with a blank name and a different Applications list. 47 of the
        61 duplicate-email groups differ precisely by that Applications list.
        Salesforce HAS the junction (LDGCRM_Application_Contact__c), so
        migrating 1:1 would import a workaround the target schema doesn't need
        and split one person into up to 4 Contacts.

        This lives in the shared module rather than in Build-ContactLoad.ps1
        because the Application-Contact junction chunk must map EVERY Airtable
        Contact record ID onto whichever Contact actually got created. If that
        chunk re-derived the grouping itself, the two implementations could
        drift and the junction would point at Contacts that don't exist.

        Rows are NOT merged when:
          - there's no usable email (nothing to match on), or
          - the group holds two or more DIFFERENT non-empty names, which means
            either a typo'd duplicate or a genuinely shared mailbox (e.g.
            enterpriseservicedesk@dol.gov is used by both "EBSA Lost & Found
            Help Desk Information" and "ENT BPMS Contact Center"). Auto-merging
            those would silently discard one identity, so they stay separate
            and get flagged for a human.

        Returns an array of PSCustomObjects:
          ExternalId      - the Airtable rec... ID chosen to represent the group
                            (the row carrying a Name when there is one, so the
                            surviving record is the most complete)
          MemberRecordIds - every Airtable rec... ID folded into this group
          Rows            - the underlying Airtable records
          NameConflict    - $true when the group was left unmerged because its
                            names disagree
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Records
    )

    $ByEmail = @{}
    $NoEmail = [System.Collections.Generic.List[object]]::new()

    foreach ($Row in $Records) {
        $Email = Get-CleanContactEmail $Row.fields.Email
        if (-not $Email) {
            $NoEmail.Add($Row)
            continue
        }
        if (-not $ByEmail.ContainsKey($Email)) {
            $ByEmail[$Email] = [System.Collections.Generic.List[object]]::new()
        }
        $ByEmail[$Email].Add($Row)
    }

    $Groups = [System.Collections.Generic.List[object]]::new()

    foreach ($Email in $ByEmail.Keys) {
        $Rows = $ByEmail[$Email]

        # Only PRIMARY-source names can create a name conflict. The Contacts
        # table is authoritative for identity; a differing spelling in a
        # secondary source (Opportunity Contacts) must not fracture a group that
        # the primary source already established as one person.
        #
        # This is the same idempotency concern as survivor selection below, and
        # it bit for real: an Opportunity Contacts row for
        # Stephen.Wilford@opm.gov carried a different name, tripped the conflict
        # branch, split an already-merged group, and re-keyed a Contact that had
        # already been loaded. Scoping conflict detection to the primary source
        # keeps Contacts-only behaviour byte-identical to before this second
        # source existed.
        $NameRows = @($Rows | Where-Object { -not $_.__IsSecondarySource })
        if ($NameRows.Count -eq 0) { $NameRows = @($Rows) }

        $DistinctNames = @($NameRows | ForEach-Object { $_.fields.Name } |
            Where-Object { $_ } | ForEach-Object { "$_".Trim() } | Sort-Object -Unique)

        if ($DistinctNames.Count -gt 1) {
            # Ambiguous identity - keep every row as its own Contact.
            foreach ($Row in $Rows) {
                $Groups.Add([PSCustomObject]@{
                    ExternalId      = $Row.id
                    MemberRecordIds = @($Row.id)
                    Rows            = @($Row)
                    NameConflict    = $true
                })
            }
            continue
        }

        # Choosing the survivor: PRIMARY-SOURCE ROWS ALWAYS WIN.
        #
        # This ordering is load-bearing for idempotency, not a style choice.
        # The survivor's Airtable id becomes the Salesforce Contact's
        # LDGCRM_External_ID__c. Once a Contact is loaded, anything that changes
        # which row survives changes that external ID and the next upsert creates
        # a DUPLICATE Contact instead of matching the existing one.
        #
        # A second source (Opportunity Contacts) was added after Contact had
        # already been loaded from the Contacts table alone. Preferring a
        # named row outright would hand primacy to an Opportunity Contacts row
        # whenever the Contacts-table row had a blank Name - silently
        # re-keying an already-migrated Contact. So: any primary-source row
        # beats every secondary-source row, and Name only breaks ties WITHIN a
        # source.
        $PrimaryCandidates = @($Rows | Where-Object { -not $_.__IsSecondarySource })
        if ($PrimaryCandidates.Count -eq 0) { $PrimaryCandidates = @($Rows) }

        $Primary = $PrimaryCandidates | Where-Object { $_.fields.Name } | Select-Object -First 1
        if (-not $Primary) { $Primary = $PrimaryCandidates | Sort-Object id | Select-Object -First 1 }

        $Groups.Add([PSCustomObject]@{
            ExternalId      = $Primary.id
            MemberRecordIds = @($Rows | ForEach-Object { $_.id })
            Rows            = @($Rows)
            NameConflict    = $false
        })
    }

    foreach ($Row in $NoEmail) {
        $Groups.Add([PSCustomObject]@{
            ExternalId      = $Row.id
            MemberRecordIds = @($Row.id)
            Rows            = @($Row)
            NameConflict    = $false
        })
    }

    # CALLER CONTRACT: wrap the call site in @(), same as Invoke-SalesforceQuery
    # above. Returning normally (not Write-Output -NoEnumerate) is deliberate -
    # -NoEnumerate emits the whole array as ONE object, so an @() caller gets a
    # nested 1-element array. That exact bug was written here first and caught
    # only because the group count came back as 1 against 1,599 input rows.
    return $Groups.ToArray()
}

function ConvertTo-ContactShapedRecord {
    <#
        Projects an Airtable "Opportunity Contacts" row into the same shape
        Get-AirtableContactGroups expects from a Contacts-table row, so both
        sources can be merged into one identity per person.

        WHY THIS EXISTS: the Opportunity Contacts table names its columns
        differently ("Contact" holds the person's name, where the Contacts table
        uses "Name") and, critically, has NO link to the Contacts table at all -
        no rec... id, just a name string and an email. 348 of its 520 rows
        reference people who appear nowhere in the Contacts table, so they have
        to become Contacts in their own right or their OpportunityContactRole
        rows can never be created.

        Every projected record is stamped __IsSecondarySource = $true. That flag
        is what stops a row from this table ever becoming the surviving record
        of a merge group that also contains a real Contacts-table row - which
        would re-key an already-loaded Contact and duplicate it on the next
        upsert. See the survivor-selection block in Get-AirtableContactGroups.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Record
    )

    return [PSCustomObject]@{
        id                    = $Record.id
        createdTime           = $Record.createdTime
        __IsSecondarySource   = $true
        fields                = [PSCustomObject]@{
            Name  = $Record.fields.'Contact'
            Email = $Record.fields.Email
            Phone = $Record.fields.Phone
            Title = $Record.fields.'Role'   # free-text job title here, NOT the OpportunityContactRole.Role picklist
        }
    }
}
