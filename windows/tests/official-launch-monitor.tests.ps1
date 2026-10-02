[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Root)

$ErrorActionPreference = 'Stop'
. (Join-Path $Root 'scripts\common-windows.ps1')

$fakeExecutable = 'C:\Program Files\WindowsApps\OpenAI.Codex_fixture\app\ChatGPT.exe'
$fakeCodex = [pscustomobject]@{
  Executable = $fakeExecutable
  PackageRoot = 'C:\Program Files\WindowsApps\OpenAI.Codex_fixture'
  PackageFullName = 'OpenAI.Codex_fixture_26.928.2636.0_x64__test'
  PackageFamilyName = 'OpenAI.Codex_fixture_test'
  Version = '26.928.2636.0'
}
$mainProcess = [pscustomobject]@{
  ProcessId = 501
  ParentProcessId = 100
  ExecutablePath = $fakeExecutable
  CommandLine = '"C:\Program Files\WindowsApps\OpenAI.Codex_fixture\app\ChatGPT.exe" --app-shell'
}
$rendererProcess = [pscustomobject]@{
  ProcessId = 502
  ParentProcessId = 501
  ExecutablePath = $fakeExecutable
  CommandLine = '"C:\Program Files\WindowsApps\OpenAI.Codex_fixture\app\ChatGPT.exe" --type=renderer --renderer-client-id=3'
}
$crashpadProcess = [pscustomobject]@{
  ProcessId = 503
  ParentProcessId = 501
  ExecutablePath = $fakeExecutable
  CommandLine = '"C:\Program Files\WindowsApps\OpenAI.Codex_fixture\app\ChatGPT.exe" --type=crashpad-handler'
}
$parentProcess = [pscustomobject]@{
  ProcessId = 100
  ExecutablePath = 'C:\Windows\explorer.exe'
  CommandLine = '"C:\Windows\explorer.exe"'
}
$script:processStartTimes = @{
  501 = '2026-10-02T01:00:00.0000000Z'
  502 = '2026-10-02T01:00:00.1000000Z'
  503 = '2026-10-02T01:00:00.2000000Z'
}
$script:listenerOwnerId = 501

