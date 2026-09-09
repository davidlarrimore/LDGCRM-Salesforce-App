#Requires -Version 5.1
<#
    ACCOUNT MATCHING AND CREATION - the shared rules, in one place.

    Extracted from Build-AccountReconciliation.ps1 so the reconciliation, the
    creation transform and any future analysis all decide "is this the same
    office?" the same way. Three scripts previously answered that question with
    three different amounts of care, which is how a Housing and Urban
    Development row came to own Commerce's Account.

    WHAT THIS EXISTS TO PREVENT
    ---------------------------
    1. WRONG LINKS. Matching on name alone, where a name matches exactly one
       Account, silently attaches one agency's records to another agency's
       office. Seven Accounts were linked that way. Parent is therefore a VETO
       here, not a tie-breaker: where Airtable names a parent and the
       candidate's agency contradicts it, that is not a match at any candidate
       count.

    2. NEEDLESS CREATION. Production disambiguates same-named offices with an
       agency suffix ("Office of Civil Rights - GSA") while Airtable stores the
       bare name plus a Parent column. A matcher that does not know that
       convention proposes creating records that already exist. The cascade
       below tries the suffix in both directions before giving up.

    NOTHING HERE WRITES TO SALESFORCE.
#>

# No Set-StrictMode here on purpose: this file is dot-sourced into other
# scripts, and setting it would silently change THEIR strictness for the rest
# of the run. A library does not get to make that choice for its callers.

# ------------------------------------------------------------
# NAME NORMALISATION
# ------------------------------------------------------------

function Get-LdgcrmNameExact {
    <# Trim + lower-case only. The conservative key. #>
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return "" }
    return $Name.Trim().ToLowerInvariant()
}

function Get-LdgcrmNameLoose {
    <#
        Punctuation-insensitive key. "Economic & Business Affairs" and
        "Economic and Business Affairs" are the same office; en/em dashes are
        folded because Airtable produces them and Salesforce does not
        ("Interpol - Washington" vs "INTERPOL Washington").
    #>
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return "" }
    $s = $Name.Trim().ToLowerInvariant()
    $s = $s -replace [char]0x2013, '-'
    $s = $s -replace [char]0x2014, '-'
    $s = $s -replace '&', ' and '
    $s = $s -replace '[^a-z0-9 ]', ' '
    $s = $s -replace '\s+', ' '
    return $s.Trim()
}

# Words that carry no discriminating power in a federal office name, so token
# overlap is not dominated by them.
$Script:LdgcrmNameStopWords = @(
    'the','for','and','of','us','usa','united','states','department','dept',
    'office','bureau','national','federal','agency','administration'
)

function Get-LdgcrmNameTokens {
    param([string]$Name)
    $Loose = Get-LdgcrmNameLoose -Name $Name
    if (-not $Loose) { return @() }
    return @($Loose -split ' ' | Where-Object {
        $_.Length -gt 2 -and $Script:LdgcrmNameStopWords -notcontains $_
    })
}

function Split-LdgcrmAgencySuffix {
    <#
        Splits "Office of Civil Rights - GSA" into its bare name and suffix.
        Returns the input unchanged when there is no suffix.

        The pattern is deliberately tight - 1 to 6 letters after " - " - so an
        ordinary hyphenated name ("Interpol - Washington") is not mistaken for
        a suffixed one.
    #>
    param([string]$Name)

    $Result = [PSCustomObject]@{ Bare = $Name; Suffix = "" }
    if ([string]::IsNullOrWhiteSpace($Name)) { return $Result }

    if ($Name -match '^(.+?)\s+-\s+([A-Za-z]{1,6})$') {
        $Result.Bare   = $Matches[1]
        $Result.Suffix = $Matches[2]
    }
    return $Result
}

# ------------------------------------------------------------
# THE ACCOUNT INDEX
# ------------------------------------------------------------

function New-LdgcrmAccountIndex {
    <#
        Builds every lookup the cascade needs, once.

        -Accounts expects objects carrying Name and ParentName. Both the
        production export (Import-ProdAccountExport) and a Salesforce query
        (flattened from Parent.Name) can be shaped to that, so the same
        matching runs against either without a second implementation.

        Returns a PSCustomObject the other functions in this file consume.
        Treat it as opaque.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Accounts
    )

    $ByLoose   = @{}   # loose name  -> list of accounts
    $Children  = @{}   # loose parent name -> list of accounts
    $NameCount = @{}   # exact name  -> how many accounts bear it

    foreach ($Account in $Accounts) {
        $Name = $Account.Name
        if ([string]::IsNullOrWhiteSpace($Name)) { continue }

        $Loose = Get-LdgcrmNameLoose -Name $Name

        # Cached on the record itself, because the whole-export sweep runs once
        # per unmatched Airtable row and would otherwise re-derive the loose
        # name and tokens for every Account, every time - 720 x 1,352 string
        # rebuilds, which took the reconciliation from seconds to minutes.
        $Account | Add-Member -NotePropertyName LdgcrmLoose  -NotePropertyValue $Loose -Force
        $Account | Add-Member -NotePropertyName LdgcrmTokens -NotePropertyValue (Get-LdgcrmNameTokens -Name $Name) -Force
        $Account | Add-Member -NotePropertyName LdgcrmKey    -NotePropertyValue (Get-LdgcrmAccountKey -Account $Account) -Force

        if ($Loose) {
            if (-not $ByLoose.ContainsKey($Loose)) { $ByLoose[$Loose] = New-Object System.Collections.ArrayList }
            [void]$ByLoose[$Loose].Add($Account)
        }

        $Exact = Get-LdgcrmNameExact -Name $Name
        if ($Exact) {
            if (-not $NameCount.ContainsKey($Exact)) { $NameCount[$Exact] = 0 }
            $NameCount[$Exact]++
        }

        $ParentKey = Get-LdgcrmNameLoose -Name $Account.ParentName
        if ($ParentKey) {
            if (-not $Children.ContainsKey($ParentKey)) { $Children[$ParentKey] = New-Object System.Collections.ArrayList }
            [void]$Children[$ParentKey].Add($Account)
        }
    }

    return [PSCustomObject]@{
        # EVERY structure here is IMMUTABLE and describes the org as it is.
        # Claiming is tracked separately, in Claimed, and filtered at the point
        # of use.
        #
        # An earlier version removed claimed records from these instead, which
        # was wrong in a way that only showed up once the agency lookup started
        # using them: an agency is still an agency after its own Airtable row
        # has claimed it. Removing "General Services Administration" when its
        # row matched meant every later GSA child failed to resolve its own
        # agency, and 11 Accounts that had matched stopped matching. Hierarchy
        # is a fact about the org; claiming is a fact about this run.
        Accounts    = $Accounts
        ByLoose     = $ByLoose
        Children    = $Children
        NameCount   = $NameCount
        Claimed     = @{}
        SuffixByAgency = (New-LdgcrmAgencySuffixMap -Accounts $Accounts)
    }
}

