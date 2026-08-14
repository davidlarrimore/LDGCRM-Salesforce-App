#Requires -Version 5.1

<#
    THE RUN REPORT
    ==============
    Builds the one artifact that says how a whole migration load went.

    WHY THIS EXISTS
      Everything it reports was already being produced - and that was the
      problem. A full load leaves behind a transcript per script (twelve of
      them), a Bulk job result per object, a per-object failure directory, and
      around twenty review CSVs, all in one flat folder keyed only by
      timestamp. logs/data-migration/ held 330 CSVs across ~40 runs by
      2026-08-13. Answering "how did the last load go, and was anything in it
      new?" meant knowing which timestamps belonged to which run and opening a
      dozen files.

      Worse, the biggest category was invisible. The 2026-08-13 reload FAILED 31
      rows - and its transforms WITHHELD several hundred more before submitting
      anything (62 Opportunities, 54 Contacts, 30 Applications, 128 junction
      rows). Those never appeared in any summary, because a withheld row is not
      a load error: it is a row that was never sent, so the Bulk API reports
      nothing and the step is recorded as a clean success.

    EXPECTED VS UNEXPECTED, WITHOUT A LIST THAT GOES STALE
      Every run writes findings.csv and errors.csv; the next run diffs against
      the most recent previous one. So the report says "62 rows withheld (was
      126, -64)" and "NEW: 3 rows failed on a cause never seen before" without
      anyone maintaining a table of expected counts.

      That choice is deliberate and follows a lesson already learned in this
      pipeline: the FCIC junk-Account check used to test for zero and therefore
      cried wolf on every single run, which made it a check nobody read. A
      hard-coded expectation is wrong the moment Airtable is fixed - and this
      project fixed nine data-quality items in a single day. A comparison
      re-baselines itself.

      The per-ROW expected/unexpected split is a different mechanism and stays
      where it is: Invoke-SalesforceLoad.ps1 matches each failure against that
      object's -ExpectedFailurePatterns and reports the verdict through its
      step-result JSON. This module presents that; it does not second-guess it.

    DEPENDENCIES
      Dot-source AFTER Common.ps1 and Common.DataMigration.ps1 - it uses
      Get-LogDirectory from the first and ConvertTo-NormalisedErrorMessage from
      the second. That normaliser lives there rather than here because
      Invoke-SalesforceLoad.ps1 needs it too and does not load this file.

    WHAT IT DELIBERATELY DOES NOT DO
      It does not read Salesforce, and it does not decide whether a run passed.
      Post-load validation already does that. A reporting bug must never be
      able to fail a good load, which is why every entry point here is wrapped
      by its caller and failure degrades to "the report is thinner", never to a
      non-zero exit.
#>

# Review-CSV name fragment -> what kind of finding it is. Matched as a
# substring, longest first, so "-portal-team-review-" wins over "-review-".
#
# THREE KINDS, because they need three different reactions:
#   Withheld - rows that never reached Salesforce. The invisible category, and
#              the one to read first: these are records missing from the CRM
#              that no load error will ever mention.
#   Review   - the pipeline refused to guess and wants a human. Ambiguous
#              matches, unresolved owners, conflicting values.
#   Caveat   - loaded, but something was derived, dropped or truncated on the
#              way in. Correct-by-design, worth spot-checking.
$Script:LoadFindingKinds = [ordered]@{
    "-domain-inferred-account-" = @{ Kind = "Review";   Label = "Account inferred from email domain" }
    "-portal-team-conflicts-"   = @{ Kind = "Review";   Label = "Conflicting portal team" }
    "-portal-team-review-"      = @{ Kind = "Review";   Label = "Portal team needs review" }
    "-severity-conflict-"       = @{ Kind = "Review";   Label = "Conflicting severity" }
    "-unresolved-owner-"        = @{ Kind = "Review";   Label = "Owner did not resolve" }
    "-unmapped-owner-"          = @{ Kind = "Review";   Label = "Owner not mapped" }
    "-unmapped-rampup-"         = @{ Kind = "Review";   Label = "Ramp-up value not mapped" }
    "-broker-parent-skipped-"   = @{ Kind = "Withheld"; Label = "Broker parent not linked" }
    "-closedate-fallback-"      = @{ Kind = "Caveat";   Label = "Close date defaulted" }
    "-admin-source-"            = @{ Kind = "Info";     Label = "Partner Portal Admin provenance" }
    "-role-mailbox-"            = @{ Kind = "Caveat";   Label = "Role/shared mailbox, name not split" }
    "-name-review-"             = @{ Kind = "Caveat";   Label = "Name derived, not authored" }
    "-value-review-"            = @{ Kind = "Caveat";   Label = "Value dropped or blanked" }
    "-overlength-"              = @{ Kind = "Caveat";   Label = "Value truncated to fit the field" }
    "-no-account-"              = @{ Kind = "Withheld"; Label = "No Account - not loaded" }
    "-unmatched-"               = @{ Kind = "Review";   Label = "Matched no Salesforce record" }
    "-ambiguous-"               = @{ Kind = "Review";   Label = "Matched more than one - not guessed" }
    "-conflicts-"               = @{ Kind = "Review";   Label = "Conflicting values" }
    "-pending-"                 = @{ Kind = "Withheld"; Label = "Deferred to a later pass" }
    "-skipped-"                 = @{ Kind = "Withheld"; Label = "Withheld - not submitted" }
}

