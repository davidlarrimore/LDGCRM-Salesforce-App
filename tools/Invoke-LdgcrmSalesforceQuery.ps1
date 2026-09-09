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
    WHY NOT THE NAMED QUERY API
    =========================================================================
    A Named Query would be the tidier server-side contract, and -NamedQuery is
    still here for when one exists. On 2026-09-09 none did, and none could be
    made from this repo: a Named Query is created in Setup > Integrations >
    Named Query API, nothing in sfdx/force-app defines one, and per CLAUDE.md
    nothing here may deploy one either - metadata moves by CHANGE SET ONLY.

    Measured against PEOdV8DVn that day, `SELECT Id FROM ApiNamedQuery` returned
    ZERO rows and the endpoint answered 400 INVALID_FIELD - "No such column
    'DeveloperName' on entity 'ApiNamedQuery'" - identically on v65.0, v66.0 and
    v67.0. That is Salesforce's own internal lookup failing before it reaches the
    query, which is what "the Named Query API is not provisioned in this org"
    looks like from outside. It is NOT a 404, so -NamedQuery recognises that body
    specifically rather than reporting a generic failure.

    The standard query resource needs none of that. It is the same app, the same
    integration user, and the same permission set, so nothing about the security
    posture changes by using it - only where the SOQL text lives.

    THE OBJECT IS LDGCRM_Application_Contact__c. There is no ApplicationContact__c
    in this org. Its lookup to Contact is spelled LDGCRM_contact__c with a
    LOWER-CASE c - a real API-name typo that is load-bearing.

    =========================================================================
    DEV AND QA ONLY, PROVEN AGAINST THE REGISTRY
    =========================================================================
    SALESFORCE_INSTANCE_URL must match an InstanceUrl in
    Get-LdgcrmEnvironmentTable exactly. Production is deliberately absent from
    that registry, so pointing this at gsa-peo fails before a token is ever
    requested. That matters more here than it looks: the rows this pulls are
    applicant PII, and a production-side reader belongs in its own purpose-built
    tool rather than behind a loosened check on this one.

    Output lands in logs/tools/, which the repo-root .gitignore covers. The
    transcript deliberately records COUNTS ONLY - record contents go to the CSV
    and nowhere else, so a log file never becomes a second uncontrolled copy of
    the data.

    Targets Windows PowerShell 5.1: no ??, ?., ternary ?:, -AsHashtable,
    -Parallel or multi-argument Join-Path.
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

    # Call a Named Query by API name instead. See the header - there were none
    # in the org when this was written.
    [Parameter(ParameterSetName = "NamedQuery", Mandatory = $true)]
    [string]$NamedQuery,

    # Input parameters a Named Query declares, sent as URI query parameters.
    # A Named Query may only parameterise its WHERE and LIMIT clauses.
    [Parameter(ParameterSetName = "NamedQuery")]
    [hashtable]$Parameters = @{},

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

. (Join-Path $PSScriptRoot "Common.Tools.ps1")
# For Import-DotEnv and, through Common.Orgs.ps1, Get-LdgcrmEnvironmentTable -
# the same registry every loading script proves its target against.
. (Join-Path $PSScriptRoot "data-loading\Common.ps1")

# PS 5.1 negotiates SSL3/TLS1.0 by default on some builds, and Salesforce has
# required TLS 1.2 since 2017. Without this the token request fails with
# "The underlying connection was closed", which reads like a network fault.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-HttpErrorDetail {
    <#
        Invoke-RestMethod throws on any non-2xx and puts the useful part - the
        Salesforce error body - in the exception's response stream, not in
        .Exception.Message. Without reading it, every failure reads "The remote
        server returned an error: (400) Bad Request" and says nothing about
        which of the half-dozen possible causes it was.

        Returns a printable string; never throws.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $Response = $null

    try {
        $Response = $ErrorRecord.Exception.Response
    }
    catch {
        $Response = $null
    }

    if ($null -eq $Response) {
        return $ErrorRecord.Exception.Message
    }

    $Status = "HTTP error"

    try {
        $Status = "HTTP " + [int]$Response.StatusCode + " " + $Response.StatusCode
    }
    catch {
        $Status = "HTTP error"
    }

    $Body = ""

    try {
        $Stream = $Response.GetResponseStream()
        $Reader = New-Object System.IO.StreamReader($Stream)
        $Body = $Reader.ReadToEnd()
        $Reader.Close()
    }
    catch {
        $Body = ""
    }

    if ([string]::IsNullOrWhiteSpace($Body)) {
        return $Status
    }

    return ($Status + " - " + $Body)
}

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

