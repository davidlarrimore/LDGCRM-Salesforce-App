#Requires -Version 5.1

<#
    Shared plumbing for the Partner Portal (P3) integration readers in this
    folder. Dot-source THIS and nothing else - it pulls in Common.Tools.ps1 and
    the loading pipeline's Common.ps1 itself, so a caller needs one line:

        . (Join-Path $PSScriptRoot "Common.PortalIntegration.ps1")

    =========================================================================
    KEEP THIS FILE PURE ASCII
    =========================================================================
    powershell.exe decodes a BOM-less .ps1 as the system ANSI codepage, so a
    smart quote or an arrow in a comment does not merely look wrong - it can
    stop the file parsing. Write "-" and "->", never the typographic forms.
    Same rule applies to every .ps1 in this repo; see CLAUDE.md.
#>

. (Join-Path $PSScriptRoot "..\Common.Tools.ps1")
# For Import-DotEnv and, through Common.Orgs.ps1, Get-LdgcrmEnvironmentTable -
# the same registry every loading script proves its target against.
. (Join-Path $PSScriptRoot "..\data-loading\Common.ps1")

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

        CONTRACT: returns a printable string; never throws.
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


function Get-PortalApiContext {
    <#
        Reads the three .env values, PROVES the target is a registered Dev or QA
        sandbox, and exchanges the External Client App's consumer key/secret for
        an access token over the OAuth 2.0 client-credentials flow.

        The registry check runs BEFORE the token request on purpose. These
        readers pull applicant PII, production is deliberately absent from
        Get-LdgcrmEnvironmentTable, and a production-side reader belongs in its
        own purpose-built tool rather than behind a loosened check on this one.

        CONTRACT: returns one PSCustomObject; the caller assigns it bare and
        must NOT wrap the call in @(). Properties:

            Environment  the matched registry row (Label, SandboxName, ...)
            ApiBase      instance to call, as Salesforce handed it back
            DataBase     ApiBase + /services/data/v<ApiVersion>
            Headers      Authorization + Accept, ready for Invoke-RestMethod
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ApiVersion
    )

    Import-DotEnv

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

    # --- prove the target before asking for a token -----------------------
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
               "Dev or QA sandbox. These tools read applicant PII and are dev/QA only; " +
               "production is deliberately absent from the registry, and a production-side " +
               "reader belongs in its own tool. Registered environments:" +
               [Environment]::NewLine + ($Known -join [Environment]::NewLine))
    }

    Write-Host ("Target      : " + $Environment.Label + " (" + $Environment.SandboxName + ")")
    Write-Host ("Instance URL: " + $Environment.InstanceUrl)
    Write-Host ("API version : v" + $ApiVersion)
    Write-Host ""
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

    Write-Host "Token acquired."
    Write-Host ""

    return [PSCustomObject]@{
        Environment = $Environment
        ApiBase     = $ApiBase
        DataBase    = $ApiBase + "/services/data/v" + $ApiVersion
        Headers     = @{
            Authorization = "Bearer " + $Token.access_token
            Accept        = "application/json"
        }
    }
}


function Invoke-PortalRestPaged {
    <#
        GETs $Uri and follows nextRecordsUrl to the end, returning every record.

        Prints a per-page COUNT and nothing else. That is deliberate: these rows
        are applicant PII, they belong in the CSV and nowhere else, and a
        transcript that echoed them would become a second uncontrolled copy.

        CONTRACT: returns a List[object] via a leading comma, so the caller
        assigns it bare and must NOT wrap the call in @() - doing both yields a
        one-element array containing the list, whose .Count is silently 1.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [object]$Context,

        # Called with the Get-HttpErrorDetail string when a request fails. Lets
        # each caller add its own diagnosis without duplicating the paging loop.
        [scriptblock]$OnError = $null
    )

    $Records = [System.Collections.Generic.List[object]]::new()
    $Next = $Uri
    $Page = 0

    while (-not [string]::IsNullOrWhiteSpace($Next)) {
        $Page = $Page + 1
        $Response = $null

        try {
            $Response = Invoke-RestMethod -Method Get -Uri $Next -Headers $Context.Headers
        }
        catch {
            $Detail = Get-HttpErrorDetail -ErrorRecord $_

            if ($null -ne $OnError) {
                # A caller's handler is expected to throw with a better message.
                & $OnError $Detail
            }

            if ($Detail -match "INSUFFICIENT_ACCESS" -or $Detail -match "INVALID_SESSION_ID") {
                throw ("The integration user may not read this object or one of these fields: " + $Detail +
                       [Environment]::NewLine +
                       "Check the app's 'Run As' user still holds LDGCRM_Partnership_Portal_API_R.")
            }

            throw ("Request failed: " + $Detail)
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
                $Next = $Context.ApiBase + $Response.nextRecordsUrl
            }
        }
    }

    return ,$Records
}


function Save-PortalRecordCsv {
    <#
        Flattens records and writes the CSV, then reports counts and the PII
        reminder. Returns the destination path.

        CONTRACT: returns a string; caller assigns bare.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object]$Records,

        [Parameter(Mandatory = $true)]
        [string]$OutputName,

        [string]$OutputPath = ""
    )

    # A List, not "$Flattened += ...". Appending to a PowerShell array rebuilds
    # the whole array on every row, which is quadratic.
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

    return $Destination
}