# CSVs in logs/data-migration/ that are NOT review findings: Bulk job output
# (which the step results already cover, and which carries full record payloads)
# and the Airtable pull summary.
$Script:LoadReportIgnoredPatterns = @(
    "-failed-records.csv", "-success-records.csv",
    "pull-summary-", "PRE-RESET-baseline", "QA-reload-"
)

function Get-LoadFindingKind {
    <#
        Classifies a review CSV by its file name. Returns Kind and Label.

        An unrecognised name is returned as Kind="Other", never dropped. A new
        transform that invents a new suffix must show up in the report as
        something unclassified rather than vanish from it - a silently missing
        finding is the exact failure this whole module exists to prevent.
    #>
    param([Parameter(Mandatory = $true)][string]$FileName)

    foreach ($Fragment in $Script:LoadFindingKinds.Keys) {
        if ($FileName -like "*$Fragment*") {
            return [PSCustomObject]@{
                Kind     = $Script:LoadFindingKinds[$Fragment].Kind
                Label    = $Script:LoadFindingKinds[$Fragment].Label
                Fragment = $Fragment.Trim('-')
            }
        }
    }

    return [PSCustomObject]@{ Kind = "Other"; Label = "Unclassified review output"; Fragment = "other" }
}

function Get-LoadRunFindings {
    <#
        Collects the review CSVs a step's transform wrote, and summarises each
        by reason.

        ATTRIBUTION IS BY TIME WINDOW, not by file name. Transforms name their
        output inconsistently (Contact-no-account-*, ApplicationContact-skipped-*,
        Account-reconciliation-unmatched-*), and each child script stamps its
        own timestamp from its own Start-ScriptLog - so the orchestrator's
        timestamp does not appear in them and cannot be matched on. What the
        orchestrator does know exactly is when each step started and finished,
        and steps run strictly in sequence. Files written inside that window
        belong to that step.

        This is also why it needs no changes to any transform: they already
        write everything, and since 2026-08-13 they write it into THIS RUN'S
        directory (see Common.ps1). That containment matters - before it, this
        scanned a shared folder holding 330 files from 40 runs and relied on the
        time window alone to keep other runs out.
    #>
    param(
        [Parameter(Mandatory = $true)][datetime]$Since,
        [Parameter(Mandatory = $true)][datetime]$Until,
        [Parameter(Mandatory = $true)][string]$StepName,
        [string]$Directory = ""
    )

    if (-not $Directory) { $Directory = Get-LogDirectory -Category "data-migration" }

    $Findings = [System.Collections.Generic.List[object]]::new()

    $Files = @(Get-ChildItem -LiteralPath $Directory -Filter *.csv -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $Since -and $_.LastWriteTime -le $Until })

    foreach ($File in $Files) {
        $Ignore = $false
        foreach ($Pattern in $Script:LoadReportIgnoredPatterns) {
            if ($File.Name -like "*$Pattern*") { $Ignore = $true; break }
        }
        if ($Ignore) { continue }

        $Rows = @()
        try { $Rows = @(Import-Csv -LiteralPath $File.FullName) }
        catch { continue }   # a file still being written; it will appear next run

        # An empty review CSV is a POSITIVE result - "this run found none" - so
        # it is reported at zero rather than skipped. Dropping it would make
        # "the problem is fixed" and "the check stopped running" identical.
        $Classification = Get-LoadFindingKind -FileName $File.Name

        # Per-reason breakdown, where the transform wrote one. Reasons embed
        # record ids ("Linked Account recXYZ is not reconciled"), so they are
        # normalised before grouping for the same reason load errors are.
        $ReasonColumn = ""
        if ($Rows.Count -gt 0) {
            $ReasonColumn = @($Rows[0].PSObject.Properties.Name |
                Where-Object { $_ -match 'Reason' } | Select-Object -First 1)[0]
        }

        $Reasons = @()
        if ($ReasonColumn) {
            $Reasons = @($Rows |
                Group-Object { ConvertTo-NormalisedErrorMessage -Message "$($_.$ReasonColumn)" } |
                Sort-Object Count -Descending |
                ForEach-Object { [PSCustomObject]@{ Reason = $_.Name; Count = $_.Count } })
        }

        $Findings.Add([PSCustomObject]@{
            Step     = $StepName
            Finding  = $Classification.Fragment
            Kind     = $Classification.Kind
            Label    = $Classification.Label
            Rows     = $Rows.Count
            File     = $File.Name
            Reasons  = $Reasons
        })
    }

    return $Findings.ToArray()
}

