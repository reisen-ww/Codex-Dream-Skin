. (Join-Path $PSScriptRoot 'config-utf8.ps1')

$script:DreamSkinStartResultCategories = @(
  'none',
  'cdp-unsupported',
  'cdp-launch-failed',
  'cdp-direct-access-denied',
  'cdp-endpoint-unavailable',
  'port-unavailable',
  'state-reconciliation-failed',
  'injector-start-failed',
  'renderer-verification-failed',
  'superseded',
  'internal-start-failure'
)
$script:DreamSkinStartAppearanceRecoveryStates = @(
  'not-needed',
  'retained',
  'restored',
  'conflict-preserved',
  'blocked',
  'preserved-rendered'
)

function New-DreamSkinStartException {
  param(
    [Parameter(Mandatory = $true)][string]$Category,
    [Parameter(Mandatory = $true)][string]$Message,
    [AllowNull()][System.Exception]$InnerException
  )
  if ($script:DreamSkinStartResultCategories -cnotcontains $Category -or $Category -ceq 'none') {
    throw 'Invalid Dream Skin start failure category.'
  }
  $exception = if ($null -ne $InnerException) {
    [System.InvalidOperationException]::new($Message, $InnerException)
  } else {
    [System.InvalidOperationException]::new($Message)
  }
  $exception.Data['DreamSkinStartCategory'] = $Category
  return $exception
}

function Get-DreamSkinStartFailureCategory {
  param(
    [Parameter(Mandatory = $true)][System.Exception]$Exception,
    [ValidateSet(
      'cdp-unsupported', 'cdp-launch-failed', 'cdp-direct-access-denied', 'cdp-endpoint-unavailable',
      'port-unavailable', 'state-reconciliation-failed', 'injector-start-failed',
      'renderer-verification-failed', 'superseded', 'internal-start-failure'
    )]
    [string]$FallbackCategory = 'internal-start-failure'
  )
  $current = $Exception
  while ($null -ne $current) {
    $category = "$($current.Data['DreamSkinStartCategory'])"
    if ($script:DreamSkinStartResultCategories -ccontains $category -and $category -cne 'none') {
      return $category
    }
    $current = $current.InnerException
  }
  return $FallbackCategory
}

function Get-DreamSkinStartResultPath {
  param(
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [Parameter(Mandatory = $true)][string]$Token
  )
  if ($Token -cnotmatch '\A[a-f0-9]{32}\z') {
    throw 'Dream Skin start result token is invalid.'
  }
  $root = [System.IO.Path]::GetFullPath($StateRoot)
  return Join-Path $root ('.start-result-' + $Token + '.json')
}

function Write-DreamSkinStartResult {
  param(
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [Parameter(Mandatory = $true)][string]$Token,
    [Parameter(Mandatory = $true)][ValidateSet('success', 'failure')][string]$Outcome,
    [Parameter(Mandatory = $true)][string]$Category,
    [Parameter(Mandatory = $true)][string]$AppearanceRecovery
  )
  if ($script:DreamSkinStartResultCategories -cnotcontains $Category -or
    $script:DreamSkinStartAppearanceRecoveryStates -cnotcontains $AppearanceRecovery -or
    ($Outcome -ceq 'success' -and $Category -cne 'none') -or
    ($Outcome -ceq 'failure' -and $Category -ceq 'none')) {
    throw 'Dream Skin start result fields are invalid.'
  }
  $path = Get-DreamSkinStartResultPath -StateRoot $StateRoot -Token $Token
  [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetFullPath($StateRoot)) | Out-Null
  if (Get-Command Assert-DreamSkinNoReparseComponents -ErrorAction SilentlyContinue) {
    Assert-DreamSkinNoReparseComponents -Path $path
  }
  $result = [ordered]@{
    schemaVersion = 1
    token = $Token
    outcome = $Outcome
    category = $Category
    appearanceRecovery = $AppearanceRecovery
  }
  $content = (($result | ConvertTo-Json -Compress) + "`r`n")
  if ($script:DreamSkinUtf8NoBom.GetByteCount($content) -gt 4096) {
    throw 'Dream Skin start result exceeded its fixed size limit.'
  }
  Write-DreamSkinUtf8FileAtomically -Path $path -Content $content -ExpectedBytes $null
}

function Read-DreamSkinStartResult {
  param(
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [Parameter(Mandatory = $true)][string]$Token
  )
  $path = Get-DreamSkinStartResultPath -StateRoot $StateRoot -Token $Token
  if (Get-Command Assert-DreamSkinNoReparseComponents -ErrorAction SilentlyContinue) {
    Assert-DreamSkinNoReparseComponents -Path $path
  }
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw 'Dream Skin start did not return a structured result.'
  }
  $stream = $null
  try {
    # Hold one non-writable, non-deletable handle from the size check through
    # the read. This prevents a path swap or growth between two file opens.
    $stream = [System.IO.FileStream]::new(
      $path,
      [System.IO.FileMode]::Open,
      [System.IO.FileAccess]::Read,
      [System.IO.FileShare]::Read
    )
    if ($stream.Length -le 0 -or $stream.Length -gt 4096) {
      throw 'Dream Skin start returned an invalid structured result size.'
    }
    $bytes = [byte[]]::new([int]$stream.Length)
    $offset = 0
    while ($offset -lt $bytes.Length) {
      $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
      if ($read -le 0) {
        throw 'Dream Skin start returned a truncated structured result.'
      }
      $offset += $read
    }
  } finally {
    if ($null -ne $stream) { $stream.Dispose() }
  }
  $json = ConvertFrom-DreamSkinUtf8Bytes -Bytes $bytes -Path $path
  try { $result = $json | ConvertFrom-Json -ErrorAction Stop } catch {
    throw 'Dream Skin start returned invalid structured result JSON.'
  }
  if ($null -eq $result -or $result -is [string] -or $result -is [array]) {
    throw 'Dream Skin start returned an invalid structured result object.'
  }
  $allowed = @('schemaVersion', 'token', 'outcome', 'category', 'appearanceRecovery')
  $properties = @($result.PSObject.Properties)
  if ($properties.Count -ne $allowed.Count) {
    throw 'Dream Skin start returned an unexpected structured result shape.'
  }
  foreach ($property in $properties) {
    if ($allowed -cnotcontains $property.Name) {
      throw 'Dream Skin start returned an unexpected structured result field.'
    }
  }
  if (($result.schemaVersion -isnot [int] -and $result.schemaVersion -isnot [long]) -or
    [int64]$result.schemaVersion -ne 1 -or
    $result.token -isnot [string] -or "$($result.token)" -cne $Token -or
    $result.outcome -isnot [string] -or
    @('success', 'failure') -cnotcontains "$($result.outcome)" -or
    $result.category -isnot [string] -or
    $script:DreamSkinStartResultCategories -cnotcontains "$($result.category)" -or
    $result.appearanceRecovery -isnot [string] -or
    $script:DreamSkinStartAppearanceRecoveryStates -cnotcontains "$($result.appearanceRecovery)" -or
    ("$($result.outcome)" -ceq 'success' -and "$($result.category)" -cne 'none') -or
    ("$($result.outcome)" -ceq 'failure' -and "$($result.category)" -ceq 'none')) {
    throw 'Dream Skin start returned invalid structured result values.'
  }
  return $result
}

function Enter-DreamSkinOperationLock {
  param(
    [ValidateRange(0, 300000)]
    [int]$TimeoutMilliseconds = 0
  )
  $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $mutex = [System.Threading.Mutex]::new($false, "Local\CodexDreamSkin.$sid.Operation")
  $acquired = $false
  try {
    $acquired = $mutex.WaitOne($TimeoutMilliseconds)
  } catch [System.Threading.AbandonedMutexException] {
    $acquired = $true
  }
  if (-not $acquired) {
    $mutex.Dispose()
    if ($TimeoutMilliseconds -eq 0) {
      throw 'Another Codex Dream Skin install, start, restore, or verify operation is already running.'
    }
    throw "Another Codex Dream Skin operation did not finish within $TimeoutMilliseconds ms."
  }
  return $mutex
}

function Exit-DreamSkinOperationLock {
  param([Parameter(Mandatory = $true)][System.Threading.Mutex]$Mutex)
  try { $Mutex.ReleaseMutex() } finally { $Mutex.Dispose() }
}

function Test-DreamSkinOperationLockAvailable {
  $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $mutex = [System.Threading.Mutex]::new($false, "Local\CodexDreamSkin.$sid.Operation")
  $acquired = $false
  try {
    try {
      $acquired = $mutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
      $acquired = $true
    }
    return [bool]$acquired
  } finally {
    if ($acquired) { try { $mutex.ReleaseMutex() } catch {} }
    $mutex.Dispose()
  }
}

function Assert-DreamSkinPort {
  param([Parameter(Mandatory = $true)][int]$Port)
  if ($Port -lt 1024 -or $Port -gt 65535) { throw "Port must be between 1024 and 65535: $Port" }
}

function Test-DreamSkinWindows11 {
  try {
    $version = [Environment]::OSVersion.Version
    return $version.Major -eq 10 -and $version.Build -ge 22000
  } catch {
    return $false
  }
}

function Assert-DreamSkinWindows11 {
  if (-not (Test-DreamSkinWindows11)) {
    throw 'Codex Dream Skin v1.5.20 requires Windows 11 (build 22000 or newer). No files or Codex settings were changed.'
  }
}

function Get-DreamSkinDisabledPath {
  param([Parameter(Mandatory = $true)][string]$StateRoot)
  return Join-Path ([System.IO.Path]::GetFullPath($StateRoot)) 'dream-skin.disabled'
}

function Test-DreamSkinDisabled {
  param([Parameter(Mandatory = $true)][string]$StateRoot)
  $path = Get-DreamSkinDisabledPath -StateRoot $StateRoot
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
  try {
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0)
  } catch {
    return $true
  }
}

function Set-DreamSkinDisabled {
  param(
    [Parameter(Mandatory = $true)][bool]$Disabled,
    [Parameter(Mandatory = $true)][string]$StateRoot
  )
  $root = [System.IO.Path]::GetFullPath($StateRoot)
  if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    [void][System.IO.Directory]::CreateDirectory($root)
  }
  if (Get-Command Assert-DreamSkinNoReparseComponents -CommandType Function -ErrorAction SilentlyContinue) {
    Assert-DreamSkinNoReparseComponents -Path $root
  }
  $path = Get-DreamSkinDisabledPath -StateRoot $root
  if ($Disabled) {
    Write-DreamSkinUtf8FileAtomically -Path $path -Content ('restored-base-theme' + [Environment]::NewLine)
  } else {
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
  }
}

function Get-DreamSkinAutoStartDisabledPath {
  param([Parameter(Mandatory = $true)][string]$StateRoot)
  return Join-Path ([System.IO.Path]::GetFullPath($StateRoot)) 'autostart.disabled'
}

function Test-DreamSkinAutoStartDisabled {
  param([Parameter(Mandatory = $true)][string]$StateRoot)
  $path = Get-DreamSkinAutoStartDisabledPath -StateRoot $StateRoot
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
  try {
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0)
  } catch {
    return $true
  }
}

