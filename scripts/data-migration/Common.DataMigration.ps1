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

function Resolve-ProdAccountExportPath {
    <#
        Finds the production Account export used to bootstrap a fresh org's
        Account tree: data/peo-prod-accounts-<yyyy-MM-dd>.xls.

        Glob-matched rather than hard-coded so dropping in a newer dated export
        is all it takes to refresh the bootstrap source - the newest filename
        wins (the dates are ISO, so a plain descending sort is chronological).
        The file was originally delivered as "PEO PROD Accounts 07162026 (1).xls";
        it was renamed 2026-08-13 to this convention.

        Returns "" when no export is present. Callers treat that as "the
        bootstrap option isn't available", not as an error - the cleanup script
        relies on this to decide whether to even offer it.
    #>

    $DataDir = Join-Path (Get-RepoRoot) "data"

    if (-not (Test-Path -LiteralPath $DataDir)) {
        return ""
    }

    # Not named $Matches - that's PowerShell's automatic -match variable.
    $Candidates = @(Get-ChildItem -LiteralPath $DataDir -Filter "peo-prod-accounts-*.xls" -File -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending)

    if ($Candidates.Count -eq 0) {
        return ""
    }

    return $Candidates[0].FullName
}

function Import-ProdAccountExport {
    <#
        Parses the production Account export into one object per row.

        FORMAT: despite the .xls extension this is an HTML table - a browser
        "Export" from a Salesforce report, not a binary Excel file. Parsed with
        regex accordingly.

        TWO TRAPS IN THIS FILE, both found 2026-08-13 by checking what the
        columns actually contain rather than trusting their headers:

        1. THE "Account ID" COLUMN IS NOT THE ROW'S OWN ACCOUNT ID. The same
           Id appears on completely unrelated rows - 378 collisions across
           1,369 rows, e.g. 001SJ00000HVpEq is given for both "Office of Human
           Resources and Administration" (under Veterans Affairs) and "Office of
           Congressional Workplace Rights" (under U.S. Congress). It is a
           misaligned report column. It is therefore NOT returned by this
           function at all: nothing may key off it. (Prod Ids would be useless
           in a sandbox anyway, but a caller could easily have used it as a
           dedupe key and silently collapsed unrelated Accounts.)

        2. "Parent Account" IS AUTHORITATIVE; the Level 1/2/3 columns are not.
           They agree for 1,365 of 1,369 rows. The 4 that differ are the ones
           that matter: 3 rows name themselves as their own parent (Department
           of Defense, District of Columbia, Office of the Director of National
           Intelligence) and 1 is a depth-4 row ("Defense Technical Information
           Center") whose real parent sits below the deepest ancestor column.
           So ParentName comes from "Parent Account", and the ancestor columns
           are kept only as disambiguation context for duplicate names.

        Self-parenting rows are returned with ParentName = "" and
        IsSelfParent = $true. Salesforce rejects a self-referencing ParentId
        outright, so they can only ever be loaded as roots.

        Returns PSCustomObjects:
          Name          - the Account name
          ParentName    - parent Account name, "" for a root
          Ancestors     - @(Level 1, Level 2, Level 3) minus blanks, outermost
                          first; context only
          AncestorPath  - "A > B > C > Name", lower-cased; disambiguates rows
                          whose Name is duplicated elsewhere in the export
          Level         - Salesforce's "Account Level" label, verbatim
          RecordType    - "Account Record Type" verbatim (all Federal today)
          OwnerName     - "Account Owner" DISPLAY NAME, not an email. Not
                          currently loaded; see Invoke-AccountBootstrap.ps1.
          IsSelfParent  - see above
          SourceRow     - 1-based row number in the export, for review CSVs
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Production Account export not found: $Path"
    }

    $Html = Get-Content -LiteralPath $Path -Raw -Encoding UTF8

    $AllRows = [System.Collections.Generic.List[string[]]]::new()

    foreach ($RowMatch in [regex]::Matches($Html, '<tr>(.*?)</tr>')) {
        $CellMatches = [regex]::Matches($RowMatch.Groups[1].Value, '<t[hd][^>]*>(.*?)</t[hd]>')
        # @() around the pipeline: a single-cell row would otherwise come back
        # as a bare string and index by character.
        $Cells = @($CellMatches | ForEach-Object { ConvertFrom-ProdExportHtmlEntities ($_.Groups[1].Value.Trim()) })
        $AllRows.Add($Cells)
    }

    if ($AllRows.Count -lt 2) {
        throw "Expected a header row plus data rows in $Path, found $($AllRows.Count) row(s) total."
    }

    $Header = $AllRows[0]

    # Resolved by header name, not by position: this is a report export, and a
    # report's columns get reordered by whoever runs it next.
    $Index = @{}
    foreach ($Column in @("Account Name", "Parent Account", "Account Level", "Account Record Type",
                          "Account Owner", "Level 1 Account", "Level 2 Account", "Level 3 Account")) {
        $Found = [array]::IndexOf($Header, $Column)

        if ($Found -lt 0) {
            throw "Column '$Column' not found in $Path. Header: $($Header -join ' | ')"
        }

        $Index[$Column] = $Found
    }

    $Rows = [System.Collections.Generic.List[object]]::new()

    for ($i = 1; $i -lt $AllRows.Count; $i++) {
        $Cells = $AllRows[$i]
        $Name = $Cells[$Index["Account Name"]]

        if ([string]::IsNullOrWhiteSpace($Name)) {
            continue
        }

        $Name = $Name.Trim()
        $ParentName = "$($Cells[$Index['Parent Account']])".Trim()

        $IsSelfParent = $false

        if ($ParentName -and $ParentName -eq $Name) {
            $IsSelfParent = $true
            $ParentName = ""
        }

        $Ancestors = @(@(
            $Cells[$Index["Level 1 Account"]],
            $Cells[$Index["Level 2 Account"]],
            $Cells[$Index["Level 3 Account"]]
        ) | ForEach-Object { "$_".Trim() } | Where-Object { $_ })

        # The Level 1 column repeats the row's own name on root rows, which
        # would otherwise duplicate it in the path.
        $PathParts = @($Ancestors | Where-Object { $_ -ne $Name })
        $PathParts += $Name

        $Rows.Add([PSCustomObject]@{
            Name         = $Name
            ParentName   = $ParentName
            Ancestors    = $Ancestors
            AncestorPath = ($PathParts -join " > ").ToLowerInvariant()
            Level        = "$($Cells[$Index['Account Level']])".Trim()
            RecordType   = "$($Cells[$Index['Account Record Type']])".Trim()
            OwnerName    = "$($Cells[$Index['Account Owner']])".Trim()
            IsSelfParent = $IsSelfParent
            SourceRow    = $i
        })
    }

    # CALLER CONTRACT: wrap in @() - same reason as Invoke-SalesforceQuery.
    return $Rows.ToArray()
}

