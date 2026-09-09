#Requires -Version 5.1

<#
    Runs a Salesforce NAMED QUERY as the External Client App
    LDGCRM_P3_Client_app_Localdev, over the OAuth 2.0 client-credentials flow,
    and writes the rows to a UTF-8 CSV.

        Invoke-LdgcrmNamedQuery.ps1
            Runs ldgcrmPartnerPortalAdminQuery - every Partner Portal admin on
            LDGCRM_Application_Contact__c. 1,089 rows in Dev on 2026-09-09.

        Invoke-LdgcrmNamedQuery.ps1 -NamedQuery someOtherQuery

        Invoke-LdgcrmNamedQuery.ps1 -Parameters @{ teamUuid = "abc-123" }

        Invoke-LdgcrmNamedQuery.ps1 -List
            What named queries does this org have?

    =========================================================================
    THE ENDPOINT, AND WHY IT LOOKS LIKE IT DOES NOT EXIST
    =========================================================================
        GET /services/data/v<ApiVersion>/named/query/<ApiName>

    VERIFIED against PEOdV8DVn on 2026-09-09: 1,089 records, done=true, with
    exactly the columns ldgcrmPartnerPortalAdminQuery selects. Four plausible
    alternatives were tried the same day and every one of them returned an
    errorCode/message object instead:

        /named/query/<n>                 <- the real one
        /query/named/<n>                 error
        /namedQuery/<n>                  error
        /queryNamed/<n>                  error
        /connect/named-queries/<n>       error

    ** "named" IS ABSENT FROM THE RESOURCE MAP. ** GET /services/data/v67.0/
    lists 57 resources - query, queryAll, tooling, composite, connect and the
    rest - and no named-query entry among them. So the one place you would look
    to confirm the endpoint exists says it does not, while the endpoint answers
    perfectly. Do not "correct" the path above on the strength of that map.

    This is the third distinct way this feature has read as missing when it was
    present. The other two are in scripts/docs/integration-user.md section 3:
    an empty ApiNamedQuery table answering 400 INVALID_FIELD rather than 404,
    and the Setup page being invisible without a permission set.

    =========================================================================
    WHY A NAMED QUERY RATHER THAN -Soql
    =========================================================================
    The SOQL lives in the ORG, as metadata, not in this file. That means the
    portal's contract can be reviewed and changed without shipping a client, and
    the caller needs no ability to compose arbitrary SOQL.

    The trade is that the query text is now a deployable component, and
    ApiNamedQuery has a version trap: it DOES NOT EXIST BELOW API VERSION 65.0,
    and a retrieve against a manifest saying 64.0 fails while still reporting
    "status": "Succeeded" and "success": true. The failure shows up only in the
    per-component files array. sfdx/manifest/package.xml carries the warning.

    Sibling script: Invoke-LdgcrmSalesforceQuery.ps1 reads the same rows through
    the standard query resource, building the SOQL here instead. Same app, same
    integration user, same permission set - only where the query text lives
    differs, so neither is more privileged than the other.

    =========================================================================
    DEV AND QA ONLY, PROVEN AGAINST THE REGISTRY
    =========================================================================
    SALESFORCE_INSTANCE_URL must match an InstanceUrl in
    Get-LdgcrmEnvironmentTable exactly, and that check runs BEFORE any token is
    requested. Production is deliberately absent from that registry.

    Output lands in logs/tools/, which the repo-root .gitignore covers. The
    transcript records COUNTS ONLY - rows go to the CSV and nowhere else.

    Targets Windows PowerShell 5.1, and this file is PURE ASCII on purpose.
#>

[CmdletBinding(DefaultParameterSetName = "Run")]
param(
    # API name of the named query, NOT its label. The one that exists in Dev is
    # "ldgcrmPartnerPortalAdminQuery"; its label is "Login.gov Partner Portal
    # Admin Query" and passing that will not resolve.
    [Parameter(ParameterSetName = "Run")]
    [string]$NamedQuery = "ldgcrmPartnerPortalAdminQuery",

    # Input parameters the named query declares, sent as URI query parameters.
    # A named query may only parameterise its WHERE and LIMIT clauses.
    [Parameter(ParameterSetName = "Run")]
    [hashtable]$Parameters = @{},

    # List the org's named queries and exit. Needs a user that can read the
    # ApiNamedQuery tooling object - see the note where this is handled.
    [Parameter(ParameterSetName = "List", Mandatory = $true)]
    [switch]$List,

    # 67.0 is the highest this org serves, and what ldgcrmPartnerPortalAdminQuery
    # declares. sfdx-project.json says 64.0, which is the project's RETRIEVE
    # version and is not what this resource wants.
    [string]$ApiVersion = "67.0",

    # Where to write the CSV. Defaults to this run's log directory.
    [string]$OutputPath = "",

    # Also emit the flattened records to the pipeline. Off by default so an
    # interactive run cannot spray PII across the transcript by accident.
    [switch]$PassThru
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "Common.PortalIntegration.ps1")

# Discarded deliberately: Start-ToolLog returns the run's timestamp for naming
# extra output files, and this script names its one CSV after the query instead.
$null = Start-ToolLog -ScriptName "Invoke-LdgcrmNamedQuery"

