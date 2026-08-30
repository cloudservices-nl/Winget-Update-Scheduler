#requires -Version 5.1
<#
.SYNOPSIS
    Builds the Winget Monthly Updater MSI from the current repository sources.
#>
[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string] $Version = '1.0.0'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectPath = Join-Path $PSScriptRoot 'WingetMonthlyUpdater.wixproj'
$outputPath = Join-Path $PSScriptRoot 'bin\Release\WingetMonthlyUpdater.msi'

& dotnet build $projectPath --configuration Release "-p:ProductVersion=$Version"
if ($LASTEXITCODE -ne 0) {
    throw "MSI build failed with exit code $LASTEXITCODE."
}
if (-not (Test-Path -LiteralPath $outputPath)) {
    throw "MSI build completed but did not produce $outputPath."
}

Write-Host "MSI created: $outputPath" -ForegroundColor Green