function Set-DreamSkinAutoStartDisabled {
  param(
    [Parameter(Mandatory = $true)][bool]$Disabled,
    [Parameter(Mandatory = $true)][string]$StateRoot
  )
  $root = [System.IO.Path]::GetFullPath($StateRoot)
  if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    [void][System.IO.Directory]::CreateDirectory($root)
  }
  if (Get-Command Assert-DreamSkinNoReparseComponents -CommandType Function -ErrorAction SilentlyContinue) {
    Assert-DreamSkinNoReparseComponents -Path $root
  }
  $path = Get-DreamSkinAutoStartDisabledPath -StateRoot $root
  if ($Disabled) {
    Write-DreamSkinUtf8FileAtomically -Path $path -Content ('disabled' + [Environment]::NewLine)
  } else {
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
  }
}

function Test-DreamSkinPathEqual {
  param([string]$Left, [string]$Right)
  if (-not $Left -or -not $Right) { return $false }
  try {
    return ([System.IO.Path]::GetFullPath($Left).TrimEnd('\') -ieq [System.IO.Path]::GetFullPath($Right).TrimEnd('\'))
  } catch {
    return $false
  }
}

function Test-DreamSkinPathWithin {
  param([string]$Path, [string]$Root)
  if (-not $Path -or -not $Root) { return $false }
  try {
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $prefix = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    return $fullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
  } catch {
    return $false
  }
}

function Get-DreamSkinRuntimeEnginePaths {
  param([string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'))
  $root = Join-Path ([System.IO.Path]::GetFullPath($StateRoot)) 'engine'
  $scripts = Join-Path $root 'scripts'
  return [pscustomobject]@{
    Root = $root
    Scripts = $scripts
    Runtime = Join-Path $root 'runtime'
    Version = Join-Path $root 'VERSION'
    CommunityApply = Join-Path $scripts 'apply-community-theme.ps1'
    Start = Join-Path $scripts 'start-dream-skin.ps1'
    Restore = Join-Path $scripts 'restore-dream-skin.ps1'
    Tray = Join-Path $scripts 'tray-dream-skin.ps1'
    CheckUpdate = Join-Path $scripts 'check-update.ps1'
  }
}

function Test-DreamSkinTrayActive {
  $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $mutex = [System.Threading.Mutex]::new($false, "Local\CodexDreamSkin.$sid.Tray")
  $acquired = $false
  try {
    try { $acquired = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] {
      $acquired = $true
    }
    if ($acquired) {
      $mutex.ReleaseMutex()
      $acquired = $false
      return $false
    }
    return $true
  } finally {
    if ($acquired) { try { $mutex.ReleaseMutex() } catch {} }
    $mutex.Dispose()
  }
}

function Stop-DreamSkinTrayProcess {
  param(
    [string[]]$ScriptPaths = @(),
    [switch]$RequireStopped
  )
  if ($ScriptPaths.Count -eq 0) {
    $ScriptPaths = @((Get-DreamSkinRuntimeEnginePaths).Tray)
  }
  $normalized = @($ScriptPaths | ForEach-Object {
    try { [System.IO.Path]::GetFullPath($_) } catch { $null }
  } | Where-Object { $_ })
  $failures = @()
  try {
    $processes = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" `
      -ErrorAction Stop
    foreach ($process in $processes) {
      if ($process.ProcessId -eq $PID -or -not $process.CommandLine) { continue }
      $matchesTray = $false
      foreach ($scriptPath in $normalized) {
        if (Test-DreamSkinPowerShellFileCommandLine -CommandLine "$($process.CommandLine)" -ScriptPath $scriptPath) {
          $matchesTray = $true
          break
        }
      }
      if (-not $matchesTray) { continue }
      try {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
        Wait-Process -Id $process.ProcessId -Timeout 5 -ErrorAction SilentlyContinue
      } catch {
        $failures += "PID $($process.ProcessId): $($_.Exception.Message)"
      }
    }
  } catch {
    $failures += $_.Exception.Message
  }
  if ($failures.Count -gt 0) {
    $message = 'Could not close the Dream Skin tray automatically: ' + ($failures -join '; ')
    if ($RequireStopped) { throw $message }
    Write-Warning $message
  }
  if ($RequireStopped -and (Test-DreamSkinTrayActive)) {
    throw 'The Dream Skin tray is still active. Exit it and retry the operation.'
  }
}

function Assert-DreamSkinRuntimeTree {
  param([Parameter(Mandatory = $true)][string]$Path)
  $root = [System.IO.Path]::GetFullPath($Path)
  if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    throw "Dream Skin runtime directory does not exist: $root"
  }
  if (-not (Get-Command Assert-DreamSkinNoReparseComponents -ErrorAction SilentlyContinue)) {
    throw 'Dream Skin managed-path validation is unavailable.'
  }
  Assert-DreamSkinNoReparseComponents -Path $root
  foreach ($item in Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction Stop) {
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Dream Skin runtime contains a junction or symbolic link: $($item.FullName)"
    }
  }
}

function Remove-DreamSkinRuntimeTree {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$StateRoot
  )
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $fullStateRoot = [System.IO.Path]::GetFullPath($StateRoot)
  if (-not (Test-DreamSkinPathWithin -Path $fullPath -Root $fullStateRoot)) {
    throw "Refusing to remove a runtime path outside the Dream Skin state root: $fullPath"
  }
  if (-not (Test-Path -LiteralPath $fullPath)) { return }
  Assert-DreamSkinRuntimeTree -Path $fullPath
  Remove-Item -LiteralPath $fullPath -Recurse -Force -ErrorAction Stop
}

function Install-DreamSkinRuntimeEngine {
  param(
    [Parameter(Mandatory = $true)][string]$SkillRoot,
    [Parameter(Mandatory = $true)][string]$StateRoot
  )
  if (-not (Get-Command Ensure-DreamSkinManagedDirectory -ErrorAction SilentlyContinue)) {
    throw 'Dream Skin managed-directory validation is unavailable.'
  }

  $sourceRoot = [System.IO.Path]::GetFullPath($SkillRoot)
  $fullStateRoot = [System.IO.Path]::GetFullPath($StateRoot)
  $engine = Get-DreamSkinRuntimeEnginePaths -StateRoot $fullStateRoot
  $required = @(
    'VERSION',
    'assets\dream-reference.jpg',
    'assets\dream-skin.css',
    'assets\renderer-inject.js',
    'assets\safe-css-policy.json',
    'assets\safe-css-validator.mjs',
    'assets\selectors.json',
    'assets\theme-package-validator.mjs',
    'assets\theme.json',
    'presets\preset-gothic-void-crusade\background.jpg',
    'presets\preset-gothic-void-crusade\theme.json',
    'scripts\apply-community-theme.ps1',
    'scripts\common-windows.ps1',
    'scripts\check-update.ps1',
    'scripts\config-utf8.ps1',
    'scripts\image-metadata.mjs',
    'scripts\injector.mjs',
    'scripts\install-dream-skin.ps1',
    'scripts\localization-windows.ps1',
    'scripts\restore-dream-skin.ps1',
    'scripts\start-dream-skin.ps1',
    'scripts\theme-windows.ps1',
    'scripts\tray-dream-skin.ps1',
    'scripts\validate-safe-css-file.mjs',
    'scripts\verify-dream-skin.ps1'
  )
  $sourceHasBundledRuntime = Test-Path -LiteralPath (Join-Path $sourceRoot 'runtime') `
    -PathType Container
  if ($sourceHasBundledRuntime) {
    $required += @('runtime\node\node.exe', 'runtime\node\LICENSE')
  }
  foreach ($relative in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot $relative) -PathType Leaf)) {
      throw "Dream Skin runtime source is incomplete: $relative"
    }
  }
  $sourceDirectories = @('assets', 'scripts', 'presets')
  if ($sourceHasBundledRuntime) {
    $sourceDirectories += 'runtime'
  }
  foreach ($directoryName in $sourceDirectories) {
    $sourceDirectory = Join-Path $sourceRoot $directoryName
    if ((Test-DreamSkinPathEqual -Left $fullStateRoot -Right $sourceDirectory) -or
      (Test-DreamSkinPathWithin -Path $fullStateRoot -Root $sourceDirectory)) {
      throw "Dream Skin state root cannot be created inside its runtime source: $fullStateRoot"
    }
    Assert-DreamSkinRuntimeTree -Path $sourceDirectory
  }

  Ensure-DreamSkinManagedDirectory -Path $fullStateRoot -Root $fullStateRoot
  $token = [guid]::NewGuid().ToString('N')
  $stagingRoot = Join-Path $fullStateRoot ".engine-staging-$token"
  $backupRoot = Join-Path $fullStateRoot ".engine-backup-$token"
  Ensure-DreamSkinManagedDirectory -Path $stagingRoot -Root $fullStateRoot

  try {
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'VERSION') -Destination $stagingRoot `
      -Force -ErrorAction Stop
    foreach ($directoryName in $sourceDirectories) {
      Copy-Item -LiteralPath (Join-Path $sourceRoot $directoryName) -Destination $stagingRoot `
        -Recurse -Force -ErrorAction Stop
    }
    Assert-DreamSkinRuntimeTree -Path $stagingRoot
    foreach ($relative in $required) {
      if (-not (Test-Path -LiteralPath (Join-Path $stagingRoot $relative) -PathType Leaf)) {
        throw "Staged Dream Skin runtime is incomplete: $relative"
      }
    }

    $sourcePrefix = $sourceRoot.TrimEnd('\') + '\'
    $sourceFileRoots = @($sourceDirectories | ForEach-Object { Join-Path $sourceRoot $_ })
    $stagedFileRoots = @($sourceDirectories | ForEach-Object { Join-Path $stagingRoot $_ })
    $sourceFiles = @((Get-Item -LiteralPath (Join-Path $sourceRoot 'VERSION'))) + @(
      Get-ChildItem -LiteralPath $sourceFileRoots -Recurse -File -Force -ErrorAction Stop
    )
    $stagedFiles = @((Get-Item -LiteralPath (Join-Path $stagingRoot 'VERSION'))) + @(
      Get-ChildItem -LiteralPath $stagedFileRoots -Recurse -File -Force -ErrorAction Stop
    )
    if ($sourceFiles.Count -ne $stagedFiles.Count) {
      throw 'Staged Dream Skin runtime file count does not match its source.'
    }
    foreach ($sourceFile in $sourceFiles) {
      $relative = $sourceFile.FullName.Substring($sourcePrefix.Length)
      $stagedFile = Join-Path $stagingRoot $relative
      if (-not (Test-Path -LiteralPath $stagedFile -PathType Leaf) -or
        (Get-FileHash -Algorithm SHA256 -LiteralPath $sourceFile.FullName).Hash -cne
        (Get-FileHash -Algorithm SHA256 -LiteralPath $stagedFile).Hash) {
        throw "Staged Dream Skin runtime failed hash verification: $relative"
      }
    }

    # Unblock only verified managed copies so shortcuts can honor RemoteSigned instead of bypassing policy.
    foreach ($runtimeScript in Get-ChildItem -LiteralPath (Join-Path $stagingRoot 'scripts') `
      -Filter '*.ps1' -Recurse -File -Force -ErrorAction Stop) {
      Unblock-File -LiteralPath $runtimeScript.FullName -ErrorAction Stop
    }
    if (Test-Path -LiteralPath (Join-Path $stagingRoot 'runtime') -PathType Container) {
      foreach ($runtimeFile in Get-ChildItem -LiteralPath (Join-Path $stagingRoot 'runtime') `
        -Recurse -File -Force -ErrorAction Stop) {
        Unblock-File -LiteralPath $runtimeFile.FullName -ErrorAction Stop
      }
    }

    $hasBackup = $false
    if (Test-Path -LiteralPath $engine.Root) {
      Assert-DreamSkinRuntimeTree -Path $engine.Root
      Move-Item -LiteralPath $engine.Root -Destination $backupRoot -ErrorAction Stop
      $hasBackup = $true
    }
    try {
      Move-Item -LiteralPath $stagingRoot -Destination $engine.Root -ErrorAction Stop
    } catch {
      $installError = $_.Exception.Message
      if ($hasBackup -and -not (Test-Path -LiteralPath $engine.Root)) {
        try {
          Move-Item -LiteralPath $backupRoot -Destination $engine.Root -ErrorAction Stop
          $hasBackup = $false
        } catch {
          throw "Dream Skin runtime update failed and its previous engine could not be restored. Backup preserved at ${backupRoot}: $installError"
        }
      }
      throw
    }
    if ($hasBackup) {
      try { Remove-DreamSkinRuntimeTree -Path $backupRoot -StateRoot $fullStateRoot } catch {
        try {
          Write-Warning "Installed the new runtime but could not remove its previous backup: $($_.Exception.Message)"
        } catch {
          # Cleanup must never make a committed runtime update look unsuccessful.
        }
      }
    }
    return Get-DreamSkinRuntimeEnginePaths -StateRoot $fullStateRoot
  } finally {
    if (Test-Path -LiteralPath $stagingRoot) {
      try { Remove-DreamSkinRuntimeTree -Path $stagingRoot -StateRoot $fullStateRoot } catch {
        try {
          Write-Warning "Could not remove the staged Dream Skin runtime: $($_.Exception.Message)"
        } catch {
          # Cleanup must never mask the runtime installation result.
        }
      }
    }
  }
}

function ConvertFrom-DreamSkinStrictCommandLine {
  param([string]$CommandLine)
  if (-not $CommandLine) { return $null }

  $tokens = [System.Collections.Generic.List[string]]::new()
  $index = 0
  while ($index -lt $CommandLine.Length) {
    while ($index -lt $CommandLine.Length -and [char]::IsWhiteSpace($CommandLine[$index])) {
      $index++
    }
    if ($index -ge $CommandLine.Length) { break }

    $quoted = $CommandLine[$index] -eq '"'
    if ($quoted) { $index++ }
    $builder = [System.Text.StringBuilder]::new()
    $closed = -not $quoted
    while ($index -lt $CommandLine.Length) {
      $character = $CommandLine[$index]
      if ($quoted -and $character -eq '"') {
        $closed = $true
        $index++
        break
      }
      if (-not $quoted -and [char]::IsWhiteSpace($character)) { break }
      if (-not $quoted -and $character -eq '"') { return $null }
      [void]$builder.Append($character)
      $index++
    }
    if (-not $closed) { return $null }
    if ($index -lt $CommandLine.Length -and -not [char]::IsWhiteSpace($CommandLine[$index])) {
      return $null
    }
    $tokens.Add($builder.ToString())
  }
  return $tokens.ToArray()
}

function Test-DreamSkinCommandLineToken {
  param([string]$CommandLine, [string]$Token)
  if (-not $CommandLine -or -not $Token) { return $false }
  $pattern = '(?i)(?:^|[\s"])' + [regex]::Escape($Token) + '(?=$|[\s"])'
  return [regex]::IsMatch($CommandLine, $pattern)
}

function Test-DreamSkinNamedArgument {
  param([string[]]$Arguments, [string]$Name, [string]$Value)
  if (-not $Arguments -or -not $Name -or $null -eq $Value) { return $false }
  $matches = 0
  for ($index = 0; $index -lt $Arguments.Count; $index++) {
    if ($Arguments[$index] -ieq $Name) {
      if ($index + 1 -ge $Arguments.Count -or $Arguments[$index + 1] -cne $Value) { return $false }
      $matches++
      $index++
      continue
    }
    $prefix = "$Name="
    if ($Arguments[$index].StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      if ($Arguments[$index].Substring($prefix.Length) -cne $Value) { return $false }
      $matches++
    }
  }
  return $matches -eq 1
}

function Test-DreamSkinInjectorCommandLine {
  param([string]$CommandLine, [string]$InjectorPath, [int]$Port, [string]$BrowserId)
  $arguments = @(ConvertFrom-DreamSkinStrictCommandLine -CommandLine $CommandLine)
  if ($arguments.Count -lt 3 -or
      -not (Test-DreamSkinPathEqual -Left $arguments[1] -Right $InjectorPath) -or
      $arguments[2] -cne '--watch') {
    return $false
  }
  return (Test-DreamSkinNamedArgument -Arguments $arguments -Name '--port' -Value "$Port") -and
    (Test-DreamSkinNamedArgument -Arguments $arguments -Name '--browser-id' -Value $BrowserId)
}

function Test-DreamSkinPowerShellFileCommandLine {
  param([string]$CommandLine, [string]$ScriptPath)
  $arguments = @(ConvertFrom-DreamSkinStrictCommandLine -CommandLine $CommandLine)
  if ($arguments.Count -lt 3) { return $false }
  $hostName = [System.IO.Path]::GetFileName($arguments[0])
  if ($hostName -ine 'powershell.exe' -and $hostName -ine 'pwsh.exe') { return $false }

  for ($index = 1; $index -lt $arguments.Count; $index++) {
    $argument = $arguments[$index]
    if ($argument -ieq '-File') {
      return $index + 1 -lt $arguments.Count -and
        (Test-DreamSkinPathEqual -Left $arguments[$index + 1] -Right $ScriptPath)
    }
    if ($argument -iin @('-NoProfile', '-NoLogo', '-NonInteractive', '-STA', '-MTA')) {
      continue
    }
    if ($argument -ieq '-WindowStyle') {
      if ($index + 1 -ge $arguments.Count -or
          $arguments[$index + 1] -inotmatch '^(Normal|Minimized|Maximized|Hidden)$') {
        return $false
      }
      $index++
      continue
    }
    if ($argument -ieq '-ExecutionPolicy') {
      if ($index + 1 -ge $arguments.Count -or
          $arguments[$index + 1] -inotmatch '^(AllSigned|Bypass|Default|RemoteSigned|Restricted|Undefined|Unrestricted)$') {
        return $false
      }
      $index++
      continue
    }
    return $false
  }
  return $false
}

function Get-DreamSkinCodexDebugArgumentStatus {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Processes,
    [Parameter(Mandatory = $true)][int]$Port
  )
  Assert-DreamSkinPort -Port $Port
  $flag = "--remote-debugging-port=$Port"
  $encodedFlag = [Uri]::EscapeDataString($flag)
  $sawReadableCommandLine = $false
  $sawProtocolRedirect = $false
  foreach ($process in $Processes) {
    $commandLine = "$($process.CommandLine)"
    if (-not $commandLine) { continue }
    $sawReadableCommandLine = $true
    $protocolPattern = '(?i)(?<!\S)"?(?<url>codex://[^\s"]*)"?'
    $protocolMatches = [regex]::Matches($commandLine, $protocolPattern)
    foreach ($protocolMatch in $protocolMatches) {
      $protocolArgument = $protocolMatch.Groups['url'].Value
      if ($protocolArgument.IndexOf($encodedFlag, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        $protocolArgument.IndexOf($flag, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        $sawProtocolRedirect = $true
      }
    }
    $rawArguments = [regex]::Replace($commandLine, $protocolPattern, ' ')
    if (Test-DreamSkinCommandLineToken -CommandLine $rawArguments -Token $flag) {
      return 'forwarded'
    }
  }
  if ($sawProtocolRedirect) { return 'protocol-redirected' }
  if ($sawReadableCommandLine) { return 'not-forwarded' }
  return 'uninspectable'
}

function ConvertTo-DreamSkinProcessArgument {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
  if ($Value.Contains('"')) { throw 'Process arguments containing a double quote are not supported.' }
  if ($Value.Length -eq 0) { return '""' }
  if ($Value -notmatch '\s') { return $Value }
  $escaped = [regex]::Replace($Value, '(\\+)$', '$1$1')
  return '"' + $escaped + '"'
}

function ConvertTo-DreamSkinArgumentLine {
  param([AllowEmptyCollection()][string[]]$Arguments = @())
  return (($Arguments | ForEach-Object { ConvertTo-DreamSkinProcessArgument -Value $_ }) -join ' ')
}

function Get-DreamSkinProcessExecutablePath {
  param([Parameter(Mandatory = $true)][object]$ProcessInfo)
  if ($ProcessInfo.ExecutablePath) { return "$($ProcessInfo.ExecutablePath)" }
  try {
    $process = Get-Process -Id ([int]$ProcessInfo.ProcessId) -ErrorAction Stop
    if ($process.Path) { return "$($process.Path)" }
    return "$($process.MainModule.FileName)"
  } catch {
    return $null
  }
}

# Windows PowerShell 5.1 promotes redirected native-command stderr lines to
# ErrorRecords; while $ErrorActionPreference is 'Stop' the first stderr line
# becomes a terminating NativeCommandError before the exit code can be read.
# Run the command with the preference relaxed and report output + exit code.
function Invoke-DreamSkinNative {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [string[]]$ArgumentList = @(),
    [switch]$DiscardStderr
  )
  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    if ($DiscardStderr) {
      $nativeOutput = @(& $FilePath @ArgumentList 2>$null)
    } else {
      $nativeOutput = @(& $FilePath @ArgumentList 2>&1)
    }
    $exitCode = $LASTEXITCODE
    $output = @($nativeOutput | ForEach-Object { "$_" })
    return [pscustomobject]@{ Output = $output; ExitCode = $exitCode }
  } finally {
    $ErrorActionPreference = $previousPreference
  }
}

function ConvertFrom-DreamSkinUtf8Base64 {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
  )
  try {
    $bytes = [Convert]::FromBase64String($Value.Trim())
    return ([System.Text.UTF8Encoding]::new($false, $true)).GetString($bytes)
  } catch {
    throw 'The native UTF-8 probe returned invalid data.'
  }
}

function Import-DreamSkinPowerShellSecurityModule {
  $command = Get-Command Get-AuthenticodeSignature -CommandType Cmdlet -ErrorAction SilentlyContinue
  if ($command) { return }
  try {
    Import-Module Microsoft.PowerShell.Security -ErrorAction Stop
  } catch {
    $modulePath = Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1'
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
      throw "PowerShell security module is unavailable: $($_.Exception.Message)"
    }
    Import-Module $modulePath -ErrorAction Stop
  }
  $command = Get-Command Get-AuthenticodeSignature -CommandType Cmdlet -ErrorAction SilentlyContinue
  if (-not $command) {
    throw 'PowerShell security module loaded, but Get-AuthenticodeSignature is unavailable.'
  }
}

function Assert-DreamSkinTrustedNodeImage {
  param([Parameter(Mandatory = $true)][string]$Path)

  # Runs BEFORE the binary is ever executed. Get-DreamSkinValidatedNodeRuntime
  # learns the version by running `node -p`, so any authenticity check placed
  # after that point would already have executed attacker-controlled code.
  Import-DreamSkinPowerShellSecurityModule
  $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
  if ("$($signature.Status)" -ine 'Valid') {
    throw "The Node.js runtime is not validly signed: $Path ($($signature.Status))."
  }
  $subject = "$($signature.SignerCertificate.Subject)"
  # Publisher names observed on official Node.js builds. The subject is echoed
  # in the failure so an unexpected-but-legitimate publisher can be identified
  # and added deliberately, rather than the check being loosened blindly.
  if ($subject -notmatch '(?i)O=("?)(OpenJS Foundation|Node\.js Foundation|Microsoft Corporation|GitHub, Inc\.)') {
    throw "The Node.js runtime is signed by an unexpected publisher: $subject"
  }
}

function Get-DreamSkinValidatedNodeRuntime {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [int]$MinimumMajor = 22
  )
  $candidate = [System.IO.Path]::GetFullPath($Path)
  if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
    throw "Node.js runtime does not exist: $candidate"
  }
  Assert-DreamSkinTrustedNodeImage -Path $candidate
  $versionProbe = Invoke-DreamSkinNative -FilePath $candidate -ArgumentList @('-p', 'process.versions.node') -DiscardStderr
  $version = ($versionProbe.Output -join '').Trim()
  if ($versionProbe.ExitCode -ne 0 -or -not $version) { throw 'The Node.js runtime could not be validated.' }
  # Windows PowerShell 5.1 decodes redirected native stdout through the active
  # console code page. Node writes UTF-8, so a non-ASCII temporary path can be
  # corrupted before Test-Path sees it. Keep the transport ASCII-only and
  # decode the original UTF-8 bytes explicitly; never fall back to the
  # candidate when the identity probe is invalid.
  $pathProbe = Invoke-DreamSkinNative -FilePath $candidate -ArgumentList @(
    '-e', "process.stdout.write(Buffer.from(process.execPath, 'utf8').toString('base64'))"
  ) -DiscardStderr
  $encodedRuntimePath = ($pathProbe.Output -join '').Trim()
  $runtimePath = ''
  if ($pathProbe.ExitCode -eq 0 -and $encodedRuntimePath) {
    try {
      $runtimePath = ConvertFrom-DreamSkinUtf8Base64 -Value $encodedRuntimePath
    } catch {
      $runtimePath = ''
    }
  }
  $runtimePathExists = $false
  if ($runtimePath) {
    try { $runtimePathExists = Test-Path -LiteralPath $runtimePath -PathType Leaf } catch {}
  }
  if ($pathProbe.ExitCode -ne 0 -or -not $runtimePath -or -not $runtimePathExists) {
    $reason = 'path-not-found'
    if ($pathProbe.ExitCode -ne 0) { $reason = 'probe-exit' }
    elseif (-not $encodedRuntimePath) { $reason = 'empty-output' }
    elseif (-not $runtimePath) { $reason = 'invalid-output' }
    throw "The Node.js executable path could not be validated ($reason)."
  }
  $major = 0
  if (-not [int]::TryParse(($version -split '\.')[0], [ref]$major) -or $major -lt $MinimumMajor) {
    throw "Node.js $MinimumMajor or newer is required; found $version at $runtimePath."
  }
  return [pscustomobject]@{ Path = $runtimePath; Version = $version; Major = $major }
}

function Get-DreamSkinNodeRuntime {
  param([int]$MinimumMajor = 22)

  # The runtime that runs Safe CSS validation, theme-package validation, image
  # metadata limits and the injector must not be redirectable: anyone able to
  # write HKCU\Environment (no admin needed) could otherwise point every
  # validator at their own node.exe and bypass all of them at once. So there is
  # no environment-variable override -- macOS pins the same way, see
  # require_signed_node_runtime in macos/scripts/common-macos.sh.
  #
  # An installed engine always ships runtime\node\node.exe and must use it. The
  # repository source tree has no bundled copy (the installer downloads it), so
  # running the suite from source falls back to PATH -- but that candidate goes
  # through the exact same Authenticode gate, so a hostile node.exe on PATH is
  # rejected before it is ever executed.
  $runtimeRoot = Split-Path -Parent $PSScriptRoot
  $bundledNode = Join-Path $runtimeRoot 'runtime\node\node.exe'
  if (Test-Path -LiteralPath $bundledNode -PathType Leaf) {
    return Get-DreamSkinValidatedNodeRuntime -Path $bundledNode -MinimumMajor $MinimumMajor
  }

  $command = Get-Command node.exe -ErrorAction SilentlyContinue
  if (-not $command) { $command = Get-Command node -ErrorAction SilentlyContinue }
  if (-not $command) {
    throw "The bundled Node.js runtime is missing ($bundledNode) and Node.js $MinimumMajor or newer was not found in PATH."
  }
  return Get-DreamSkinValidatedNodeRuntime -Path $command.Source -MinimumMajor $MinimumMajor
}

function ConvertTo-DreamSkinCodexInstall {
  param(
    [Parameter(Mandatory = $true)][object]$Package,
    [AllowNull()][object]$Manifest
  )
  if ("$($Package.Name)" -ine 'OpenAI.Codex' -or -not $Package.InstallLocation -or
    -not $Package.PackageFullName -or -not $Package.PackageFamilyName -or
    "$($Package.SignatureKind)" -ine 'Store' -or [bool]$Package.IsDevelopmentMode) {
    return $null
  }
  $packageRoot = "$($Package.InstallLocation)"
  $executable = Join-Path $packageRoot 'app\ChatGPT.exe'
  if (-not (Test-Path -LiteralPath $executable)) { return $null }
  try {
    if (-not $PSBoundParameters.ContainsKey('Manifest')) {
      $Manifest = Get-AppxPackageManifest -Package $Package -ErrorAction Stop
    }
    $applications = @($Manifest.Package.Applications.Application | Where-Object {
      "$($_.Executable)".Replace('/', '\') -ieq 'app\ChatGPT.exe'
    })
    if ($applications.Count -ne 1) { return $null }
    $applicationId = "$($applications[0].Id)"
  } catch {
    return $null
  }
  $packageFamilyName = "$($Package.PackageFamilyName)"
  if ($packageFamilyName -cnotmatch '^[A-Za-z0-9._-]{1,128}$' -or
    $applicationId -cnotmatch '^[A-Za-z0-9._-]{1,64}$') {
    return $null
  }
  return [pscustomobject]@{
    PackageRoot = $packageRoot
    Executable = $executable
    Version = "$($Package.Version)"
    PackageFullName = "$($Package.PackageFullName)"
    PackageFamilyName = $packageFamilyName
    ApplicationId = $applicationId
    AppUserModelId = "$packageFamilyName!$applicationId"
    SignatureKind = "$($Package.SignatureKind)"
  }
}

function Get-DreamSkinRegisteredCodexInstalls {
  $packages = @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop | Sort-Object Version -Descending)
  $installs = @()
  foreach ($package in $packages) {
    $install = ConvertTo-DreamSkinCodexInstall -Package $package
    if ($null -ne $install) { $installs += $install }
  }
  return $installs
}

function Get-DreamSkinCodexInstall {
  $installs = @(Get-DreamSkinRegisteredCodexInstalls)
  if ($installs.Count -eq 0) { throw 'The official OpenAI.Codex Store package is not installed or its identity cannot be validated.' }
  return $installs[0]
}

function Resolve-DreamSkinCodexInstallForTarget {
  param(
    [AllowEmptyString()][string]$PackageFullName,
    [AllowEmptyString()][string]$PackageFamilyName,
    [AllowEmptyString()][string]$PackageRoot
  )
  if ([string]::IsNullOrWhiteSpace($PackageFullName) -and
    [string]::IsNullOrWhiteSpace($PackageFamilyName) -and
    [string]::IsNullOrWhiteSpace($PackageRoot)) {
    return Get-DreamSkinCodexInstall
  }
  if ([string]::IsNullOrWhiteSpace($PackageFullName) -or
    [string]::IsNullOrWhiteSpace($PackageFamilyName)) {
    throw 'Automatic Codex takeover requires both package full-name and family-name identity.'
  }
  $matches = @(Get-DreamSkinRegisteredCodexInstalls | Where-Object {
    "$($_.PackageFullName)" -ceq $PackageFullName -and
      "$($_.PackageFamilyName)" -ceq $PackageFamilyName -and
      ([string]::IsNullOrWhiteSpace($PackageRoot) -or
        (Test-DreamSkinPathEqual -Left "$($_.PackageRoot)" -Right $PackageRoot))
  })
  if ($matches.Count -ne 1) {
    throw 'The requested official Codex package identity is no longer registered uniquely.'
  }
  return $matches[0]
}

function Initialize-DreamSkinPackageLauncher {
  if ('CodexDreamSkin.PackageLauncher' -as [type]) { return }
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace CodexDreamSkin {
  [Flags]
  internal enum ActivateOptions : uint {
    None = 0
  }

  [ComImport]
  [Guid("2e941141-7f97-4756-ba1d-9decde894a3d")]
  [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  internal interface IApplicationActivationManager {
    [PreserveSig]
    int ActivateApplication(
      [MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
      [MarshalAs(UnmanagedType.LPWStr)] string arguments,
      ActivateOptions options,
      out uint processId);
  }

  [ComImport]
  [Guid("45ba127d-10a8-46ea-8ab7-56ea9078943c")]
  internal class ApplicationActivationManager {}

  public static class PackageLauncher {
    public static uint Launch(string appUserModelId, string arguments) {
      var manager = (IApplicationActivationManager)new ApplicationActivationManager();
      try {
        uint processId;
        int result = manager.ActivateApplication(
          appUserModelId,
          arguments ?? string.Empty,
          ActivateOptions.None,
          out processId);
        Marshal.ThrowExceptionForHR(result);
        return processId;
      } finally {
        if (Marshal.IsComObject(manager)) Marshal.FinalReleaseComObject(manager);
      }
    }
  }
}
'@
}

function Start-DreamSkinCodex {
  param(
    [Parameter(Mandatory = $true)][object]$Codex,
    [AllowEmptyCollection()][string[]]$Arguments = @()
  )
  $appUserModelId = "$($Codex.AppUserModelId)"
  if ($appUserModelId -cnotmatch '^[A-Za-z0-9._-]{1,128}![A-Za-z0-9._-]{1,64}$') {
    throw 'The registered Codex AppUserModelId is unavailable or invalid.'
  }
  Initialize-DreamSkinPackageLauncher
  $argumentLine = ConvertTo-DreamSkinArgumentLine -Arguments $Arguments
  $processId = [CodexDreamSkin.PackageLauncher]::Launch($appUserModelId, $argumentLine)
  if ($processId -le 0) { throw 'Windows did not return a Codex process ID after package activation.' }
  return $processId
}

function Assert-DreamSkinCodexDirectLaunchTarget {
  param([Parameter(Mandatory = $true)][object]$Codex)
  $expectedExecutable = if ($Codex.PackageRoot) {
    Join-Path "$($Codex.PackageRoot)" 'app\ChatGPT.exe'
  } else {
    $null
  }
  $expectedAppUserModelId = if ($Codex.PackageFamilyName -and $Codex.ApplicationId) {
    "$($Codex.PackageFamilyName)!$($Codex.ApplicationId)"
  } else {
    $null
  }
  if ("$($Codex.SignatureKind)" -ine 'Store' -or -not $Codex.PackageFullName -or
    -not $expectedExecutable -or -not $expectedAppUserModelId -or
    "$($Codex.AppUserModelId)" -cne $expectedAppUserModelId -or
    -not (Test-DreamSkinPathEqual -Left "$($Codex.Executable)" -Right $expectedExecutable) -or
    -not (Test-Path -LiteralPath $expectedExecutable -PathType Leaf)) {
    throw 'Direct launch requires the exact executable from the validated OpenAI.Codex Store package.'
  }
}

function Start-DreamSkinCodexDirect {
  param(
    [Parameter(Mandatory = $true)][object]$Codex,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments
  )
  Assert-DreamSkinCodexDirectLaunchTarget -Codex $Codex
  $argumentLine = ConvertTo-DreamSkinArgumentLine -Arguments $Arguments
  $process = Start-Process -FilePath "$($Codex.Executable)" -ArgumentList $argumentLine `
    -PassThru -ErrorAction Stop
  try {
    if ($process.Id -le 0) { throw 'Windows did not return a Codex process ID after direct launch.' }
    return $process.Id
  } finally {
    $process.Dispose()
  }
}

function Get-DreamSkinDirectLaunchFailureKind {
  param([Parameter(Mandatory = $true)][System.Exception]$Exception)
  $current = $Exception
  while ($null -ne $current) {
    if ($current -is [System.UnauthorizedAccessException] -or
      ($current -is [System.ComponentModel.Win32Exception] -and $current.NativeErrorCode -eq 5) -or
      $current.HResult -eq -2147024891) {
      return 'access-denied'
    }
    $current = $current.InnerException
  }
  return 'start-failed'
}

function Wait-DreamSkinCodexDebugArgumentStatus {
  param(
    [Parameter(Mandatory = $true)][object]$Codex,
    [Parameter(Mandatory = $true)][int]$Port,
    [int]$TimeoutSeconds = 5
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $lastStatus = 'uninspectable'
  do {
    $processes = @(Get-DreamSkinCodexProcesses -Codex $Codex)
    $lastStatus = Get-DreamSkinCodexDebugArgumentStatus -Processes $processes -Port $Port
    if ($lastStatus -in @('forwarded', 'protocol-redirected')) { return $lastStatus }
    if ((Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
  } while ((Get-Date) -lt $deadline)
  return $lastStatus
}

function Start-DreamSkinCodexForDebugging {
  param(
    [Parameter(Mandatory = $true)][object]$Codex,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments,
    [Parameter(Mandatory = $true)][int]$Port,
    [AllowEmptyCollection()][int[]]$PreserveProcessIds
  )
  $preservedProcessIds = if ($PSBoundParameters.ContainsKey('PreserveProcessIds')) {
    @($PreserveProcessIds)
  } else {
    @(Get-DreamSkinCodexProcesses -Codex $Codex | ForEach-Object { [int]$_.ProcessId })
  }
 $packageProcessId = Start-DreamSkinCodex -Codex $Codex -Arguments $Arguments
 $packageStatus = Wait-DreamSkinCodexDebugArgumentStatus -Codex $Codex -Port $Port
  if ($packageStatus -eq 'not-forwarded') {
    # A readable official process without the raw CDP flag is different from
    # owl's codex:// redirect. The safety contract permits the exact
    # executable fallback only after that explicit protocol evidence. Give a
    # real listener one final chance, then stop this stock session and fail
    # closed instead of waiting through the full endpoint timeout.
    $verifiedIdentity = Get-DreamSkinVerifiedCdpIdentity -Port $Port -Codex $Codex
    if ($null -ne $verifiedIdentity) {
      return [pscustomobject]@{
        ProcessId = $packageProcessId
        Strategy = 'package-activation'
        ArgumentStatus = $packageStatus
        PackageArgumentStatus = $packageStatus
      }
    }
    try {
      Stop-DreamSkinCodex -Codex $Codex -PreserveProcessIds $preservedProcessIds -AllowForce
    } catch {
      throw (New-DreamSkinStartException -Category 'cdp-launch-failed' `
        -Message 'Codex package activation did not retain the CDP arguments, and the stock session could not be closed safely.' `
        -InnerException $_.Exception)
    }
    throw (New-DreamSkinStartException -Category 'cdp-unsupported' `
      -Message "Codex $($Codex.Version) started without --remote-debugging-port=$Port and exposed no verified listener. This Codex build does not currently expose a supported Dream Skin CDP launch path; Dream Skin stopped safely without modifying the protected app package." `
      -InnerException $null)
  }
 if ($packageStatus -ne 'protocol-redirected') {
   return [pscustomobject]@{
     ProcessId = $packageProcessId
     Strategy = 'package-activation'
     ArgumentStatus = $packageStatus
     PackageArgumentStatus = $packageStatus
   }
 }

  try {
    Stop-DreamSkinCodex -Codex $Codex -PreserveProcessIds $preservedProcessIds -AllowForce
  } catch {
    throw (New-DreamSkinStartException -Category 'cdp-launch-failed' `
      -Message 'Codex package activation did not retain the CDP arguments, and its process could not be closed safely.' `
      -InnerException $_.Exception)
  }

  try {
    $directProcessId = Start-DreamSkinCodexDirect -Codex $Codex -Arguments $Arguments
  } catch {
    $failureKind = Get-DreamSkinDirectLaunchFailureKind -Exception $_.Exception
    $category = if ($failureKind -ceq 'access-denied') {
      'cdp-direct-access-denied'
    } else {
      'cdp-launch-failed'
    }
    throw (New-DreamSkinStartException -Category $category `
      -Message "Codex $($Codex.Version) converted the CDP argument into a codex:// navigation path. Direct launch of the validated Store executable failed ($failureKind), so this Codex/Windows combination cannot expose the Dream Skin debugging endpoint without modifying the protected app package." `
      -InnerException $_.Exception)
  }

  $directStatus = Wait-DreamSkinCodexDebugArgumentStatus -Codex $Codex -Port $Port
  if ($directStatus -in @('protocol-redirected', 'not-forwarded')) {
    try {
      Stop-DreamSkinCodex -Codex $Codex -PreserveProcessIds $preservedProcessIds -AllowForce
    } catch {
      throw (New-DreamSkinStartException -Category 'cdp-endpoint-unavailable' `
        -Message 'Direct Codex launch did not retain the CDP arguments and could not be closed safely.' `
        -InnerException $_.Exception)
    }
    $category = if ($directStatus -ceq 'not-forwarded') { 'cdp-unsupported' } else { 'cdp-endpoint-unavailable' }
    throw (New-DreamSkinStartException -Category $category `
      -Message "Codex $($Codex.Version) did not retain the CDP argument during package activation or validated direct launch. Dream Skin cannot run without modifying the protected app package." `
      -InnerException $null)
  }

  return [pscustomobject]@{
    ProcessId = $directProcessId
    Strategy = 'direct-store-executable'
    ArgumentStatus = $directStatus
    PackageArgumentStatus = $packageStatus
  }
}

function Get-DreamSkinCodexStatePathCandidate {
  param([AllowNull()][object]$State)
  if ($null -eq $State -or -not $State.codexExe -or -not $State.codexPackageRoot) { return $null }
  $executable = "$($State.codexExe)"
  $packageRoot = "$($State.codexPackageRoot)"
  $expectedExecutable = Join-Path $packageRoot 'app\ChatGPT.exe'
  if (-not (Test-DreamSkinPathEqual -Left $executable -Right $expectedExecutable)) { return $null }
  return [pscustomobject]@{
    PackageRoot = $packageRoot
    Executable = $executable
    Version = "$($State.codexVersion)"
    FromState = $true
    RegisteredPackageVerified = $false
  }
}

function Resolve-DreamSkinCodexInstallFromState {
  param(
    [AllowNull()][object]$State,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$RegisteredInstalls
  )
  $candidate = Get-DreamSkinCodexStatePathCandidate -State $State
  if ($null -eq $candidate) { return $null }

  $hasFullName = [bool]$State.codexPackageFullName
  $hasFamilyName = [bool]$State.codexPackageFamilyName
  if ($hasFullName -xor $hasFamilyName) { return $null }
  foreach ($install in $RegisteredInstalls) {
    $pathMatches = (Test-DreamSkinPathEqual -Left $candidate.PackageRoot -Right $install.PackageRoot) -and
      (Test-DreamSkinPathEqual -Left $candidate.Executable -Right $install.Executable)
    if (-not $pathMatches) { continue }
    if ($hasFullName -and ("$($State.codexPackageFullName)" -ine $install.PackageFullName -or
      "$($State.codexPackageFamilyName)" -ine $install.PackageFamilyName)) {
      continue
    }
    return [pscustomobject]@{
      PackageRoot = $install.PackageRoot
      Executable = $install.Executable
      Version = $install.Version
      PackageFullName = $install.PackageFullName
      PackageFamilyName = $install.PackageFamilyName
      ApplicationId = $install.ApplicationId
      AppUserModelId = $install.AppUserModelId
      SignatureKind = $install.SignatureKind
      FromState = $true
      RegisteredPackageVerified = $true
    }
  }
  return $null
}

function Get-DreamSkinCodexInstallFromState {
  param([AllowNull()][object]$State)
  try { $installs = @(Get-DreamSkinRegisteredCodexInstalls) } catch { return $null }
  return Resolve-DreamSkinCodexInstallFromState -State $State -RegisteredInstalls $installs
}

function Test-DreamSkinWebSocketUrl {
  param([string]$Value, [int]$Port)
  try {
    $uri = [Uri]$Value
    $hostName = $uri.Host.ToLowerInvariant()
    return ($uri.IsAbsoluteUri -and $uri.Scheme -eq 'ws' -and $uri.Port -eq $Port -and
      $hostName -in @('127.0.0.1', 'localhost', '::1', '[::1]') -and -not $uri.UserInfo -and
      -not $uri.Query -and -not $uri.Fragment -and
      $uri.AbsolutePath -cmatch '^/devtools/(?:page|browser)/[A-Za-z0-9._-]{1,200}$')
  } catch {
    return $false
  }
}

function Test-DreamSkinCdpPageTarget {
  param([AllowNull()][object]$Target, [int]$Port)
  if ($null -eq $Target -or "$($Target.type)" -cne 'page' -or
    "$($Target.url)" -notlike 'app://*') {
    return $false
  }
  if ($Target.id -isnot [string]) { return $false }
  $targetId = "$($Target.id)"
  $webSocketUrl = "$($Target.webSocketDebuggerUrl)"
  if (-not (Test-DreamSkinBrowserId -Value $targetId) -or
    -not (Test-DreamSkinWebSocketUrl -Value $webSocketUrl -Port $Port)) {
    return $false
  }
  try {
    return ([Uri]$webSocketUrl).AbsolutePath -ceq "/devtools/page/$targetId"
  } catch {
    return $false
  }
}

function Get-DreamSkinCdpTargets {
  param([int]$Port)
  try {
    $targets = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/list" -TimeoutSec 2 `
      -MaximumRedirection 0 -ErrorAction Stop
    return @($targets | Where-Object { Test-DreamSkinCdpPageTarget -Target $_ -Port $Port })
  } catch {
    return @()
  }
}

function Test-DreamSkinBrowserId {
  param([string]$Value)
  return [bool]($Value -and $Value.Length -le 200 -and $Value -cmatch '^[A-Za-z0-9._-]+$')
}

function Get-DreamSkinCdpBrowserIdentity {
  param([int]$Port)
  try {
    $version = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/version" -TimeoutSec 2 `
      -MaximumRedirection 0 -ErrorAction Stop
    $webSocketUrl = "$($version.webSocketDebuggerUrl)"
    if (-not (Test-DreamSkinWebSocketUrl -Value $webSocketUrl -Port $Port)) { return $null }
    $uri = [Uri]$webSocketUrl
    $match = [regex]::Match($uri.AbsolutePath, '^/devtools/browser/(?<id>[A-Za-z0-9._-]{1,200})$')
    if (-not $match.Success -or $uri.Query -or $uri.Fragment) { return $null }
    $browserId = $match.Groups['id'].Value
    if (-not (Test-DreamSkinBrowserId -Value $browserId)) { return $null }
    return [pscustomobject]@{
      BrowserId = $browserId
      WebSocketDebuggerUrl = $webSocketUrl
      Browser = "$($version.Browser)"
    }
  } catch {
    return $null
  }
}

function Get-DreamSkinPortListeners {
  param([int]$Port)
  if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
    throw 'Get-NetTCPConnection is required to verify CDP listener ownership.'
  }
  return @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
}

function Test-DreamSkinPortAvailable {
  param([int]$Port)
  return (Get-DreamSkinPortListeners -Port $Port).Count -eq 0
}

function Test-DreamSkinCodexPortOwner {
  param([int]$Port, [Parameter(Mandatory = $true)][object]$Codex)
  $listeners = Get-DreamSkinPortListeners -Port $Port
  if ($listeners.Count -eq 0) { return $false }
  $ownerIds = @()
  foreach ($listener in $listeners) {
    if ($listener.LocalAddress -notin @('127.0.0.1', '::1')) { return $false }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $([int]$listener.OwningProcess)" -ErrorAction SilentlyContinue
    if ($null -eq $process -or -not (Test-DreamSkinCodexMainProcess -ProcessInfo $process -Codex $Codex)) {
      return $false
    }
    $ownerId = [int]$listener.OwningProcess
    if ($ownerIds -notcontains $ownerId) { $ownerIds += $ownerId }
  }
  $main = Get-DreamSkinCodexMainProcessRecord -Codex $Codex
  return $null -ne $main -and $ownerIds.Count -eq 1 -and $ownerIds[0] -eq [int]$main.ProcessId
}

function Get-DreamSkinVerifiedCdpIdentity {
  param([int]$Port, [Parameter(Mandatory = $true)][object]$Codex)
  if (-not (Test-DreamSkinCodexPortOwner -Port $Port -Codex $Codex)) { return $null }
  $browser = Get-DreamSkinCdpBrowserIdentity -Port $Port
  if ($null -eq $browser) { return $null }
  $targets = Get-DreamSkinCdpTargets -Port $Port
  if ($targets.Count -eq 0) { return $null }
  if (-not (Test-DreamSkinCodexPortOwner -Port $Port -Codex $Codex)) { return $null }
  return [pscustomobject]@{
    BrowserId = $browser.BrowserId
    BrowserWebSocketDebuggerUrl = $browser.WebSocketDebuggerUrl
    Browser = $browser.Browser
    TargetCount = $targets.Count
  }
}

function Test-DreamSkinCodexCdpEndpoint {
  param([int]$Port, [Parameter(Mandatory = $true)][object]$Codex)
  return $null -ne (Get-DreamSkinVerifiedCdpIdentity -Port $Port -Codex $Codex)
}

function Get-DreamSkinVerifiedCdpIdentityForAnyRegistered {
  # A Store auto-update replaces the "current" package directory while the
  # older version keeps running and owning the verified endpoint.  Accepting
  # any registered OpenAI.Codex install keeps the strict owner validation
  # (every candidate passed the same package identity checks) without
  # restarting a healthy skinned Codex just because the Store updated.
  param([int]$Port)
  foreach ($install in @(Get-DreamSkinRegisteredCodexInstalls)) {
    $identity = Get-DreamSkinVerifiedCdpIdentity -Port $Port -Codex $install
    if ($null -ne $identity) {
      return [pscustomobject]@{
        Identity = $identity
        Codex = $install
      }
    }
  }
  return $null
}

function Select-DreamSkinPort {
  param([int]$PreferredPort)
  for ($candidate = $PreferredPort; $candidate -le [Math]::Min(65535, $PreferredPort + 100); $candidate++) {
    if (Test-DreamSkinPortAvailable -Port $candidate) { return $candidate }
  }
  throw "No free loopback port was found between $PreferredPort and $([Math]::Min(65535, $PreferredPort + 100))."
}

function Wait-DreamSkinPortAvailable {
  param([int]$Port, [int]$TimeoutSeconds = 5)
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    if (Test-DreamSkinPortAvailable -Port $Port) { return $true }
    Start-Sleep -Milliseconds 200
  } while ((Get-Date) -lt $deadline)
  return $false
}

function Read-DreamSkinState {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  try {
    $state = (Read-DreamSkinUtf8File -Path $Path) | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $state -or $state -is [string] -or $state -is [array]) { throw 'State root must be an object.' }
    $properties = @($state.PSObject.Properties.Name)
    if ($properties -contains 'platform' -and "$($state.platform)" -ine 'windows') {
      throw 'State platform is not Windows.'
    }
    $schemaVersion = 1
    if ($properties -contains 'schemaVersion') {
      $schemaVersion = 0
      if (-not [int]::TryParse("$($state.schemaVersion)", [ref]$schemaVersion) -or
        $schemaVersion -lt 1 -or $schemaVersion -gt 4) {
        throw 'State schema is not supported.'
      }
    }
    if ($schemaVersion -ge 3) {
      foreach ($required in @(
        'platform', 'port', 'injectorPid', 'injectorStartedAt', 'injectorPath', 'nodePath',
        'codexExe', 'codexPackageRoot', 'codexPackageFullName', 'codexPackageFamilyName', 'browserId'
      )) {
        if ($properties -notcontains $required -or -not $state.$required) {
          throw "State schema 3 is missing required field: $required"
        }
      }
    }
    if ($schemaVersion -ge 4) {
      foreach ($required in @('sessionId', 'codexMainProcess', 'codexListenerProcess',
        'launchSource', 'lastObservedAt', 'watcherStatus')) {
        if ($properties -notcontains $required -or $null -eq $state.$required) {
          throw "State schema 4 is missing required field: $required"
        }
      }
      if ("$($state.sessionId)" -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$') {
        throw 'State session ID is invalid.'
      }
      if ("$($state.launchSource)" -notin @('dream-skin', 'official-auto', 'recovery')) {
        throw 'State launch source is invalid.'
      }
      if ("$($state.watcherStatus)" -notin @('running', 'stopped', 'stale', 'blocked')) {
        throw 'State watcher status is invalid.'
      }
      try { [void][datetime]::Parse("$($state.lastObservedAt)") } catch {
        throw 'State last-observed timestamp is invalid.'
      }
      foreach ($recordName in @('codexMainProcess', 'codexListenerProcess')) {
        $record = $state.$recordName
        if ($record -is [string] -or $record -is [array]) {
          throw "State $recordName identity is invalid."
        }
        foreach ($required in @('processId', 'startedAt', 'executable')) {
          if (@($record.PSObject.Properties.Name) -notcontains $required -or
            $null -eq $record.$required -or "$($record.$required)" -eq '') {
            throw "State $recordName is missing required field: $required"
          }
        }
        $recordPid = 0
        if (-not [int]::TryParse("$($record.processId)", [ref]$recordPid) -or $recordPid -le 0) {
          throw "State $recordName PID is invalid."
        }
        try { [void][datetime]::Parse("$($record.startedAt)") } catch {
          throw "State $recordName start time is invalid."
        }
        if (-not [System.IO.Path]::IsPathRooted("$($record.executable)")) {
          throw "State $recordName executable path is invalid."
        }
      }
      foreach ($required in @('packageRoot', 'packageFullName', 'packageFamilyName')) {
        if (@($state.codexMainProcess.PSObject.Properties.Name) -notcontains $required -or
          -not $state.codexMainProcess.$required) {
          throw "State codexMainProcess is missing required field: $required"
        }
      }
    }
    if ($properties -contains 'port') {
      $statePort = 0
      if (-not [int]::TryParse("$($state.port)", [ref]$statePort)) { throw 'State port is invalid.' }
      Assert-DreamSkinPort -Port $statePort
    }
    if ($properties -contains 'injectorPid' -and $null -ne $state.injectorPid) {
      $statePid = 0
      if (-not [int]::TryParse("$($state.injectorPid)", [ref]$statePid) -or $statePid -le 0) {
        throw 'State injector PID is invalid.'
      }
    }
    if ($properties -contains 'browserId' -and $state.browserId -and
      -not (Test-DreamSkinBrowserId -Value "$($state.browserId)")) {
      throw 'State browser ID is invalid.'
    }
    return $state
  } catch {
    throw "Dream Skin state is unreadable; it was preserved for inspection: $Path"
  }
}

function Write-DreamSkinState {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object]$State)
  $json = $State | ConvertTo-Json -Depth 6
  Write-DreamSkinUtf8FileAtomically -Path $Path -Content ($json + "`r`n")
}

function Get-DreamSkinOfficialLaunchMonitorDisabledPath {
  param([Parameter(Mandatory = $true)][string]$StateRoot)
  return Join-Path ([System.IO.Path]::GetFullPath($StateRoot)) 'official-launch-monitor.disabled'
}

function Test-DreamSkinOfficialLaunchMonitorEnabled {
  param([Parameter(Mandatory = $true)][string]$StateRoot)
  $path = Get-DreamSkinOfficialLaunchMonitorDisabledPath -StateRoot $StateRoot
  if (-not (Test-Path -LiteralPath $path)) { return $true }
  try {
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    return $false
  } catch {
    return $false
  }
}

function Set-DreamSkinOfficialLaunchMonitorEnabled {
  param(
    [Parameter(Mandatory = $true)][bool]$Enabled,
    [Parameter(Mandatory = $true)][string]$StateRoot
  )
  $root = [System.IO.Path]::GetFullPath($StateRoot)
  if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    [void][System.IO.Directory]::CreateDirectory($root)
  }
  if (Get-Command Assert-DreamSkinNoReparseComponents -CommandType Function -ErrorAction SilentlyContinue) {
    Assert-DreamSkinNoReparseComponents -Path $root
  }
  $path = Get-DreamSkinOfficialLaunchMonitorDisabledPath -StateRoot $root
  if ($Enabled) {
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    return
  }
  Write-DreamSkinUtf8FileAtomically -Path $path -Content "disabled`r`n"
}