$originalFunctions = @{}
$createdFunctions = @()
foreach ($functionName in @(
  'Get-DreamSkinCodexProcesses',
  'Get-DreamSkinProcessExecutablePath',
  'Get-DreamSkinProcessStartedAt',
  'Get-DreamSkinPortListeners',
  'Get-DreamSkinRegisteredCodexInstalls'
)) {
  $originalFunctions[$functionName] = (Get-Command $functionName -CommandType Function).ScriptBlock
}
if (Get-Command Get-CimInstance -CommandType Function -ErrorAction SilentlyContinue) {
  $originalFunctions['Get-CimInstance'] = (Get-Command Get-CimInstance -CommandType Function).ScriptBlock
} else {
  $createdFunctions += 'Get-CimInstance'
}

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
  'dreamskin-official-launch-' + [guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
try {
  function Get-DreamSkinCodexProcesses {
    param([object]$Codex)
    return @($mainProcess, $rendererProcess, $crashpadProcess)
  }
  function Get-DreamSkinProcessExecutablePath {
    param([object]$ProcessInfo)
    return "$($ProcessInfo.ExecutablePath)"
  }
  function Get-DreamSkinProcessStartedAt {
    param([int]$ProcessId)
    return $script:processStartTimes[$ProcessId]
  }
  function Get-DreamSkinPortListeners {
    param([int]$Port)
    return [pscustomobject]@{
      LocalAddress = '127.0.0.1'
      OwningProcess = $script:listenerOwnerId
    }
  }
  function Get-DreamSkinRegisteredCodexInstalls {
    return @($fakeCodex)
  }
  function Get-CimInstance {
    param([string]$ClassName, [string]$Filter)
    if ($Filter -match 'ProcessId = 100') { return $parentProcess }
    if ($Filter -match 'ProcessId = 501') { return $mainProcess }
    if ($Filter -match 'ProcessId = 502') { return $rendererProcess }
    if ($Filter -match 'ProcessId = 503') { return $crashpadProcess }
    return $null
  }

  $mainProcesses = @(Get-DreamSkinCodexMainProcesses -Codex $fakeCodex)
  if ($mainProcesses.Count -ne 1 -or $mainProcesses[0].ProcessId -ne 501) {
    throw 'The official launch observer did not exclude the Chromium renderer child.'
  }
  $mainRecord = Get-DreamSkinCodexMainProcessRecord -Codex $fakeCodex
  if ($null -eq $mainRecord -or $mainRecord.ProcessId -ne 501 -or
    $mainRecord.StartedAt -cne $script:processStartTimes[501]) {
    throw 'The official launch observer did not preserve the main PID and start time.'
  }
  if (-not (Test-DreamSkinCodexPortOwner -Port 9335 -Codex $fakeCodex)) {
    throw 'A verified listener owned by the main Codex process was rejected.'
  }
  $script:listenerOwnerId = 502
  if (Test-DreamSkinCodexPortOwner -Port 9335 -Codex $fakeCodex) {
    throw 'A listener owned by a renderer child was accepted as the Codex CDP owner.'
  }
  $script:listenerOwnerId = 501
  $resolvedTarget = Resolve-DreamSkinCodexInstallForTarget -PackageFullName $fakeCodex.PackageFullName -PackageFamilyName $fakeCodex.PackageFamilyName -PackageRoot $fakeCodex.PackageRoot
  if ($null -eq $resolvedTarget -or $resolvedTarget.PackageFullName -cne $fakeCodex.PackageFullName) {
    throw 'The exact official package identity was not resolved uniquely.'
  }

  $intent = New-DreamSkinLaunchIntent -StateRoot $temporaryRoot -Codex $fakeCodex `
    -Port 9335 -PreserveProcessIds @(501)
  $intentPath = Get-DreamSkinLaunchIntentPath -StateRoot $temporaryRoot
  $loadedIntent = Read-DreamSkinLaunchIntent -StateRoot $temporaryRoot
  if ($null -eq $loadedIntent -or "$($loadedIntent.token)" -cne "$($intent.token)" -or
    -not (Test-Path -LiteralPath $intentPath -PathType Leaf)) {
    throw 'The short-lived launch intent did not survive its strict round-trip.'
  }
  $candidate = [pscustomobject]@{ Codex = $fakeCodex; Process = $mainRecord }
  if (Test-DreamSkinLaunchIntentForCandidate -Intent $loadedIntent -Candidate $candidate -Port 9335) {
    throw 'A preserved pre-launch PID was incorrectly accepted as a managed launch candidate.'
  }
  $newProcess = $mainRecord.PSObject.Copy()
  $newProcess.ProcessId = 504
  $newProcess.StartedAt = '2026-10-02T03:00:00.0000000Z'
  $newCandidate = [pscustomobject]@{ Codex = $fakeCodex; Process = $newProcess }
  if (-not (Test-DreamSkinLaunchIntentForCandidate -Intent $loadedIntent -Candidate $newCandidate -Port 9335)) {
    throw 'A new process from the exact managed Store package was not accepted by the launch intent.'
  }
  if (-not (Remove-DreamSkinLaunchIntent -StateRoot $temporaryRoot -Token "$($intent.token)") -or
    (Test-Path -LiteralPath $intentPath)) {
    throw 'The short-lived launch intent was not removed by its token.'
  }

  $observed = @([pscustomobject]@{ Codex = $fakeCodex; Process = $mainRecord })
  $emptyObservation = Get-DreamSkinOfficialLaunchObservation -Baseline @{} -Observed $observed
  if ($emptyObservation.Candidates.Count -ne 1 -or $emptyObservation.Ambiguous) {
    throw 'A single new official main process was not recognized as an unambiguous candidate.'
  }
  $baseline = @{}
  $baseline[(ConvertTo-DreamSkinProcessIdentityKey -ProcessRecord $mainRecord)] = $observed[0]
  $sameObservation = Get-DreamSkinOfficialLaunchObservation -Baseline $baseline -Observed $observed
  if ($sameObservation.Candidates.Count -ne 0) {
    throw 'An unchanged official main process was treated as a new launch.'
  }

  $reusedPidRecord = $mainRecord.PSObject.Copy()
  $reusedPidRecord.StartedAt = '2026-10-02T02:00:00.0000000Z'
  $reusedObservation = Get-DreamSkinOfficialLaunchObservation -Baseline $baseline -Observed @([pscustomobject]@{ Codex = $fakeCodex; Process = $reusedPidRecord })
  if ($reusedObservation.Candidates.Count -ne 1 -or
    (Test-DreamSkinCodexProcessIdentity -Recorded $mainRecord -Current $reusedPidRecord)) {
    throw 'A reused PID with a different start time was not rejected as a new process identity.'
  }
  if (-not (Test-DreamSkinCodexProcessIdentity -Recorded $mainRecord -Current $mainRecord)) {
    throw 'An exact PID/start-time process identity was rejected.'
  }

  $secondCodex = $fakeCodex.PSObject.Copy()
  $secondCodex.PackageFullName = 'OpenAI.Codex_fixture_26.927.0.0_x64__test'
  $ambiguous = Get-DreamSkinOfficialLaunchObservation -Baseline @{} -Observed @(
    [pscustomobject]@{ Codex = $fakeCodex; Process = $mainRecord },
    [pscustomobject]@{ Codex = $secondCodex; Process = $reusedPidRecord }
  )
  if (-not $ambiguous.Ambiguous) {
    throw 'Simultaneous registered Codex package versions did not fail closed.'
  }

  $statePath = Join-Path $temporaryRoot 'state.json'
  $state = [pscustomobject]@{
    schemaVersion = 4
    platform = 'windows'
    port = 9335
    injectorPid = 1234
    injectorStartedAt = '2026-10-02T01:00:10.0000000Z'
    injectorPath = 'C:\Dream Skin\injector.mjs'
    nodePath = 'C:\Program Files\nodejs\node.exe'
    codexExe = $fakeCodex.Executable
    codexPackageRoot = $fakeCodex.PackageRoot
    codexPackageFullName = $fakeCodex.PackageFullName
    codexPackageFamilyName = $fakeCodex.PackageFamilyName
    browserId = 'browser-26-928'
    sessionId = '11111111-1111-4111-8111-111111111111'
    codexMainProcess = $mainRecord
    codexListenerProcess = [pscustomobject]@{
      ProcessId = 501
      StartedAt = $mainRecord.StartedAt
      Executable = $mainRecord.Executable
    }
    launchSource = 'official-auto'
    lastObservedAt = '2026-10-02T01:00:10.0000000Z'
    watcherStatus = 'running'
  }
  Write-DreamSkinState -Path $statePath -State $state
  $loaded = Read-DreamSkinState -Path $statePath
  if ($loaded.schemaVersion -ne 4 -or $loaded.launchSource -cne 'official-auto' -or
    $loaded.codexMainProcess.processId -ne 501) {
    throw 'Schema 4 session provenance did not survive the strict state round-trip.'
  }

  if (-not (Test-DreamSkinOfficialLaunchMonitorEnabled -StateRoot $temporaryRoot)) {
    throw 'The official launch monitor was disabled without a marker.'
  }
  Set-DreamSkinOfficialLaunchMonitorEnabled -Enabled $false -StateRoot $temporaryRoot
  if (Test-DreamSkinOfficialLaunchMonitorEnabled -StateRoot $temporaryRoot) {
    throw 'The command-line fallback did not persistently disable official launch takeover.'
  }
  Set-DreamSkinOfficialLaunchMonitorEnabled -Enabled $true -StateRoot $temporaryRoot
  if (-not (Test-DreamSkinOfficialLaunchMonitorEnabled -StateRoot $temporaryRoot)) {
    throw 'The command-line fallback did not re-enable official launch takeover.'
  }
  Set-DreamSkinDisabled -Disabled $true -StateRoot $temporaryRoot
  if (Test-DreamSkinOfficialLaunchMonitorState -StatePath $statePath -ThemeReady $true -Paused $false) {
    throw 'A restored-base-theme marker incorrectly allowed official launch takeover.'
  }
  Set-DreamSkinDisabled -Disabled $false -StateRoot $temporaryRoot
  Set-DreamSkinAutoStartDisabled -Disabled $true -StateRoot $temporaryRoot
  if (-not (Test-DreamSkinAutoStartDisabled -StateRoot $temporaryRoot)) {
    throw 'The disabled login-start preference was not persisted.'
  }
  Set-DreamSkinAutoStartDisabled -Disabled $false -StateRoot $temporaryRoot
  if (Test-DreamSkinAutoStartDisabled -StateRoot $temporaryRoot) {
    throw 'The login-start preference could not be re-enabled.'
  }

  Remove-Item -LiteralPath $statePath -Force
  if (-not (Test-DreamSkinOfficialLaunchMonitorState -StatePath $statePath -ThemeReady $true -Paused $false)) {
    throw 'A ready theme without a previous session state was incorrectly blocked.'
  }
  if (Test-DreamSkinOfficialLaunchMonitorState -StatePath $statePath -ThemeReady $false -Paused $false) {
    throw 'Official launch takeover was allowed without a ready theme.'
  }
  if (Test-DreamSkinOfficialLaunchMonitorState -StatePath $statePath -ThemeReady $true -Paused $true) {
    throw 'Official launch takeover was allowed while the theme was paused.'
  }

  $incompleteState = [pscustomobject]@{
    schemaVersion = 3
    platform = 'windows'
    port = 9335
  }
  Write-DreamSkinUtf8FileAtomically -Path $statePath -Content (($incompleteState | ConvertTo-Json -Depth 6) + "`r`n")
  if (Test-DreamSkinOfficialLaunchMonitorState -StatePath $statePath -ThemeReady $true -Paused $false) {
    throw 'An incomplete legacy state incorrectly allowed official launch takeover.'
  }

  $blockedState = $state.PSObject.Copy()
  $blockedState.watcherStatus = 'blocked'
  Write-DreamSkinState -Path $statePath -State $blockedState
  if (Test-DreamSkinOfficialLaunchMonitorState -StatePath $statePath -ThemeReady $true -Paused $false) {
    throw 'A blocked session state incorrectly allowed official launch takeover.'
  }
} finally {
  foreach ($functionName in $originalFunctions.Keys) {
    Set-Item ("function:$functionName") -Value $originalFunctions[$functionName]
  }
  foreach ($functionName in $createdFunctions) {
    Remove-Item ("function:$functionName") -ErrorAction SilentlyContinue
  }
  Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'PASS: official Codex launch monitoring is main-process-only, start-time-safe, schema-4-backed, and fail-closed.'