function Get-LdgcrmAccountKey {
    <#
        Identity for an Account within one run. Id where there is one - a
        Salesforce query - and name-under-parent where there is not, which is
        the production export, whose Ids are unreliable and deliberately not
        returned by Import-ProdAccountExport.
    #>
    param([Parameter(Mandatory = $true)]$Account)

    if ($Account.PSObject.Properties.Name -contains 'Id' -and $Account.Id) { return [string]$Account.Id }
    return ("{0}|{1}" -f (Get-LdgcrmNameLoose -Name $Account.Name), (Get-LdgcrmNameLoose -Name $Account.ParentName))
}

function Remove-LdgcrmAccountFromIndex {
    <#
        Takes an Account out of the candidate pool once an Airtable row has
        claimed it.

        This is what stops two Airtable rows resolving to the SAME Salesforce
        Account and overwriting each other's external ID - which reports as a
        clean success while quietly losing one of the rows. The second row
        finds nothing left and is reported, which is the honest outcome.

        Removal is by identity, not by index position: with parent matching the
        winner is not necessarily the first candidate in the list.
    #>
    param(
        [Parameter(Mandatory = $true)]$Index,
        [Parameter(Mandatory = $true)]$Account
    )

    # Marked, not removed. The index describes the org; removing a record from
    # it would also remove it from the HIERARCHY, and a claimed Account is still
    # somebody's parent.
    $Index.Claimed[$Account.LdgcrmKey] = $true
}

function Test-LdgcrmAccountClaimed {
    param(
        [Parameter(Mandatory = $true)]$Index,
        [Parameter(Mandatory = $true)]$Account
    )
    # The key is cached on the record at index time; deriving it here instead
    # cost a PSObject.Properties walk per account per row.
    return $Index.Claimed.ContainsKey($Account.LdgcrmKey)
}

function New-LdgcrmAgencySuffixMap {
    <#
        Learns the "- ACRONYM" convention FROM THE DATA rather than hard-coding
        a list of agency acronyms here.

        The org already writes "Office of Civil Rights - GSA" and "Office of the
        General Counsel - NRC", so the mapping from an agency to its suffix is
        recoverable by reading existing names. A hard-coded table would drift
        from the org the moment anyone added an agency, and would be wrong in
        any org whose conventions differ.

        Where an agency's children disagree, the most common suffix wins.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Accounts
    )

    $Votes = @{}

    foreach ($Account in $Accounts) {
        if ([string]::IsNullOrWhiteSpace($Account.Name)) { continue }

        $Split = Split-LdgcrmAgencySuffix -Name $Account.Name
        if (-not $Split.Suffix) { continue }

        # Only an UPPER-CASE suffix is a convention marker. "Interpol -
        # Washington" splits cleanly but is a place, not an acronym.
        if ($Split.Suffix -cne $Split.Suffix.ToUpperInvariant()) { continue }

        $Agency = Get-LdgcrmNameLoose -Name $Account.ParentName
        if (-not $Agency) { continue }

        if (-not $Votes.ContainsKey($Agency)) { $Votes[$Agency] = @{} }
        if (-not $Votes[$Agency].ContainsKey($Split.Suffix)) { $Votes[$Agency][$Split.Suffix] = 0 }
        $Votes[$Agency][$Split.Suffix]++
    }

    $Map = @{}
    foreach ($Agency in $Votes.Keys) {
        $Winner = ($Votes[$Agency].GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1)
        $Map[$Agency] = $Winner.Key
    }
    return $Map
}

