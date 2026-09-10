#Requires -Version 5.1

<#
    Runs a Salesforce NAMED QUERY as the External Client App
    LDGCRM_P3_Client_app_Localdev, over the OAuth 2.0 client-credentials flow,
    and writes the rows to a UTF-8 CSV.

        Invoke-LdgcrmNamedQuery.ps1
            Every Partner Portal admin on LDGCRM_Application_Contact__c.
            1,089 rows in Dev on 2026-09-09.

        Invoke-LdgcrmNamedQuery.ps1 -NamedQuery ldgcrmApplicationContactsByTeamUuid -TeamUuid "abc-123"

        Invoke-LdgcrmNamedQuery.ps1 -NamedQuery ldgcrmApplicationContactsByEmail -Email "a@b.gov"

        Invoke-LdgcrmNamedQuery.ps1 -NamedQuery ldgcrmApplicationContactsModifiedSince -ModifiedSince (Get-Date).AddDays(-1)

        Invoke-LdgcrmNamedQuery.ps1 -NamedQuery someOtherQuery -Parameters @{ x = "y" }

        Invoke-LdgcrmNamedQuery.ps1 -List
            What named queries does this org have?

    =========================================================================
    ONE NAMED QUERY PER SCENARIO, NOT ONE QUERY WITH OPTIONAL FILTERS
    =========================================================================
    "If the Named Query API has multiple parameters, you must include all of
    them as URI parameters." Every declared parameter is MANDATORY, there is no
    way to write "ignore this one", and SOQL will not let a bind variable sit on
    the left of a comparison - so ":teamUuid = 'ALL'" is not expressible either.

    The only wildcard left is LIKE, and LIKE NEVER MATCHES NULL. Measured in Dev
    on 2026-09-09: "LDGCRM_P3_Team_UUID__c LIKE '%'" returns 841 of the 1,089
    admins, because 248 of them have no team. A single query with an optional-
    looking team filter would drop 23% of the baseline in silence.

    So each scenario gets its own named query, declaring exactly the parameters
    its name implies. That is why the typed parameters below have NO defaults
    and are sent only when passed: for any given query, most of them are wrong.

    ** A PARAMETER THE QUERY DOES NOT DECLARE IS SILENTLY IGNORED. ** The guard
    in Get-NamedQueryDeclaredParameter is what makes this design safe - without
    it, aiming -TeamUuid at the wrong query returns every row and looks fine.

    =========================================================================
    THE ENDPOINT, AND WHY IT LOOKS LIKE IT DOES NOT EXIST
    =========================================================================
        GET /services/data/v<ApiVersion>/named/query/<ApiName>

    VERIFIED against PEOdV8DVn on 2026-09-09: 1,089 records, done=true, with
    exactly the columns ldgcrmApplicationContactsPartnerAdminOnly selects. Four plausible
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
    # API name of the named query, NOT its label. The default's label is
    # "Login.gov Application Contacts - Partner Admin Only", and passing that
    # will not resolve. -List prints the API names this org actually has.
    #
    # It defaults to the admin query because that one declares NO parameters, so
    # a zero-argument run still means something. Every other query in the set
    # needs its parameter passed.
    #
    # TAB-COMPLETES, rather than validating. A ValidateSet would be typo-proof
    # but would also reject any query added to the org after this file was last
    # edited, which is exactly the thing a generic runner must not do. The
    # completer suggests; the org decides. A wrong name is caught before the
    # call and answered with the list of real ones.
    [Parameter(ParameterSetName = "Run")]
    [ArgumentCompleter({
        param($CommandName, $ParameterName, $WordToComplete, $CommandAst, $FakeBoundParameters)

        # Static, and deliberately so: a completer that called Salesforce would
        # put a network round trip behind the Tab key.
        @(
            "ldgcrmApplicationContactsPartnerAdminOnly"
            "ldgcrmApplicationContactsAll"
            "ldgcrmApplicationContactsByTeamUuid"
            "ldgcrmApplicationContactsByEmail"
            "ldgcrmApplicationContactsModifiedSince"
        ) | Where-Object { $_ -like "$WordToComplete*" }
    })]
    [string]$NamedQuery = "ldgcrmApplicationContactsPartnerAdminOnly",

    # ---------------------------------------------------------------------
    # The typed parameters below are sent ONLY when you pass them explicitly.
    # ---------------------------------------------------------------------
    # There are no defaults, and that is deliberate. Each named query declares
    # exactly the parameters its name implies, so supplying one it does not
    # declare is a mistake rather than a harmless extra - and Salesforce will
    # not tell you, it just ignores it. The guard before the request checks what
    # you passed against what the query actually declares, in both directions.

    # ldgcrmApplicationContactsByTeamUuid
    [Parameter(ParameterSetName = "Run")]
    [string]$TeamUuid,

    # ldgcrmApplicationContactsByEmail
    [Parameter(ParameterSetName = "Run")]
    [string]$Email,

    # ldgcrmApplicationContactsModifiedSince
    [Parameter(ParameterSetName = "Run")]
    [datetime]$ModifiedSince,

    # Raw parameter values, for a named query this script knows nothing about.
    # Entries here OVERRIDE anything the typed parameters above produced.
    [Parameter(ParameterSetName = "Run")]
    [hashtable]$Parameters = @{},

    # List the org's named queries and exit. Needs a user that can read the
    # ApiNamedQuery tooling object - see the note where this is handled.
    [Parameter(ParameterSetName = "List", Mandatory = $true)]
    [switch]$List,

    # 67.0 is the highest this org serves, and what ldgcrmApplicationContactsPartnerAdminOnly
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