function Get-DreamSkinLaunchIntentPath {
  param([Parameter(Mandatory = $true)][string]$StateRoot)
  return Join-Path ([System.IO.Path]::GetFullPath($StateRoot)) 'launch-intent.json'
}

function New-DreamSkinLaunchIntent {
  param(
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [Parameter(Mandatory = $true)][object]$Codex,
    [Parameter(Mandatory = $true)][int]$Port,
    [AllowEmptyCollection()][int[]]$PreserveProcessIds = @(),
    [ValidateRange(1, 300)][int]$TtlSeconds = 60
  )
  if ($null -eq $script:DreamSkinUtf8NoBom) {
    $script:DreamSkinUtf8NoBom = [System.Text.UTF8Encoding]::new($false, $true)
  }
  Assert-DreamSkinPort -Port $Port
  foreach ($property in @('PackageRoot', 'PackageFullName', 'PackageFamilyName')) {
    if ([string]::IsNullOrWhiteSpace("$($Codex.$property)")) {
      throw "Cannot create a Dream Skin launch intent without Codex $property."
    }
  }
  $root = [System.IO.Path]::GetFullPath($StateRoot)
  if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    [void][System.IO.Directory]::CreateDirectory($root)
  }
  if (Get-Command Assert-DreamSkinNoReparseComponents -CommandType Function -ErrorAction SilentlyContinue) {
    Assert-DreamSkinNoReparseComponents -Path $root
  }
  $createdAt = [datetime]::UtcNow
  $intent = [ordered]@{
    schemaVersion = 1
    token = [guid]::NewGuid().ToString('N')
    createdAt = $createdAt.ToString('o')
    expiresAt = $createdAt.AddSeconds($TtlSeconds).ToString('o')
    port = $Port
    packageRoot = "$($Codex.PackageRoot)"
    packageFullName = "$($Codex.PackageFullName)"
    packageFamilyName = "$($Codex.PackageFamilyName)"
    preserveProcessIds = @($PreserveProcessIds | ForEach-Object { [int]$_ })
  }
  $content = (($intent | ConvertTo-Json -Compress) + "`r`n")
  if ([System.Text.UTF8Encoding]::new($false).GetByteCount($content) -gt 8192) {
    throw 'Dream Skin launch intent exceeded its fixed size limit.'
  }
  Write-DreamSkinUtf8FileAtomically -Path (Get-DreamSkinLaunchIntentPath -StateRoot $root) -Content $content
  return [pscustomobject]$intent
}

