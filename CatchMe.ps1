[CmdletBinding()]
param(
    [switch]$StartAuthorized,
    [switch]$Background,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$script:Version = 1
$script:AppName = "CatchMe Lite"
$script:AppRoot = Join-Path $env:LOCALAPPDATA "CatchMeLite"
$script:ConfigPath = Join-Path $script:AppRoot "config.json"
$script:AuthorizationPath = Join-Path $script:AppRoot "authorization.json"
$script:PendingPath = Join-Path $script:AppRoot "pending.jsonl"
$script:LogPath = Join-Path $script:AppRoot "background.log"
$script:StartupName = "CatchMe Lite Personal Recorder.lnk"
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:Paused = $false
$script:CurrentApp = ""
$script:CurrentTitle = ""
$script:HasWindowContext = $false
$script:PreviousText = $null
$script:PreviousControlId = ""
$script:LastKeyDownMilliseconds = 0L
$script:LastClipboard = $null
$script:LastIdleState = ""
$script:SyncInProgress = $false

function Initialize-Directories {
    [IO.Directory]::CreateDirectory($script:AppRoot) | Out-Null
}

function Write-BackgroundLog([string]$Message) {
    try {
        Initialize-Directories
        $line = "{0:o} {1}{2}" -f [DateTime]::UtcNow, $Message, [Environment]::NewLine
        [IO.File]::AppendAllText($script:LogPath, $line, $script:Utf8NoBom)
        $file = Get-Item -LiteralPath $script:LogPath -ErrorAction SilentlyContinue
        if ($file -and $file.Length -gt 1MB) {
            $backup = "$($script:LogPath).1"
            if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
            [IO.File]::Move($script:LogPath, $backup)
        }
    } catch {
        # Logging must never stop recording or expose captured content.
    }
}

function Write-PrivateJson([string]$Path, [object]$Value) {
    $json = $Value | ConvertTo-Json -Depth 10
    $temporary = "$Path.tmp"
    [IO.File]::WriteAllText($temporary, $json + [Environment]::NewLine, $script:Utf8NoBom)
    if ([IO.File]::Exists($Path)) {
        [IO.File]::Delete($Path)
    }
    [IO.File]::Move($temporary, $Path)
}

function New-DefaultConfig {
    $passwordTitleChinese = -join @([char]0x5BC6, [char]0x7801)
    $verificationCodeChinese = -join @([char]0x9A8C, [char]0x8BC1, [char]0x7801)
    return [ordered]@{
        version = $script:Version
        device_id = [Guid]::NewGuid().ToString()
        server_url = "https://g.anyq.site/catchme"
        encrypted_device_token = ""
        sync_interval_seconds = 60
        batch_size = 250
        clipboard_max_bytes = 1048576
        idle_seconds = 300
        excluded_apps = @(
            "1password", "bitwarden", "keepass", "keepassxc",
            "lastpass", "dashlane", "enpass"
        )
        excluded_window_titles = @(
            "password", $passwordTitleChinese, $verificationCodeChinese, "one-time code"
        )
    }
}

function Get-Config {
    Initialize-Directories
    if (-not [IO.File]::Exists($script:ConfigPath)) {
        $created = New-DefaultConfig
        Write-PrivateJson $script:ConfigPath $created
        return ($created | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
    }
    try {
        return (Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        throw "Invalid CatchMe Lite configuration: $($_.Exception.Message)"
    }
}

function Save-Config([object]$Config) {
    Write-PrivateJson $script:ConfigPath $Config
}

function Get-WindowsPowerShellPath {
    return (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe")
}

function Get-StartupPath {
    $shell = New-Object -ComObject WScript.Shell
    $startup = $shell.SpecialFolders.Item("Startup")
    return (Join-Path $startup $script:StartupName)
}

function Install-Startup {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut((Get-StartupPath))
    $shortcut.TargetPath = Get-WindowsPowerShellPath
    $shortcut.Arguments = ('-NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File "{0}" -Background' -f $PSCommandPath)
    $shortcut.WorkingDirectory = $PSScriptRoot
    $shortcut.Description = "CatchMe Lite personal recorder (tray controls available)"
    $shortcut.Save()
}

function Remove-Startup {
    $path = Get-StartupPath
    if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
}

function Save-LauncherAuthorization {
    Initialize-Directories
    $record = [ordered]@{
        version = $script:Version
        granted = $true
        granted_at_utc = [DateTime]::UtcNow.ToString("o")
        authorization_action = "Ran Start-and-Authorize-CatchMe launcher"
        records = @(
            "committed text and shortcuts",
            "active-window context",
            "clipboard text up to 1 MiB",
            "idle state"
        )
        visible_tray_controls = $true
    }
    Write-PrivateJson $script:AuthorizationPath $record
}

function Test-Authorized {
    if (-not [IO.File]::Exists($script:AuthorizationPath)) { return $false }
    try {
        $value = Get-Content -LiteralPath $script:AuthorizationPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return ($value.version -eq $script:Version -and $value.granted -eq $true)
    } catch {
        return $false
    }
}

function Start-BackgroundProcess {
    $arguments = '-NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File "{0}" -Background' -f $PSCommandPath
    Start-Process -FilePath (Get-WindowsPowerShellPath) -ArgumentList $arguments -WindowStyle Hidden | Out-Null
}

function Initialize-RuntimeTypes {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    Add-Type -AssemblyName System.Security
    if (-not ("CatchMeLite.WindowsRuntime" -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot "CatchMe.Core.cs")
    }
}

function Protect-DeviceToken([string]$Token) {
    $plain = [Text.Encoding]::UTF8.GetBytes($Token)
    $protected = [Security.Cryptography.ProtectedData]::Protect(
        $plain,
        $null,
        [Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    return [Convert]::ToBase64String($protected)
}

function Unprotect-DeviceToken([string]$CipherText) {
    if ([string]::IsNullOrWhiteSpace($CipherText)) { return "" }
    try {
        $protected = [Convert]::FromBase64String($CipherText)
        $plain = [Security.Cryptography.ProtectedData]::Unprotect(
            $protected,
            $null,
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return [Text.Encoding]::UTF8.GetString($plain)
    } catch {
        return ""
    }
}

function Initialize-DeviceRegistration([object]$Config) {
    if (-not [string]::IsNullOrWhiteSpace([string]$Config.encrypted_device_token)) {
        return
    }

    $request = [ordered]@{
        device_id = [string]$Config.device_id
        device_name = [Environment]::MachineName
    } | ConvertTo-Json -Compress
    $responseText = [CatchMeLite.WindowsRuntime]::PostJson(
        ([string]$Config.server_url).TrimEnd('/') + "/v1/devices/register",
        "registration",
        $request,
        20000
    )
    $response = $responseText | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$response.device_token)) {
        throw "The server did not issue a device token."
    }
    $Config.encrypted_device_token = Protect-DeviceToken ([string]$response.device_token)
    Save-Config $Config
    Write-BackgroundLog "automatic device registration completed"
}

function Test-ExcludedContext([object]$Config) {
    $app = $script:CurrentApp.ToLowerInvariant()
    $title = $script:CurrentTitle.ToLowerInvariant()
    foreach ($value in $Config.excluded_apps) {
        if ($app.Contains(([string]$value).ToLowerInvariant())) { return $true }
    }
    foreach ($value in $Config.excluded_window_titles) {
        if ($title.Contains(([string]$value).ToLowerInvariant())) { return $true }
    }
    return $false
}

function Protect-CapturedText([string]$Text) {
    $value = $Text
    $value = [regex]::Replace(
        $value,
        '-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----.*?-----END (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----',
        '[redacted:private_key]',
        [Text.RegularExpressions.RegexOptions]::Singleline
    )
    $value = [regex]::Replace($value, '\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b', '[redacted:jwt]')
    $value = [regex]::Replace($value, '\b(?:ghp|github_pat)_[A-Za-z0-9_]{20,}\b', '[redacted:github_token]')
    $value = [regex]::Replace($value, '\bsk-[A-Za-z0-9_-]{20,}\b', '[redacted:openai_key]')
    $value = [regex]::Replace(
        $value,
        '(?i)\b(api[_-]?key|access[_-]?token|secret|password|passwd)\b\s*[:=]\s*([^\s,;]{8,})',
        '$1=[redacted:generic_secret]'
    )
    return $value
}

function Write-CapturedEvent([object]$Config, [string]$Kind, [Collections.IDictionary]$Data) {
    if ($script:Paused) { return }
    if (($Kind -eq "keyboard" -or $Kind -eq "clipboard") -and -not $script:HasWindowContext) {
        return
    }
    if (Test-ExcludedContext $Config) { return }

    if ($Kind -ne "window" -and $script:HasWindowContext) {
        $Data["context"] = [ordered]@{
            app = $script:CurrentApp
            title = $script:CurrentTitle
        }
    }
    $event = [ordered]@{
        event_id = "{0}:{1}" -f $Config.device_id, [Guid]::NewGuid().ToString()
        timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0
        kind = $Kind
        data = $Data
    }
    $line = $event | ConvertTo-Json -Compress -Depth 8
    [IO.File]::AppendAllText($script:PendingPath, $line + [Environment]::NewLine, $script:Utf8NoBom)
}

function Update-WindowContext([object]$Config) {
    $window = [CatchMeLite.WindowsRuntime]::GetActiveWindow()
    $app = [string]$window.ProcessName
    $title = [string]$window.Title
    if ($app -eq $script:CurrentApp -and $title -eq $script:CurrentTitle) { return }
    $script:CurrentApp = $app
    $script:CurrentTitle = $title
    $script:HasWindowContext = $true
    $script:PreviousText = $null
    $script:PreviousControlId = ""
    if (Test-ExcludedContext $Config) { return }
    Write-CapturedEvent $Config "window" ([ordered]@{
        app = $app
        title = $title
        process_id = [int]$window.ProcessId
    })
}

function Get-KeyName([int]$VirtualKey) {
    $special = @{
        8 = "backspace"; 9 = "tab"; 13 = "enter"; 27 = "escape"; 32 = "space"
        33 = "pageup"; 34 = "pagedown"; 35 = "end"; 36 = "home"
        37 = "left"; 38 = "up"; 39 = "right"; 40 = "down"; 46 = "delete"
    }
    if ($special.ContainsKey($VirtualKey)) { return $special[$VirtualKey] }
    if ($VirtualKey -ge 112 -and $VirtualKey -le 123) { return "F$($VirtualKey - 111)" }
    if (($VirtualKey -ge 48 -and $VirtualKey -le 57) -or ($VirtualKey -ge 65 -and $VirtualKey -le 90)) {
        return ([char]$VirtualKey).ToString().ToLowerInvariant()
    }
    return "vk_$VirtualKey"
}

function Update-KeyboardEvents([object]$Config) {
    $keyboardEvent = $null
    while ([CatchMeLite.WindowsRuntime]::TryDequeueKeyboardEvent([ref]$keyboardEvent)) {
        if (-not $keyboardEvent.KeyDown) { continue }
        $script:LastKeyDownMilliseconds = [long]$keyboardEvent.TimestampMilliseconds
        if ($keyboardEvent.VirtualKey -in @(16, 17, 18, 91, 92)) { continue }
        $hasCommandModifier = $keyboardEvent.Ctrl -or $keyboardEvent.Alt -or $keyboardEvent.Win
        $isSpecial = $keyboardEvent.VirtualKey -in @(8, 9, 13, 27, 32, 33, 34, 35, 36, 37, 38, 39, 40, 46) -or ($keyboardEvent.VirtualKey -ge 112 -and $keyboardEvent.VirtualKey -le 123)
        if (-not $hasCommandModifier -and -not $isSpecial) { continue }
        $modifiers = New-Object System.Collections.ArrayList
        if ($keyboardEvent.Ctrl) { [void]$modifiers.Add("ctrl") }
        if ($keyboardEvent.Alt) { [void]$modifiers.Add("alt") }
        if ($keyboardEvent.Shift) { [void]$modifiers.Add("shift") }
        if ($keyboardEvent.Win) { [void]$modifiers.Add("win") }
        $eventType = "special"
        if ($hasCommandModifier) { $eventType = "shortcut" }
        Write-CapturedEvent $Config "keyboard" ([ordered]@{
            key = Get-KeyName $keyboardEvent.VirtualKey
            modifiers = @($modifiers)
            type = $eventType
        })
    }
}

function Get-AddedText([string]$OldValue, [string]$NewValue) {
    $prefix = 0
    while ($prefix -lt $OldValue.Length -and $prefix -lt $NewValue.Length -and $OldValue[$prefix] -eq $NewValue[$prefix]) {
        $prefix++
    }
    $oldSuffix = $OldValue.Length - 1
    $newSuffix = $NewValue.Length - 1
    while ($oldSuffix -ge $prefix -and $newSuffix -ge $prefix -and $OldValue[$oldSuffix] -eq $NewValue[$newSuffix]) {
        $oldSuffix--
        $newSuffix--
    }
    if ($newSuffix -lt $prefix) { return "" }
    return $NewValue.Substring($prefix, $newSuffix - $prefix + 1)
}

function Update-FocusedText([object]$Config) {
    if (-not $script:HasWindowContext -or (Test-ExcludedContext $Config)) {
        $script:PreviousText = $null
        $script:PreviousControlId = ""
        return
    }
    try {
        $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
        if ($null -eq $focused) { return }
        $isPassword = $focused.GetCurrentPropertyValue([System.Windows.Automation.AutomationElement]::IsPasswordProperty)
        if ([bool]$isPassword) {
            $script:PreviousText = $null
            $script:PreviousControlId = ""
            return
        }
        $pattern = $null
        if (-not $focused.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) {
            $script:PreviousText = $null
            $script:PreviousControlId = ""
            return
        }
        $valuePattern = [System.Windows.Automation.ValuePattern]$pattern
        $value = [string]$valuePattern.Current.Value
        $runtimeId = ($focused.GetRuntimeId() -join ".")
        if ($runtimeId -ne $script:PreviousControlId -or $null -eq $script:PreviousText) {
            $script:PreviousControlId = $runtimeId
            $script:PreviousText = $value
            return
        }
        if ($value -eq $script:PreviousText) { return }
        $added = Get-AddedText ([string]$script:PreviousText) $value
        $script:PreviousText = $value
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        if (($now - $script:LastKeyDownMilliseconds) -gt 700) { return }
        if ([string]::IsNullOrEmpty($added) -or $added.Length -gt 200) { return }
        Write-CapturedEvent $Config "keyboard" ([ordered]@{
            key = Protect-CapturedText $added
            modifiers = @()
            type = "text"
        })
    } catch {
        $script:PreviousText = $null
        $script:PreviousControlId = ""
    }
}

function Update-Clipboard([object]$Config) {
    if (-not $script:HasWindowContext -or (Test-ExcludedContext $Config)) { return }
    try {
        if (-not [Windows.Forms.Clipboard]::ContainsText()) { return }
        $text = [Windows.Forms.Clipboard]::GetText()
        if ($text -eq $script:LastClipboard) { return }
        $script:LastClipboard = $text
        $bytes = [Text.Encoding]::UTF8.GetByteCount($text)
        if ($bytes -gt [int]$Config.clipboard_max_bytes) {
            Write-CapturedEvent $Config "clipboard" ([ordered]@{
                dropped = $true
                reason = "over_limit"
                utf8_bytes = $bytes
            })
            return
        }
        Write-CapturedEvent $Config "clipboard" ([ordered]@{
            content = Protect-CapturedText $text
            utf8_bytes = $bytes
        })
    } catch {
        # Clipboard can be temporarily locked by another process.
    }
}

function Update-IdleState([object]$Config) {
    $seconds = [CatchMeLite.WindowsRuntime]::GetIdleSeconds()
    $state = "active"
    if ($seconds -ge [double]$Config.idle_seconds) { $state = "idle" }
    if ($state -eq $script:LastIdleState) { return }
    $script:LastIdleState = $state
    Write-CapturedEvent $Config "idle" ([ordered]@{
        status = $state
        seconds = [Math]::Round($seconds, 1)
    })
}

function Rewrite-PendingQueue([string[]]$Lines) {
    $temporary = "$($script:PendingPath).tmp"
    if ($Lines.Count -eq 0) {
        [IO.File]::WriteAllText($temporary, "", $script:Utf8NoBom)
    } else {
        [IO.File]::WriteAllText($temporary, (($Lines -join [Environment]::NewLine) + [Environment]::NewLine), $script:Utf8NoBom)
    }
    if ([IO.File]::Exists($script:PendingPath)) { [IO.File]::Delete($script:PendingPath) }
    [IO.File]::Move($temporary, $script:PendingPath)
}

function Invoke-Sync([object]$Config) {
    if ($script:SyncInProgress -or -not [IO.File]::Exists($script:PendingPath)) { return 0 }
    $token = Unprotect-DeviceToken ([string]$Config.encrypted_device_token)
    if ([string]::IsNullOrWhiteSpace($token)) { return 0 }
    $serverUrl = ([string]$Config.server_url).TrimEnd('/')
    if (-not $serverUrl.StartsWith("https://", [StringComparison]::OrdinalIgnoreCase)) { return 0 }

    $script:SyncInProgress = $true
    try {
        $lines = @([IO.File]::ReadAllLines($script:PendingPath, [Text.Encoding]::UTF8) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($lines.Count -eq 0) { return 0 }
        $count = [Math]::Min([int]$Config.batch_size, $lines.Count)
        $events = New-Object System.Collections.ArrayList
        for ($index = 0; $index -lt $count; $index++) {
            [void]$events.Add(($lines[$index] | ConvertFrom-Json))
        }
        $batchId = [Guid]::NewGuid().ToString()
        $payload = [ordered]@{
            batch_id = $batchId
            device_id = [string]$Config.device_id
            sent_at = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0
            events = @($events)
        } | ConvertTo-Json -Compress -Depth 10
        $responseText = [CatchMeLite.WindowsRuntime]::PostGzipJson(
            $serverUrl + "/v1/events/batches",
            $token,
            $payload,
            20000
        )
        $acknowledgement = $responseText | ConvertFrom-Json
        if ($acknowledgement.accepted -ne $true -or $acknowledgement.batch_id -ne $batchId) {
            throw "The server did not acknowledge the batch."
        }
        $remaining = @()
        if ($count -lt $lines.Count) { $remaining = @($lines[$count..($lines.Count - 1)]) }
        Rewrite-PendingQueue $remaining
        Write-BackgroundLog "sync acknowledged batch=$batchId events=$count"
        return $count
    } catch {
        Write-BackgroundLog "sync failed: $($_.Exception.Message)"
        return 0
    } finally {
        $script:SyncInProgress = $false
    }
}

function Start-TrayRuntime {
    if (-not (Test-Authorized)) { exit 2 }
    Initialize-RuntimeTypes
    Initialize-Directories

    $createdNew = $false
    $mutex = New-Object Threading.Mutex($true, "Local\CatchMeLitePersonalRecorder", [ref]$createdNew)
    if (-not $createdNew) {
        $mutex.Dispose()
        return
    }

    $config = Get-Config
    try { Initialize-DeviceRegistration $config } catch { Write-BackgroundLog "automatic device registration failed: $($_.Exception.Message)" }

    $notifyIcon = New-Object Windows.Forms.NotifyIcon
    $notifyIcon.Icon = [Drawing.SystemIcons]::Information
    $notifyIcon.Text = "CatchMe Lite - recording"
    $notifyIcon.Visible = $true
    $menu = New-Object Windows.Forms.ContextMenuStrip
    $statusItem = $menu.Items.Add("Status: recording")
    $statusItem.Enabled = $false
    $pauseItem = $menu.Items.Add("Pause recording")
    $syncItem = $menu.Items.Add("Sync now")
    $openItem = $menu.Items.Add("Open data folder")
    [void]$menu.Items.Add("-")
    $exitItem = $menu.Items.Add("Exit CatchMe Lite")
    $disableItem = $menu.Items.Add("Disable and remove startup")
    $notifyIcon.ContextMenuStrip = $menu

    $pauseItem.Add_Click({
        $script:Paused = -not $script:Paused
        if ($script:Paused) {
            $pauseItem.Text = "Resume recording"
            $statusItem.Text = "Status: paused"
            $notifyIcon.Text = "CatchMe Lite - paused"
        } else {
            $pauseItem.Text = "Pause recording"
            $statusItem.Text = "Status: recording"
            $notifyIcon.Text = "CatchMe Lite - recording"
        }
    })
    $syncItem.Add_Click({ [void](Invoke-Sync $config) })
    $openItem.Add_Click({ Start-Process explorer.exe -ArgumentList ('"{0}"' -f $script:AppRoot) })
    $exitItem.Add_Click({ [Windows.Forms.Application]::Exit() })
    $disableItem.Add_Click({
        Remove-Startup
        if ([IO.File]::Exists($script:AuthorizationPath)) { [IO.File]::Delete($script:AuthorizationPath) }
        [Windows.Forms.Application]::Exit()
    })

    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 100
    $lastWindow = [DateTime]::MinValue
    $lastClipboardPoll = [DateTime]::MinValue
    $lastIdlePoll = [DateTime]::MinValue
    $lastSync = [DateTime]::UtcNow
    $timer.Add_Tick({
        try {
            $now = [DateTime]::UtcNow
            Update-KeyboardEvents $config
            Update-FocusedText $config
            if (($now - $lastWindow).TotalMilliseconds -ge 1000) {
                Update-WindowContext $config
                $lastWindow = $now
            }
            if (($now - $lastClipboardPoll).TotalMilliseconds -ge 1000) {
                Update-Clipboard $config
                $lastClipboardPoll = $now
            }
            if (($now - $lastIdlePoll).TotalMilliseconds -ge 5000) {
                Update-IdleState $config
                $lastIdlePoll = $now
            }
            if (($now - $lastSync).TotalSeconds -ge [double]$config.sync_interval_seconds) {
                if ([string]::IsNullOrWhiteSpace((Unprotect-DeviceToken ([string]$config.encrypted_device_token)))) {
                    try {
                        Initialize-DeviceRegistration $config
                    } catch {
                        Write-BackgroundLog "automatic device registration retry failed: $($_.Exception.Message)"
                    }
                }
                [void](Invoke-Sync $config)
                $lastSync = $now
            }
        } catch {
            Write-BackgroundLog "timer error: $($_.Exception.Message)"
        }
    })

    try {
        [CatchMeLite.WindowsRuntime]::StartKeyboardHook()
        $timer.Start()
        [Windows.Forms.Application]::Run()
    } finally {
        $timer.Stop()
        $timer.Dispose()
        [CatchMeLite.WindowsRuntime]::StopKeyboardHook()
        $notifyIcon.Visible = $false
        $notifyIcon.Dispose()
        $menu.Dispose()
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

if ($SelfTest) {
    Initialize-RuntimeTypes
    $window = [CatchMeLite.WindowsRuntime]::GetActiveWindow()
    $probeToken = "catchme-lite-self-test-token"
    $protectedProbe = Protect-DeviceToken $probeToken
    $unprotectedProbe = Unprotect-DeviceToken $protectedProbe
    $redactedProbe = Protect-CapturedText "api_key=example-secret-value-123456"
    $diffProbe = Get-AddedText "hello" "hello world"
    if ($unprotectedProbe -ne $probeToken) { throw "DPAPI round trip failed." }
    if ($redactedProbe.Contains("example-secret")) { throw "Secret redaction failed." }
    if ($diffProbe -ne " world") { throw "Committed text diff failed." }
    [ordered]@{
        status = "ok"
        powershell = $PSVersionTable.PSVersion.ToString()
        apartment = [Threading.Thread]::CurrentThread.ApartmentState.ToString()
        active_process_available = -not [string]::IsNullOrWhiteSpace($window.ProcessName)
        dpapi = "ok"
        redaction = "ok"
        text_diff = "ok"
    } | ConvertTo-Json -Compress
    exit 0
}

if ($StartAuthorized) {
    Save-LauncherAuthorization
    Install-Startup
    Start-BackgroundProcess
    exit 0
}

if ($Background) {
    Start-TrayRuntime
    exit 0
}

Write-Output "Use the 'Start and Authorize CatchMe' launcher."
exit 2