function ConvertTo-FlatRecord {
    <#
        Turns one Salesforce record into a flat ordered dictionary suitable for
        CSV: drops the "attributes" block Salesforce adds to every record and
        every nested relationship, and flattens a relationship one dotted level
        at a time (LDGCRM_contact__r.Name). Anything that is neither scalar nor
        a single related record - a subquery's result set - is kept as compact
        JSON rather than silently rendered as "System.Object[]".

        CONTRACT: returns the dictionary itself. PowerShell does not unroll a
        dictionary onto the pipeline, so the caller assigns it bare and must NOT
        wrap the call in @().
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Record,

        [string]$Prefix = ""
    )

    $Flat = [ordered]@{}

    foreach ($Property in $Record.PSObject.Properties) {
        if ($Property.Name -eq "attributes") {
            continue
        }

        $Name = $Prefix + $Property.Name
        $Value = $Property.Value

        if ($null -eq $Value) {
            $Flat[$Name] = ""
        }
        elseif ($Value -is [System.Management.Automation.PSCustomObject]) {
            $Nested = ConvertTo-FlatRecord -Record $Value -Prefix ($Name + ".")

            foreach ($Key in $Nested.Keys) {
                $Flat[$Key] = $Nested[$Key]
            }
        }
        elseif ($Value -is [System.Array] -or $Value -is [System.Collections.IList]) {
            $Flat[$Name] = ($Value | ConvertTo-Json -Compress -Depth 6)
        }
        else {
            $Flat[$Name] = $Value
        }
    }

    return $Flat
}

function Write-Utf8NoBomCsv {
    <#
        PS 5.1's Export-Csv -Encoding UTF8 always writes a byte-order mark, and
        a BOM gets read as part of the first column header by most things that
        consume these files. Writes the CSV by hand instead.

        Unlike the pipeline's Export-DataLoaderCsv this tolerates zero rows: a
        read that legitimately matched nothing is a result, not a fault.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $Lines = @($InputObject | ConvertTo-Csv -NoTypeInformation)
    $Utf8NoBom = New-Object System.Text.UTF8Encoding $false

    [System.IO.File]::WriteAllLines($Path, $Lines, $Utf8NoBom)
}

$Timestamp = Start-ToolLog -ScriptName "Invoke-LdgcrmSalesforceQuery"

