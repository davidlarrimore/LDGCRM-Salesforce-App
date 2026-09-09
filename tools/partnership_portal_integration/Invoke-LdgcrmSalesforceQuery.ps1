#Requires -Version 5.1

<#
    Reads records out of the Dev or QA sandbox as the External Client App
    LDGCRM_P3_Client_app_Localdev, over the OAuth 2.0 client-credentials flow,
    and writes them to a UTF-8 CSV.

    Uses the STANDARD REST API query resource:

        GET /services/data/v<ApiVersion>/query?q=<soql>

    Three ways in, in increasing specificity:

        Invoke-LdgcrmSalesforceQuery.ps1
            Every readable field on LDGCRM_Application_Contact__c. The field list
            comes from a describe call, so it is whatever the integration user can
            actually see rather than a list in this file that goes stale.

        Invoke-LdgcrmSalesforceQuery.ps1 -Object Contact -Where "AccountId != null" -Limit 500

        Invoke-LdgcrmSalesforceQuery.ps1 -Soql "SELECT Id, Name FROM Account"

    =========================================================================
    THE NAMED QUERY PATH LIVES IN THE SIBLING SCRIPT
    =========================================================================
    -NamedQuery used to be a parameter set here, added when NO named query
    existed in the org and the endpoint was therefore unverified. One exists now
    - "ldgcrmPartnerPortalAdminQuery" - and the endpoint was confirmed against
    PEOdV8DVn on 2026-09-09, so that path moved to its own script:

        Invoke-LdgcrmNamedQuery.ps1

    Deliberately not kept in both places. Two implementations of the same
    endpoint drift, and the interesting parts - the version floor, the label vs
    API name trap, the resource map that omits the resource - are worth stating
    once, where they are load-bearing.

    Same app, same integration user, same permission set either way. Nothing
    about the security posture changes between the two; only where the query
    text lives. This script composes SOQL locally, that one runs SOQL stored in
    the org as metadata.

    THE OBJECT IS LDGCRM_Application_Contact__c. There is no ApplicationContact__c
    in this org. Its lookup to Contact is spelled LDGCRM_contact__c with a
    LOWER-CASE c - a real API-name typo that is load-bearing.

    =========================================================================
    DEV AND QA ONLY, PROVEN AGAINST THE REGISTRY
    =========================================================================
    SALESFORCE_INSTANCE_URL must match an InstanceUrl in
    Get-LdgcrmEnvironmentTable exactly, and that check runs BEFORE any token is
    requested. Production is deliberately absent from that registry, so pointing
    this at gsa-peo fails before a token is ever asked for. That matters more
    here than it looks: the rows this pulls are applicant PII, and a
    production-side reader belongs in its own purpose-built tool rather than
    behind a loosened check on this one.

    Output lands in logs/tools/, which the repo-root .gitignore covers. The
    transcript deliberately records COUNTS ONLY - record contents go to the CSV
    and nowhere else, so a log file never becomes a second uncontrolled copy of
    the data.

    Targets Windows PowerShell 5.1, and this file is PURE ASCII on purpose:
    powershell.exe decodes a BOM-less .ps1 as the system ANSI codepage.
#>

[CmdletBinding(DefaultParameterSetName = "Object")]
param(
    # Read every field the integration user can see on this object.
    [Parameter(ParameterSetName = "Object")]
    [string]$Object = "LDGCRM_Application_Contact__c",

    # Optional SOQL WHERE body, without the keyword: -Where "LDGCRM_Email__c != null"
    [Parameter(ParameterSetName = "Object")]
    [string]$Where = "",

    # Optional row cap. 0 means no LIMIT clause - paging fetches everything.
    [Parameter(ParameterSetName = "Object")]
    [int]$Limit = 0,

    # Run this SOQL verbatim instead of building one.
    [Parameter(ParameterSetName = "Soql", Mandatory = $true)]
    [string]$Soql,

    # 67.0 is the highest this org serves. sfdx-project.json says 64.0, which is
    # the project's retrieve version and is not what these resources want.
    [string]$ApiVersion = "67.0",

    # Where to write the CSV. Defaults to this run's log directory.
    [string]$OutputPath = "",

    # Also emit the flattened records to the pipeline. Off by default so an
    # interactive run cannot spray PII across the transcript by accident.
    [switch]$PassThru
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "Common.PortalIntegration.ps1")