function Read-DreamSkinLaunchIntent {
  param([Parameter(Mandatory = $true)][string]$StateRoot)
  if ($null -eq $script:DreamSkinUtf8NoBom) {
    $script:DreamSkinUtf8NoBom = [System.Text.UTF8Encoding]::new($false, $true)
  }
  $path = Get-DreamSkinLaunchIntentPath -StateRoot $StateRoot
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  try {
    if (Get-Command Assert-DreamSkinNoReparseComponents -CommandType Function -ErrorAction SilentlyContinue) {
      Assert-DreamSkinNoReparseComponents -Path $path
    }
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if ($item.Length -le 0 -or $item.Length -gt 8192) { return $null }
    $intent = Read-DreamSkinUtf8File -Path $path | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $intent -or $intent -is [array] -or $intent -is [string]) { return $null }
    $allowed = @(
      'schemaVersion', 'token', 'createdAt', 'expiresAt', 'port',
      'packageRoot', 'packageFullName', 'packageFamilyName', 'preserveProcessIds'
    )
    $properties = @($intent.PSObject.Properties)
    if ($properties.Count -ne $allowed.Count -or
      @($properties | Where-Object { $allowed -cnotcontains $_.Name }).Count -gt 0) { return $null }
    if ([int]$intent.schemaVersion -ne 1 -or
      "$($intent.token)" -notmatch '\A[a-f0-9]{32}\z' -or
      [string]::IsNullOrWhiteSpace("$($intent.packageRoot)") -or
      [string]::IsNullOrWhiteSpace("$($intent.packageFullName)") -or
      [string]::IsNullOrWhiteSpace("$($intent.packageFamilyName)")) { return $null }
    $intentPort = 0
    if (-not [int]::TryParse("$($intent.port)", [ref]$intentPort)) { return $null }
    Assert-DreamSkinPort -Port $intentPort
    $expiresAt = [datetime]::Parse("$($intent.expiresAt)").ToUniversalTime()
    if ([datetime]::UtcNow -gt $expiresAt) {
      Remove-DreamSkinLaunchIntent -StateRoot $StateRoot
      return $null
    }
    $preserveIds = @($intent.preserveProcessIds | ForEach-Object {
      $value = 0
      if (-not [int]::TryParse("$_", [ref]$value) -or $value -le 0) { throw 'Invalid preserved process ID.' }
      $value
    })
    $intent | Add-Member -NotePropertyName preserveProcessIds -NotePropertyValue $preserveIds -Force
    return $intent
  } catch {
    return $null
  }
}