function ConvertFrom-ProdExportHtmlEntities {
    <#
        The report export HTML-escapes cell text ("Office of Oceanic &amp;
        Atmospheric Research"). Unescaping matters for more than cosmetics:
        these strings are matched against Salesforce Account Names, so a stray
        &amp; is a failed parent lookup.
    #>
    param([string]$Text)

    if (-not $Text) { return $Text }

    return $Text -replace '&amp;', '&' -replace '&lt;', '<' -replace '&gt;', '>' `
                 -replace '&quot;', '"' -replace '&#39;', "'" -replace '&nbsp;', ' '
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

    # SILENT TRUNCATION GUARD. `sf data query` follows queryMore itself, but a
    # partial result is indistinguishable from a small one at the call site -
    # every caller here does .Count on the result and reports it as fact. A
    # truncated Account query in particular would make Invoke-AccountBootstrap
    # re-insert Accounts it simply didn't see. Cheap to check, impossible to
    # notice if it's missing.
    $Returned = @($JsonResult.result.records).Count
    $Total = [int]$JsonResult.result.totalSize

    if ($Returned -lt $Total) {
        throw ("Query returned $Returned of $Total records - the result set was truncated, so any count " +
               "derived from it would be wrong. Narrow the query or page it explicitly. SOQL: $Soql")
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

function Resolve-SalesforceOwnerIds {
    <#
        Resolves a set of Airtable owner email addresses to Salesforce User
        Ids, for the record-ownership rule agreed 2026-08-13:

            "If the Airtable owner has a matching Salesforce User, assign the
             record to them. If not, fall back to a single default owner."

        This is the ONLY place that mapping is implemented. It was previously
        inline in Build-PartnerAccountLoad.ps1 and had two defects that are
        fixed here, both of which silently produce a WRONG owner rather than
        an error:

          1. NO IsActive FILTER. Salesforce rejects an inactive User as an
             OwnerId, so an inactive match is not a match - it has to fall
             back like any other unresolved owner. gsa-peo has real cases:
             7 of the 40 distinct Meeting Leaders resolve only to a
             deactivated User.
          2. DUPLICATE EMAILS WERE LAST-WRITE-WINS. moncef.belyamani@gsa.gov
             has TWO User records in gsa-peo - one active, one inactive - and
             a plain hashtable assignment in query order could land on either.
             Filtering to IsActive resolves that particular case outright;
             genuinely ambiguous ones (2+ ACTIVE users on one address) are
             reported to the caller instead of being picked silently.
          3. NO UserType FILTER - found 2026-08-13, and the most expensive of
             the set because IsActive does not imply "can own a record".
             Shaunte Brown is an ACTIVE user on the "GSA Chatter Free User"
             profile (UserType = CsnOnly). Chatter Free / portal / community
             users cannot own standard or custom object records at all, so the
             resolver handed back a perfectly valid-looking User Id and the
             LOAD failed - 150 of 688 Applications rejected with:
                 OP_WITH_INVALID_USER_TYPE_EXCEPTION: Operation not valid for
                 this user type
             The message names no field and no user, so it reads like a
             permissions problem rather than an owner problem. This org has
             ~2,637 Chatter-only users, so the exposure is not incidental.
             Restricted to UserType = 'Standard': of the 14 distinct owners
             this migration assigns, 13 are Standard and exactly 1 was CsnOnly,
             so this costs nothing real and that one owner now falls back
             correctly. Revisit only if a legitimate portal-user owner ever
             appears.

        SANDBOX EMAIL SUFFIX: Salesforce appends ".invalid" to every user's
        Email when a sandbox is refreshed, so "jane.doe@gsa.gov" in Airtable is
        "jane.doe@gsa.gov.invalid" in gsa-peo. Both forms are queried, so this
        works unchanged against production, where the suffix isn't present.

        Returns a PSCustomObject:
          IdByEmail - hashtable, lower-cased plain email -> User Id. Contains
                      ONLY confidently-resolved active users; an email absent
                      from it is the caller's signal to apply the fallback.
          Ambiguous - emails matching more than one ACTIVE User, for a review
                      CSV. These are deliberately left OUT of IdByEmail rather
                      than guessed at.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Emails,

        [Parameter(Mandatory = $true)]
        [string]$OrgAlias,

        [string]$ApiVersion = "67.0"
    )

    $Result = [PSCustomObject]@{
        IdByEmail = @{}
        Ambiguous = @()
    }

    $Distinct = @($Emails |
        Where-Object { $_ } |
        ForEach-Object { "$_".Trim().ToLower() } |
        Where-Object { $_ } |
        Sort-Object -Unique)

    # An empty IN () list is a SOQL syntax error, not an empty result set.
    if ($Distinct.Count -eq 0) { return $Result }

    # Collect active matches per email first, so ambiguity can be detected
    # across the whole result rather than overwritten as rows stream past.
    $ActiveIdsByEmail = @{}

    # Chunked so a large owner set can't blow the SOQL statement length limit.
    $ChunkSize = 200

    for ($Offset = 0; $Offset -lt $Distinct.Count; $Offset += $ChunkSize) {
        $Last = [Math]::Min($Offset + $ChunkSize, $Distinct.Count) - 1
        $Chunk = @($Distinct[$Offset..$Last])

        $Literals = [System.Collections.Generic.List[string]]::new()

        foreach ($Email in $Chunk) {
            # Escape embedded quotes/backslashes rather than assuming an
            # address can't contain them.
            $Safe = $Email -replace '\\', '\\\\' -replace "'", "\'"
            $Literals.Add("'$Safe'")
            $Literals.Add("'$Safe.invalid'")
        }

        # UserType = 'Standard' is NOT cosmetic - see trap 4 in the header.
        # An active Chatter Free user matches on email and is rejected at LOAD
        # time with OP_WITH_INVALID_USER_TYPE_EXCEPTION.
        $Soql = "SELECT Id, Email FROM User WHERE IsActive = true AND UserType = 'Standard' AND Email IN (" +
            ($Literals -join ",") + ")"

        # @() per the Invoke-SalesforceQuery caller contract - a single match
        # would otherwise unwrap to a bare scalar and break .Count/foreach.
        $Users = @(Invoke-SalesforceQuery -Soql $Soql -OrgAlias $OrgAlias -ApiVersion $ApiVersion)

        foreach ($User in $Users) {
            $Plain = ("$($User.Email)" -replace '\.invalid$', '').ToLower()

            if (-not $ActiveIdsByEmail.ContainsKey($Plain)) {
                $ActiveIdsByEmail[$Plain] = [System.Collections.Generic.List[string]]::new()
            }

            if (-not $ActiveIdsByEmail[$Plain].Contains($User.Id)) {
                $ActiveIdsByEmail[$Plain].Add($User.Id)
            }
        }
    }

    $AmbiguousEmails = [System.Collections.Generic.List[string]]::new()

    foreach ($Email in $ActiveIdsByEmail.Keys) {
        $Ids = $ActiveIdsByEmail[$Email]

        if ($Ids.Count -eq 1) {
            $Result.IdByEmail[$Email] = $Ids[0]
        }
        else {
            # Two or more ACTIVE users share this address. Picking one would
            # assign real records to a possibly-wrong person, so it falls back
            # and gets surfaced for a human instead.
            $AmbiguousEmails.Add($Email)
        }
    }

    $Result.Ambiguous = @($AmbiguousEmails)

    return $Result
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

function Resolve-SalesforceOwnerIdsByName {
    <#
        The display-name counterpart to Resolve-SalesforceOwnerIds, for the one
        source that doesn't carry emails: the production Account export's
        "Account Owner" column holds a User's DISPLAY NAME ("SNA MSadi"), never
        an address.

        USE THIS ONLY WHERE THERE IS NO EMAIL. A display name is a weaker join
        than an email - it is not unique, not stable, and not an identifier - so
        the guards matter more here than in the email version, not less. Both
        failure modes are real in this data, not hypothetical:
          - "Matthew Taylor" matches TWO Users in the Dev sandbox (one active,
            one inactive);
          - "SNA JTScholz" matches two, both inactive.

        Same contract as the email resolver: active Users only (Salesforce
        refuses to assign a record to an inactive one), and a name matching
        several ACTIVE Users is reported rather than picked.

        Returns a PSCustomObject:
          IdByName  - hashtable, name -> User Id (PowerShell hashtables are
                      case-insensitive, which suits "GABRIEL VORLETO" appearing
                      in an export against "Gabriel Vorleto" in Salesforce).
          Ambiguous - names matching more than one ACTIVE User.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Names,

        [Parameter(Mandatory = $true)]
        [string]$OrgAlias,

        [string]$ApiVersion = "67.0"
    )

    $Result = [PSCustomObject]@{
        IdByName  = @{}
        Ambiguous = @()
    }

    $Distinct = @($Names |
        Where-Object { $_ } |
        ForEach-Object { "$_".Trim() } |
        Where-Object { $_ } |
        Sort-Object -Unique)

    if ($Distinct.Count -eq 0) { return $Result }

    $ActiveIdsByName = @{}
    $ChunkSize = 200

    for ($Offset = 0; $Offset -lt $Distinct.Count; $Offset += $ChunkSize) {
        $Last = [Math]::Min($Offset + $ChunkSize, $Distinct.Count) - 1
        $Chunk = @($Distinct[$Offset..$Last])

        $Literals = @($Chunk | ForEach-Object {
            "'" + ($_ -replace '\\', '\\\\' -replace "'", "\'") + "'"
        })

        # UserType = 'Standard' for the same reason as the email resolver: an
        # active Chatter Free / portal user cannot own a record, and the load
        # fails with OP_WITH_INVALID_USER_TYPE_EXCEPTION rather than the
        # resolver reporting anything. This path assigns Account.OwnerId during
        # the bootstrap, where the same trap applies.
        $Soql = "SELECT Id, Name FROM User WHERE IsActive = true AND UserType = 'Standard' AND Name IN (" +
            ($Literals -join ",") + ")"

        $Users = @(Invoke-SalesforceQuery -Soql $Soql -OrgAlias $OrgAlias -ApiVersion $ApiVersion)

        foreach ($User in $Users) {
            $Key = "$($User.Name)"
            if (-not $ActiveIdsByName.ContainsKey($Key)) {
                $ActiveIdsByName[$Key] = [System.Collections.Generic.List[string]]::new()
            }
            if (-not $ActiveIdsByName[$Key].Contains($User.Id)) {
                $ActiveIdsByName[$Key].Add($User.Id)
            }
        }
    }

    $AmbiguousNames = [System.Collections.Generic.List[string]]::new()

    foreach ($Name in $ActiveIdsByName.Keys) {
        if ($ActiveIdsByName[$Name].Count -eq 1) {
            $Result.IdByName[$Name] = $ActiveIdsByName[$Name][0]
        }
        else {
            $AmbiguousNames.Add($Name)
        }
    }

    $Result.Ambiguous = @($AmbiguousNames)

    return $Result
}

function Resolve-FallbackOwnerId {
    <#
        Resolves the single fallback owner every transform assigns when a
        record's own owner can't be determined, and THROWS if it can't be
        resolved.

        WHY IT THROWS INSTEAD OF DEGRADING: the fallback was originally an empty
        OwnerId, which makes Salesforce assign the record to whoever ran the
        load. That was correct while the loader and the intended owner were the
        same person. They are not any more - GSA IT Operations runs this in
        production, and the agreed fallback owner is a named Partnerships person
        - so an empty OwnerId would silently hand thousands of records to
        whichever engineer happened to run the job. Since these objects use
        org-wide-default-restricted sharing with owner-based rules, that
        decides who can SEE the records, not just a label. Failing the run is
        strictly better than discovering it afterwards.

        KNOWN TRADE-OFF: because the fallback is now written explicitly rather
        than left blank, a re-run RE-ASSERTS it. A record manually reassigned in
        Salesforce, and still owned by the fallback owner's records set, will be
        pushed back to the fallback owner on the next load. The blank-OwnerId
        design preserved such changes; a named fallback owner cannot. Documented
        in docs/engineering/TRANSFORMATION-RULES.md's "Record ownership" section.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Email,

        [Parameter(Mandatory = $true)]
        [string]$OrgAlias,

        [string]$ApiVersion = "67.0"
    )

    if ([string]::IsNullOrWhiteSpace($Email)) {
        throw "No fallback owner email supplied. Pass -FallbackOwnerEmail; there is no safe default."
    }

    $Lookup = Resolve-SalesforceOwnerIds -Emails @($Email) -OrgAlias $OrgAlias -ApiVersion $ApiVersion
    $Key = $Email.Trim().ToLower()

    if (-not $Lookup.IdByEmail.ContainsKey($Key)) {
        throw ("FALLBACK OWNER NOT RESOLVED: '$Email' does not match an ACTIVE Salesforce User in " +
               "'$OrgAlias' (checked with and without the sandbox '.invalid' suffix). Every record " +
               "whose own owner can't be determined would otherwise be assigned to whoever runs the " +
               "load. Provision or correct that user, or pass a different -FallbackOwnerEmail. " +
               "Nothing was written.")
    }

    return $Lookup.IdByEmail[$Key]
}

function Get-EmailDomain {
    <#
        Returns the lower-cased domain part of an address, or "" if there
        isn't one. Expects an address already cleaned by Get-CleanContactEmail -
        the raw Airtable Email column embeds names and phone numbers on 28 rows,
        which would otherwise produce a nonsense "domain".
    #>
    param([string]$Email)

    if (-not $Email) { return "" }

    if ($Email -match '@([^@\s]+)$') {
        return $Matches[1].Trim().ToLower()
    }

    return ""
}

# =============================================================================
# DERIVING A NAME FROM AN EMAIL ADDRESS
# =============================================================================
# Only 491 of 1,599 Airtable Contact rows carry a Name, and LastName is required
# in Salesforce. Everything below exists to turn an address into a real
# FirstName/LastName where the address genuinely encodes one, and to STOP where
# it doesn't - an invented name is worse than an honest placeholder, because it
# looks like data.
#
# Every rule here was derived by measuring the actual 970-row population on
# 2026-08-13, not assumed. The measurements are recorded in
# docs/engineering/TRANSFORMATION-RULES.md's Contact section.

# Local parts that identify a ROLE or SHARED MAILBOX rather than a person:
# support@, tracs-helpdesk@, fmcsa_api@, waso_youth_partner_portal@ and so on.
# 56 of 970. These are deliberately NOT split into a first/last name - doing so
# invents a person called "Tracs Helpdesk". They keep the local part verbatim as
# LastName and are reported for a human decision on whether they belong in the
# CRM at all.
$Script:RoleMailboxPattern =
    '(^|[._-])(' +
    'info|support|helpdesk|help|desk|servicedesk|admin|contact|noreply|no-reply|' +
    'donotreply|sales|team|group|service|services|office|hq|mail|inbox|general|' +
    'inquiries|enquiries|webmaster|postmaster|security|privacy|legal|billing|' +
    'accounts|payroll|itsupport|feedback|press|media|marketing|api|alerts|notify|' +
    'notifications|monitoring|ops|portal|filing|exchange|analytics|officer' +
    ')([._-]|$)'

function Test-RoleMailbox {
    <#
        True when an address looks like a shared/role inbox rather than a person.
    #>
    param([string]$Email)

    $Local = "$Email".Split('@')[0].ToLower()
    if (-not $Local) { return $false }

    return [bool]($Local -match $Script:RoleMailboxPattern)
}

function Get-EmailNameOrderByDomain {
    <#
        Works out, PER DOMAIN, whether "a.b@domain" means first.last or
        last.first - by measuring it against the contacts whose real names are
        already known.

        WHY THIS ISN'T A CONSTANT: it is a per-agency convention, and assuming
        first.last everywhere is wrong for real partners. Measured across the 490
        Airtable contacts that carry BOTH a Name and an Email (2026-08-13):

            dol.gov     16 last.first vs  1 first.last
            pbgc.gov     7 last.first vs  5 first.last
            epa.gov      2 last.first vs  0 first.last
            octo.us      2 last.first vs  0 first.last
            everywhere else strongly first.last (235 vs 27 overall)

        batchelet.doug@dol.gov is Doug Batchelet. A blanket first.last rule
        reverses 44 of the 970 unnamed contacts, concentrated in one major
        partner agency.

        Self-correcting: as real names are filled in upstream, the evidence for
        each domain improves. -MinSupport guards against flipping a whole domain
        on the strength of one or two rows, the same reasoning as the .gov
        Account-domain inference.

        Returns a hashtable: domain -> 'FirstLast' | 'LastFirst'. Domains with
        insufficient evidence are ABSENT, and the caller defaults to first.last.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$KnownNamePairs,      # objects with .Name and .Email

        [int]$MinSupport = 3
    )

    $Evidence = @{}

    foreach ($Pair in $KnownNamePairs) {
        $Name = "$($Pair.Name)".Trim()
        $Email = "$($Pair.Email)".Trim().ToLower()
        if (-not $Name -or -not $Email) { continue }

        $Local = $Email.Split('@')[0]
        $Domain = Get-EmailDomain -Email $Email
        if (-not $Domain) { continue }

        # Only two-token local parts can testify to an ORDER.
        if ($Local -notmatch "^([a-z'\-]+)\.([a-z'\-]+)$") { continue }
        $Left = $Matches[1]; $Right = $Matches[2]

        $Tokens = @(($Name -replace "[^A-Za-z\s'\-]", '') -split '\s+' | Where-Object { $_ })
        if ($Tokens.Count -lt 2) { continue }
        $First = $Tokens[0].ToLower()
        $Last = $Tokens[-1].ToLower()

        if (-not $Evidence.ContainsKey($Domain)) {
            $Evidence[$Domain] = @{ FirstLast = 0; LastFirst = 0 }
        }

        # A symmetric case (first and last identical) testifies to nothing.
        if ($Left -eq $First -and $Right -eq $Last -and $First -ne $Last) { $Evidence[$Domain].FirstLast++ }
        elseif ($Left -eq $Last -and $Right -eq $First -and $First -ne $Last) { $Evidence[$Domain].LastFirst++ }
    }

    $Order = @{}
    foreach ($Domain in $Evidence.Keys) {
        $Fl = $Evidence[$Domain].FirstLast
        $Lf = $Evidence[$Domain].LastFirst

        # Only record a domain when the evidence is both sufficient AND
        # one-sided. A domain that genuinely uses both conventions is left out,
        # so it falls back to first.last rather than being coin-flipped.
        if (($Fl + $Lf) -lt $MinSupport) { continue }
        if ($Lf -gt $Fl) { $Order[$Domain] = 'LastFirst' }
        elseif ($Fl -gt $Lf) { $Order[$Domain] = 'FirstLast' }
    }

    return $Order
}

function Resolve-NameFromEmail {
    <#
        Derives FirstName/LastName from an email address, where the address
        actually encodes one.

        Returns a PSCustomObject:
          FirstName / LastName - LastName is never empty for a usable address
          Rule                 - which rule fired, for the review CSV and summary
          IsPerson             - $false for role/shared mailboxes
          Confident            - $true only when a genuine first AND last name
                                 were recovered

        THE RULES, in order, with the 2026-08-13 counts out of 970:

          role mailbox      56   NOT split. LastName = local part verbatim.
                                 Splitting invents "Tracs Helpdesk".
          DoD suffix        56   christopher.m.tork.ctr -> strip .ctr/.civ/.mil,
                                 then re-apply. Without this the surname is "ctr".
          first.M.last      47   tara.r.wells -> Tara Wells. Drop the single
                                 letter; a middle initial is not a surname.
          first.last       440   Split. ORDER COMES FROM THE DOMAIN - see
                                 Get-EmailNameOrderByDomain.
          first_last        61   Same, on underscore.
          no separator     242   jwoolf, crdavis1 - an initial+surname
                                 compression with no defensible split point.
                                 LastName = local part, no first name invented.
          other             68   Anything left. Same treatment as above.

        HYPHEN IS DELIBERATELY NOT A SEPARATOR, and this was checked rather than
        assumed. Of 20 hyphenated local parts, nearly all are role inboxes
        (e-filing, tracs-helpdesk, benefits-notify, eere-exchangesupport) - and
        hyphens appear legitimately INSIDE surnames (singi-reddy). Splitting on
        one both invents people and breaks real names, so hyphens are preserved.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Email,

        # domain -> 'FirstLast' | 'LastFirst', from Get-EmailNameOrderByDomain.
        [hashtable]$NameOrderByDomain = @{}
    )

    $Result = [PSCustomObject]@{
        FirstName = ""
        LastName  = ""
        Rule      = "none"
        IsPerson  = $true
        Confident = $false
    }

    $Clean = "$Email".Trim().ToLower()
    if (-not $Clean -or $Clean -notmatch '@') { return $Result }

    $Local = $Clean.Split('@')[0]
    $Domain = Get-EmailDomain -Email $Clean
    if (-not $Local) { return $Result }

    # --- role / shared mailbox: never split -------------------------------
    if ($Local -match $Script:RoleMailboxPattern) {
        $Result.LastName = $Local
        $Result.Rule = "role mailbox (not split)"
        $Result.IsPerson = $false
        return $Result
    }

    # --- DoD affiliation suffix -------------------------------------------
    # .civ / .mil / .ctr is an affiliation marker, not a name token.
    $Rule = ""
    $Core = $Local -replace '\.(civ|mil|ctr\d*)$', ''
    if ($Core -ne $Local) { $Rule = "DoD suffix stripped + " }
    if (-not $Core) { $Core = $Local }

    # --- first.MIDDLEINITIAL.last -----------------------------------------
    if ($Core -match "^([a-z'\-]+)\.[a-z]\.([a-z'\-]+)$") {
        $Left = $Matches[1]; $Right = $Matches[2]
        $Rule += "first.M.last"
    }
    # --- first.last / first_last ------------------------------------------
    elseif ($Core -match "^([a-z'\-]+)[._]([a-z'\-]+)$") {
        $Left = $Matches[1]; $Right = $Matches[2]
        $Rule += if ($Core -match '_') { "first_last" } else { "first.last" }
    }
    else {
        # No defensible split. jwoolf / crdavis1 / a1dta.a1.sd all land here.
        # LastName carries the local part so the record is findable and it is
        # obvious in the UI that a real name is still needed.
        $Result.LastName = $Local
        $Result.Rule = if ($Local -match '[._-]') { "unsplittable (local part)" } else { "no separator (local part)" }
        return $Result
    }

    # --- decide the order from the domain ---------------------------------
    $Order = "FirstLast"
    if ($Domain -and $NameOrderByDomain.ContainsKey($Domain)) {
        $Order = $NameOrderByDomain[$Domain]
    }

    if ($Order -eq 'LastFirst') {
        $First = $Right; $Last = $Left
        $Rule += " (domain uses last.first)"
    }
    else {
        $First = $Left; $Last = $Right
    }

    $Result.FirstName = ConvertTo-NameCase -Token $First
    $Result.LastName  = ConvertTo-NameCase -Token $Last
    $Result.Rule      = $Rule
    $Result.Confident = $true

    return $Result
}

function ConvertTo-NameCase {
    <#
        "mcdonald" -> "Mcdonald", "singi-reddy" -> "Singi-Reddy",
        "o'brien" -> "O'Brien".

        Deliberately does NOT attempt McDonald / MacLeod / van der Berg. Those
        need a dictionary and guessing wrong is worse than plain title case,
        which reads as a machine-derived name - which is exactly what it is.
    #>
    param([string]$Token)

    if (-not $Token) { return "" }

    $Parts = [regex]::Split($Token.ToLower(), "([\-'])")
    $Out = ""
    foreach ($Part in $Parts) {
        if ($Part -match "^[\-']$") { $Out += $Part; continue }
        if (-not $Part) { continue }
        $Out += $Part.Substring(0, 1).ToUpper() + $Part.Substring(1)
    }

    return $Out
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
