[CmdletBinding()]
param(
  [int]$Port = 9335,
  [Alias('NoAutoAttach')][switch]$DisableOfficialLaunchMonitor,
  [switch]$EnableOfficialLaunchMonitor
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
. (Join-Path $PSScriptRoot 'localization-windows.ps1')
. (Join-Path $PSScriptRoot 'common-windows.ps1')
. (Join-Path $PSScriptRoot 'theme-windows.ps1')
Assert-DreamSkinWindows11

Assert-DreamSkinPort -Port $Port
$PortExplicit = $PSBoundParameters.ContainsKey('Port')
$PortFromState = $false
$SkillRoot = Split-Path -Parent $PSScriptRoot
$StateRoot = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'
$paths = $null
$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
$startScript = Join-Path $PSScriptRoot 'start-dream-skin.ps1'
$restoreScript = Join-Path $PSScriptRoot 'restore-dream-skin.ps1'
$checkUpdateScript = Join-Path $PSScriptRoot 'check-update.ps1'
$startupShortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'Codex Dream Skin.lnk'

$sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$mutex = [System.Threading.Mutex]::new($false, "Local\CodexDreamSkin.$sid.Tray")
$acquired = $false
$notify = $null
$trayIcon = $null
$recoveryTimer = $null
$recoveryMonitor = @{
  Process = $null
  NextAttemptAt = [datetime]::MinValue
}
$officialLaunchMonitor = @{
  Enabled = $true
  Baseline = @{}
  BaselineInitialized = $false
  Seen = @{}
  Pending = @{}
  Process = $null
  CandidateKey = $null
  Candidate = $null
  ResultToken = $null
  NextAttemptAt = [datetime]::MinValue
}
if ($DisableOfficialLaunchMonitor -and $EnableOfficialLaunchMonitor) {
  throw 'Choose either -DisableOfficialLaunchMonitor or -EnableOfficialLaunchMonitor, not both.'
}
if ($DisableOfficialLaunchMonitor -or $EnableOfficialLaunchMonitor) {
  $toggleLock = Enter-DreamSkinOperationLock
  try {
    Set-DreamSkinOfficialLaunchMonitorEnabled -Enabled:(-not $DisableOfficialLaunchMonitor) -StateRoot $StateRoot
  } finally {
    Exit-DreamSkinOperationLock -Mutex $toggleLock
  }
  $mutex.Dispose()
  exit 0
}
try {
  try { $acquired = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
  if (-not $acquired) { exit 0 }

  $initializationLock = Enter-DreamSkinOperationLock
  try {
    $paths = Initialize-DreamSkinThemeStore -SkillRoot $SkillRoot -StateRoot $StateRoot
    $existingState = $null
    try { $existingState = Read-DreamSkinState -Path $paths.State } catch {}
    if (-not $PortExplicit -and $null -ne $existingState -and $existingState.port) {
      $Port = [int]$existingState.port
      Assert-DreamSkinPort -Port $Port
      $PortFromState = $true
    }
    if ($DisableOfficialLaunchMonitor) {
      Set-DreamSkinOfficialLaunchMonitorEnabled -Enabled $false -StateRoot $StateRoot
    } elseif ($EnableOfficialLaunchMonitor) {
      Set-DreamSkinOfficialLaunchMonitorEnabled -Enabled $true -StateRoot $StateRoot
    }
    $officialLaunchMonitor.Enabled = Test-DreamSkinOfficialLaunchMonitorEnabled -StateRoot $StateRoot
  } finally {
    Exit-DreamSkinOperationLock -Mutex $initializationLock
  }

  $notify = [System.Windows.Forms.NotifyIcon]::new()
  $iconPath = Join-Path $SkillRoot 'assets\codex-dream-skin.ico'
  if (Test-Path -LiteralPath $iconPath -PathType Leaf) {
    $trayIcon = [System.Drawing.Icon]::new($iconPath)
    $notify.Icon = $trayIcon
  } else {
    $notify.Icon = [System.Drawing.SystemIcons]::Application
  }
  $notify.Text = 'Codex Dream Skin'
  $notify.Visible = $true
  $menu = [System.Windows.Forms.ContextMenuStrip]::new()
  $notify.ContextMenuStrip = $menu

  function Show-DreamSkinTrayError {
    param([string]$Message)
    [void][System.Windows.Forms.MessageBox]::Show(
      $Message,
      'Codex Dream Skin',
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Error
    )
  }

  function Get-DreamSkinTrayText {
    param(
      [Parameter(Mandatory = $true)][string]$Key,
      [object[]]$FormatArguments = @()
    )
    $language = Resolve-DreamSkinLanguage -StateRoot $StateRoot
    Get-DreamSkinText -Key $Key -Language $language -FormatArguments $FormatArguments
  }

  function Start-DreamSkinPowerShell {
    param(
      [Parameter(Mandatory = $true)][string]$Script,
      [string[]]$Arguments = @(),
      [switch]$PassThru
    )
    $scriptToken = ConvertTo-DreamSkinProcessArgument -Value $Script
    $argumentLine = '-NoProfile -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File ' + $scriptToken
    if ($Arguments.Count -gt 0) { $argumentLine += ' ' + (ConvertTo-DreamSkinArgumentLine -Arguments $Arguments) }
    $previousLanguage = $env:DREAMSKIN_LANG
    try {
      $env:DREAMSKIN_LANG = Resolve-DreamSkinLanguage -StateRoot $StateRoot
      $process = Start-Process -FilePath $powershell -ArgumentList $argumentLine -WindowStyle Hidden -PassThru
      if ($PassThru) { return $process }
      $process.Dispose()
    } finally {
      $env:DREAMSKIN_LANG = $previousLanguage
    }
  }

  function Get-DreamSkinTrayStartArguments {
    param(
      [AllowEmptyCollection()][string[]]$AdditionalArguments = @(),
      [switch]$ForcePort
    )
    $arguments = @()
    if ($ForcePort -or $PortExplicit -or $PortFromState) {
      $arguments += @('-Port', "$Port")
    }
    return @($arguments + $AdditionalArguments)
  }

  function Get-DreamSkinTrayOfficialProcessSnapshot {
    try {
      $observed = @(Get-DreamSkinRegisteredCodexMainProcessRecords)
      $records = @{}
      foreach ($item in $observed) {
        $key = ConvertTo-DreamSkinProcessIdentityKey -ProcessRecord $item.Process
        $records[$key] = $item
      }
      return [pscustomobject]@{ Ready = $true; Observed = $observed; Records = $records }
    } catch {
      return [pscustomobject]@{ Ready = $false; Observed = @(); Records = @{} }
    }
  }

  function Update-DreamSkinTrayOfficialProcessBaseline {
    $snapshot = Get-DreamSkinTrayOfficialProcessSnapshot
    if ($snapshot.Ready) {
      $officialLaunchMonitor.Baseline = $snapshot.Records
      $officialLaunchMonitor.BaselineInitialized = $true
    }
    return $snapshot
  }

  function Test-DreamSkinTrayOfficialLaunchEligibility {
    try {
      $active = Read-DreamSkinTheme -ThemeDirectory $paths.Active -SkipImageMetadata
      $themeReady = $null -ne $active -and $null -ne $active.Theme -and
        -not [string]::IsNullOrWhiteSpace("$($active.Theme.name)")
      return $officialLaunchMonitor.Enabled -and
        (Test-DreamSkinOfficialLaunchMonitorState -StatePath $paths.State `
          -ThemeReady $themeReady -Paused:(Test-DreamSkinPaused -StateRoot $StateRoot))
    } catch {
      return $false
    }
  }

  function Invoke-DreamSkinTrayOfficialLaunchMonitor {
    if ($null -ne $recoveryMonitor.Process) {
      try {
        if (-not $recoveryMonitor.Process.HasExited) { return }
        $recoveryMonitor.Process.Dispose()
      } catch {}
      $recoveryMonitor.Process = $null
      $null = Update-DreamSkinTrayOfficialProcessBaseline
      $officialLaunchMonitor.NextAttemptAt = (Get-Date).AddSeconds(5)
      return
    }
    if ($null -ne $officialLaunchMonitor.Process) {
      $completedProcess = $officialLaunchMonitor.Process
      $completedKey = $officialLaunchMonitor.CandidateKey
      $completedToken = $officialLaunchMonitor.ResultToken
      $succeeded = $false
      try {
        if (-not $completedProcess.HasExited) { return }
        if ($completedToken) {
          try {
            $result = Read-DreamSkinStartResult -StateRoot $StateRoot -Token $completedToken
            $succeeded = "$($result.outcome)" -ceq 'success'
          } catch {}
          Remove-Item -LiteralPath (Get-DreamSkinStartResultPath -StateRoot $StateRoot -Token $completedToken) -Force -ErrorAction SilentlyContinue
        } else {
          $succeeded = $completedProcess.ExitCode -eq 0
        }
        $completedProcess.Dispose()
      } catch {}
      $officialLaunchMonitor.Process = $null
      $officialLaunchMonitor.CandidateKey = $null
      $officialLaunchMonitor.Candidate = $null
      $officialLaunchMonitor.ResultToken = $null
      if ($succeeded -and $completedKey) {
        $officialLaunchMonitor.Seen[$completedKey] = $true
        while ($officialLaunchMonitor.Seen.Count -gt 64) {
          $oldest = @($officialLaunchMonitor.Seen.Keys | Select-Object -First 1)
          if ($oldest.Count -eq 0) { break }
          $officialLaunchMonitor.Seen.Remove($oldest[0])
        }
        $null = Update-DreamSkinTrayOfficialProcessBaseline
      }
      $officialLaunchMonitor.NextAttemptAt = (Get-Date).AddSeconds($(if ($succeeded) { 5 } else { 30 }))
      return
    }

    $markerEnabled = Test-DreamSkinOfficialLaunchMonitorEnabled -StateRoot $StateRoot
    if ($markerEnabled -ne $officialLaunchMonitor.Enabled) {
      $officialLaunchMonitor.Enabled = $markerEnabled
      $officialLaunchMonitor.Baseline = @{}
      $officialLaunchMonitor.BaselineInitialized = $false
      $officialLaunchMonitor.Seen = @{}
      $officialLaunchMonitor.Pending = @{}
    }
    if (-not $officialLaunchMonitor.Enabled) { return }

    $now = Get-Date
    if ($now -lt $officialLaunchMonitor.NextAttemptAt) { return }
    $snapshot = Get-DreamSkinTrayOfficialProcessSnapshot
    if (-not $snapshot.Ready) { return }
    if (-not $officialLaunchMonitor.BaselineInitialized) {
      $officialLaunchMonitor.Baseline = $snapshot.Records
      $officialLaunchMonitor.BaselineInitialized = $true
      return
    }

    $observation = Get-DreamSkinOfficialLaunchObservation `
      -Baseline $officialLaunchMonitor.Baseline -Observed $snapshot.Observed
    $candidates = @($observation.Candidates | Where-Object {
      $key = ConvertTo-DreamSkinProcessIdentityKey -ProcessRecord $_.Process
      -not $officialLaunchMonitor.Seen.ContainsKey($key)
    })
    if ($candidates.Count -eq 0) {
      $officialLaunchMonitor.Baseline = $observation.Current
      return
    }

    # Multiple simultaneous Store versions or multiple root processes are
    # ambiguous. Keep the official app untouched and consume this observation.
    if ($observation.Ambiguous) {
      foreach ($candidate in $candidates) {
        $key = ConvertTo-DreamSkinProcessIdentityKey -ProcessRecord $candidate.Process
        $officialLaunchMonitor.Seen[$key] = $true
      }
      $officialLaunchMonitor.Baseline = $observation.Current
      return
    }

    if (-not (Test-DreamSkinTrayOfficialLaunchEligibility)) {
      $key = ConvertTo-DreamSkinProcessIdentityKey -ProcessRecord $candidates[0].Process
      $officialLaunchMonitor.Seen[$key] = $true
      $officialLaunchMonitor.Baseline = $observation.Current
      return
    }

    $candidate = $candidates[0]
    $candidateKey = ConvertTo-DreamSkinProcessIdentityKey -ProcessRecord $candidate.Process
    $launchIntent = Read-DreamSkinLaunchIntent -StateRoot $StateRoot
    $intentMatches = Test-DreamSkinLaunchIntentForCandidate `
      -Intent $launchIntent -Candidate $candidate -Port $Port
    $verifiedIdentity = $null
    try {
      $verifiedIdentity = Get-DreamSkinVerifiedCdpIdentity -Port $Port -Codex $candidate.Codex
    } catch {}

    # A normal Codex launch is never restarted just to obtain CDP. A managed
    # Dream Skin launch is already being handled by start-dream-skin.ps1 while
    # it owns the operation lock; let that operation finish instead of
    # starting a second takeover process. An independently launched Codex may
    # be attached only when it already owns a verified loopback endpoint.
    $activeState = $null
    try { $activeState = Read-DreamSkinState -Path $paths.State } catch {}
    if ($null -ne $activeState -and $null -ne $activeState.codexMainProcess -and
      (Test-DreamSkinCodexProcessIdentity -Recorded $activeState.codexMainProcess -Current $candidate.Process)) {
      $officialLaunchMonitor.Pending.Remove($candidateKey)
      $officialLaunchMonitor.Seen[$candidateKey] = $true
      $officialLaunchMonitor.Baseline = $observation.Current
      return
    }
    if ($intentMatches -and -not (Test-DreamSkinOperationLockAvailable)) {
      $officialLaunchMonitor.NextAttemptAt = $now.AddSeconds(5)
      return
    }
    if ($null -eq $verifiedIdentity) {
      $retryUntil = $officialLaunchMonitor.Pending[$candidateKey]
      if ($null -eq $retryUntil) {
        $retryUntil = $now.AddSeconds(30)
        $officialLaunchMonitor.Pending[$candidateKey] = $retryUntil
      }
      if ($now -lt $retryUntil) {
        $officialLaunchMonitor.NextAttemptAt = $now.AddSeconds(2)
        return
      }
      $officialLaunchMonitor.Pending.Remove($candidateKey)
      $officialLaunchMonitor.Seen[$candidateKey] = $true
      $officialLaunchMonitor.Baseline = $observation.Current
      return
    }
    $officialLaunchMonitor.Pending.Remove($candidateKey)
    if (-not (Test-DreamSkinOperationLockAvailable)) {
      $officialLaunchMonitor.NextAttemptAt = $now.AddSeconds(5)
      return
    }
    $resultToken = [guid]::NewGuid().ToString('N')
    try {
      $targetArguments = @(
        '-LaunchSource', 'official-auto',
        '-ResultToken', $resultToken,
        '-TargetPackageFullName', "$($candidate.Codex.PackageFullName)",
        '-TargetPackageFamilyName', "$($candidate.Codex.PackageFamilyName)",
        '-TargetPackageRoot', "$($candidate.Codex.PackageRoot)",
        '-TargetProcessId', "$($candidate.Process.ProcessId)",
        '-TargetProcessStartedAt', "$($candidate.Process.StartedAt)"
      )
      $officialLaunchMonitor.Process = Start-DreamSkinPowerShell -Script $startScript -Arguments (Get-DreamSkinTrayStartArguments -AdditionalArguments $targetArguments) -PassThru
      $officialLaunchMonitor.CandidateKey = $candidateKey
      $officialLaunchMonitor.Candidate = $candidate
      $officialLaunchMonitor.ResultToken = $resultToken
      $officialLaunchMonitor.NextAttemptAt = $now.AddSeconds(30)
    } catch {
      $officialLaunchMonitor.Process = $null
      $officialLaunchMonitor.CandidateKey = $null
      $officialLaunchMonitor.Candidate = $null
      $officialLaunchMonitor.ResultToken = $null
      $officialLaunchMonitor.NextAttemptAt = $now.AddSeconds(30)
    }
  }

  function Invoke-DreamSkinTrayRecovery {
    if ($null -ne $officialLaunchMonitor.Process) {
      try { if (-not $officialLaunchMonitor.Process.HasExited) { return } } catch {}
    }
    if (Test-DreamSkinPaused -StateRoot $StateRoot) { return }
    if ($null -ne $recoveryMonitor.Process) {
      try {
        if (-not $recoveryMonitor.Process.HasExited) { return }
        $recoveryMonitor.Process.Dispose()
      } catch {}
      $recoveryMonitor.Process = $null
      $null = Update-DreamSkinTrayOfficialProcessBaseline
      $officialLaunchMonitor.NextAttemptAt = (Get-Date).AddSeconds(5)
      return
    }

    $now = Get-Date
    if ($now -lt $recoveryMonitor.NextAttemptAt) { return }
    $state = Read-DreamSkinState -Path $paths.State
    $context = Get-DreamSkinInjectorRecoveryContext -State $state
    if ($null -eq $context) { return }

    # The locked start path repeats official-package and Browser ownership
    # checks. RecoverExisting cannot launch, restart, or resume Codex.
    $recoveryMonitor.NextAttemptAt = $now.AddSeconds(30)
    $recoveryMonitor.Process = Start-DreamSkinPowerShell -Script $startScript -Arguments @(
      '-Port', "$($context.Port)", '-RecoverExisting'
    ) -PassThru
  }

  function Add-DreamSkinTrayItem {
    param(
      [Parameter(Mandatory = $true)]
      [AllowEmptyCollection()]
      [System.Windows.Forms.ToolStripItemCollection]$Items,
      [Parameter(Mandatory = $true)][string]$Text,
      [AllowNull()][scriptblock]$Action,
      [bool]$Enabled = $true,
      [bool]$Checked = $false
    )
    $item = [System.Windows.Forms.ToolStripMenuItem]::new($Text)
    $item.Enabled = $Enabled
    $item.Checked = $Checked
    if ($null -ne $Action) {
      $item.add_Click({
        try { & $Action } catch { Show-DreamSkinTrayError -Message $_.Exception.Message }
      }.GetNewClosure())
    }
    [void]$Items.Add($item)
    return $item
  }

  function Add-DreamSkinTrayLanguageMenu {
    $preference = Get-DreamSkinLanguagePreference -StateRoot $StateRoot
    $languageMenu = [System.Windows.Forms.ToolStripMenuItem]::new(
      (Get-DreamSkinTrayText -Key 'Language')
    )
    foreach ($option in @(
      @{ Value = 'system'; Label = (Get-DreamSkinTrayText -Key 'LanguageSystem') },
      @{ Value = 'en-US'; Label = (Get-DreamSkinTrayText -Key 'LanguageEnglish') },
      @{ Value = 'zh-CN'; Label = (Get-DreamSkinTrayText -Key 'LanguageChinese') }
    )) {
      $optionValue = $option.Value
      $optionAction = {
        Set-DreamSkinLanguage -Language $optionValue -StateRoot $StateRoot
        Rebuild-DreamSkinTrayMenu
      }.GetNewClosure()
      $optionItem = Add-DreamSkinTrayItem -Items $languageMenu.DropDownItems -Text $option.Label -Action $optionAction
      $optionItem.Checked = $preference -ceq $optionValue
    }
    [void]$menu.Items.Add($languageMenu)
  }

  function Invoke-DreamSkinTrayThemeOperation {
    param([Parameter(Mandatory = $true)][scriptblock]$Action)
    $themeOperationLock = Enter-DreamSkinOperationLock
    try {
      return & $Action
    } finally {
      Exit-DreamSkinOperationLock -Mutex $themeOperationLock
    }
  }

  function Set-DreamSkinAutoStart {
    param([Parameter(Mandatory = $true)][bool]$Enabled)
    if (-not $Enabled) {
      Remove-Item -LiteralPath $startupShortcut -Force -ErrorAction SilentlyContinue
      Set-DreamSkinAutoStartDisabled -Disabled $true -StateRoot $StateRoot
      return
    }
    Set-DreamSkinAutoStartDisabled -Disabled $false -StateRoot $StateRoot
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($startupShortcut)
    $shortcut.TargetPath = $powershell
    $startupArguments = @('-NoProfile', '-STA', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'RemoteSigned', '-File', (Join-Path $PSScriptRoot 'tray-dream-skin.ps1'))
    if ($PortExplicit -or $PortFromState) { $startupArguments += @('-Port', "$Port") }
    $shortcut.Arguments = ConvertTo-DreamSkinArgumentLine -Arguments $startupArguments
    $shortcut.WorkingDirectory = $SkillRoot
    $shortcut.Description = 'Start Codex Dream Skin in the notification area'
    $shortcut.Save()
  }

  function Rebuild-DreamSkinTrayMenu {
    $menu.Items.Clear()
    $paused = Test-DreamSkinPaused -StateRoot $StateRoot
    $state = $null
    try { $state = Read-DreamSkinState -Path $paths.State } catch {}
    $active = $null
    try { $active = Read-DreamSkinTheme -ThemeDirectory $paths.Active -SkipImageMetadata } catch {}
    $stateStatus = Get-DreamSkinStateStatus -Path $paths.State
    $status = if ($paused) {
      Get-DreamSkinTrayText -Key 'StatusPaused'
    } else {
      switch ($stateStatus) {
        'running' { Get-DreamSkinTrayText -Key 'StatusRunning'; break }
        'stale' { Get-DreamSkinTrayText -Key 'StatusStale'; break }
        'blocked' { Get-DreamSkinTrayText -Key 'StatusBlocked'; break }
        default { Get-DreamSkinTrayText -Key 'StatusStopped'; break }
      }
    }
    if ($null -ne $active -and $null -ne $active.Theme -and $active.Theme.name) {
      $status += " · $($active.Theme.name)"
    }
    $null = Add-DreamSkinTrayItem -Items $menu.Items -Text $status -Action $null -Enabled $false
    [void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
    $officialMonitorEnabled = Test-DreamSkinOfficialLaunchMonitorEnabled -StateRoot $StateRoot
    $officialMonitorAction = {
      $next = -not (Test-DreamSkinOfficialLaunchMonitorEnabled -StateRoot $StateRoot)
      Set-DreamSkinOfficialLaunchMonitorEnabled -Enabled $next -StateRoot $StateRoot
      $officialLaunchMonitor.Enabled = $next
      $officialLaunchMonitor.Baseline = @{}
      $officialLaunchMonitor.BaselineInitialized = $false
      $officialLaunchMonitor.Seen = @{}
      Rebuild-DreamSkinTrayMenu
    }.GetNewClosure()
    $null = Add-DreamSkinTrayItem -Items $menu.Items -Text (Get-DreamSkinTrayText -Key 'OfficialLaunchMonitor') `
      -Action $officialMonitorAction -Checked $officialMonitorEnabled

    [void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())

    $null = Add-DreamSkinTrayItem -Items $menu.Items -Text (Get-DreamSkinTrayText -Key 'Apply') -Action {
      $session = Get-DreamSkinLiveSessionContext -StateRoot $StateRoot
      $begin = $null
      if ($null -ne $session) {
        $begin = Show-DreamSkinOperationUi -Session $session -Phase begin -Kind apply -TimeoutMs 3000
      }
      Start-DreamSkinPowerShell -Script $startScript -Arguments (Get-DreamSkinTrayStartArguments -AdditionalArguments @('-PromptRestart'))
      # start-dream-skin is async; close the in-window loading so it does not stick for 180s.
      if ($null -ne $session -and $null -ne $begin -and $begin.Ok) {
        $null = Show-DreamSkinOperationUi -Session $session -Phase finish -Token $begin.Token `
          -UiState success -Message (Get-DreamSkinTrayText -Key 'ApplyStarted') -TimeoutMs 1500
      }
      $notify.ShowBalloonTip(1800, 'Codex Dream Skin', (Get-DreamSkinTrayText -Key 'Applying'), [System.Windows.Forms.ToolTipIcon]::Info)
    }
    # Match macOS menubar: pause = mark + live remove; resume lets the serialized
    # start path clear pause only after its safety checks and any restart consent.
    if ($paused) {
      $null = Add-DreamSkinTrayItem -Items $menu.Items -Text (Get-DreamSkinTrayText -Key 'Resume') -Action {
        # Keep pause set while the start path validates and prompts; show in-window
        # loading when the existing CDP session is still reachable.
        $session = Get-DreamSkinLiveSessionContext -StateRoot $StateRoot
        $begin = $null
        if ($null -ne $session) {
          $begin = Show-DreamSkinOperationUi -Session $session -Phase begin -Kind apply -TimeoutMs 3000
        }
        Start-DreamSkinPowerShell -Script $startScript -Arguments (Get-DreamSkinTrayStartArguments -AdditionalArguments @('-PromptRestart'))
        if ($null -ne $session -and $null -ne $begin -and $begin.Ok) {
          $null = Show-DreamSkinOperationUi -Session $session -Phase finish -Token $begin.Token `
          -UiState success -Message (Get-DreamSkinTrayText -Key 'ResumeStarted') -TimeoutMs 1500
        }
        $notify.ShowBalloonTip(
          1800,
          'Codex Dream Skin',
          (Get-DreamSkinTrayText -Key 'Reapplying'),
          [System.Windows.Forms.ToolTipIcon]::Info
        )
      }
    } else {
      $null = Add-DreamSkinTrayItem -Items $menu.Items -Text (Get-DreamSkinTrayText -Key 'Pause') -Action {
        # Match macOS pause: marker + live remove with in-window loading / result.
        $pauseNoSessionMessage = Get-DreamSkinTrayText -Key 'PauseNoSession'
        $pauseSucceededMessage = Get-DreamSkinTrayText -Key 'PauseSucceeded'
        $pauseFailedMessage = Get-DreamSkinTrayText -Key 'PauseFailed'
        $removal = Invoke-DreamSkinTrayThemeOperation -Action {
          Set-DreamSkinPaused -Paused $true -StateRoot $StateRoot | Out-Null
          Invoke-DreamSkinLiveRemove -StateRoot $StateRoot `
            -PauseNoSessionMessage $pauseNoSessionMessage `
            -PauseSucceededMessage $pauseSucceededMessage `
            -PauseFailedMessage $pauseFailedMessage
        }
        $icon = if ($removal.Removed) {
          [System.Windows.Forms.ToolTipIcon]::Info
        } else {
          [System.Windows.Forms.ToolTipIcon]::Warning
        }
        $removalMessage = $removal.Message
        $notify.ShowBalloonTip(2800, 'Codex Dream Skin', $removalMessage, $icon)
        if (-not $removal.Removed -and $removal.Attempted) {
          Show-DreamSkinTrayError -Message $removalMessage
        }
      }
    }
    $null = Add-DreamSkinTrayItem -Items $menu.Items -Text (Get-DreamSkinTrayText -Key 'ChangeBackground') -Action {
      $dialog = [System.Windows.Forms.OpenFileDialog]::new()
      $dialog.Title = Get-DreamSkinTrayText -Key 'BackgroundTitle'
      $dialog.Filter = Get-DreamSkinTrayText -Key 'ImageFilter'
      $dialog.Multiselect = $false
      try {
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
          $null = Invoke-DreamSkinTrayThemeOperation -Action {
            $null = Set-DreamSkinActiveThemeImage -ImagePath $dialog.FileName `
              -StateRoot $StateRoot
            Set-DreamSkinPaused -Paused $false -StateRoot $StateRoot | Out-Null
          }
          $notify.ShowBalloonTip(1800, 'Codex Dream Skin', (Get-DreamSkinTrayText -Key 'BackgroundUpdated'), [System.Windows.Forms.ToolTipIcon]::Info)
        }
      } finally {
        $dialog.Dispose()
      }
    }
    $null = Add-DreamSkinTrayItem -Items $menu.Items -Text (Get-DreamSkinTrayText -Key 'ImportZip') -Action {
      $dialog = [System.Windows.Forms.OpenFileDialog]::new()
      $dialog.Title = Get-DreamSkinTrayText -Key 'ImportTitle'
      $dialog.Filter = 'Dream Skin theme ZIP|*.zip'
      $dialog.Multiselect = $false
      try {
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
          $imported = Import-DreamSkinThemeZip -ArchivePath $dialog.FileName -StateRoot $StateRoot
          if ($imported.Status -ceq 'Duplicate') {
            $message = Get-DreamSkinTrayText -Key 'ThemeExists' -FormatArguments @($imported.Name)
          } elseif ($imported.Replaced) {
            $message = Get-DreamSkinTrayText -Key 'ThemeUpdated' -FormatArguments @($imported.Name)
          } else {
            $message = Get-DreamSkinTrayText -Key 'ThemeImported' -FormatArguments @($imported.Name)
            if ($imported.Renamed) {
              $message += Get-DreamSkinTrayText -Key 'NewIdentifier' -FormatArguments @($imported.Id)
            }
            if ($imported.NameCollision) { $message += Get-DreamSkinTrayText -Key 'NameCollision' }
          }
          if ($imported.SafeCssStatus -ceq 'validated') {
            $message += Get-DreamSkinTrayText -Key 'CssValidated'
          }
          if ($imported.SignatureIgnored) { $message += Get-DreamSkinTrayText -Key 'SignatureIgnored' }
          $cleanupProperty = $imported.PSObject.Properties['CleanupWarning']
          $hasCleanupWarning = $null -ne $cleanupProperty -and
            -not [string]::IsNullOrWhiteSpace("$($cleanupProperty.Value)")
          if ($hasCleanupWarning) {
            $message += Get-DreamSkinTrayText -Key 'CleanupWarning'
          }
          $messageIcon = if ($hasCleanupWarning) {
            [System.Windows.Forms.ToolTipIcon]::Warning
          } else {
            [System.Windows.Forms.ToolTipIcon]::Info
          }
          $notify.ShowBalloonTip(4200, 'Codex Dream Skin', $message, $messageIcon)
        }
      } finally {
        $dialog.Dispose()
      }
    }
    $null = Add-DreamSkinTrayItem -Items $menu.Items -Text (Get-DreamSkinTrayText -Key 'SaveCurrent') -Action {
      $name = [Microsoft.VisualBasic.Interaction]::InputBox(
        (Get-DreamSkinTrayText -Key 'SavePrompt'),
        (Get-DreamSkinTrayText -Key 'SaveTitle'),
        ''
      )
      if ($name.Trim()) {
        $saved = Invoke-DreamSkinTrayThemeOperation -Action {
          Save-DreamSkinCurrentTheme -Name $name -StateRoot $StateRoot
        }
        $notify.ShowBalloonTip(
          1800,
          'Codex Dream Skin',
          (Get-DreamSkinTrayText -Key 'Saved' -FormatArguments @($saved.Theme.name)),
          [System.Windows.Forms.ToolTipIcon]::Info
        )
      }
    }

    $savedMenu = [System.Windows.Forms.ToolStripMenuItem]::new(
      (Get-DreamSkinTrayText -Key 'SavedThemes')
    )
    $savedThemes = @(Get-DreamSkinSavedThemes -StateRoot $StateRoot -SkipImageMetadata)
    if ($savedThemes.Count -eq 0) {
      $empty = [System.Windows.Forms.ToolStripMenuItem]::new(
        (Get-DreamSkinTrayText -Key 'NoSavedThemes')
      )
      $empty.Enabled = $false
      [void]$savedMenu.DropDownItems.Add($empty)
    } else {
      foreach ($saved in $savedThemes) {
        $savedPath = $saved.Path
        $savedName = $saved.Name
        $savedAction = {
          $null = Invoke-DreamSkinTrayThemeOperation -Action {
            $null = Use-DreamSkinSavedTheme -ThemeDirectory $savedPath -StateRoot $StateRoot
            Set-DreamSkinPaused -Paused $false -StateRoot $StateRoot | Out-Null
          }
          $notify.ShowBalloonTip(
            1800,
            'Codex Dream Skin',
            (Get-DreamSkinTrayText -Key 'Applied' -FormatArguments @($savedName)),
            [System.Windows.Forms.ToolTipIcon]::Info
          )
        }.GetNewClosure()
        $null = Add-DreamSkinTrayItem -Items $savedMenu.DropDownItems -Text $savedName -Action $savedAction
      }
    }
    [void]$menu.Items.Add($savedMenu)

    $null = Add-DreamSkinTrayItem -Items $menu.Items -Text (Get-DreamSkinTrayText -Key 'OpenThemes') -Action {
      $themeDirectoryToken = ConvertTo-DreamSkinProcessArgument -Value $paths.Saved
      Start-Process -FilePath explorer.exe -ArgumentList $themeDirectoryToken | Out-Null
    }
    $null = Add-DreamSkinTrayItem -Items $menu.Items -Text (Get-DreamSkinTrayText -Key 'OpenImages') -Action {
      $imageDirectoryToken = ConvertTo-DreamSkinProcessArgument -Value $paths.Images
      Start-Process -FilePath explorer.exe -ArgumentList $imageDirectoryToken | Out-Null
    }
    [void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
    $null = Add-DreamSkinTrayItem -Items $menu.Items -Text (Get-DreamSkinTrayText -Key 'CheckUpdate') -Action {
      Start-DreamSkinPowerShell -Script $checkUpdateScript -Arguments @('-Interactive')
    }
    $null = Add-DreamSkinTrayItem -Items $menu.Items -Text (Get-DreamSkinTrayText -Key 'Gallery') -Action {
      Start-Process -FilePath 'https://dreamskin.cc/gallery' | Out-Null
    }
    $null = Add-DreamSkinTrayItem -Items $menu.Items -Text (Get-DreamSkinTrayText -Key 'Studio') -Action {
      Start-Process -FilePath 'https://dreamskin.cc/studio' | Out-Null
    }
    $null = Add-DreamSkinTrayItem -Items $menu.Items -Text (Get-DreamSkinTrayText -Key 'OpenSite') -Action {
      Start-Process -FilePath 'https://dreamskin.cc' | Out-Null
    }
    $autoStartEnabled = Test-Path -LiteralPath $startupShortcut -PathType Leaf
    $autoStartAction = {
      Set-DreamSkinAutoStart -Enabled:(-not $autoStartEnabled)
    }.GetNewClosure()
    $null = Add-DreamSkinTrayItem -Items $menu.Items -Text (Get-DreamSkinTrayText -Key 'LaunchAtLogin') `
      -Action $autoStartAction -Checked $autoStartEnabled
    Add-DreamSkinTrayLanguageMenu
    [void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
    $null = Add-DreamSkinTrayItem -Items $menu.Items -Text (Get-DreamSkinTrayText -Key 'Restore') -Action {
      Start-DreamSkinPowerShell -Script $restoreScript -Arguments (
        Get-DreamSkinTrayStartArguments -AdditionalArguments @('-RestoreBaseTheme', '-PromptRestart')
      )
      $notify.Visible = $false
      [System.Windows.Forms.Application]::Exit()
    }
    $null = Add-DreamSkinTrayItem -Items $menu.Items -Text (Get-DreamSkinTrayText -Key 'Exit') -Action {
      $notify.Visible = $false
      [System.Windows.Forms.Application]::Exit()
    }
  }

  $null = Update-DreamSkinTrayOfficialProcessBaseline
  $menu.add_Opening({ Rebuild-DreamSkinTrayMenu })
  $notify.add_DoubleClick({
    try {
      Start-DreamSkinPowerShell -Script $startScript -Arguments (Get-DreamSkinTrayStartArguments -AdditionalArguments @('-PromptRestart'))
    } catch {
      Show-DreamSkinTrayError -Message $_.Exception.Message
    }
  })
  $recoveryTimer = [System.Windows.Forms.Timer]::new()
  $recoveryTimer.Interval = 5000
  $recoveryTimer.add_Tick({
    try {
      Invoke-DreamSkinTrayRecovery
    } catch {
      $recoveryMonitor.NextAttemptAt = (Get-Date).AddSeconds(30)
    }
    try {
      Invoke-DreamSkinTrayOfficialLaunchMonitor
    } catch {
      $officialLaunchMonitor.NextAttemptAt = (Get-Date).AddSeconds(30)
    }
  })
  $recoveryTimer.Start()
  [System.Windows.Forms.Application]::Run()
} finally {
  if ($null -ne $recoveryTimer) {
    $recoveryTimer.Stop()
    $recoveryTimer.Dispose()
  }
  if ($null -ne $recoveryMonitor.Process) {
    try { $recoveryMonitor.Process.Dispose() } catch {}
  }
  if ($null -ne $officialLaunchMonitor.Process) {
    try { $officialLaunchMonitor.Process.Dispose() } catch {}
  }
  if ($null -ne $notify) { $notify.Dispose() }
  if ($null -ne $trayIcon) { $trayIcon.Dispose() }
  if ($acquired) { try { $mutex.ReleaseMutex() } catch {} }
  $mutex.Dispose()
}