function Resolve-LdgcrmAgencyName {
    <#
        Maps the agency name Airtable writes onto the name this org uses, so
        the subtree filter actually finds something.

        WHY THIS EXISTS. The agency name was previously looked up verbatim, and
        a miss meant no subtree at all - the row skipped agency scoping and went
        to the whole-org sweep, which is where every bad suggestion comes from.
        Measured against Dev: 530 rows name a parent and 51 of them resolved to
        nothing, because the two systems use different words for the same body -
        Airtable's "The Executive Office of the President" against the org's
        "Executive Office of the President", "Army" against "Department of the
        Army", "Congress" against "U.S. Congress".

        It is the same variant problem already handled for the CHILD name; it
        simply was never applied to the parent.

        Containment only counts when exactly ONE Account matches. "Army" inside
        both "Department of the Army" and "U.S. Army Futures Command" resolves
        to neither, because scoping to the wrong agency is worse than not
        scoping at all - it would hide the real candidates instead of merely
        failing to narrow them.

        Returns the Account name to scope by, or "" when nothing is confident.
    #>
    param(
        [Parameter(Mandatory = $true)]$Index,
        [Parameter(Mandatory = $true)][string]$ParentName
    )

    if ([string]::IsNullOrWhiteSpace($ParentName)) { return "" }

    $Loose = Get-LdgcrmNameLoose -Name $ParentName

    # 1. the name as written
    if ($Index.ByLoose.ContainsKey($Loose) -and $Index.ByLoose[$Loose].Count -ge 1) { return $ParentName }

    # 2. one Account whose name contains this one, or is contained by it
    $Hits = @($Index.Accounts | Where-Object {
        $Their = $_.LdgcrmLoose
        $Their -and ($Their -like "*$Loose*" -or $Loose -like "*$Their*")
    })

    if ($Hits.Count -eq 1) { return $Hits[0].Name }

    # 3. several candidates: take one only if exactly one of them is an agency
    #    -level record, i.e. sits at the top of the tree. "Army" matches both
    #    "Department of the Army" (top level) and "U.S. Army Futures Command"
    #    (a child); the department is the one being named.
    $TopLevel = @($Hits | Where-Object { [string]::IsNullOrWhiteSpace($_.ParentName) })
    if ($TopLevel.Count -eq 1) { return $TopLevel[0].Name }

    return ""
}

function Get-LdgcrmAccountDescendants {
    <#
        Every Account beneath an agency, to a bounded depth.

        This is what makes the parent a veto: the candidate pool for a row that
        names an agency IS that agency's subtree, so an office belonging to a
        different department can never be considered in the first place.

        Depth is bounded rather than unbounded because the hierarchy is
        self-referential and a cycle would otherwise hang the run.
    #>
    param(
        [Parameter(Mandatory = $true)]$Index,
        [Parameter(Mandatory = $true)][string]$AgencyName,
        [int]$MaxDepth = 4
    )

    $Out      = New-Object System.Collections.ArrayList
    $Seen     = @{}
    $Frontier = @($AgencyName)

    for ($Depth = 0; $Depth -lt $MaxDepth; $Depth++) {
        $Next = New-Object System.Collections.ArrayList

        foreach ($Parent in $Frontier) {
            $Key = Get-LdgcrmNameLoose -Name $Parent
            if (-not $Key -or -not $Index.Children.ContainsKey($Key)) { continue }

            foreach ($Child in $Index.Children[$Key]) {
                if ($Seen.ContainsKey($Child.Name)) { continue }
                $Seen[$Child.Name] = $true
                [void]$Out.Add($Child)
                [void]$Next.Add($Child.Name)
            }
        }

        $Frontier = $Next
    }

    # Returned BARE: every call site wraps it in @(). Combining that with a
    # leading comma yields a one-element array holding the list - the trap
    # documented in CLAUDE.md.
    return $Out.ToArray()
}

# ------------------------------------------------------------
# THE CASCADE
# ------------------------------------------------------------

function Get-LdgcrmAccountLevelRank {
    <#
        Orders Account_Level__c so "nearer the top of the hierarchy" sorts first.

        Account_Level__c is NOT ours - it is un-prefixed and belongs to the
        OTCRM app - so this only ever READS it, to choose between records the
        org already holds. Nothing here writes it.

        "Level 3 or below" is a LEGACY value that coexists with "Level 3" (40
        records against 297 in the 2026-07-16 production export). It ranks below
        every concrete level deliberately: the three self-parented Accounts in
        production all carry it, so where a duplicate offers a concrete level
        and its twin offers this one, the concrete record is the sound one.

        A blank level ranks last rather than throwing. Callers that never
        populate Level get 99 for every candidate, which makes this a no-op and
        leaves the older top-level/lowest-Id behaviour exactly as it was.
    #>
    param([string]$Level)

    switch ("$Level".Trim()) {
        "Level 1"          { return 1 }
        "Level 2"          { return 2 }
        "Level 3"          { return 3 }
        "Level 4+"         { return 4 }
        "Level 3 or below" { return 5 }
        default            { return 99 }
    }
}

function Test-LdgcrmAccountSelfParented {
    <#
        True when an Account is its own parent - a corruption, not a hierarchy.

        Three production Accounts are in this state (Department of Defense,
        District of Columbia, Office of the Director of National Intelligence),
        every one of them also carrying the legacy "Level 3 or below". Matched
        on Id where both are known, falling back to name for callers shaped from
        the production export, which has no Ids for parents.
    #>
    param([object]$Account)

    $Id = "$($Account.Id)"
    $ParentId = "$($Account.ParentId)"
    if ($Id -and $ParentId -and $Id -eq $ParentId) { return $true }

    # The export names parents rather than keying them, so compare names when
    # there is no parent Id to compare.
    if (-not $ParentId) {
        $Name = "$($Account.Name)"
        $ParentName = "$($Account.ParentName)"
        if ($Name -and $ParentName -and $Name -eq $ParentName) { return $true }
    }

    return $false
}

