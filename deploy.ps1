#!/usr/bin/env pwsh
<#
.SYNOPSIS
    This script is the PowerShell entry point for the PNGEncoder deploy CLI.

.DESCRIPTION
    This script finds Git Bash and sends all arguments to ./deploy.sh. Thus you
    can start the guided deploy from a PowerShell prompt.

        .\deploy.ps1                 # interactive, pick the network from a menu
        .\deploy.ps1 --dry-run
        .\deploy.ps1 --sepolia
        .\deploy.ps1 --mainnet --hd-path "m/44'/60'/0'/0/0"

    deploy.sh contains all of the logic: the preflight checks, the selection of
    the Ledger account, the simulation, the confirmation, the broadcast and the
    verification. This script only starts deploy.sh. forge and cast (native
    binaries) do the Ledger signing. Thus the signing works the same from this
    script and from Git Bash.

    This script requires Git for Windows (Git Bash). If PowerShell blocks this
    script, run it one time as:
        powershell -ExecutionPolicy Bypass -File .\deploy.ps1 <args>
#>

$ErrorActionPreference = 'Stop'

# Find Git Bash. Prefer the bash of Git for Windows to the `bash` on PATH. On
# most Windows computers, the `bash` on PATH is the WSL launcher in System32.
# That launcher cannot resolve Windows-style paths. It also cannot see the
# Windows forge and cast that this deploy uses.
$candidates = @(
    "$env:ProgramFiles\Git\bin\bash.exe",
    "$env:ProgramW6432\Git\bin\bash.exe",
    "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
    "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe",
    "$env:ProgramFiles\Git\usr\bin\bash.exe"
)
$bash = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $bash) {
    # As a last alternative, use a `bash` on PATH if it is not the WSL launcher
    # in System32.
    $pathBash = (Get-Command bash -ErrorAction SilentlyContinue).Source
    if ($pathBash -and $pathBash -notlike "*\System32\*") { $bash = $pathBash }
}
if (-not $bash) {
    Write-Error "Could not find Git Bash. Install Git for Windows (https://git-scm.com/download/win). A WSL 'bash' on PATH won't work here: it can't see your Windows forge/cast."
    exit 1
}

# Give deploy.sh as an absolute path (with forward slashes for MSYS). deploy.sh
# changes to its own directory, so the current working directory is not
# important.
$scriptPath = "$PSScriptRoot/deploy.sh" -replace '\\', '/'

& $bash $scriptPath @args
$code = $LASTEXITCODE
if ($null -eq $code) { $code = 0 }
exit $code
