<#
Bike Dash: drive the Mac build from this PC (Windows PowerShell 5.1 or 7).

  .\scripts\pc\mac.ps1 build          push to the Mac, build, install on the iPhone
  .\scripts\pc\mac.ps1 build -Launch  same, then open the app (phone unlocked)
  .\scripts\pc\mac.ps1 test           run the BikeDashCore unit tests on the Mac
  .\scripts\pc\mac.ps1 status         last build result and signing expiry
  .\scripts\pc\mac.ps1 setup          first time: repo on the Mac, XcodeGen, project

Commit first: only committed code reaches the Mac.
Keep this file ASCII: Windows PowerShell 5.1 reads it as ANSI.
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet('build', 'test', 'status', 'setup')]
    [string]$Action = 'build',
    [switch]$Launch,
    [int]$TimeoutMinutes = 20
)

$ErrorActionPreference = 'Stop'
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Ssh = 'C:\Windows\System32\OpenSSH\ssh.exe'
$MacHost = 'mac'   # Host entry in ~/.ssh/config

function Invoke-Mac([string]$Command) {
    & $Ssh -o BatchMode=yes -o ConnectTimeout=15 $MacHost $Command
    if ($LASTEXITCODE -ne 0) { throw "Mac command failed (exit $LASTEXITCODE): $Command" }
}

function Push-ToMac {
    if (git -C $Repo status --porcelain) {
        Write-Warning 'There are uncommitted changes; only committed code is built.'
    }
    git -C $Repo push --quiet mac HEAD:main
    if ($LASTEXITCODE -ne 0) { throw 'git push to the Mac failed.' }
}

switch ($Action) {
    'setup' {
        Invoke-Mac 'git init -q -b main ~/bike-dash 2>/dev/null; git -C ~/bike-dash config receive.denyCurrentBranch updateInstead && mkdir -p ~/.config/bike-dash/queue ~/Library/Logs/bike-dash'
        if ((git -C $Repo remote) -notcontains 'mac') { git -C $Repo remote add mac 'mac:bike-dash' }
        git -C $Repo config core.sshCommand 'C:/Windows/System32/OpenSSH/ssh.exe'
        Push-ToMac
        Invoke-Mac 'test -x /opt/homebrew/bin/xcodegen || /opt/homebrew/bin/brew install xcodegen'
        Invoke-Mac 'cd ~/bike-dash && /opt/homebrew/bin/xcodegen generate'
        Write-Host 'Mac ready: ~/bike-dash/BikeDash.xcodeproj is generated.'
    }
    'build' {
        Push-ToMac
        $id = Get-Date -Format 'yyyyMMdd-HHmmss'
        $request = 'build'
        if ($Launch) { $request = 'build launch' }
        Invoke-Mac "printf '%s' '$request' > ~/.config/bike-dash/queue/$id.req"
        Write-Host "Build $id queued on the Mac..."
        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
        $status = ''
        while ($status -notmatch "^(ok|failed) $id" -and (Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 5
            $status = (& $Ssh -o BatchMode=yes -o ConnectTimeout=15 $MacHost 'cat ~/.config/bike-dash/status 2>/dev/null') -join ''
        }
        & $Ssh -o BatchMode=yes $MacHost "cat ~/Library/Logs/bike-dash/$id.log 2>/dev/null"
        if ($status -notmatch "^ok $id") { throw "Build $id did not finish OK (status: '$status')" }
    }
    'test' {
        Push-ToMac
        Invoke-Mac 'export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; cd ~/bike-dash/Packages/BikeDashCore && swift test > /tmp/bike-dash-test.log 2>&1; rc=$?; tail -n 40 /tmp/bike-dash-test.log; exit $rc'
    }
    'status' {
        Invoke-Mac 'cat ~/.config/bike-dash/status 2>/dev/null; cat ~/.config/bike-dash/state.json 2>/dev/null'
    }
}