# Set by the catch below and returned after the transcript closes, so a failure
# is reported once as text and once as an exit code, rather than three times as
# a PowerShell error record. Exiting from inside the try would skip nothing -
# finally still runs - but this keeps the one exit in one place.
$ExitCode = 0

. (Join-Path $PSScriptRoot "Common.PortalIntegration.ps1")


function Get-NamedQueryDeclaredParameter {
    <#
        The :bind names the named query's own body declares, read from the org.

        WHY THIS EXISTS. ** A URI PARAMETER A NAMED QUERY DOES NOT DECLARE IS
        SILENTLY IGNORED. ** Not rejected, not warned about - dropped. Caught in
        Dev on 2026-09-09: the query still had a hard-coded
        "WHERE LGDCRM_P3_Partner_Portal_Admin__c = TRUE", this script sent five
        parameters at it, and the call returned 1,089 rows and printed all five
        as though they had been applied. A -TeamUuid run would have returned
        every row in the org and looked exactly like a filtered one.

        So the parameters this script sends are checked against the query that
        will actually run, every time. Comparing counts would not catch it - an
        ignored filter returns MORE rows, and more rows never looks like failure.

        Needs ViewSetup, which the integration user now has for the named query
        call itself, so this costs one extra request and no extra permission.

        CONTRACT: returns a PSCustomObject with .Read (did the org answer?),
        .Found (does a query of this name exist?) and .Names (an array, possibly
        empty). .Read false means the request failed; .Read true with .Found
        false means the org answered and has no such query, which is a typo and
        should be reported with the list of real names rather than as a failure
        to reach the org.

        IT IS AN OBJECT AND NOT AN ARRAY FOR A REASON. Returning a bare @()
        unrolls to nothing on the way out of a function, so a caller testing
        "$null -eq $result" cannot tell "the query declares no parameters" from
        "the body could not be read". That is exactly what happened on the first
        cut of this function: the body read fine, the old query declared zero
        parameters, the empty array vanished, and the script reported it could
        not reach the org. An object never unrolls.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$NamedQuery,

        [Parameter(Mandatory = $true)]
        [object]$Context
    )

    $Soql = "SELECT Body2 FROM ApiNamedQuery WHERE DeveloperName = '" + $NamedQuery + "'"
    $Uri = $Context.DataBase + "/tooling/query?q=" + [uri]::EscapeDataString($Soql)

    $Unread = [PSCustomObject]@{ Read = $false; Found = $false; Names = @() }
    $Response = $null

    try {
        $Response = Invoke-RestMethod -Method Get -Uri $Uri -Headers $Context.Headers
    }
    catch {
        return $Unread
    }

    $Rows = @($Response.records)

    # The org answered and has no query by this name. A typo, not a failure.
    if ($Rows.Count -eq 0) {
        return [PSCustomObject]@{ Read = $true; Found = $false; Names = @() }
    }

    if ($Rows.Count -ne 1) {
        return $Unread
    }

    $Body = [string]$Rows[0].Body2

    if ([string]::IsNullOrWhiteSpace($Body)) {
        return $Unread
    }

    # ":name" anywhere in the body. Salesforce has no datetime literal that
    # would false-positive here, because a bind is the only use of a colon in
    # SOQL outside a quoted string.
    $Names = @()

    foreach ($Match in [regex]::Matches($Body, ':([A-Za-z_][A-Za-z0-9_]*)')) {
        $Name = $Match.Groups[1].Value

        if ($Names -notcontains $Name) {
            $Names += $Name
        }
    }

    return [PSCustomObject]@{ Read = $true; Found = $true; Names = $Names }
}