try {
    Import-DotEnv

    # ---------------------------------------------------------------------
    # 1. Credentials
    # ---------------------------------------------------------------------
    $InstanceUrl = $env:SALESFORCE_INSTANCE_URL
    $ConsumerKey = $env:SALESFORCE_CONSUMER_KEY
    $ConsumerSecret = $env:SALESFORCE_CONSUMER_SECRET

    $Missing = @()

    if ([string]::IsNullOrWhiteSpace($InstanceUrl)) { $Missing += "SALESFORCE_INSTANCE_URL" }
    if ([string]::IsNullOrWhiteSpace($ConsumerKey)) { $Missing += "SALESFORCE_CONSUMER_KEY" }
    if ([string]::IsNullOrWhiteSpace($ConsumerSecret)) { $Missing += "SALESFORCE_CONSUMER_SECRET" }

    if ($Missing.Count -gt 0) {
        throw ("Missing from .env at " + (Join-Path (Get-RepoRoot) ".env") + ": " +
               ($Missing -join ", ") + ". See .env.example for what each one is.")
    }

    $InstanceUrl = $InstanceUrl.Trim().TrimEnd("/")

    # ---------------------------------------------------------------------
    # 2. Prove the target is Dev or QA before asking for a token
    # ---------------------------------------------------------------------
    $Registry = Get-LdgcrmEnvironmentTable
    $Environment = $null

    foreach ($Key in $Registry.Keys) {
        if ($Registry[$Key].InstanceUrl -eq $InstanceUrl) {
            $Environment = $Registry[$Key]
            break
        }
    }

    if ($null -eq $Environment) {
        $Known = @()

        foreach ($Key in $Registry.Keys) {
            $Known += ("  " + $Registry[$Key].Key + "  " + $Registry[$Key].InstanceUrl)
        }

        throw ("SALESFORCE_INSTANCE_URL is " + $InstanceUrl + ", which is not a registered " +
               "Dev or QA sandbox. This tool reads applicant PII and is dev/QA only; " +
               "production is deliberately absent from the registry, and a production-side " +
               "reader belongs in its own tool. Registered environments:" +
               [Environment]::NewLine + ($Known -join [Environment]::NewLine))
    }

    Write-Host ("Target      : " + $Environment.Label + " (" + $Environment.SandboxName + ")")
    Write-Host ("Instance URL: " + $Environment.InstanceUrl)
    Write-Host ("API version : v" + $ApiVersion)
    Write-Host ""

    # ---------------------------------------------------------------------
    # 3. Token - OAuth 2.0 client credentials
    # ---------------------------------------------------------------------
    Write-Host "Requesting an access token..."

    $Token = $null

    try {
        $Token = Invoke-RestMethod `
            -Method Post `
            -Uri ($Environment.InstanceUrl + "/services/oauth2/token") `
            -ContentType "application/x-www-form-urlencoded" `
            -Body @{
                grant_type    = "client_credentials"
                client_id     = $ConsumerKey
                client_secret = $ConsumerSecret
            }
    }
    catch {
        # invalid_client_id covers three unrelated causes and Salesforce says
        # nothing to tell them apart. The first one below has already happened
        # here: .env held an 84-character key against the app's real 85.
        throw ("Token request failed: " + (Get-HttpErrorDetail -ErrorRecord $_) + [Environment]::NewLine +
               "Check, in this order:" + [Environment]::NewLine +
               "  1. SALESFORCE_CONSUMER_KEY matches the app's Consumer Key character for character." + [Environment]::NewLine +
               "     Compare it against <consumerKey> in sfdx/force-app/main/default/" + [Environment]::NewLine +
               "     extlClntAppGlobalOauthSets/. A key one character short returns invalid_client_id" + [Environment]::NewLine +
               "     and nothing else." + [Environment]::NewLine +
               "  2. Client Credentials Flow is still enabled on the External Client App:" + [Environment]::NewLine +
               "     Setup > External Client App Manager > Login.gov Partnership Portal Client App" + [Environment]::NewLine +
               "     (Local) > Settings > OAuth > Flow Enablement." + [Environment]::NewLine +
               "  3. The app still has a 'Run As' user. Client credentials has no interactive user," + [Environment]::NewLine +
               "     so without one Salesforce refuses the grant.")
    }

    if ([string]::IsNullOrWhiteSpace($Token.access_token)) {
        throw "Token request succeeded but returned no access_token."
    }

    # Salesforce returns the instance to actually call, which can differ from
    # the login host. Use what it hands back.
    $ApiBase = $Environment.InstanceUrl

    if (-not [string]::IsNullOrWhiteSpace($Token.instance_url)) {
        $ApiBase = $Token.instance_url.TrimEnd("/")
    }

    $Headers = @{
        Authorization = "Bearer " + $Token.access_token
        Accept        = "application/json"
    }

    Write-Host "Token acquired."
    Write-Host ""

    # ---------------------------------------------------------------------
    # 4. Build the first request
    # ---------------------------------------------------------------------
    $DataBase = $ApiBase + "/services/data/v" + $ApiVersion

    if ($PSCmdlet.ParameterSetName -eq "NamedQuery") {
        $Uri = $DataBase + "/named/query/" + $NamedQuery
        $OutputName = $NamedQuery

        if ($Parameters.Count -gt 0) {
            $Pairs = @()

            foreach ($Key in $Parameters.Keys) {
                $Pairs += ([uri]::EscapeDataString([string]$Key) + "=" +
                           [uri]::EscapeDataString([string]$Parameters[$Key]))
            }

            $Uri = $Uri + "?" + ($Pairs -join "&")
        }

        Write-Host ("Named Query : " + $NamedQuery)
    }
    else {
        if ($PSCmdlet.ParameterSetName -eq "Object") {
            # Describe first, so the SELECT is whatever this user can actually
            # read. A hard-coded field list here would go stale the first time a
            # field is added, and would fail the whole query rather than skip it.
            Write-Host ("Describing " + $Object + "...")

            $Describe = $null

            try {
                $Describe = Invoke-RestMethod -Method Get -Headers $Headers `
                    -Uri ($DataBase + "/sobjects/" + $Object + "/describe")
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
        else {
            $OutputName = "soql-query"
        }

        $Uri = $DataBase + "/query?q=" + [uri]::EscapeDataString($Soql)

        Write-Host ("SOQL        : " + $Soql)
    }

    Write-Host ""

    # ---------------------------------------------------------------------
    # 5. Fetch, following nextRecordsUrl
    # ---------------------------------------------------------------------
    # List[object] built with ::new() - @( ) cannot bind a PSObject-wrapped
    # generic list under PS 5.1, and New-Object produces exactly that.
    $Records = [System.Collections.Generic.List[object]]::new()
    $Next = $Uri
    $Page = 0

    while (-not [string]::IsNullOrWhiteSpace($Next)) {
        $Page = $Page + 1
        $Response = $null

        try {
            $Response = Invoke-RestMethod -Method Get -Uri $Next -Headers $Headers
        }
        catch {
            $Detail = Get-HttpErrorDetail -ErrorRecord $_

            # The signature of "the Named Query API is not provisioned in this
            # org": Salesforce's own lookup against ApiNamedQuery fails before it
            # ever reaches the query. It arrives as a 400, not a 404, so a status
            # check alone reports the wrong thing entirely.
            if ($Detail -match "ApiNamedQuery") {
                throw ("The Named Query '" + $NamedQuery + "' could not be resolved." + [Environment]::NewLine +
                       $Detail + [Environment]::NewLine +
                       [Environment]::NewLine +
                       "There were no Named Queries in this org on 2026-09-09, and if the Setup page" + [Environment]::NewLine +
                       "(Integrations > Named Query API) is absent the feature is not enabled at all." + [Environment]::NewLine +
                       "Drop the -NamedQuery argument to read the same rows through the standard" + [Environment]::NewLine +
                       "query resource, as the same app and the same user.")
            }

            if ($Detail -match "INSUFFICIENT_ACCESS" -or $Detail -match "INVALID_SESSION_ID") {
                throw ("The integration user may not read this object or one of these fields: " + $Detail +
                       [Environment]::NewLine +
                       "Check the app's 'Run As' user still holds LDGCRM_Partnership_Portal_API_R.")
            }

            throw ("Query request failed: " + $Detail)
        }

        $PageRecords = @()

        if ($null -ne $Response.PSObject.Properties["records"]) {
            $PageRecords = @($Response.records)
        }
        else {
            $PageRecords = @($Response)
        }

        foreach ($Record in $PageRecords) {
            $Records.Add($Record)
        }

        Write-Host ("Page " + $Page + ": " + $PageRecords.Count + " record(s)")

        $Next = ""

        if ($null -ne $Response.PSObject.Properties["nextRecordsUrl"]) {
            if (-not [string]::IsNullOrWhiteSpace($Response.nextRecordsUrl)) {
                $Next = $ApiBase + $Response.nextRecordsUrl
            }
        }
    }

    # ---------------------------------------------------------------------
    # 6. Flatten and write
    # ---------------------------------------------------------------------
    # A List, not "$Flattened += ...". Appending to a PowerShell array rebuilds
    # the whole array on every row, which is quadratic and gets slow long before
    # it gets noticeably slow - the point where it starts to hurt is a much
    # larger object than this one.
    $Flattened = [System.Collections.Generic.List[object]]::new()

    foreach ($Record in $Records) {
        $Flattened.Add([PSCustomObject](ConvertTo-FlatRecord -Record $Record))
    }

    $Destination = $OutputPath

    if ([string]::IsNullOrWhiteSpace($Destination)) {
        $Destination = Join-Path (Get-LdgcrmRunDirectory) ($OutputName + ".csv")
    }

    Write-Utf8NoBomCsv -InputObject $Flattened -Path $Destination

    Write-Host ""
    Write-Host ("Records: " + $Flattened.Count)
    Write-Host ("CSV    : " + $Destination)

    if ($Flattened.Count -eq 0) {
        Write-Warning ("The query returned no rows. That is a result, not an error - but if the " +
                       "sandbox was expected to hold these records, check the run-as user's " +
                       "record-level access before concluding the data is missing.")
    }

    Write-Host ""
    Write-Host "This CSV contains applicant PII. logs/ is gitignored; keep it that way."

    if ($PassThru) {
        $Flattened
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
