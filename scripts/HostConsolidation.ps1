# Rolls the accepted leaf reports up into one super-skill findings-report in code, with no agent call.
# It follows BCQuality's composition rules (skills/do.md, "Composition (super-skills)") and is meant to satisfy exactly what
# tools/Validate-FindingsReport.ps1 checks for -SkillKind super, so the same acceptance gate decides whether it is used:
#   * sub-results are the accepted leaf reports, unchanged, in worklist order;
#   * every finding of a non-failed leaf becomes a top-level finding with `from-sub-skill` set; a finding with no
#     citation (an agent finding) gets its id prefixed with `<leaf id>:`; everything else is copied verbatim;
#   * two top-level findings that overlap and prescribe the same correction must be one finding (the validator rejects
#     duplicates), so those are merged: highest severity and confidence, references added;
#   * outcome, summary.counts and summary.coverage are derived, never copied.
# What it does NOT do: the super-skill's own cross-cutting "self-review" pass (agent findings with
# from-sub-skill "agent"). That needs a model; use `consolidation: "agent"` for it.
Set-StrictMode -Version Latest

$script:RollupSeverityRank = @{ info = 0; minor = 1; major = 2; blocker = 3 }
$script:RollupConfidenceRank = @{ low = 0; medium = 1; high = 2 }

function Test-RollupHasProperty {
    param($Object, [string] $Name)
    $null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]
}

function Get-RollupOutcome {
    # The super-skill outcome when every selected leaf has returned (do.md, "Outcome rollup").
    param([string[]] $Outcomes)
    if (-not $Outcomes.Count) { return 'not-applicable' }
    if (-not @($Outcomes | Where-Object { $_ -cne 'failed' }).Count) { return 'failed' }
    if (($Outcomes -ccontains 'partial') -or ($Outcomes -ccontains 'failed')) { return 'partial' }
    if (-not @($Outcomes | Where-Object { $_ -cne 'not-applicable' }).Count) { return 'not-applicable' }
    if (($Outcomes -ccontains 'no-knowledge') -and -not @($Outcomes | Where-Object { $_ -cnotin @('no-knowledge', 'not-applicable') }).Count) { return 'no-knowledge' }
    'completed'
}

function Test-RollupOverlap {
    # Same file and overlapping line spans; a finding with no location overlaps nothing.
    param($First, $Second)
    if (-not ($First.Contains('location') -and $Second.Contains('location'))) { return $false }
    $a = $First['location']; $b = $Second['location']
    if ($a.file -cne $b.file) { return $false }
    $aEnd = $a.line; if (Test-RollupHasProperty $a 'range') { $aEnd = $a.range.'end-line' }
    $bEnd = $b.line; if (Test-RollupHasProperty $b 'range') { $bEnd = $b.range.'end-line' }
    $a.line -le $bEnd -and $b.line -le $aEnd
}

function Test-RollupSameCorrection {
    # With suggested code on either side the code must match; otherwise the messages must.
    param($First, $Second)
    $aCode = $First.Contains('suggested-code'); $bCode = $Second.Contains('suggested-code')
    if ($aCode -or $bCode) {
        return $aCode -and $bCode -and [string]::Equals($First['suggested-code'], $Second['suggested-code'], [StringComparison]::Ordinal)
    }
    [string]::Equals($First['message'], $Second['message'], [StringComparison]::Ordinal)
}

function Test-RollupReferencePresent {
    param([object[]] $References, $Reference)
    foreach ($r in $References) {
        if ($r.path -cne $Reference.path) { continue }
        $rSha = Test-RollupHasProperty $r 'sha'; $wSha = Test-RollupHasProperty $Reference 'sha'
        if ($rSha -eq $wSha -and (-not $rSha -or $r.sha -ceq $Reference.sha)) { return $true }
    }
    $false
}