function Get-PreviousLoadRunDirectory {
    <#
        The most recent previous run directory that actually carries a
        findings.csv, so this run has something to compare against.

        Skips directories without one rather than taking the newest blindly:
        every run before this feature existed has no findings.csv, and so does
        any run that died before writing its report. Comparing against a
        half-written run would report every finding as new.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$CurrentDirectory,
        [string]$Directory = ""
    )

    # Sibling runs live beside this one, so the run directory's own parent is
    # the right place to look - NOT Get-LogDirectory. Deriving it from the
    # current run keeps the comparison correct when the report is written
    # somewhere other than the standard log tree, which is exactly what a test
    # does; the first version defaulted to the log directory and silently
    # compared a test run against the real ones.
    if (-not $Directory) { $Directory = Split-Path -Parent $CurrentDirectory }

    $Current = (Split-Path -Leaf $CurrentDirectory)

    # Named after the orchestrator, because that is what Start-ScriptLog calls a
    # run directory now. The old "full-load-*" shape is still matched so the
    # first run after the consolidation still has something to compare against.
    # Sorted on the trailing timestamp, NOT the folder name: the two prefixes
    # sort against each other alphabetically ("full-load-" after
    # "Invoke-FullMigrationLoad-"), which would pick a much older run as "most
    # recent" purely because of its name.
    $Candidates = @(Get-ChildItem -LiteralPath $Directory -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "Invoke-FullMigrationLoad-*" -or $_.Name -like "full-load-*" } |
        Where-Object { $_.Name -ne $Current } |
        Sort-Object { if ($_.Name -match '(\d{8}-\d{6})$') { $Matches[1] } else { "" } } -Descending)

    foreach ($Candidate in $Candidates) {
        if (Test-Path -LiteralPath (Join-Path $Candidate.FullName "findings.csv")) {
            return $Candidate.FullName
        }
    }

    return ""
}

function Format-LoadDelta {
    <#
        " (was 126, -64)" / " (NEW)" / "" - the run-over-run comparison, as it
        appears against a line in the report.

        No previous value at all is NOT reported as an increase from zero. On
        a first run everything would be "NEW", which is noise; and an increase
        from a run that never measured this is not an increase. Absence is
        reported as absence.
    #>
    param(
        [Parameter(Mandatory = $true)][int]$Current,
        $Previous,
        [switch]$NoBaseline
    )

    if ($NoBaseline) { return "" }
    if ($null -eq $Previous) { return "  (NEW)" }

    $Delta = $Current - [int]$Previous
    if ($Delta -eq 0) { return ("  (was {0}, unchanged)" -f $Previous) }

    return ("  (was {0}, {1})" -f $Previous, ("{0:+#;-#;0}" -f $Delta))
}