function Get-NamedQueryName {
    <#
        Every named query API name in the org, for tab completion and for telling
        someone what they could have typed.

        CONTRACT: returns a plain array, empty if the org cannot be reached. It is
        a convenience, so it NEVER throws - a completer that threw would break
        tab-completion in a way that looks like the shell is broken.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Context
    )

    $Soql = "SELECT DeveloperName FROM ApiNamedQuery ORDER BY DeveloperName"
    $Uri = $Context.DataBase + "/tooling/query?q=" + [uri]::EscapeDataString($Soql)

    try {
        $R = Invoke-RestMethod -Method Get -Uri $Uri -Headers $Context.Headers
        return @($R.records | ForEach-Object { $_.DeveloperName })
    }
    catch {
        return @()
    }
}

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

    # ONLY what the caller actually passed. $PSBoundParameters is the test, not
    # "is it non-empty" - an explicit -Email "" is still a deliberate filter,
    # and an omitted -TeamUuid must not become teamUuid="" and quietly match
    # nothing. Nothing has a default, so nothing is sent by accident.
    $Effective = @{}

    # ** PARAMETER NAMES ARE LOWERCASE, AND SALESFORCE ENFORCES IT. ** A deploy
    # carrying parameterName "teamUuid" is rejected with "must be lowercase", and
    # a :teamUuid bind in the body is echoed back lowercased in error messages.
    # So the SOQL bind, the parameterName and the URI parameter are all one
    # lowercase word, and nothing here should camelCase them back.
    if ($PSBoundParameters.ContainsKey("TeamUuid")) { $Effective["teamuuid"] = $TeamUuid }
    if ($PSBoundParameters.ContainsKey("Email")) { $Effective["email"] = $Email }

    if ($PSBoundParameters.ContainsKey("ModifiedSince")) {
        # A datetime literal must carry an offset and NO fractional seconds.
        # "o" emits seven of them (2026-09-09T00:00:00.0000000-04:00), which is
        # not one of the literal forms the Named Query API documents.
        $Effective["modifiedsince"] = $ModifiedSince.ToString("yyyy-MM-ddTHH:mm:sszzz")
    }

    foreach ($Key in $Parameters.Keys) {
        $Effective[[string]$Key] = $Parameters[$Key]
    }

    # Prove the query declares what we are about to send. See
    # Get-NamedQueryDeclaredParameter for why a count check cannot do this.
    $Declared = Get-NamedQueryDeclaredParameter -NamedQuery $NamedQuery -Context $Context

    if ($Declared.Read -and -not $Declared.Found) {
        # The org answered and has nothing by this name. Say what it does have,
        # rather than letting the call fail later on a resolution error that
        # reads like a permission problem.
        $Available = @(Get-NamedQueryName -Context $Context)

        throw ("No named query called '" + $NamedQuery + "' exists in " +
               $Context.Environment.Label + "." + [Environment]::NewLine +
               $(if ($Available.Count -eq 0) {
                     "The org returned no named queries at all."
                 } else {
                     "It has:" + [Environment]::NewLine + "  " + ($Available -join ([Environment]::NewLine + "  "))
                 }) + [Environment]::NewLine +
               "Pass the API NAME, not the label. -List prints these with their labels.")
    }

    if (-not $Declared.Read) {
        Write-Warning ("Could not read " + $NamedQuery + "'s body from the org, so the parameters " +
                       "below are UNVERIFIED. Salesforce ignores a parameter a named query does not " +
                       "declare, so a filter may do nothing and the row count will not show it.")
    }
    else {
        $DeclaredNames = @($Declared.Names)
        $Ignored = @($Effective.Keys | Where-Object { $DeclaredNames -notcontains $_ })
        $Unset = @($DeclaredNames | Where-Object { -not $Effective.ContainsKey($_) })

        if ($Ignored.Count -gt 0) {
            throw ("These parameters are not declared by '" + $NamedQuery + "' and Salesforce would " +
                   "SILENTLY IGNORE them: " + (($Ignored | Sort-Object) -join ", ") + [Environment]::NewLine +
                   "The query would run unfiltered and return MORE rows, which never looks like a" + [Environment]::NewLine +
                   "failure. The query declares: " +
                   $(if ($DeclaredNames.Count -eq 0) { "no parameters at all" } else { (($DeclaredNames | Sort-Object) -join ", ") }) + "." + [Environment]::NewLine +
                   "Fix the query body in Setup > Integrations > Named Query API, or drop the" + [Environment]::NewLine +
                   "parameters. scripts/docs/integration-user.md section 3 has the body to paste.")
        }

        if ($Unset.Count -gt 0) {
            throw ("'" + $NamedQuery + "' declares parameters this run does not supply: " +
                   (($Unset | Sort-Object) -join ", ") + [Environment]::NewLine +
                   "Every parameter a named query declares is mandatory. Pass them with -Parameters.")
        }
    }

    if ($Effective.Count -gt 0) {
        $Pairs = @()

        foreach ($Key in $Effective.Keys) {
            $Pairs += ([uri]::EscapeDataString([string]$Key) + "=" +
                       [uri]::EscapeDataString([string]$Effective[$Key]))
        }

        $Uri = $Uri + "?" + ($Pairs -join "&")
    }

    Write-Host ("Named Query : " + $NamedQuery)

    foreach ($Key in ($Effective.Keys | Sort-Object)) {
        Write-Host ("  " + $Key.PadRight(14) + " = " + $Effective[$Key])
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
            # SIX LINES, ON PURPOSE. This message used to run to thirty, and
            # PowerShell prints a thrown string THREE TIMES - once here, once as
            # the error record, once inside FullyQualifiedErrorId - so thirty
            # lines arrived as ninety and buried the one line that mattered.
            # The reasoning lives in the doc; the console gets the verdict.
            throw ("Named query '" + $NamedQuery + "' did not resolve FOR THIS CALLER." + [Environment]::NewLine +
                   $Detail + [Environment]::NewLine +
                   [Environment]::NewLine +
                   "THE CALLER IS MISSING 'View Setup and Configuration'. Salesforce's REST API" + [Environment]::NewLine +
                   "guide lists it under User Permissions Needed: 'To execute a Named Query API:" + [Environment]::NewLine +
                   "View Setup and Configuration'. Read access on the queried object governs" + [Environment]::NewLine +
                   "which ROWS come back, not who may CALL - which is why the blog's 'just needs" + [Environment]::NewLine +
                   "read access' is true and still not enough." + [Environment]::NewLine +
                   [Environment]::NewLine +
                   "That SOQL above is Salesforce's, not ours: it resolves the name by querying" + [Environment]::NewLine +
                   "ApiNamedQuery, a SETUP entity, as whoever called - and reports an entity the" + [Environment]::NewLine +
                   "caller cannot see as a column that does not exist." + [Environment]::NewLine +
                   [Environment]::NewLine +
                   "FIX: add ViewSetup to LDGCRM_Partnership_Portal_API_R. That is additive" + [Environment]::NewLine +
                   "metadata, so it travels in a CHANGE SET, not a CLI deploy. It also widens the" + [Environment]::NewLine +
                   "integration's reach past what section 4 of the doc describes - read it first." + [Environment]::NewLine +
                   "scripts/docs/integration-user.md section 3." + [Environment]::NewLine +
                   "Reads the same rows meanwhile: Invoke-LdgcrmSalesforceQuery.ps1")
        }
    }

    $Records = Invoke-PortalRestPaged -Uri $Uri -Context $Context -OnError $OnError

    # ---------------------------------------------------------------------
    # 6. Write
    # ---------------------------------------------------------------------
    $null = Save-PortalRecordCsv -Records $Records -OutputName $NamedQuery -OutputPath $OutputPath

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

    # exit 1, NOT re-throw. Re-throwing printed the whole message a second time
    # as the error record and a third inside FullyQualifiedErrorId, on top of
    # the Write-Host above. The exit code still says the run failed, the finally
    # below still closes the transcript, and the operator reads it once.
    $ExitCode = 1
}
finally {
    Stop-ToolLog
}

exit $ExitCode
