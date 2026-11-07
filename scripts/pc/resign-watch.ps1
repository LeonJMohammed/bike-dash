<#
Bike Dash re-sign watch, run by this PC every 10 minutes (Windows PowerShell 5.1).

The MacBook re-signs Bike Dash by itself once less than 2 days of the 7-day signature are
left, but it can't do that, or tell you anything, while it's asleep or off. This PC is
always on, so it watches for that:

  * Whenever it can reach the MacBook, it reads when the signature on the iPhone expires
    (~/.config/bike-dash/state.json there) and keeps a copy in pc-data\resign-watch.json.
  * When a re-sign is due and it hasn't reached the MacBook for 30 minutes, it sends the
    ntfy alert "Bike Dash: open the MacBook": only between 7 am and 10 pm, at most every
    8 hours, high priority in the last 12 hours, and once a day after it has expired.
  * While the MacBook can be reached it stays quiet: the MacBook's own job re-signs, says
    "Bike Dash re-signed", and alerts if the iPhone isn't reachable or a build fails.

  resign-watch.ps1              one run (the task "Bike Dash Re-sign Watch")
  resign-watch.ps1 -Dry         what it sees and would do; sends and saves nothing
  resign-watch.ps1 -Dry -PretendNow '2026-11-11 08:00' [-PretendOffline]
                                the same at another time, or as if the MacBook were off
  resign-watch.ps1 -Test        send a TEST alert in the real format
  resign-watch.ps1 -SetExpiry '2026-11-12 22:14'
                                tell it the expiry while the MacBook can't be reached
  resign-watch.ps1 -Register    create or update the scheduled task (no admin needed)

The ntfy settings come from the system monitor's .env: the same topic as the MacBook's.
Keep this file ASCII: Windows PowerShell 5.1 reads it as ANSI.
#>
[CmdletBinding()]
param(
    [switch]$Dry,
    [string]$PretendNow = '',
    [switch]$PretendOffline,
    [switch]$Test,
    [string]$SetExpiry = '',
    [switch]$Register
)

$ErrorActionPreference = 'Stop'
$Repo        = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$DataDir     = Join-Path $Repo 'pc-data'
$StateFile   = Join-Path $DataDir 'resign-watch.json'
$LogFile     = Join-Path $DataDir 'resign-watch.log'
$NtfyEnvFile = 'C:\system-monitor\.env'
$Ssh         = 'C:\Windows\System32\OpenSSH\ssh.exe'
$MacHost     = 'mac'   # Host entry in ~/.ssh/config
$TaskName    = 'Bike Dash Re-sign Watch'

$RenewWithinHours   = 48   # the MacBook renews with less than this left (RENEW_WITHIN in refresh.sh)
$OfflineMinutes     = 30   # a MacBook seen this recently may just be napping
$DayStartHour       = 7    # alerts only from 7:00 ...
$DayEndHour         = 22   # ... until 22:00
$RepeatHours        = 8    # between alerts while it's due
$ExpiredRepeatHours = 24   # between alerts once it has expired
$UrgentHours        = 12   # high priority in the last 12 hours
$Invariant = [Globalization.CultureInfo]::InvariantCulture
$Fix = 'Open it on the charger with your iPhone on home Wi-Fi, and it re-signs by itself.'

function Write-Log([string]$Message) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    if ($Dry) { return }
    New-Item -ItemType Directory -Force $DataDir | Out-Null
    Add-Content -Path $LogFile -Value $line -Encoding ASCII
}

# Times are kept as epoch seconds, so Windows PowerShell 5.1 and 7 read the state file alike.
function ConvertTo-Epoch([DateTime]$Time) { [long]([DateTimeOffset]$Time).ToUnixTimeSeconds() }
function ConvertFrom-Epoch([long]$Seconds) { [DateTimeOffset]::FromUnixTimeSeconds($Seconds).LocalDateTime }
function Format-When([long]$Seconds) { (ConvertFrom-Epoch $Seconds).ToString('ddd dd MMM HH:mm', $Invariant) }
function ConvertFrom-LocalText([string]$Text) {
    [DateTime]::Parse($Text, $Invariant, [Globalization.DateTimeStyles]::AssumeLocal)
}

function Read-DotEnv([string]$Path) {
    $values = @{}
    if (Test-Path $Path) {
        foreach ($line in Get-Content $Path) {
            if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') { $values[$Matches[1]] = $Matches[2].Trim().Trim('"') }
        }
    }
    return $values
}