try {
    # ---------------------------------------------------------------------
    # 1. Refuse an API version that cannot serve the resource at all
    # ---------------------------------------------------------------------
    # Below 65.0 ApiNamedQuery does not exist. Catching it here turns an
    # otherwise opaque 404/400 into the one sentence that explains it.
    $VersionNumber = 0.0

    if (-not [double]::TryParse($ApiVersion, [ref]$VersionNumber)) {
        throw ("-ApiVersion must be a number like 67.0, not '" + $ApiVersion + "'.")
    }

    if ($VersionNumber -lt 65.0) {
        throw ("-ApiVersion is " + $ApiVersion + ", but the Named Query API does not exist below " +
               "65.0. Nothing about the response would tell you that: the request simply fails. " +
               "Use 67.0, which is the highest this org serves.")
    }

    # ---------------------------------------------------------------------
    # 2. Registry check, then token
    # ---------------------------------------------------------------------
    $Context = Get-PortalApiContext -ApiVersion $ApiVersion

    # ---------------------------------------------------------------------
    # 3. -List: what named queries exist?
    # ---------------------------------------------------------------------
    if ($PSCmdlet.ParameterSetName -eq "List") {
        # ApiNamedQuery's label field is MasterLabel. It has NO DeveloperName
        # column, and asking for one returns 400 INVALID_FIELD - which was once
        # read here as the feature being unprovisioned. It was not; the table
        # was empty. A zero-row count on a queryable table means empty, never
        # absent.
        $ListSoql = "SELECT Id, MasterLabel FROM ApiNamedQuery"
        $ListUri = $Context.DataBase + "/tooling/query?q=" + [uri]::EscapeDataString($ListSoql)

        $Found = $null

        try {
            $Found = Invoke-RestMethod -Method Get -Uri $ListUri -Headers $Context.Headers
        }
        catch {
            throw ("Could not list named queries: " + (Get-HttpErrorDetail -ErrorRecord $_) +
                   [Environment]::NewLine +
                   "This reads the ApiNamedQuery TOOLING object, which the integration user is " +
                   "not normally granted. It is a convenience, not part of running a query - " +
                   "drop -List and the run below works regardless." + [Environment]::NewLine +
                   "As an admin you can get the same answer with:" + [Environment]::NewLine +
                   "  sf data query --use-tooling-api --target-org peodv8dvn \" + [Environment]::NewLine +
                   "     --query ""SELECT Id, MasterLabel FROM ApiNamedQuery""")
        }

        $Rows = @($Found.records)

        Write-Host ("Named queries in " + $Context.Environment.Label + ": " + $Rows.Count)
        Write-Host ""

        foreach ($Row in $Rows) {
            Write-Host ("  " + $Row.MasterLabel)
            Write-Host ("      Id: " + $Row.Id)
        }

        if ($Rows.Count -eq 0) {
            Write-Warning ("Zero rows means the table is EMPTY, not that the feature is off. " +
                           "Create one at Setup > Integrations > Named Query API - and if that " +
                           "page is absent, check for the 'Orgwide - Named Query - Admin' " +
                           "permission set on your OWN user before concluding anything. See " +
                           "scripts/docs/integration-user.md section 3.")
        }

        return
    }

    # ---------------------------------------------------------------------
    # 4. Build the request
    # ---------------------------------------------------------------------
    $Uri = $Context.DataBase + "/named/query/" + $NamedQuery

    if ($Parameters.Count -gt 0) {
        $Pairs = @()

        foreach ($Key in $Parameters.Keys) {
            $Pairs += ([uri]::EscapeDataString([string]$Key) + "=" +
                       [uri]::EscapeDataString([string]$Parameters[$Key]))
        }

        $Uri = $Uri + "?" + ($Pairs -join "&")
    }

    Write-Host ("Named Query : " + $NamedQuery)

    if ($Parameters.Count -gt 0) {
        Write-Host ("Parameters  : " + (($Parameters.Keys | Sort-Object) -join ", "))
    }

    Write-Host ""

    # ---------------------------------------------------------------------
    # 5. Fetch
    # ---------------------------------------------------------------------
    # The name not resolving arrives as a 400 mentioning ApiNamedQuery, NOT a
    # 404, so a status-code check alone reports the wrong thing entirely.
    $OnError = {
        param($Detail)

        if ($Detail -match "ApiNamedQuery" -or $Detail -match "NOT_FOUND" -or $Detail -match "INVALID_QUERY") {
            throw ("The named query '" + $NamedQuery + "' could not be resolved." + [Environment]::NewLine +
                   $Detail + [Environment]::NewLine +
                   [Environment]::NewLine +
                   "This means the NAME did not resolve - not that the feature is off." + [Environment]::NewLine +
                   "Check the spelling, and that you passed the API NAME rather than the label:" + [Environment]::NewLine +
                   "  API name  ldgcrmPartnerPortalAdminQuery   <- what this wants" + [Environment]::NewLine +
                   "  Label     Login.gov Partner Portal Admin Query" + [Environment]::NewLine +
                   [Environment]::NewLine +
                   "Run with -List to see what this org actually has, or fall back to" + [Environment]::NewLine +
                   "Invoke-LdgcrmSalesforceQuery.ps1, which reads the same rows without" + [Environment]::NewLine +
                   "depending on a named query existing at all.")
        }
    }

    $Records = Invoke-PortalRestPaged -Uri $Uri -Context $Context -OnError $OnError

    # ---------------------------------------------------------------------
    # 6. Write
    # ---------------------------------------------------------------------
    $Destination = Save-PortalRecordCsv -Records $Records -OutputName $NamedQuery -OutputPath $OutputPath

    if ($PassThru) {
        foreach ($Record in $Records) {
            [PSCustomObject](ConvertTo-FlatRecord -Record $Record)
        }
    }
}
catch {
    # WRITE THE DIAGNOSIS BEFORE THE TRANSCRIPT CLOSES. Without this the failure
    # messages above never reach the run's log: the finally below stops the
    # transcript, and only THEN does the exception surface on the host.
    Write-Host ""
    Write-Host $_.Exception.Message

    throw
}
finally {
    Stop-ToolLog
}