function Remove-DreamSkinLaunchIntent {
  param(
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [AllowEmptyString()][string]$Token = ''
  )
  $path = Get-DreamSkinLaunchIntentPath -StateRoot $StateRoot
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
  if (Get-Command Assert-DreamSkinNoReparseComponents -CommandType Function -ErrorAction SilentlyContinue) {
    Assert-DreamSkinNoReparseComponents -Path $path
  }
  if ($Token) {
    try {
      $current = Read-DreamSkinLaunchIntent -StateRoot $StateRoot
      if ($null -eq $current -or "$($current.token)" -cne $Token) { return $false }
    } catch { return $false }
  }
  Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
  return $true
}

function Test-DreamSkinLaunchIntentForCandidate {
  param(
    [AllowNull()][object]$Intent,
    [AllowNull()][object]$Candidate,
    [Parameter(Mandatory = $true)][int]$Port
  )
  if ($null -eq $Intent -or $null -eq $Candidate -or $null -eq $Candidate.Codex -or $null -eq $Candidate.Process) {
    return $false
  }
  try {
    $intentPort = [int]$Intent.port
    if ($intentPort -ne $Port) { return $false }
    if ("$($Intent.packageFullName)" -cne "$($Candidate.Codex.PackageFullName)" -or
      "$($Intent.packageFamilyName)" -cne "$($Candidate.Codex.PackageFamilyName)" -or
      -not (Test-DreamSkinPathEqual -Left "$($Intent.packageRoot)" -Right "$($Candidate.Codex.PackageRoot)")) {
      return $false
    }
    $candidatePid = [int]$Candidate.Process.ProcessId
    return @($Intent.preserveProcessIds | ForEach-Object { [int]$_ }) -notcontains $candidatePid
  } catch {
    return $false
  }
}