function Format-LoadReportText {
    param([string]$Text, [int]$Width)

    $Clean = ("$Text" -replace '\s+', ' ').Trim()
    if ($Clean.Length -le $Width) { return $Clean }
    return $Clean.Substring(0, [Math]::Max(1, $Width - 3)) + "..."
}

function Write-LoadRunReport {
    <#
        Writes the run report: SUMMARY.txt plus the three machine-readable
        files that make the NEXT run's comparison possible.

          SUMMARY.txt        the master, human-readable summary
          load-summary.csv   one row per step
          errors.csv         one row per distinct error message, classified
          findings.csv       one row per review CSV this run produced

        findings.csv and errors.csv are BOTH output and input: the next run
        reads them to say what changed. That is the whole self-baselining
        mechanism, so they are written even when a run is clean - "this run
        found none" has to be recordable, or a fixed problem and a check that
        stopped running look identical next time.

        Returns the report text so a caller can print a condensed form.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$RunDirectory,
        [Parameter(Mandatory = $true)]$Steps,
        [Parameter(Mandatory = $true)][hashtable]$Header,
        $Validation = $null
    )

    if (-not (Test-Path -LiteralPath $RunDirectory)) {
        New-Item -ItemType Directory -Path $RunDirectory -Force | Out-Null
    }

    # --- the previous run, for the comparison ------------------------------
    $PreviousDirectory = Get-PreviousLoadRunDirectory -CurrentDirectory $RunDirectory
    $PreviousFindings = @{}
    $PreviousErrors = @{}
    $HasBaseline = $false

    if ($PreviousDirectory) {
        $HasBaseline = $true
        try {
            foreach ($Row in @(Import-Csv -LiteralPath (Join-Path $PreviousDirectory "findings.csv"))) {
                $PreviousFindings["$($Row.Step)|$($Row.Finding)"] = [int]$Row.Rows
            }
        }
        catch { $HasBaseline = $false }

        $PreviousErrorFile = Join-Path $PreviousDirectory "errors.csv"
        if (Test-Path -LiteralPath $PreviousErrorFile) {
            try {
                foreach ($Row in @(Import-Csv -LiteralPath $PreviousErrorFile)) {
                    $PreviousErrors["$($Row.Step)|$($Row.Message)"] = [int]$Row.Count
                }
            }
            catch { }
        }
    }

    # --- flatten to the machine-readable rows ------------------------------
    $SummaryRows = [System.Collections.Generic.List[object]]::new()
    $FindingRows = [System.Collections.Generic.List[object]]::new()
    $ErrorRows = [System.Collections.Generic.List[object]]::new()

    foreach ($Step in $Steps) {
        $Result = $Step.StepResult

        $Withheld = 0
        foreach ($Finding in @($Step.Findings)) {
            if ($Finding.Kind -eq "Withheld") { $Withheld += $Finding.Rows }

            $FindingRows.Add([PSCustomObject]@{
                Step    = $Step.Step
                Finding = $Finding.Finding
                Kind    = $Finding.Kind
                Label   = $Finding.Label
                Rows    = $Finding.Rows
                File    = $Finding.File
            })
        }

        $Submitted = 0; $Loaded = 0; $FailedCount = 0; $Expected = 0; $Unexpected = 0
        if ($Result) {
            $Submitted = [int]$Result.Submitted
            $Loaded = [int]$Result.Succeeded
            $FailedCount = [int]$Result.Failed
            $Expected = [int]$Result.ExpectedFailed
            $Unexpected = [int]$Result.UnexpectedFailed

            foreach ($Entry in @($Result.Errors)) {
                if (-not $Entry) { continue }
                $ErrorRows.Add([PSCustomObject]@{
                    Step           = $Step.Step
                    Object         = $Result.Object
                    Classification = $Entry.Classification
                    Count          = [int]$Entry.Count
                    Message        = $Entry.Message
                })
            }
        }
        else {
            # No step result: the step was planned, skipped, or its transform
            # failed before any load. Rows is what the orchestrator counted in
            # the CSV, which is the honest figure for "would have been sent".
            $Submitted = [int]$Step.Rows
        }

        $SummaryRows.Add([PSCustomObject]@{
            Step             = $Step.Step
            Object           = $Step.Object
            Submitted        = $Submitted
            Loaded           = $Loaded
            Failed           = $FailedCount
            ExpectedFailed   = $Expected
            UnexpectedFailed = $Unexpected
            Withheld         = $Withheld
            Result           = $Step.Result
        })
    }

    $SummaryRows | Export-Csv -LiteralPath (Join-Path $RunDirectory "load-summary.csv") -NoTypeInformation -Encoding UTF8
    $FindingRows | Export-Csv -LiteralPath (Join-Path $RunDirectory "findings.csv") -NoTypeInformation -Encoding UTF8
    $ErrorRows | Export-Csv -LiteralPath (Join-Path $RunDirectory "errors.csv") -NoTypeInformation -Encoding UTF8

    # --- the readable report -----------------------------------------------
    $Line = "-" * 108
    $Out = [System.Collections.Generic.List[string]]::new()

    function Add-Line {
        param([string]$Text = "")
        $Out.Add($Text)
    }

    Add-Line ("=" * 108)
    Add-Line " MIGRATION LOAD REPORT"
    Add-Line ("=" * 108)
    Add-Line (" Run            {0}" -f (Split-Path -Leaf $RunDirectory))
    Add-Line (" Environment    {0}  ({1})" -f $Header.Environment, $Header.Org)
    Add-Line (" Started        {0}" -f ([datetime]$Header.Started).ToString("yyyy-MM-dd HH:mm:ss"))
    Add-Line (" Duration       {0}" -f ((New-TimeSpan -Start $Header.Started -End (Get-Date)).ToString("hh\:mm\:ss")))
    Add-Line (" Mode           {0}" -f $Header.Mode)
    if ($HasBaseline) {
        Add-Line (" Compared with  {0}" -f (Split-Path -Leaf $PreviousDirectory))
    }
    else {
        Add-Line " Compared with  (nothing - no earlier run carries a findings.csv, so no deltas below)"
    }
    Add-Line ""

    # 1. WHAT LOADED
    Add-Line $Line
    Add-Line " 1. WHAT LOADED"
    Add-Line $Line
    # KEYED BY OBJECT, which is what anyone reading this is actually asking
    # about. The step name is appended only where it has to be: two steps load
    # LDGCRM_application__c (Application, then PopulateBrokerParent for the self-lookup
    # second pass), so the object alone is not unique. Everywhere else the step
    # name would just repeat the object.
    $ObjectCounts = @{}
    foreach ($Row in $SummaryRows) {
        if (-not $ObjectCounts.ContainsKey($Row.Object)) { $ObjectCounts[$Row.Object] = 0 }
        $ObjectCounts[$Row.Object]++
    }

    Add-Line ("  {0,-38} {1,9} {2,9} {3,7} {4,9}  {5}" -f `
        "OBJECT", "SUBMITTED", "LOADED", "FAILED", "WITHHELD", "RESULT")
    foreach ($Row in $SummaryRows) {
        $Label = if ($ObjectCounts[$Row.Object] -gt 1) { "{0} ({1})" -f $Row.Object, $Row.Step }
                 else { $Row.Object }
        Add-Line ("  {0,-38} {1,9:N0} {2,9:N0} {3,7:N0} {4,9:N0}  {5}" -f `
            $Label, $Row.Submitted, $Row.Loaded, $Row.Failed, $Row.Withheld, $Row.Result)
    }
    Add-Line ("  {0,-38} {1,9:N0} {2,9:N0} {3,7:N0} {4,9:N0}" -f "TOTAL",
        (($SummaryRows | Measure-Object Submitted -Sum).Sum),
        (($SummaryRows | Measure-Object Loaded -Sum).Sum),
        (($SummaryRows | Measure-Object Failed -Sum).Sum),
        (($SummaryRows | Measure-Object Withheld -Sum).Sum))
    Add-Line ""
    Add-Line "  WITHHELD counts rows the transform never submitted. They are NOT load errors -"
    Add-Line "  Salesforce never saw them - so nothing else in a load result will mention them."
    Add-Line ""

    # 2. LOAD FAILURES
    Add-Line $Line
    Add-Line " 2. LOAD FAILURES - rows Salesforce rejected"
    Add-Line $Line
    $UnexpectedErrors = @($ErrorRows | Where-Object { $_.Classification -eq "UNEXPECTED" })
    $ExpectedErrors = @($ErrorRows | Where-Object { $_.Classification -ne "UNEXPECTED" })

    Add-Line ""
    Add-Line "  UNEXPECTED - no configured cause matches. These stop the run."
    if ($UnexpectedErrors.Count -eq 0) {
        Add-Line "    (none)"
    }
    else {
        foreach ($Row in ($UnexpectedErrors | Sort-Object Count -Descending)) {
            $Delta = Format-LoadDelta -Current $Row.Count -Previous $PreviousErrors["$($Row.Step)|$($Row.Message)"] -NoBaseline:(-not $HasBaseline)
            Add-Line ("    {0,-23} {1,6:N0}  {2}{3}" -f $Row.Step, $Row.Count, (Format-LoadReportText -Text $Row.Message -Width 58), $Delta)
        }
    }

    Add-Line ""
    Add-Line "  EXPECTED - a known cause for that object, within its allowance."
    if ($ExpectedErrors.Count -eq 0) {
        Add-Line "    (none)"
    }
    else {
        foreach ($Row in ($ExpectedErrors | Sort-Object Count -Descending)) {
            $Delta = Format-LoadDelta -Current $Row.Count -Previous $PreviousErrors["$($Row.Step)|$($Row.Message)"] -NoBaseline:(-not $HasBaseline)
            Add-Line ("    {0,-23} {1,6:N0}  {2}{3}" -f $Row.Step, $Row.Count, (Format-LoadReportText -Text $Row.Message -Width 58), $Delta)
        }
    }

    # WHAT STOPPED HAPPENING. A cause that failed rows last run and none this
    # run is reported explicitly, because the alternative is that it simply
    # disappears from the report - and "we fixed it" then looks exactly like
    # "the check stopped running". This is the same reason an empty review CSV
    # is reported at zero rather than skipped.
    if ($HasBaseline) {
        $CurrentErrorKeys = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($Row in $ErrorRows) { $CurrentErrorKeys.Add("$($Row.Step)|$($Row.Message)") | Out-Null }

        $Resolved = @($PreviousErrors.Keys | Where-Object { -not $CurrentErrorKeys.Contains($_) })
        if ($Resolved.Count -gt 0) {
            Add-Line ""
            Add-Line "  GONE SINCE THE LAST RUN - failed then, did not fail now."
            foreach ($Key in ($Resolved | Sort-Object)) {
                $Parts = $Key -split '\|', 2
                Add-Line ("    {0,-23} {1,6}  {2}" -f $Parts[0], "0", (Format-LoadReportText -Text $Parts[1] -Width 58))
                Add-Line ("    {0,-23} {1,6}  (was {2})" -f "", "", $PreviousErrors[$Key])
            }
        }
    }
    Add-Line ""

    # FINDINGS BY KIND. Numbered as they are emitted rather than hard-coded,
    # because the last section is conditional - a fixed "6." that sometimes
    # doesn't appear makes the report look like it lost a section.
    $SectionNumber = 2
    $Sections = @(
        @{ Kind = "Withheld"; Title = "ROWS WITHHELD - never submitted, so no load error mentions them" }
        @{ Kind = "Review";   Title = "NEEDS A HUMAN - the pipeline refused to guess" }
        @{ Kind = "Caveat";   Title = "LOADED WITH A CAVEAT - derived, dropped or truncated on the way in" }
        @{ Kind = "Other";    Title = "UNCLASSIFIED REVIEW OUTPUT - a finding this report does not recognise" }
    )

    foreach ($Section in $Sections) {
        $Matching = @()
        foreach ($Step in $Steps) {
            foreach ($Finding in @($Step.Findings)) {
                if ($Finding.Kind -eq $Section.Kind) {
                    $Matching += [PSCustomObject]@{ Step = $Step.Step; Finding = $Finding }
                }
            }
        }

        # "Other" is only worth a section when something landed in it.
        if ($Section.Kind -eq "Other" -and $Matching.Count -eq 0) { continue }

        $SectionNumber++
        Add-Line $Line
        Add-Line (" {0}. {1}" -f $SectionNumber, $Section.Title)
        Add-Line $Line
        if ($Matching.Count -eq 0) {
            Add-Line "  (none)"
            Add-Line ""
            continue
        }

        foreach ($Entry in ($Matching | Sort-Object { -$_.Finding.Rows })) {
            $Finding = $Entry.Finding
            $Delta = Format-LoadDelta -Current $Finding.Rows -Previous $PreviousFindings["$($Entry.Step)|$($Finding.Finding)"] -NoBaseline:(-not $HasBaseline)
            Add-Line ("  {0,-24} {1,7:N0}  {2}{3}" -f $Entry.Step, $Finding.Rows, $Finding.Label, $Delta)
            Add-Line ("  {0,-24} {1,7}  {2}" -f "", "", $Finding.File)

            # Top reasons. Capped, and the cap is STATED - a silent "top 5" reads
            # as "these are all of them".
            $Shown = 0
            foreach ($Reason in @($Finding.Reasons)) {
                if ($Shown -ge 5) { break }
                Add-Line ("  {0,-24} {1,7:N0}    {2}" -f "", $Reason.Count, (Format-LoadReportText -Text $Reason.Reason -Width 70))
                $Shown++
            }
            if (@($Finding.Reasons).Count -gt $Shown) {
                Add-Line ("  {0,-24} {1,7}    ... and {2} more reason(s) - see the file" -f "", "", (@($Finding.Reasons).Count - $Shown))
            }
            Add-Line ""
        }
    }

    $SectionNumber++
    Add-Line $Line
    Add-Line (" {0}. POST-LOAD VALIDATION - the failures a success count cannot show" -f $SectionNumber)
    Add-Line $Line
    if ($null -eq $Validation) {
        Add-Line "  (not run - see Mode above)"
    }
    else {
        if (@($Validation.Problems).Count -eq 0) { Add-Line "  PROBLEMS   (none)" }
        else {
            Add-Line "  PROBLEMS"
            foreach ($Problem in $Validation.Problems) { Add-Line ("    - {0}" -f $Problem) }
        }
        if (@($Validation.Notices).Count -gt 0) {
            Add-Line ""
            Add-Line "  KNOWN INCOMPLETE - loaded correctly, still waiting on something outside this repo"
            foreach ($Notice in $Validation.Notices) { Add-Line ("    - {0}" -f $Notice) }
        }
    }
    Add-Line ""

    $SectionNumber++
    Add-Line $Line
    Add-Line (" {0}. WHERE TO LOOK NEXT" -f $SectionNumber)
    Add-Line $Line
    # Everything this run produced is in ONE folder, so this is a list of file
    # names rather than a tour of four directories - which is the whole point of
    # the 2026-08-13 consolidation.
    Add-Line ("  Everything from this run is in:")
    Add-Line ("    {0}" -f $RunDirectory)
    Add-Line ""
    Add-Line ("    SUMMARY.txt                    this report")
    Add-Line ("    load-summary.csv               one row per step")
    Add-Line ("    errors.csv                     one row per distinct error, classified")
    Add-Line ("    findings.csv                   one row per review CSV")
    Add-Line ("    <Script>.log                   each step's full transcript")
    Add-Line ("    <object>-*-failed-records.csv  the rows Salesforce rejected, with payloads")
    Add-Line ("    external-ids-*.csv             what existed before - a rollback needs these")
    Add-Line ""
    Add-Line "  A clean report is not a verified migration. Walk docs/operations/RELOAD-QA-CHECKLIST.md."
    Add-Line ""

    $Text = ($Out -join [Environment]::NewLine)
    Set-Content -LiteralPath (Join-Path $RunDirectory "SUMMARY.txt") -Value $Text -Encoding UTF8

    return $Text
}