function Select-LdgcrmDuplicateAccount {
    <#
        Picks one Account from a set that all bear the same name.

        Salesforce holds the same body twice under 22+ names. Refusing to choose
        cost records in every org: AmeriCorps and MCC lose 5, U.S. Army Futures
        Command lost 46 on 2026-08-16. The duplicates are being cleaned up after
        the migration either way, so picking one and reporting it is strictly
        better than loading nothing (project owner, 2026-08-17).

        The pick is DETERMINISTIC so re-runs choose the same record:
          1. A self-parented record loses to any twin that is not. It is
             corrupt, and in production it is always the wrong one.
          2. Top level (no parent) wins. Where the duplicate is an independent
             agency filed under a department by mistake, the top-level record is
             the correct one - verified for AmeriCorps and MCC.
          3. The best Account_Level__c wins. ADDED 2026-08-24: rules 1-2 leave
             District of Columbia tied on two top-level records, and lowest-Id
             then picked the "Level 3 or below" one over the "Level 1" one.
             This step only decides ties the earlier ones could not, so the
             AmeriCorps/MCC and Army Futures Command outcomes are unchanged.
          4. Otherwise the lowest Id, which is stable and usually the oldest.

        Callers must still report the pick: the losing record is a duplicate
        someone has to merge.
    #>
    param([object[]]$Candidates)

    $All = @($Candidates)
    if ($All.Count -eq 0) { return $null }
    if ($All.Count -eq 1) { return $All[0] }

    $Sound = @($All | Where-Object { -not (Test-LdgcrmAccountSelfParented -Account $_) })
    if ($Sound.Count -gt 0) { $All = $Sound }
    if ($All.Count -eq 1) { return $All[0] }

    $TopLevel = @($All | Where-Object {
        [string]::IsNullOrWhiteSpace("$($_.ParentId)") -and [string]::IsNullOrWhiteSpace("$($_.ParentName)")
    })

    $Pool = if ($TopLevel.Count -gt 0) { $TopLevel } else { $All }

    return @($Pool | Sort-Object `
        @{ Expression = { Get-LdgcrmAccountLevelRank -Level "$($_.Level)" } }, `
        @{ Expression = { "$($_.Id)" } })[0]
}

function Get-LdgcrmParentRepairPlan {
    <#
        Decides which Accounts are parented onto a DUPLICATE of their real
        parent, and which sound twin each should point at instead.

        Lives here rather than inside Build-AccountParentRepair.ps1 because it
        is the only rule in this pipeline that writes ParentId on a record the
        migration did not create. Keeping it a pure function of its input makes
        it testable without an org, which is the only way this rule can be
        checked at all: Dev and QA have a bootstrapped hierarchy with a blank
        Account_Level__c, so neither validation rule can fire there and the
        whole path is dead code until it reaches a production copy.

        -Accounts expects objects carrying Id, Name, ParentId, ParentName,
        ParentLevel and Level.

        Returns an object with four collections:
          Repairs      Id / ParentId pairs, ready for an UPDATE load
          Review       every decision, repointed and not, with its reason
          SelfParented Accounts that are their own parent - reported, never edited
          AlreadySound how many children already satisfy the level rule
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Accounts
    )

    # The parent level each child level REQUIRES, straight off
    # OTCRM_Federal_Parent_Account_Level_Check. A level absent from this table
    # cannot trip that rule, so those children are not this function's business.
    $RequiredParentLevel = @{
        "Level 2"  = "Level 1"
        "Level 3"  = "Level 2"
        "Level 4+" = "Level 3"
    }

    # Exact name -> every Account bearing it. The duplicates this repairs are
    # exact duplicates; a loose match here would repoint a child onto a
    # DIFFERENT office whose name merely resembles its parent's, which is the
    # failure mode the reconciliation's agency veto exists to prevent.
    $ByExactName = @{}
    foreach ($Account in $Accounts) {
        $Key = "$($Account.Name)".Trim()
        if (-not $Key) { continue }
        if (-not $ByExactName.ContainsKey($Key)) {
            $ByExactName[$Key] = [System.Collections.Generic.List[object]]::new()
        }
        $ByExactName[$Key].Add($Account)
    }

    $Repairs = [System.Collections.Generic.List[object]]::new()
    $Review = [System.Collections.Generic.List[object]]::new()
    $SelfParented = [System.Collections.Generic.List[object]]::new()
    $AlreadySound = 0

    foreach ($Account in $Accounts) {

        $Level = "$($Account.Level)".Trim()
        $ParentId = "$($Account.ParentId)"
        $ParentName = "$($Account.ParentName)".Trim()
        $ParentLevel = "$($Account.ParentLevel)".Trim()

        # An Account that is its own parent is corrupt whether or not a rule
        # fires on it today. Reported so the duplicate can be merged, but never
        # edited here: nothing this function knows says what its parent SHOULD
        # be, and clearing it is a different decision from repointing a child.
        if (Test-LdgcrmAccountSelfParented -Account $Account) {
            $SelfParented.Add([PSCustomObject]@{
                SalesforceId = $Account.Id
                Name         = $Account.Name
                Level        = $Level
                Reason       = "This Account is its own parent. Corrupt hierarchy - merge it into the sound record of the same name. Not edited by this script."
            })
        }

        # ---- Parent_Account_Required_for_Level_3_Acct --------------------
        # No parent to repoint, so repointing cannot fix it.
        if ($Level -eq "Level 3 or below" -and -not $ParentId) {
            $Review.Add([PSCustomObject]@{
                SalesforceId  = $Account.Id
                Name          = $Account.Name
                Level         = $Level
                CurrentParent = ""
                Rule          = "Parent_Account_Required_for_Level_3_Acct"
                Reason        = "Marked 'Level 3 or below' with no parent at all. Needs a parent choosing, or relabelling to Level 1 - this script will not guess which."
            })
            continue
        }

        # ---- OTCRM_Federal_Parent_Account_Level_Check --------------------
        if (-not $RequiredParentLevel.ContainsKey($Level)) { continue }
        if (-not $ParentId) { continue }

        $Required = $RequiredParentLevel[$Level]
        if ($ParentLevel -eq $Required) { $AlreadySound++; continue }

        # The rule fires. Is there another Account of the parent's name
        # carrying exactly the level the rule wants?
        $Alternatives = @()
        if ($ParentName -and $ByExactName.ContainsKey($ParentName)) {
            $Alternatives = @($ByExactName[$ParentName] | Where-Object {
                "$($_.Id)" -ne $ParentId -and "$($_.Level)".Trim() -eq $Required
            })
        }

        $ParentLevelShown = if ($ParentLevel) { $ParentLevel } else { "blank" }

        if ($Alternatives.Count -eq 0) {
            $Review.Add([PSCustomObject]@{
                SalesforceId  = $Account.Id
                Name          = $Account.Name
                Level         = $Level
                CurrentParent = "$ParentName ($ParentId) is '$ParentLevelShown'"
                Rule          = "OTCRM_Federal_Parent_Account_Level_Check"
                Reason        = "Parent must be '$Required'. No other Account named '$ParentName' carries that level, so this is a mis-filing rather than a duplicate. Not repointed - a human must decide."
            })
            continue
        }

        # More than one sound alternative is possible; pick deterministically
        # the same way every other duplicate in this pipeline is picked.
        $Best = Select-LdgcrmDuplicateAccount -Candidates $Alternatives

        $Repairs.Add([PSCustomObject]@{
            Id       = $Account.Id
            ParentId = $Best.Id
        })

        $Review.Add([PSCustomObject]@{
            SalesforceId  = $Account.Id
            Name          = $Account.Name
            Level         = $Level
            CurrentParent = "$ParentName ($ParentId) is '$ParentLevelShown'"
            Rule          = "REPOINTED"
            Reason        = "Repointed to $($Best.Id), the '$Required' Account of the same name. The old parent is a duplicate that still needs merging."
        })
    }

    return [PSCustomObject]@{
        Repairs      = $Repairs
        Review       = $Review
        SelfParented = $SelfParented
        AlreadySound = $AlreadySound
    }
}