function Get-DreamSkinStateStatus {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'stopped' }
  try {
    $state = Read-DreamSkinState -Path $Path
  } catch {
    return 'stale'
  }
  $schemaVersion = 1
  if ($state.schemaVersion) { [void][int]::TryParse("$($state.schemaVersion)", [ref]$schemaVersion) }
  if ($schemaVersion -lt 4) { return 'stale' }
  $watcherStatus = "$($state.watcherStatus)"
  if ($watcherStatus -ceq 'blocked') { return 'blocked' }
  if ($watcherStatus -ceq 'running') {
    try {
      if (Test-DreamSkinRecordedInjectorRunning -State $state) { return 'running' }
      return 'stale'
    } catch {
      return 'blocked'
    }
  }
  if ($watcherStatus -in @('stopped', 'stale')) { return 'stale' }
  return 'blocked'
}

function Test-DreamSkinOfficialLaunchMonitorState {
  param(
    [Parameter(Mandatory = $true)][string]$StatePath,
    [Parameter(Mandatory = $true)][bool]$ThemeReady,
    [Parameter(Mandatory = $true)][bool]$Paused
  )
  if (-not $ThemeReady -or $Paused) { return $false }
  $stateRoot = Split-Path -Parent ([System.IO.Path]::GetFullPath($StatePath))
  if (Test-DreamSkinDisabled -StateRoot $stateRoot) { return $false }
  if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { return $true }
  try {
    $state = Read-DreamSkinState -Path $StatePath
    $schemaVersion = 1
    if ($state.schemaVersion) { [void][int]::TryParse("$($state.schemaVersion)", [ref]$schemaVersion) }
    if ($schemaVersion -lt 4 -or "$($state.watcherStatus)" -cne 'running') { return $false }
    return $true
  } catch {
    return $false
  }
}

