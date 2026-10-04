#!/usr/bin/env pwsh
<#
.SYNOPSIS
    This script is the PowerShell entry point for the PNGEncoder verify CLI.

.DESCRIPTION
    This script finds Git Bash and sends all arguments to ./verify.sh. verify.sh
    uses the deployment record to verify a deployed PNGEncoder on Etherscan.
    Verification is optional and independent of the deploy. Thus you can deploy
    first and publish the source later.

        .\verify.ps1 sepolia
        .\verify.ps1 mainnet
        .\verify.ps1                 # if exactly one deployments\*.json exists, use it

    verify.sh contains all of the logic. This script only starts verify.sh. This
    script requires ETHERSCAN_API_KEY (in .env) and Git for Windows (Git Bash).
    If PowerShell blocks this script, run it one time as:
        powershell -ExecutionPolicy Bypass -File .\verify.ps1 <args>
#>

$ErrorActionPreference = 'Stop'

# Prefer the bash of Git for Windows to a `bash` on PATH. The `bash` on PATH is
# usually the WSL launcher in System32, which cannot see the Windows forge that
# this script uses.
$candidates = @(
    "$env:ProgramFiles\Git\bin\bash.exe",
    "$env:ProgramW6432\Git\bin\bash.exe",
    "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
    "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe",
    "$env:ProgramFiles\Git\usr\bin\bash.exe"
)
$bash = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $bash) {
    $pathBash = (Get-Command bash -ErrorAction SilentlyContinue).Source
    if ($pathBash -and $pathBash -notlike "*\System32\*") { $bash = $pathBash }
}
if (-not $bash) {
    Write-Error "Could not find Git Bash. Install Git for Windows (https://git-scm.com/download/win). A WSL 'bash' on PATH won't work here: it can't see your Windows forge."
    exit 1
}

$scriptPath = "$PSScriptRoot/verify.sh" -replace '\\', '/'

& $bash $scriptPath @args
$code = $LASTEXITCODE
if ($null -eq $code) { $code = 0 }
exit $code