function Resolve-LdgcrmAccount {
    <#
        Decides what to do with one Airtable Account row.

        Returns:
          Verdict  Match   - one Account, confidently, inside the named agency
                   Confirm - candidates found, but a human must choose
                   Create  - nothing plausible; a new Account is needed
          Account  the matched Account object (Match only)
          Candidates  what was found (Confirm), or what was ruled out (Create)
          Route    which rule decided it, for the report
          ProposedName  the name a created Account should carry (Create only)

        The order matters. Exact beats loose beats suffix beats tokens, and a
        row only reaches Create after the whole export has been swept - because
        proposing to create an Account that already exists is the failure this
        was built to stop.
    #>
    param(
        [Parameter(Mandatory = $true)]$Index,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$ParentName = "",

        # Below this, token overlap inside the agency is treated as a
        # suggestion for a human rather than a match.
        [int]$ConfirmThreshold = 55
    )

    $Result = [PSCustomObject]@{
        Verdict      = ""
        Account      = $null
        Candidates   = @()
        Route        = ""
        ProposedName = ""
        # True when Verdict is Match but the name was duplicated in the org and
        # one was chosen. The row loads; the duplicate still needs merging, so
        # callers report these rather than passing them over in silence.
        PickedFromDuplicates = $false
    }

    $Split   = Split-LdgcrmAgencySuffix -Name $Name
    $Exact   = Get-LdgcrmNameExact -Name $Name
    $Loose   = Get-LdgcrmNameLoose -Name $Name
    $Bare    = Get-LdgcrmNameLoose -Name $Split.Bare
    $Tokens  = Get-LdgcrmNameTokens -Name $Split.Bare

    # Resolve the AGENCY first, then scope by it. Airtable and the org use
    # different words for the same body often enough that a verbatim lookup
    # loses the subtree entirely on ~10% of rows that name a parent.
    $Pool   = @()
    $Agency = ""
    if ($ParentName) {
        $Agency = Resolve-LdgcrmAgencyName -Index $Index -ParentName $ParentName
        if ($Agency) {
            # Claimed records are filtered HERE rather than removed from the
            # index, so the subtree walk still passes through them.
            $Pool = @(Get-LdgcrmAccountDescendants -Index $Index -AgencyName $Agency |
                      Where-Object { -not $Index.Claimed.ContainsKey($_.LdgcrmKey) })
        }
    }

    # The suffix convention is keyed on the agency as the ORG names it, so it
    # has to be looked up with the resolved name - "Health and Human Services"
    # knows no suffix, "Department of Health and Human Services" knows "HHS".
    $AgencyKey = Get-LdgcrmNameLoose -Name $(if ($Agency) { $Agency } else { $ParentName })
    $Suffix    = ""
    if ($AgencyKey -and $Index.SuffixByAgency.ContainsKey($AgencyKey)) {
        $Suffix = $Index.SuffixByAgency[$AgencyKey]
    }

    # ---------- inside the named agency ----------
    if ($Pool.Count -gt 0) {

        # 1. exact name
        $Hit = @($Pool | Where-Object { (Get-LdgcrmNameExact -Name $_.Name) -eq $Exact })
        if ($Hit.Count -eq 1) {
            $Result.Verdict = "Match"; $Result.Account = $Hit[0]; $Result.Route = "exact name, within the agency"
            return $Result
        }

        # 2. loose name, then the same with Airtable's own suffix removed
        foreach ($Key in @($Loose, $Bare)) {
            if (-not $Key) { continue }
            $Hit = @($Pool | Where-Object { $_.LdgcrmLoose -eq $Key })
            if ($Hit.Count -eq 1) {
                $Result.Verdict = "Match"; $Result.Account = $Hit[0]
                $Result.Route = if ($Key -eq $Loose) { "loose name, within the agency" } else { "Airtable's own '- suffix' removed" }
                return $Result
            }
        }

        # 3. add the agency's suffix to Airtable's name
        if ($Suffix) {
            $Want = Get-LdgcrmNameLoose -Name ("{0} - {1}" -f $Split.Bare, $Suffix)
            $Hit  = @($Pool | Where-Object { (Get-LdgcrmNameLoose -Name $_.Name) -eq $Want })
            if ($Hit.Count -eq 1) {
                $Result.Verdict = "Match"; $Result.Account = $Hit[0]
                $Result.Route = "name plus the agency's '- $Suffix' suffix"
                return $Result
            }
        }

        # 4. strip whatever suffix the production name carries
        $Hit = @($Pool | Where-Object {
            $S = Split-LdgcrmAgencySuffix -Name $_.Name
            $S.Suffix -and (Get-LdgcrmNameLoose -Name $S.Bare) -eq $Bare
        })
        if ($Hit.Count -eq 1) {
            $Result.Verdict = "Match"; $Result.Account = $Hit[0]; $Result.Route = "production's '- suffix' removed"
            return $Result
        }
        if ($Hit.Count -gt 1) {
            $Result.Verdict = "Confirm"; $Result.Candidates = $Hit; $Result.Route = "several suffixed candidates in the agency"
            return $Result
        }

        # 5. token overlap, still inside the agency
        $Scored = @($Pool | ForEach-Object {
            $Their  = $_.LdgcrmTokens
            $Shared = @($Tokens | Where-Object { $Their -contains $_ }).Count
            $Denom  = [Math]::Max(1, [Math]::Max($Tokens.Count, $Their.Count))
            [PSCustomObject]@{ Score = [int](100 * $Shared / $Denom); Account = $_ }
        } | Where-Object { $_.Score -ge $ConfirmThreshold } | Sort-Object Score -Descending)

        if ($Scored.Count -ge 1) {
            # AN EXACT NAME AT TOP LEVEL BEATS A FUZZY NAME INSIDE THE AGENCY.
            #
            # Airtable names a parent, so the agency subtree is searched first -
            # but when the org files that same body at TOP LEVEL instead, the
            # subtree holds only siblings with overlapping tokens. Returning
            # Confirm here reported "similar name within the agency" and never
            # reached the top-level rule further down, which would have matched
            # it exactly.
            #
            # Cost of the old order, 2026-08-16: U.S. Army Futures Command sat
            # top level after a rebuild while Airtable filed it under Department
            # of Defense. Three DoD siblings scored above the threshold, so it
            # was reported ambiguous - stranding its Partner Account and 28
            # Applications.
            $ExactAnywhere = @($Index.Accounts | Where-Object {
                -not $Index.Claimed.ContainsKey($_.LdgcrmKey) -and
                (Get-LdgcrmNameExact -Name $_.Name) -eq $Exact -and
                [string]::IsNullOrWhiteSpace("$($_.ParentName)")
            })

            if ($ExactAnywhere.Count -ge 1) {
                $Result.Verdict = "Match"
                $Result.Account = Select-LdgcrmDuplicateAccount -Candidates $ExactAnywhere
                if ($ExactAnywhere.Count -gt 1) {
                    $Result.Candidates = $ExactAnywhere
                    $Result.PickedFromDuplicates = $true
                }
                $Result.Route = "exact name at top level; Airtable files it under '$ParentName', which this org does not"
                return $Result
            }

            $Result.Verdict = "Confirm"; $Result.Candidates = @($Scored | Select-Object -First 3)
            $Result.Route = "similar name within the agency"
            return $Result
        }
    }

    # The index is immutable, so the two whole-export passes below filter
    # claimed records themselves. The key is cached on each record, making this
    # a plain hashtable lookup rather than the PSObject walk that once took the
    # reconciliation to five minutes.
    $Unclaimed = @($Index.Accounts | Where-Object { -not $Index.Claimed.ContainsKey($_.LdgcrmKey) })

    # ---------- no agency named: the whole org ----------
    if ($Pool.Count -eq 0) {

        # EXACT BEFORE LOOSE, and separately - the same precedence the in-agency
        # path uses. Testing "exact OR loose" in one pass collapses the two, so a
        # single exact match is outvoted by its own punctuation variants: the org
        # holds both "U.S. International Trade Commission" and "U.S
        # International Trade Commission", which are DIFFERENT exactly and
        # IDENTICAL loosely. The row matched one of them character for
        # character and was still reported as ambiguous, stranding 14 records
        # behind a duplicate nobody had permission to delete.
        $Hit = @($Unclaimed | Where-Object { (Get-LdgcrmNameExact -Name $_.Name) -eq $Exact })
        if ($Hit.Count -eq 1) {
            $Result.Verdict = "Match"; $Result.Account = $Hit[0]
            $Result.Route = "exact name, character for character; Airtable names no parent"
            return $Result
        }

        # Two Accounts named EXACTLY the same is a genuine Salesforce duplicate.
        # No precedence resolves it, so one is PICKED deterministically rather
        # than refused - see Select-LdgcrmDuplicateAccount. Refusing stranded 5
        # records on AmeriCorps/MCC and 46 on U.S. Army Futures Command.
        if ($Hit.Count -gt 1) {
            $Result.Verdict = "Match"
            $Result.Account = Select-LdgcrmDuplicateAccount -Candidates $Hit
            $Result.Candidates = $Hit
            $Result.PickedFromDuplicates = $true
            $Result.Route = "$($Hit.Count) Accounts carry exactly this name; picked the top-level/lowest-Id one"
            return $Result
        }

        $Hit = @($Unclaimed | Where-Object { (Get-LdgcrmNameLoose -Name $_.Name) -eq $Loose })
        if ($Hit.Count -eq 1) {
            $Result.Verdict = "Match"; $Result.Account = $Hit[0]
            $Result.Route = "name matches once punctuation is ignored; Airtable names no parent"
            return $Result
        }
        if ($Hit.Count -gt 1) {
            $Result.Verdict = "Match"
            $Result.Account = Select-LdgcrmDuplicateAccount -Candidates $Hit
            $Result.Candidates = $Hit
            $Result.PickedFromDuplicates = $true
            $Result.Route = "$($Hit.Count) Accounts share this name apart from punctuation; picked the top-level/lowest-Id one"
            return $Result
        }
    }

    # ---------- last resort: sweep everything before proposing a new record ----------
    $Sweep = @($Unclaimed | ForEach-Object {
        $TheirLoose = $_.LdgcrmLoose
        $Score = 0
        if ($TheirLoose -and $Bare -and $TheirLoose -eq $Bare) { $Score = 100 }
        elseif ($TheirLoose -and $Bare -and ($TheirLoose -like "*$Bare*" -or $Bare -like "*$TheirLoose*")) { $Score = 85 }
        else {
            $Their  = $_.LdgcrmTokens
            $Shared = @($Tokens | Where-Object { $Their -contains $_ }).Count
            $Denom  = [Math]::Max(1, [Math]::Max($Tokens.Count, $Their.Count))
            $Score  = [int](100 * $Shared / $Denom)
        }
        [PSCustomObject]@{ Score = $Score; Account = $_ }
    } | Where-Object { $_.Score -ge 50 } | Sort-Object Score -Descending)

    if ($Sweep.Count -ge 1) {
        # A near-identical name at TOP LEVEL is usually the same body filed at a
        # different depth, so it is worth a human look. A hit under a DIFFERENT
        # agency is the opposite - it is another department's office of the same
        # name, which is exactly how the wrong links happened, so it is evidence
        # FOR creating rather than against.
        # EXACTLY ONE top-level Account bearing exactly this name is accepted as
        # the same body, filed at a different depth (project owner, 2026-08-15).
        # Airtable files 55 states and territories under a "State and Local
        # Government" umbrella the org keeps at top level; treating each as a
        # human decision produced 68 review rows for one repeated pattern.
        #
        # Safe because of what it excludes, not because exact names are always
        # safe. A generic office name that several agencies share resolves to a
        # record UNDER its agency, so it never reaches this branch - and where
        # two Accounts do share the name, the earlier exact-match step has
        # already reported it rather than getting here. Containment matches
        # (score 85) stay a human decision: "Federal Permitting Improvement
        # Steering Council" vs "...(FPISC)" is a judgement, not a fact.
        $ExactTopLevel = @($Sweep | Where-Object {
            $_.Score -eq 100 -and [string]::IsNullOrWhiteSpace($_.Account.ParentName)
        })

        if ($ExactTopLevel.Count -eq 1) {
            $Result.Verdict = "Match"; $Result.Account = $ExactTopLevel[0].Account
            $Result.Route = "exact name at top level; Airtable files it under '$ParentName', which this org does not"
            return $Result
        }

        $TopLevelTwin = @($Sweep | Where-Object {
            $_.Score -ge 85 -and [string]::IsNullOrWhiteSpace($_.Account.ParentName)
        })

        if ($TopLevelTwin.Count -ge 1) {
            $Result.Verdict = "Confirm"; $Result.Candidates = @($Sweep | Select-Object -First 3)
            $Result.Route = "same name at top level - possibly the same body, filed differently"
            return $Result
        }

        # A STRONG NAME MATCH ANYWHERE IN THE ORG IS NEVER A CREATE.
        # Two things produce it and they need opposite actions, so neither may
        # be guessed at:
        #   - Airtable's Parent is wrong. Six Commerce agencies (NOAA, USPTO,
        #     International Trade Administration...) are filed under Agriculture
        #     in Airtable; the Accounts exist under Commerce. Creating would
        #     duplicate all six, under the wrong department, carrying a
        #     "- USDA" suffix invented to resolve the collision.
        #   - Airtable's Parent is right and the office genuinely belongs to
        #     another agency, so a new Account IS needed - Housing and Urban
        #     Development's "Office of the Secretary" against Commerce's.
        # Nothing in the data distinguishes them, so a human does.
        #
        # CONTAINMENT COUNTS, not just an exact name. The common name often sits
        # INSIDE the formal one the org records - "Amtrak" inside "National
        # Railroad Passenger Corporation (Amtrak)", "Senate" inside "U.S.Senate".
        # Both are plainly the same body, and both were being proposed as new
        # Accounts because the match scored 85 rather than 100.
        $StrongElsewhere = @($Sweep | Where-Object { $_.Score -ge 85 })

        if ($StrongElsewhere.Count -ge 1) {
            $Result.Verdict = "Confirm"; $Result.Candidates = @($Sweep | Select-Object -First 3)
            $Result.Route = "an Account of this name already exists elsewhere in the org - either Airtable's Parent is wrong, or this really is a separate office"
            return $Result
        }

        $Result.Candidates = @($Sweep | Select-Object -First 3)
        $Result.Route = "no match in this agency; same-named Accounts belong to OTHER agencies"
    }
    else {
        $Result.Route = "nothing in the org resembles this name"
    }

    $Result.Verdict      = "Create"
    $Result.ProposedName = New-LdgcrmAccountName -Index $Index -Name $Split.Bare -AgencySuffix $Suffix
    return $Result
}