function New-HostRollup {
    param(
        [Parameter(Mandatory)] $SuperSkill,            # { id; version }
        [Parameter(Mandatory)] [object[]] $Leaves,     # accepted leaf reports, in worklist order
        [object[]] $Skipped = @()                      # { id; version; reason }
    )
    $rolled = [System.Collections.Generic.List[object]]::new()
    foreach ($leaf in $Leaves) {
        if ($leaf.outcome -ceq 'failed') { continue }   # a failed leaf contributes no findings and no counts
        foreach ($f in @($leaf.findings)) {
            $isAgentFinding = -not @($f.references).Count
            $r = [ordered]@{}
            foreach ($p in $f.PSObject.Properties) {
                if ($p.Name -ceq 'id' -and $isAgentFinding) { $r['id'] = "$($leaf.skill.id):$($p.Value)" }
                else { $r[$p.Name] = $p.Value }
            }
            $r['from-sub-skill'] = [string]$leaf.skill.id

            # The validator rejects two overlapping findings that prescribe the same correction, so they become one.
            # An agent finding has no citation and cannot be merged into a cited one: it stays separate.
            $target = $null
            if (-not $isAgentFinding) {
                foreach ($e in $rolled) {
                    if (@($e['references']).Count -and (Test-RollupOverlap $e $r) -and (Test-RollupSameCorrection $e $r)) { $target = $e; break }
                }
            }
            if ($null -eq $target) { $rolled.Add($r); continue }
            if ($script:RollupSeverityRank[[string]$r['severity']] -gt $script:RollupSeverityRank[[string]$target['severity']]) { $target['severity'] = $r['severity'] }
            if ($script:RollupConfidenceRank[[string]$r['confidence']] -gt $script:RollupConfidenceRank[[string]$target['confidence']]) { $target['confidence'] = $r['confidence'] }
            foreach ($ref in @($r['references'])) {
                if (-not (Test-RollupReferencePresent @($target['references']) $ref)) { $target['references'] = @($target['references']) + $ref }
            }
        }
    }

    $included = @($Leaves | Where-Object { $_.outcome -cne 'failed' })
    $worklistSize = 0; $itemsEvaluated = 0
    foreach ($leaf in $included) { $worklistSize += [int]$leaf.summary.coverage.'worklist-size'; $itemsEvaluated += [int]$leaf.summary.coverage.'items-evaluated' }
    $counts = [ordered]@{}
    foreach ($severity in 'blocker', 'major', 'minor', 'info') { $counts[$severity] = @($rolled | Where-Object { $_['severity'] -ceq $severity }).Count }

    $outcome = Get-RollupOutcome @($Leaves | ForEach-Object { [string]$_.outcome })
    $report = [ordered]@{
        skill   = [ordered]@{ id = [string]$SuperSkill.id; version = $SuperSkill.version }
        outcome = $outcome
    }
    if ($outcome -ceq 'partial' -or $outcome -ceq 'failed') {
        $failed = @($Leaves | Where-Object { $_.outcome -ceq 'failed' } | ForEach-Object { [string]$_.skill.id })
        $partial = @($Leaves | Where-Object { $_.outcome -ceq 'partial' } | ForEach-Object { [string]$_.skill.id })
        $parts = @()
        if ($failed.Count) { $parts += "failed: $($failed -join ', ')" }
        if ($partial.Count) { $parts += "partial: $($partial -join ', ')" }
        $report['outcome-reason'] = "Review areas that did not complete ($($parts -join '; ')). Findings of a failed area are not included."
    }
    $report['summary'] = [ordered]@{ counts = $counts; coverage = [ordered]@{ 'worklist-size' = $worklistSize; 'items-evaluated' = $itemsEvaluated } }
    $report['findings'] = @($rolled)
    $report['suppressed'] = @()   # knowledge-file suppression lives in each leaf's own report
    $report['sub-results'] = @($Leaves)
    $report['skipped-sub-skills'] = @($Skipped | ForEach-Object {
            [ordered]@{ skill = [ordered]@{ id = [string]$_.id; version = $_.version }; reason = [string]$_.reason } })
    $report
}