function Get-QueryableFieldName {
    <#
        The field names a SELECT may name, from a describe response.

        THREE TYPES CANNOT APPEAR IN A SELECT and there is no flag on the field
        saying so - the type is the only tell:

          address / location   compound wrappers. Their COMPONENTS (BillingStreet,
                               BillingCity) are separate, queryable fields that this
                               keeps; only the wrapper itself is rejected.
          base64               body fields, which the query resource will not return.

        Including any of them fails the whole query with INVALID_FIELD, so one
        unqueryable field on an object costs every row on it.

        CONTRACT: returns a plain array. The caller wraps the call in @().
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Describe
    )

    $Names = @()

    foreach ($Field in $Describe.fields) {
        if ($Field.type -eq "address" -or $Field.type -eq "location" -or $Field.type -eq "base64") {
            continue
        }

        $Names += $Field.name
    }

    return $Names
}

# Discarded deliberately: Start-ToolLog returns the run's timestamp for naming
# extra output files, and this script names its one CSV after the query instead.
$null = Start-ToolLog -ScriptName "Invoke-LdgcrmSalesforceQuery"

try {
    # ---------------------------------------------------------------------
    # 1. Registry check, then token
    # ---------------------------------------------------------------------
    $Context = Get-PortalApiContext -ApiVersion $ApiVersion

    # ---------------------------------------------------------------------
    # 2. Build the SOQL
    # ---------------------------------------------------------------------
    $OutputName = "soql-query"

    if ($PSCmdlet.ParameterSetName -eq "Object") {
        # Describe first, so the SELECT is whatever this user can actually
        # read. A hard-coded field list here would go stale the first time a
        # field is added, and would fail the whole query rather than skip it.
        Write-Host ("Describing " + $Object + "...")

        $Describe = $null

        try {
            $Describe = Invoke-RestMethod -Method Get -Headers $Context.Headers `
                -Uri ($Context.DataBase + "/sobjects/" + $Object + "/describe")
        }
        catch {
            throw ("Cannot describe " + $Object + ": " + (Get-HttpErrorDetail -ErrorRecord $_) +
                   [Environment]::NewLine +
                   "Check the API name. The Application Contact object is " +
                   "LDGCRM_Application_Contact__c; there is no ApplicationContact__c in this org.")
        }

        $Fields = @(Get-QueryableFieldName -Describe $Describe)

        Write-Host ($Fields.Count.ToString() + " readable field(s).")

        $Soql = "SELECT " + ($Fields -join ", ") + " FROM " + $Object

        if (-not [string]::IsNullOrWhiteSpace($Where)) {
            $Soql = $Soql + " WHERE " + $Where
        }

        if ($Limit -gt 0) {
            $Soql = $Soql + " LIMIT " + $Limit
        }

        $OutputName = $Object
    }

    $Uri = $Context.DataBase + "/query?q=" + [uri]::EscapeDataString($Soql)

    Write-Host ("SOQL        : " + $Soql)
    Write-Host ""

    # ---------------------------------------------------------------------
    # 3. Fetch, following nextRecordsUrl
    # ---------------------------------------------------------------------
    $Records = Invoke-PortalRestPaged -Uri $Uri -Context $Context

    # ---------------------------------------------------------------------
    # 4. Flatten and write
    # ---------------------------------------------------------------------
    $Destination = Save-PortalRecordCsv -Records $Records -OutputName $OutputName -OutputPath $OutputPath

    if ($PassThru) {
        foreach ($Record in $Records) {
            [PSCustomObject](ConvertTo-FlatRecord -Record $Record)
        }
    }
}
catch {
    # WRITE THE DIAGNOSIS BEFORE THE TRANSCRIPT CLOSES. Without this the failure
    # messages above never reach the run's log: the finally below stops the
    # transcript, and only THEN does the exception surface on the host. The log
    # was left ending at "TerminatingError(Invoke-RestMethod): (400) Bad
    # Request" - the one line that explains nothing - while the paragraph saying
    # what to do about it went to a console nobody kept.
    Write-Host ""
    Write-Host $_.Exception.Message

    throw
}
finally {
    Stop-ToolLog
}