function New-LdgcrmAccountName {
    <#
        Names a new Account the way the org already names things.

        Bare name where it is unique. Where the name is already used by another
        agency, carry the agency suffix - otherwise the new record collides with
        an existing one and the next run cannot tell them apart, which is the
        state that produced the wrong links in the first place.
    #>
    param(
        [Parameter(Mandatory = $true)]$Index,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$AgencySuffix = ""
    )

    $Exact = Get-LdgcrmNameExact -Name $Name
    $Collides = $Index.NameCount.ContainsKey($Exact)

    if ($Collides -and $AgencySuffix) { return ("{0} - {1}" -f $Name, $AgencySuffix) }
    return $Name
}

# ------------------------------------------------------------
# MARKET SEGMENT
# ------------------------------------------------------------

# Airtable's Accounts table spells three segments differently from the segment
# records' own names, which are what LDGCRM_External_ID__c holds. Only these
# three differ; every other value passes through unchanged.
#
# Shared rather than duplicated because Account is the ONE object where the
# migration writes Market Segment directly - the other three get it from a
# before-save Flow - so a second copy of this map would silently diverge and
# only Account would be wrong.
$Script:LdgcrmMarketSegmentAliases = @{
    "Defense & National Security"       = "Defense"
    "Finance (Regulation & Compliance)" = "Finance & Regulation"
    "State & Local (SLTT)"              = "State & Local"
}