function Send-Ntfy([string]$Title, [string]$Message, [string]$Priority) {
    $config = Read-DotEnv $NtfyEnvFile
    if (-not $config.NTFY_TOPIC) { throw "NTFY_TOPIC is missing from $NtfyEnvFile" }
    $server = if ($config.NTFY_SERVER) { $config.NTFY_SERVER.TrimEnd('/') } else { 'https://ntfy.sh' }
    $headers = @{ Title = $Title; Priority = $Priority; Tags = 'bike' }
    Invoke-RestMethod -Method Post -Uri "$server/$($config.NTFY_TOPIC)" -Headers $headers `
        -Body ([Text.Encoding]::UTF8.GetBytes($Message)) -ContentType 'text/plain; charset=utf-8' -TimeoutSec 15 | Out-Null
}

$StateKeys = 'expiresAt', 'expires', 'source', 'readAt', 'macSeenAt', 'macReachable', 'alertedExpiry', 'lastAlertAt', 'lastRun'

function Read-State {
    $state = @{}
    foreach ($key in $StateKeys) { $state[$key] = $null }
    if (Test-Path $StateFile) {
        try {
            $json = Get-Content $StateFile -Raw | ConvertFrom-Json
            foreach ($key in $StateKeys) { if ($null -ne $json.$key) { $state[$key] = $json.$key } }
        } catch {
            Write-Log "Couldn't read $StateFile, starting afresh: $($_.Exception.Message)"
        }
    }
    return $state
}

function Save-State($State) {
    if ($Dry) { return }
    New-Item -ItemType Directory -Force $DataDir | Out-Null
    $tmp = "$StateFile.tmp"
    $State | ConvertTo-Json | Set-Content -Path $tmp -Encoding ASCII
    Move-Item -Force $tmp $StateFile
}

# The expiry (epoch seconds) in the MacBook's state.json text; 0 if it has none.
function Get-ExpiryFromState([string]$Json) {
    if (-not $Json.Trim()) { return [long]0 }
    try { $expiry = ($Json | ConvertFrom-Json).expiresAt } catch { return [long]0 }
    if ($expiry) { return [long]$expiry }
    return [long]0
}

# Asks the MacBook over SSH. $null if it can't be reached, otherwise its expiry (0 if none).
function Get-MacExpiry {
    $out = & $Ssh -o BatchMode=yes -o ConnectTimeout=10 $MacHost 'cat ~/.config/bike-dash/state.json 2>/dev/null; true'
    if ($LASTEXITCODE -ne 0) { return $null }
    return Get-ExpiryFromState ($out | Out-String)
}

# This PC reaches the MacBook through Tailscale; with Tailscale down here, it can't tell.
function Test-PcTailscale {
    $exe = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
    if (-not (Test-Path $exe)) { return $false }
    try { return ((& $exe status --json | Out-String | ConvertFrom-Json).BackendState -eq 'Running') } catch { return $false }
}

function Get-DueMessage([long]$Expiry, [long]$Now) {
    $left = $Expiry - $Now
    $lead = if ($left -lt $UrgentHours * 3600) { "Only $([math]::Floor($left / 3600)) h left. " } else { '' }
    "${lead}Bike Dash needs re-signing before $(Format-When $Expiry), and the MacBook seems to be asleep or off. $Fix"
}

# Whether to alert now, and what to say. Send = $false comes with the reason in Why.
function Get-Alert($State, [long]$Now, [bool]$Reachable) {
    if (-not $State.expiresAt) {
        return @{ Send = $false; Why = "No expiry known yet: the MacBook hasn't been reachable since this watch started (see -SetExpiry)." }
    }
    $expiry = [long]$State.expiresAt
    $left = $expiry - $Now
    $when = Format-When $expiry
    if ($left -gt $RenewWithinHours * 3600) {
        return @{ Send = $false; Why = "Not due: it expires $when, $([math]::Floor($left / 3600)) h from now." }
    }
    $expired = $left -le 0
    $status = if ($expired) { "Expired ($when)" } else { "Due (expires $when)" }
    if ($Reachable) {
        return @{ Send = $false; Why = "$status, and the MacBook is reachable: its own job re-signs it." }
    }
    $seen = if ($State.macSeenAt) { [long]$State.macSeenAt } else { [long]0 }
    if ($seen -and ($Now - $seen) -lt $OfflineMinutes * 60) {
        return @{ Send = $false; Why = "$status; the MacBook was reachable $([math]::Floor(($Now - $seen) / 60)) min ago, so it gets $OfflineMinutes min." }
    }
    $hour = (ConvertFrom-Epoch $Now).Hour
    if ($hour -lt $DayStartHour -or $hour -ge $DayEndHour) {
        return @{ Send = $false; Why = "$status and the MacBook can't be reached, but it's night: waiting until $($DayStartHour):00." }
    }
    $repeat = if ($expired) { $ExpiredRepeatHours } else { $RepeatHours }
    if ($State.lastAlertAt -and [long]$State.alertedExpiry -eq $expiry -and ($Now - [long]$State.lastAlertAt) -lt $repeat * 3600) {
        return @{ Send = $false; Why = "$status and the MacBook can't be reached; told at $(Format-When $State.lastAlertAt), again after $repeat h." }
    }
    if ($expired) {
        return @{ Send = $true; Why = "$status, and the MacBook can't be reached."; Priority = 'high'
                  Title = 'Bike Dash has expired'
                  Body = "Bike Dash won't open until it's re-signed, and the MacBook seems to be asleep or off. $Fix" }
    }
    $priority = if ($left -lt $UrgentHours * 3600) { 'high' } else { 'default' }
    return @{ Send = $true; Why = "Due (expires $when), and the MacBook can't be reached."; Priority = $priority
              Title = 'Bike Dash: open the MacBook'; Body = (Get-DueMessage $expiry $Now) }
}

try {
    if ($Register) {
        # conhost --headless runs PowerShell without flashing a window every 10 minutes.
        $action = New-ScheduledTaskAction -Execute 'conhost.exe' `
            -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 10)
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
            -Description 'Bike Dash: ntfy alert when a re-sign is due and the MacBook is asleep or off (scripts\pc\resign-watch.ps1)' -Force | Out-Null
        Write-Host "Registered '$TaskName' (every 10 minutes, while you're logged in)"
        exit 0
    }

    if (($PretendNow -or $PretendOffline) -and -not $Dry) { throw '-PretendNow and -PretendOffline only work with -Dry' }
    $now = if ($PretendNow) { ConvertTo-Epoch (ConvertFrom-LocalText $PretendNow) } else { ConvertTo-Epoch (Get-Date) }
    $state = Read-State

    if ($SetExpiry) {
        $expiry = ConvertTo-Epoch (ConvertFrom-LocalText $SetExpiry)
        $state.expiresAt = $expiry; $state.expires = Format-When $expiry; $state.source = 'set by hand'; $state.readAt = $now
        Save-State $state
        Write-Log "Expiry set by hand: $(Format-When $expiry)"
        exit 0
    }

    if ($Test) {
        $example = if ($state.expiresAt) { [long]$state.expiresAt } else { $now + 36 * 3600 }
        Send-Ntfy 'TEST: Bike Dash: open the MacBook' ("A test from the PC's re-sign watch. Nothing is wrong right now. " +
            "When a re-sign is due and the MacBook is asleep or off, the alert reads:`n`n" + (Get-DueMessage $example ($example - 36 * 3600))) 'default'
        Write-Host 'Sent a TEST alert.'
        exit 0
    }

    $tailscaleOk = Test-PcTailscale
    $macExpiry = $null
    if ($tailscaleOk -and -not $PretendOffline) { $macExpiry = Get-MacExpiry }
    $reachable = $null -ne $macExpiry

    if ($reachable) {
        $state.macSeenAt = $now
        if ($macExpiry -gt 0) {
            if ($macExpiry -ne [long]$state.expiresAt) { Write-Log "The signature expires $(Format-When $macExpiry) (read from the MacBook)" }
            $state.expiresAt = $macExpiry; $state.expires = Format-When $macExpiry; $state.source = 'MacBook'; $state.readAt = $now
        }
    }
    if ($tailscaleOk -and -not $PretendOffline -and [bool]$state.macReachable -ne $reachable) {
        Write-Log $(if ($reachable) { 'The MacBook is reachable' } else { "The MacBook isn't reachable" })
    }
    if ($tailscaleOk) { $state.macReachable = $reachable }

    $alert = if ($tailscaleOk) { Get-Alert $state $now $reachable }
             else { @{ Send = $false; Why = "Tailscale isn't running on this PC, so it can't tell whether the MacBook is up (the system monitor alerts on that)." } }

    if ($Dry) {
        $mac = if (-not $tailscaleOk) { 'unknown (no Tailscale here)' } elseif ($PretendOffline) { 'off (pretend)' } elseif ($reachable) { 'reachable' } else { 'not reachable' }
        "Now:     $(Format-When $now)$(if ($PretendNow) { ' (pretend)' })"
        "MacBook: $mac$(if ($state.macSeenAt) { ", last reached $(Format-When $state.macSeenAt)" })"
        "Expiry:  $(if ($state.expiresAt) { "$(Format-When $state.expiresAt) (from $($state.source), $(Format-When $state.readAt))" } else { 'unknown' })"
        if ($alert.Send) { "Would alert ($($alert.Priority) priority): $($alert.Title)"; "  $($alert.Body)" }
        else { "No alert: $($alert.Why)" }
        exit 0
    }

    if ($alert.Send) {
        Send-Ntfy $alert.Title $alert.Body $alert.Priority
        $state.lastAlertAt = $now
        $state.alertedExpiry = [long]$state.expiresAt
        Write-Log "Alert ($($alert.Priority)): $($alert.Title) | $($alert.Body)"
    }
    $state.lastRun = $now
    Save-State $state
} catch {
    try { Write-Log "ERROR: $($_.Exception.Message)" } catch { }
    exit 1
}
