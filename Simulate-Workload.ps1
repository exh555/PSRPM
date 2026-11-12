<#
.SYNOPSIS
    Root wrapper for tools\Simulate-Workload.ps1
#>
[CmdletBinding(DefaultParameterSetName = "Start")]
param(
    [Parameter(ParameterSetName = "Start")]
    [switch]$Start,

    [Parameter(ParameterSetName = "Stop")]
    [switch]$Stop,

    [Parameter(ParameterSetName = "Status")]
    [switch]$Status,

    [Parameter(ParameterSetName = "Start")]
    [ValidateRange(1, 64)]
    [int]$Count = 12,

    [Parameter(ParameterSetName = "Start")]
    [ValidateRange(1, 1440)]
    [int]$DurationMinutes = 30
)

$targetScript = Join-Path $PSScriptRoot "tools\Simulate-Workload.ps1"
if (-not (Test-Path -LiteralPath $targetScript)) {
    throw "Target simulator script not found at '$targetScript'."
}

$params = @{}
if ($Stop)   { $params['Stop'] = $true }
if ($Status) { $params['Status'] = $true }
if ($Start)  { $params['Start'] = $true }
if ($PSBoundParameters.ContainsKey('Count')) { $params['Count'] = $Count }
if ($PSBoundParameters.ContainsKey('DurationMinutes')) { $params['DurationMinutes'] = $DurationMinutes }

& $targetScript @params