function Get-LdgcrmMarketSegmentName {
    <#
        The segment name as LDGCRM_Market_Segment__c stores it, from whatever
        Airtable's Accounts table calls it. Blank in, blank out.
    #>
    param([string]$AirtableValue)

    if ([string]::IsNullOrWhiteSpace($AirtableValue)) { return "" }
    if ($Script:LdgcrmMarketSegmentAliases.ContainsKey($AirtableValue)) {
        return $Script:LdgcrmMarketSegmentAliases[$AirtableValue]
    }
    return $AirtableValue
}

# ------------------------------------------------------------
# ACCOUNT LEVEL
# ------------------------------------------------------------

# Derived from the production export, where Account Level is populated on every
# row and tracks depth exactly: no parent = Level 1, a Level 1 parent = Level 2,
# and so on. "Level 3 or below" also appears on 40 legacy rows, 11 of which have
# no parent at all - it is inconsistent and is never assigned to a new record.
$Script:LdgcrmAccountLevels = @("Level 1", "Level 2", "Level 3", "Level 4+")

function Get-LdgcrmAccountLevel {
    <#
        The Account_Level__c a record at a given DEPTH should carry.
        Depth 0 = no parent = "Level 1", 1 = "Level 2", and so on, with
        everything past the ladder collapsing to "Level 4+".

        DEPTH, NOT THE PARENT'S Account_Level__c - and that distinction is the
        whole point. The field is blank on 1,358 of 1,361 Accounts in the Dev
        sandbox, because Invoke-AccountBootstrap.ps1 loads name, parent and
        owner only. A function reading the parent's level cannot tell "my
        parent is top-level" from "my parent's level was never populated", so
        it labelled every new Account "Level 1" including ones several layers
        down. Depth is derivable from ParentId, which is always populated.

        Only this field needs setting. Level_1_Account__c, Level_2_Account__c,
        Level_3_Account__c and Agency_Acronym__c are FORMULA fields that walk
        Parent.Parent... themselves, so they populate from ParentId alone and
        Salesforce rejects any attempt to write them.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(0, 50)]
        [int]$Depth
    )

    if ($Depth -ge $Script:LdgcrmAccountLevels.Count) { return $Script:LdgcrmAccountLevels[-1] }
    return $Script:LdgcrmAccountLevels[$Depth]
}

function Get-LdgcrmAccountDepth {
    <#
        How many parents sit above an Account, by walking ParentId.

        -AccountsById expects a hashtable of Id -> object carrying ParentId.
        The walk is bounded because the lookup is self-referential and a cycle
        would otherwise hang the run; a record deeper than the bound is already
        past "Level 4+" and the answer does not change.
    #>
    param(
        [Parameter(Mandatory = $true)]$AccountsById,
        [Parameter(Mandatory = $true)][string]$AccountId,
        [int]$MaxDepth = 12
    )

    $Depth   = 0
    $Current = $AccountsById[$AccountId]

    while ($Current -and $Current.ParentId -and $Depth -lt $MaxDepth) {
        $Parent = $AccountsById[$Current.ParentId]
        if (-not $Parent) { break }
        $Current = $Parent
        $Depth++
    }

    return $Depth
}