function Archive-DreamSkinStateFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  $directory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Path))
  $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
  $archivePath = Join-Path $directory "state.stale-$stamp-$([guid]::NewGuid().ToString('N')).json"
  Move-Item -LiteralPath $Path -Destination $archivePath -ErrorAction Stop
  return $archivePath
}

function Get-DreamSkinProcessStartedAt {
  param([int]$ProcessId)
  try {
    return (Get-Process -Id $ProcessId -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o')
  } catch {
    return $null
  }
}

function Test-DreamSkinRecordedInjectorRunning {
  param([AllowNull()][object]$State)
  if ($null -eq $State -or -not $State.injectorPid -or -not $State.injectorStartedAt) {
    return $false
  }

  $processId = [int]$State.injectorPid
  $processHandle = Get-Process -Id $processId -ErrorAction SilentlyContinue
  if ($null -eq $processHandle) { return $false }
  try {
    try {
      $startedAt = $processHandle.StartTime.ToUniversalTime().ToString('o')
    } catch {
      if ($processHandle.HasExited) { return $false }
      throw "The recorded injector PID $processId is running, but its start time cannot be inspected. State was preserved."
    }
    return $startedAt -ceq "$($State.injectorStartedAt)"
  } finally {
    $processHandle.Dispose()
  }
}

function Get-DreamSkinInjectorRecoveryContext {
  param([AllowNull()][object]$State)
  if ($null -eq $State -or -not $State.port -or -not $State.injectorPid -or
    -not $State.injectorStartedAt -or -not $State.browserId) {
    return $null
  }
  if (Test-DreamSkinRecordedInjectorRunning -State $State) { return $null }

  $port = 0
  if (-not [int]::TryParse("$($State.port)", [ref]$port)) { return $null }
  Assert-DreamSkinPort -Port $port
  if (Test-DreamSkinPortAvailable -Port $port) { return $null }

  $codex = Get-DreamSkinCodexInstallFromState -State $State
  $identity = if ($null -ne $codex) {
    Get-DreamSkinVerifiedCdpIdentity -Port $port -Codex $codex
  } else {
    $null
  }
  if ($null -eq $identity) {
    $registered = Get-DreamSkinVerifiedCdpIdentityForAnyRegistered -Port $port
    if ($null -eq $registered) { return $null }
    $codex = $registered.Codex
    $identity = $registered.Identity
  }
  if ("$($identity.BrowserId)" -ceq "$($State.browserId)") { return $null }

  return [pscustomobject]@{
    Port = $port
    BrowserId = $identity.BrowserId
    Codex = $codex
  }
}

function Stop-DreamSkinRecordedInjector {
  param([AllowNull()][object]$State)
  if ($null -eq $State -or -not $State.injectorPid) { return $true }
  $processId = [int]$State.injectorPid
  $processHandle = Get-Process -Id $processId -ErrorAction SilentlyContinue
  if (-not $processHandle) { return $true }
  $process = Get-CimInstance Win32_Process -Filter "ProcessId = $processId" -ErrorAction SilentlyContinue
  if (-not $process) {
    if ($processHandle.HasExited) { return $true }
    throw "The recorded injector PID $processId is running, but its identity cannot be inspected. State was preserved."
  }

  $expectedInjector = if ($State.injectorPath) {
    "$($State.injectorPath)"
  } elseif ($State.skillRoot) {
    Join-Path "$($State.skillRoot)" 'scripts\injector.mjs'
  } else {
    $null
  }
  $processPath = Get-DreamSkinProcessExecutablePath -ProcessInfo $process
  $commandLine = "$($process.CommandLine)"
  if (-not $processPath -or -not $commandLine) {
    throw "The recorded injector PID $processId is running, but its identity cannot be inspected. State was preserved."
  }
  $isNodeExecutable = [System.IO.Path]::GetFileName("$processPath") -ieq 'node.exe'
  $nodeMatches = -not $State.nodePath -or
    (Test-DreamSkinPathEqual -Left $processPath -Right "$($State.nodePath)")
  $injectorMatches = [bool]($expectedInjector -and $State.port -and $State.browserId -and
    (Test-DreamSkinInjectorCommandLine -CommandLine $commandLine `
      -InjectorPath $expectedInjector -Port ([int]$State.port) -BrowserId "$($State.browserId)"))
  $startedAt = Get-DreamSkinProcessStartedAt -ProcessId $processId
  $startMatches = -not $State.injectorStartedAt -or $startedAt -eq "$($State.injectorStartedAt)"
  $identityMatches = [bool]($isNodeExecutable -and $nodeMatches -and $injectorMatches -and $startMatches)

  if (-not $identityMatches) {
    throw "The recorded injector PID $processId is running, but its visible identity does not match the saved Dream Skin process. State was preserved."
  }

  Stop-Process -InputObject $processHandle -Force -ErrorAction Stop
  [void]$processHandle.WaitForExit(15000)
  if (-not $processHandle.HasExited) {
    throw "The recorded Dream Skin injector did not stop: PID $processId"
  }
  return $true
}

function Get-DreamSkinCodexProcesses {
  param([Parameter(Mandatory = $true)][object]$Codex)
  return @(Get-CimInstance Win32_Process -Filter "Name = 'ChatGPT.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
      $processPath = Get-DreamSkinProcessExecutablePath -ProcessInfo $_
      Test-DreamSkinPathEqual -Left $processPath -Right $Codex.Executable
    })
}

function Test-DreamSkinCodexMainProcess {
  param(
    [Parameter(Mandatory = $true)][object]$ProcessInfo,
    [Parameter(Mandatory = $true)][object]$Codex
  )
  $processPath = Get-DreamSkinProcessExecutablePath -ProcessInfo $ProcessInfo
  if (-not $processPath -or -not (Test-DreamSkinPathEqual -Left $processPath -Right $Codex.Executable)) {
    return $false
  }
  $commandLine = "$($ProcessInfo.CommandLine)"
  if (-not $commandLine) { return $false }
  $arguments = @(ConvertFrom-DreamSkinStrictCommandLine -CommandLine $commandLine)
  if ($null -eq $arguments -or $arguments.Count -eq 0 -or
    -not (Test-DreamSkinPathEqual -Left $arguments[0] -Right $Codex.Executable)) {
    return $false
  }
  foreach ($argument in $arguments) {
    if ($argument -cmatch '^(?i:--type=(?:renderer|gpu-process|utility|zygote|sandbox|sandbox-helper|crashpad-handler)|--utility-sub-type=|--renderer-client-id=|--mojo-platform-channel-handle=)') {
      return $false
    }
  }
  $parentId = 0
  if ($null -ne $ProcessInfo.ParentProcessId -and
    [int]::TryParse("$($ProcessInfo.ParentProcessId)", [ref]$parentId) -and $parentId -gt 0) {
    try {
      $parent = Get-CimInstance Win32_Process -Filter "ProcessId = $parentId" -ErrorAction Stop
      if ($parent) {
        $parentPath = Get-DreamSkinProcessExecutablePath -ProcessInfo $parent
        if ($parentPath -and (Test-DreamSkinPathEqual -Left $parentPath -Right $Codex.Executable)) {
          return $false
        }
      }
    } catch {
      return $false
    }
  }
  return $true
}

function ConvertTo-DreamSkinCodexProcessRecord {
  param(
    [Parameter(Mandatory = $true)][object]$ProcessInfo,
    [Parameter(Mandatory = $true)][object]$Codex,
    [switch]$RequireMain
  )
  $processPath = Get-DreamSkinProcessExecutablePath -ProcessInfo $ProcessInfo
  if (-not $processPath -or -not (Test-DreamSkinPathEqual -Left $processPath -Right $Codex.Executable)) {
    return $null
  }
  if ($RequireMain -and -not (Test-DreamSkinCodexMainProcess -ProcessInfo $ProcessInfo -Codex $Codex)) {
    return $null
  }
  $processId = 0
  if (-not [int]::TryParse("$($ProcessInfo.ProcessId)", [ref]$processId) -or $processId -le 0) {
    return $null
  }
  $startedAt = Get-DreamSkinProcessStartedAt -ProcessId $processId
  if (-not $startedAt) { return $null }
  return [pscustomobject]@{
    ProcessId = $processId
    StartedAt = "$startedAt"
    Executable = "$($Codex.Executable)"
    PackageRoot = "$($Codex.PackageRoot)"
    PackageFullName = "$($Codex.PackageFullName)"
    PackageFamilyName = "$($Codex.PackageFamilyName)"
    Version = "$($Codex.Version)"
  }
}

function Get-DreamSkinCodexMainProcesses {
  param([Parameter(Mandatory = $true)][object]$Codex)
  return @(Get-DreamSkinCodexProcesses -Codex $Codex | Where-Object {
    Test-DreamSkinCodexMainProcess -ProcessInfo $_ -Codex $Codex
  })
}

function Get-DreamSkinCodexMainProcessRecords {
  param([Parameter(Mandatory = $true)][object]$Codex)
  return @(Get-DreamSkinCodexMainProcesses -Codex $Codex | ForEach-Object {
    $record = ConvertTo-DreamSkinCodexProcessRecord -ProcessInfo $_ -Codex $Codex -RequireMain
    if ($null -ne $record) { $record }
  })
}

function Get-DreamSkinCodexMainProcessRecord {
  param([Parameter(Mandatory = $true)][object]$Codex)
  $records = @(Get-DreamSkinCodexMainProcessRecords -Codex $Codex)
  if ($records.Count -ne 1) { return $null }
  return $records[0]
}

function Get-DreamSkinRegisteredCodexMainProcessRecords {
  $observed = @()
  foreach ($install in @(Get-DreamSkinRegisteredCodexInstalls)) {
    foreach ($process in @(Get-DreamSkinCodexMainProcessRecords -Codex $install)) {
      $observed += [pscustomobject]@{ Codex = $install; Process = $process }
    }
  }
  return $observed
}

function Get-DreamSkinOfficialLaunchObservation {
  param(
    [AllowNull()][hashtable]$Baseline,
    [AllowEmptyCollection()][object[]]$Observed = @()
  )
  $current = @{}
  foreach ($item in @($Observed)) {
    if ($null -eq $item -or $null -eq $item.Process) { continue }
    $key = ConvertTo-DreamSkinProcessIdentityKey -ProcessRecord $item.Process
    $current[$key] = $item
  }
  $known = if ($null -eq $Baseline) { @{} } else { $Baseline }
  $candidates = @($current.GetEnumerator() | Where-Object {
    -not $known.ContainsKey($_.Key)
  } | ForEach-Object { $_.Value })
  $packageNames = @($Observed | ForEach-Object { "$($_.Codex.PackageFullName)" } | Sort-Object -Unique)
  return [pscustomobject]@{
    Current = $current
    Candidates = $candidates
    PackageNames = $packageNames
    Ambiguous = ($Observed.Count -ne 1 -or $packageNames.Count -ne 1 -or $candidates.Count -ne 1)
  }
}

function ConvertTo-DreamSkinProcessIdentityKey {
  param([Parameter(Mandatory = $true)][object]$ProcessRecord)
  return "$($ProcessRecord.ProcessId)|$($ProcessRecord.StartedAt)"
}

function Test-DreamSkinCodexProcessIdentity {
  param(
    [AllowNull()][object]$Recorded,
    [AllowNull()][object]$Current
  )
  if ($null -eq $Recorded -or $null -eq $Current) { return $false }
  return ([int]$Recorded.ProcessId -eq [int]$Current.ProcessId -and
    "$($Recorded.StartedAt)" -ceq "$($Current.StartedAt)" -and
    (Test-DreamSkinPathEqual -Left "$($Recorded.Executable)" -Right "$($Current.Executable)") -and
    "$($Recorded.PackageFullName)" -ceq "$($Current.PackageFullName)" -and
    "$($Recorded.PackageFamilyName)" -ceq "$($Current.PackageFamilyName)")
}

function Get-DreamSkinCodexListenerProcessRecord {
  param(
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][object]$Codex
  )
  $listeners = @(Get-DreamSkinPortListeners -Port $Port)
  if ($listeners.Count -eq 0) { return $null }
  $ownerIds = @()
  $ownerRecords = @()
  foreach ($listener in $listeners) {
    if ("$($listener.LocalAddress)" -notin @('127.0.0.1', '::1')) { return $null }
    $ownerId = 0
    if (-not [int]::TryParse("$($listener.OwningProcess)", [ref]$ownerId) -or $ownerId -le 0) { return $null }
    if ($ownerIds -notcontains $ownerId) {
      $ownerIds += $ownerId
      $process = Get-CimInstance Win32_Process -Filter "ProcessId = $ownerId" -ErrorAction SilentlyContinue
      if ($null -eq $process) { return $null }
      $record = ConvertTo-DreamSkinCodexProcessRecord -ProcessInfo $process -Codex $Codex -RequireMain
      if ($null -eq $record) { return $null }
      $ownerRecords += $record
    }
  }
  if ($ownerRecords.Count -ne 1) { return $null }
  $main = Get-DreamSkinCodexMainProcessRecord -Codex $Codex
  if ($null -eq $main -or $ownerRecords[0].ProcessId -ne $main.ProcessId -or
    "$($ownerRecords[0].StartedAt)" -cne "$($main.StartedAt)") {
    return $null
  }
  return $ownerRecords[0]
}

function Get-DreamSkinCodexProcessesExcept {
  param(
    [Parameter(Mandatory = $true)][object]$Codex,
    [AllowEmptyCollection()][int[]]$PreserveProcessIds = @()
  )
  $preserved = @{}
  foreach ($processId in $PreserveProcessIds) {
    if ($processId -gt 0) { $preserved[$processId] = $true }
  }
  return @(
    Get-DreamSkinCodexProcesses -Codex $Codex | Where-Object {
      -not $preserved.ContainsKey([int]$_.ProcessId)
    }
  )
}

function Stop-DreamSkinCodex {
  param(
    [Parameter(Mandatory = $true)][object]$Codex,
    [AllowEmptyCollection()][int[]]$PreserveProcessIds = @(),
    [switch]$AllowForce
  )
  $processes = Get-DreamSkinCodexProcessesExcept -Codex $Codex -PreserveProcessIds $PreserveProcessIds
  if ($processes.Count -eq 0) { return }
  foreach ($item in $processes) {
    try { [void](Get-Process -Id $item.ProcessId -ErrorAction Stop).CloseMainWindow() } catch {}
  }

  $deadline = (Get-Date).AddSeconds(15)
  while ((Get-DreamSkinCodexProcessesExcept -Codex $Codex `
      -PreserveProcessIds $PreserveProcessIds).Count -gt 0 -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 250
  }
  $remaining = Get-DreamSkinCodexProcessesExcept -Codex $Codex -PreserveProcessIds $PreserveProcessIds
  if ($remaining.Count -eq 0) { return }
  if (-not $AllowForce) {
    throw 'Codex did not close within 15 seconds. Close it manually or explicitly authorize a forced restart.'
  }
  foreach ($item in $remaining) {
    $current = Get-CimInstance Win32_Process -Filter "ProcessId = $([int]$item.ProcessId)" -ErrorAction SilentlyContinue
    $currentPath = if ($current) { Get-DreamSkinProcessExecutablePath -ProcessInfo $current } else { $null }
    if ($currentPath -and (Test-DreamSkinPathEqual -Left $currentPath -Right $Codex.Executable)) {
      Stop-Process -Id $item.ProcessId -Force -ErrorAction SilentlyContinue
    }
  }
  Start-Sleep -Milliseconds 500
  if ((Get-DreamSkinCodexProcessesExcept -Codex $Codex `
      -PreserveProcessIds $PreserveProcessIds).Count -gt 0) {
    throw 'Codex could not be stopped safely.'
  }
}

function Confirm-DreamSkinRestart {
  param([string]$Message)
  $shell = New-Object -ComObject WScript.Shell
  return $shell.Popup($Message, 0, 'Codex Dream Skin', 52) -eq 6
}

function Invoke-DreamSkinCodexWindowActivation {
  param([Parameter(Mandatory = $true)][object]$Codex)
  $processes = @(Get-DreamSkinCodexProcesses -Codex $Codex)
  if ($processes.Count -eq 0) { return $false }
  $shell = New-Object -ComObject WScript.Shell
  foreach ($process in $processes) {
    try {
      if ($shell.AppActivate([int]$process.ProcessId)) { return $true }
    } catch {}
  }
  return $false
}
