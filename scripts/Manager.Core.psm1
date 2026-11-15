Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-XiaoAiContext {
    param([string]$PackageRoot)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    [pscustomobject]@{
        PackageRoot = [IO.Path]::GetFullPath($PackageRoot)
        InstallRoot = Join-Path $env:ProgramFiles 'XiaoAiKey'
        StateRoot = Join-Path $env:LOCALAPPDATA 'XiaoAiKey'
        PendingRoot = Join-Path $env:ProgramData 'XiaoAiKey\PendingRemoval'
        OwnerSid = $identity.User.Value
        UserName = $identity.Name
        TaskPath = '\XiaoAiKey\'
    }
}
function Test-XiaoAiAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Assert-XiaoAiPlainDirectory {
    param([Parameter(Mandatory)] [string]$Path)
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if (!$item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Not a regular directory: $Path" }
    }
}
function Resolve-XiaoAiTarget {
    param([Parameter(Mandatory)]$Settings)
    $required = @('ExecutablePath','Arguments','WorkingDirectory')
    foreach ($name in $required) {
        if ($null -eq $Settings.PSObject.Properties[$name] -or $null -eq $Settings.$name) { throw "Missing setting: $name" }
    }
    $exe = [Environment]::ExpandEnvironmentVariables([string]$Settings.ExecutablePath)
    $directory = [Environment]::ExpandEnvironmentVariables([string]$Settings.WorkingDirectory)
    $arguments = [Environment]::ExpandEnvironmentVariables([string]$Settings.Arguments)
    if ([string]::IsNullOrWhiteSpace($exe) -or ![IO.Path]::IsPathRooted($exe) -or !(Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Program or shortcut does not exist: $exe" }
    if ([IO.Path]::GetExtension($exe) -notin @('.exe','.com','.cmd','.bat','.lnk')) { throw 'Choose an executable, command script, or shortcut.' }
    if (![IO.Path]::IsPathRooted($directory) -or !(Test-Path -LiteralPath $directory -PathType Container)) { throw "Working directory does not exist: $directory" }
    [pscustomobject]@{ ExecutablePath = $exe; Arguments = $arguments; WorkingDirectory = $directory }
}
function Read-XiaoAiSettings {
    param([Parameter(Mandatory)] [string]$Path)
    $xml = New-Object Xml.XmlDocument
    $xml.XmlResolver = $null
    $xml.Load($Path)
    if (!$xml.DocumentElement -or $xml.DocumentElement.Name -ne 'XiaoAiKey') { throw 'Invalid settings root.' }
    $result = [ordered]@{}
    foreach ($name in @('ExecutablePath','Arguments','WorkingDirectory')) {
        $node = $xml.SelectSingleNode('/XiaoAiKey/' + $name)
        if (!$node) { throw "Missing setting: $name" }
        $result[$name] = $node.InnerText
    }
    [pscustomobject]$result
}
function Write-XiaoAiSettings {
    param([Parameter(Mandatory)] [string]$Path, [Parameter(Mandatory)]$Settings)
    $null = Resolve-XiaoAiTarget $Settings
    $xml = New-Object Xml.XmlDocument
    $root = $xml.CreateElement('XiaoAiKey')
    $null = $xml.AppendChild($root)
    foreach ($name in @('ExecutablePath','Arguments','WorkingDirectory')) {
        $node = $xml.CreateElement($name)
        $node.InnerText = [string]$Settings.$name
        $null = $root.AppendChild($node)
    }
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $writerSettings = New-Object Xml.XmlWriterSettings
        $writerSettings.Indent = $true
        $writerSettings.Encoding = New-Object Text.UTF8Encoding($false)
        $writer = [Xml.XmlWriter]::Create($temporary, $writerSettings)
        try { $xml.Save($writer) } finally { $writer.Dispose() }
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}
function Get-XiaoAiPayloadNames {
    @('KeyListener.exe','FilterController.exe','PromptFilter.dll','settings.xml')
}
function Test-XiaoAiPackage {
    param([Parameter(Mandatory)] [string]$PackageRoot)
    $manifest = Get-Content -LiteralPath (Join-Path $PackageRoot 'checksums.json') -Raw | ConvertFrom-Json
    foreach ($name in (Get-XiaoAiPayloadNames)) {
        $property = $manifest.PSObject.Properties[$name]
        if (!$property -or $property.Value -notmatch '^[0-9A-Fa-f]{64}$') { throw "Missing package hash: $name" }
        $file = Join-Path $PackageRoot ('bin\' + $name)
        if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $property.Value) { throw "Package checksum failed: $name" }
    }
    foreach ($name in @('Manage.ps1','Tui.cmd','scripts\Manager.Core.psm1','README.md')) {
        if (!(Test-Path -LiteralPath (Join-Path $PackageRoot $name) -PathType Leaf)) { throw "Missing manager file: $name" }
    }
}
function Get-XiaoAiOwnedFiles {
    @('KeyListener.exe','FilterController.exe','PromptFilter.dll','settings.xml','installation.json','Manage.ps1','Tui.cmd','README.md','scripts\Manager.Core.psm1')
}
function Assert-XiaoAiOwnedInstallation {
    param([Parameter(Mandatory)]$Context)
    Assert-XiaoAiPlainDirectory $Context.InstallRoot
    $manifestPath = Join-Path $Context.InstallRoot 'installation.json'
    if (!(Test-Path -LiteralPath $manifestPath)) { throw 'This directory is not managed by this installer. It has not been changed.' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.Product -ne 'XiaoAiKey' -or $manifest.Schema -ne 1 -or $manifest.OwnerSid -ne $Context.OwnerSid) { throw 'Installation belongs to another owner or uses an unsupported format.' }
    $allowedFiles = Get-XiaoAiOwnedFiles
    foreach ($item in (Get-ChildItem -LiteralPath $Context.InstallRoot -Recurse -Force)) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse points are not allowed inside the installation.' }
        $relative = $item.FullName.Substring($Context.InstallRoot.Length + 1)
        if ($item.PSIsContainer) {
            if ($relative -ne 'scripts') { throw "Unexpected installation directory: $relative" }
        } elseif ($relative -notin $allowedFiles) { throw "Unexpected installation file: $relative" }
    }
}
function Get-XiaoAiTask {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)] [string]$Name)
    Get-ScheduledTask -TaskPath $Context.TaskPath -TaskName $Name -ErrorAction SilentlyContinue
}
function Assert-XiaoAiTaskOwnership {
    param([Parameter(Mandatory)]$Context)
    $expected = @{ KeyListener='KeyListener.exe'; PromptFilter='FilterController.exe' }
    foreach ($name in $expected.Keys) {
        $task = Get-XiaoAiTask $Context $name
        if (!$task) { continue }
        if (@($task.Actions).Count -ne 1 -or $task.Actions[0].Execute -ne (Join-Path $Context.InstallRoot $expected[$name])) { throw "Task is not owned by this installation: $name" }
        $account = New-Object Security.Principal.NTAccount($task.Principal.UserId)
        try { $sid = $account.Translate([Security.Principal.SecurityIdentifier]).Value }
        catch { $sid = [string]$task.Principal.UserId }
        if ($sid -ne $Context.OwnerSid) { throw "Task belongs to another account: $name" }
    }
}
function Stop-XiaoAiTasks {
    param([Parameter(Mandatory)]$Context)
    Assert-XiaoAiTaskOwnership $Context
    foreach ($name in @('KeyListener','PromptFilter')) {
        $task = Get-XiaoAiTask $Context $name
        if ($task) { Stop-ScheduledTask -TaskPath $Context.TaskPath -TaskName $name }
    }
    for ($i=0; $i -lt 50; $i++) {
        $running = @(@('KeyListener','PromptFilter') | ForEach-Object { Get-XiaoAiTask $Context $_ } | Where-Object { $_.State -eq 'Running' })
        if (!$running.Count) { return }
        Start-Sleep -Milliseconds 100
    }
    throw 'The scheduled tasks did not stop.'
}
function Get-XiaoAiStatus {
    param([Parameter(Mandatory)]$Context)
    $listener = Get-XiaoAiTask $Context 'KeyListener'
    $filter = Get-XiaoAiTask $Context 'PromptFilter'
    $settings = $null
    $path = Join-Path $Context.InstallRoot 'settings.xml'
    $configurationError = $null
    if (Test-Path -LiteralPath $path) {
        try { $settings = Read-XiaoAiSettings $path } catch { $configurationError = $_.Exception.Message }
    }
    [pscustomobject]@{
        Installed = Test-Path -LiteralPath (Join-Path $Context.InstallRoot 'installation.json')
        ManagedDirectory = $Context.InstallRoot
        Listener = if ($listener) { [string]$listener.State } else { 'Not installed' }
        Filter = if ($filter) { [string]$filter.State } else { 'Not installed' }
        Ready = [bool]($filter -and $filter.State -eq 'Running' -and (Test-Path -LiteralPath (Join-Path $Context.StateRoot 'ready.txt')))
        Settings = $settings
        ConfigurationError = $configurationError
    }
}
function Test-XiaoAiHardware {
    try { $null = Get-CimClass -Namespace 'root/WMI' -ClassName 'HID_EVENT20' -ErrorAction Stop }
    catch { throw 'The Xiaomi HID_EVENT20 event source is unavailable. No installation was performed.' }
}
function Initialize-XiaoAiTaskFolder {
    param($Context)
    $scheduler = New-Object -ComObject 'Schedule.Service'
    $scheduler.Connect()
    try { $null = $scheduler.GetFolder($Context.TaskPath) }
    catch { $null = $scheduler.GetFolder('\').CreateFolder('XiaoAiKey') }
}
function Remove-XiaoAiTaskFolder {
    param($Context)
    try {
        $scheduler = New-Object -ComObject 'Schedule.Service'
        $scheduler.Connect()
        $scheduler.GetFolder('\').DeleteFolder('XiaoAiKey',0)
    } catch { }
}
function Wait-XiaoAiTaskStopped {
    param($Context,[string]$Name)
    for ($i=0; $i -lt 50; $i++) {
        $task = Get-XiaoAiTask $Context $Name
        if (!$task -or $task.State -ne 'Running') { return }
        Start-Sleep -Milliseconds 100
    }
    throw ('Task did not stop: ' + $Name)
}
function Install-XiaoAiKey {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Settings)
    $null = Resolve-XiaoAiTarget $Settings
    Assert-XiaoAiPlainDirectory $Context.InstallRoot
    if (Test-Path -LiteralPath $Context.InstallRoot) { throw 'Already installed, or an existing directory needs manual review. Use Configure or Uninstall.' }
    Test-XiaoAiPackage $Context.PackageRoot
    Test-XiaoAiHardware
    foreach ($name in @('KeyListener','PromptFilter')) { if (Get-XiaoAiTask $Context $name) { throw "A task already exists: $name" } }
    $created = @()
    try {
        $null = New-Item -ItemType Directory -Path $Context.InstallRoot
        $null = New-Item -ItemType Directory -Path (Join-Path $Context.InstallRoot 'scripts')
        foreach ($name in (Get-XiaoAiPayloadNames | Where-Object { $_ -ne 'settings.xml' })) {
            $sourceFile = Join-Path $Context.PackageRoot ('bin\' + $name)
            $installedFile = Join-Path $Context.InstallRoot $name
            Copy-Item -LiteralPath $sourceFile -Destination $installedFile
            if ((Get-FileHash -LiteralPath $sourceFile).Hash -ne (Get-FileHash -LiteralPath $installedFile).Hash) { throw ('Copy verification failed: ' + $name) }
        }
        foreach ($name in @('Manage.ps1','Tui.cmd','README.md','scripts\Manager.Core.psm1')) {
            Copy-Item -LiteralPath (Join-Path $Context.PackageRoot $name) -Destination (Join-Path $Context.InstallRoot $name)
        }
        Write-XiaoAiSettings (Join-Path $Context.InstallRoot 'settings.xml') $Settings
        [ordered]@{Product='XiaoAiKey';Schema=1;Version='0.2.0';OwnerSid=$Context.OwnerSid;Installed=(Get-Date -Format s)} |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Context.InstallRoot 'installation.json') -Encoding UTF8
        Initialize-XiaoAiTaskFolder $Context
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $Context.UserName
        $trigger.Delay = 'PT5S'
        $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([timespan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
        foreach ($name in @('PromptFilter','KeyListener')) {
            $exe = if ($name -eq 'KeyListener') { 'KeyListener.exe' } else { 'FilterController.exe' }
            $level = if ($name -eq 'KeyListener') { 'Limited' } else { 'Highest' }
            $action = New-ScheduledTaskAction -Execute (Join-Path $Context.InstallRoot $exe) -Argument '--run' -WorkingDirectory $Context.InstallRoot
            $principal = New-ScheduledTaskPrincipal -UserId $Context.UserName -LogonType Interactive -RunLevel $level
            $null = Register-ScheduledTask -TaskPath $Context.TaskPath -TaskName $name -Action $action -Principal $principal -Trigger $trigger -Settings $taskSettings -Description ('XiaoAiKey ' + $name)
            $created += $name
        }
        $readyPath = Join-Path $Context.StateRoot 'ready.txt'
        if (Test-Path -LiteralPath $readyPath) { Remove-Item -LiteralPath $readyPath -Force }
        Start-ScheduledTask -TaskPath $Context.TaskPath -TaskName 'PromptFilter'
        Start-ScheduledTask -TaskPath $Context.TaskPath -TaskName 'KeyListener'
        [pscustomobject]@{Message='Installed. The filter may still be waiting for a supported Xiaomi process.';PendingRemoval=$null}
    } catch {
        foreach ($name in $created) {
            Stop-ScheduledTask -TaskPath $Context.TaskPath -TaskName $name -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskPath $Context.TaskPath -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
        }
        # Retain a partially installed directory for review instead of deleting unknown files.
        throw
    }
}
function Set-XiaoAiTarget {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Settings)
    Assert-XiaoAiOwnedInstallation $Context
    Assert-XiaoAiTaskOwnership $Context
    $null = Resolve-XiaoAiTarget $Settings
    $path = Join-Path $Context.InstallRoot 'settings.xml'
    $previous = Read-XiaoAiSettings $path
    $task = Get-XiaoAiTask $Context 'KeyListener'
    $wasRunning = $task -and $task.State -eq 'Running'
    try {
        if ($task) {
            Stop-ScheduledTask -TaskPath $Context.TaskPath -TaskName 'KeyListener'
            Wait-XiaoAiTaskStopped $Context 'KeyListener'
        }
        Write-XiaoAiSettings $path $Settings
        if ($wasRunning) {
            Start-ScheduledTask -TaskPath $Context.TaskPath -TaskName 'KeyListener'
            Start-Sleep -Milliseconds 500
            if ((Get-XiaoAiTask $Context 'KeyListener').State -ne 'Running') { throw 'The listener could not load the new settings.' }
        }
    } catch {
        Write-XiaoAiSettings $path $previous
        if ($wasRunning) { Start-ScheduledTask -TaskPath $Context.TaskPath -TaskName 'KeyListener' }
        throw
    }
    [pscustomobject]@{Message='Target updated. The prompt filter was left running.';PendingRemoval=$null}
}
function Remove-XiaoAiOwnedFiles {
    param([Parameter(Mandatory)]$Context)
    Assert-XiaoAiOwnedInstallation $Context
    $locked = @()
    foreach ($name in (Get-XiaoAiOwnedFiles | Where-Object { $_ -ne 'installation.json' })) {
        $path = Join-Path $Context.InstallRoot $name
        if (Test-Path -LiteralPath $path) {
            try { Remove-Item -LiteralPath $path -Force -ErrorAction Stop } catch { $locked += $name }
        }
    }
    $scripts = Join-Path $Context.InstallRoot 'scripts'
    if (Test-Path -LiteralPath $scripts) {
        if (@(Get-ChildItem -LiteralPath $scripts -Force).Count -eq 0) { Remove-Item -LiteralPath $scripts -Force }
    }
    if (!$locked.Count) {
        Remove-Item -LiteralPath (Join-Path $Context.InstallRoot 'installation.json') -Force
        Remove-Item -LiteralPath $Context.InstallRoot -Force
    }
    $locked
}
function Uninstall-XiaoAiKey {
    param([Parameter(Mandatory)]$Context)
    Assert-XiaoAiOwnedInstallation $Context
    $backups = @{}
    foreach ($name in @('KeyListener','PromptFilter')) {
        if (Get-XiaoAiTask $Context $name) { $backups[$name] = Export-ScheduledTask -TaskPath $Context.TaskPath -TaskName $name }
    }
    Stop-XiaoAiTasks $Context
    Assert-XiaoAiPlainDirectory $Context.PendingRoot
    $null = New-Item -ItemType Directory -Path $Context.PendingRoot -Force
    $pending = Join-Path $Context.PendingRoot ([guid]::NewGuid().ToString('N'))
    $sourcePath = [IO.Path]::GetFullPath($Context.InstallRoot)
    $pendingPath = [IO.Path]::GetFullPath($pending)
    if ($sourcePath -ne (Join-Path $env:ProgramFiles 'XiaoAiKey') -or !$pendingPath.StartsWith([IO.Path]::GetFullPath($Context.PendingRoot) + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected uninstall paths.' }
    Move-Item -LiteralPath $sourcePath -Destination $pendingPath
    try {
        foreach ($name in @('KeyListener','PromptFilter')) {
            if (Get-XiaoAiTask $Context $name) { Unregister-ScheduledTask -TaskPath $Context.TaskPath -TaskName $name -Confirm:$false }
        }
    } catch {
        Move-Item -LiteralPath $pendingPath -Destination $sourcePath
        foreach ($name in $backups.Keys) {
            if (!(Get-XiaoAiTask $Context $name)) { $null = Register-ScheduledTask -TaskPath $Context.TaskPath -TaskName $name -Xml $backups[$name] }
        }
        throw
    }
    $ready = Join-Path $Context.StateRoot 'ready.txt'
    if (Test-Path -LiteralPath $ready) { Remove-Item -LiteralPath $ready -Force }
    Remove-XiaoAiTaskFolder $Context
    $copy = $Context.PSObject.Copy()
    $copy.InstallRoot = $pendingPath
    $locked = @(Remove-XiaoAiOwnedFiles $copy)
    [pscustomobject]@{Message='Tasks removed and OEM behavior restored. Logs were retained.';PendingRemoval=if($locked.Count){$pendingPath}else{$null}}
}
function Clear-XiaoAiPendingRemoval {
    param([Parameter(Mandatory)]$Context)
    if (!(Test-Path -LiteralPath $Context.PendingRoot)) { return [pscustomobject]@{Message='No pending files.';PendingRemoval=$null} }
    Assert-XiaoAiPlainDirectory $Context.PendingRoot
    $remaining = @()
    foreach ($directory in (Get-ChildItem -LiteralPath $Context.PendingRoot -Directory)) {
        if ($directory.Name -notmatch '^[a-f0-9]{32}$') { continue }
        $copy = $Context.PSObject.Copy()
        $copy.InstallRoot = $directory.FullName
        try { if (@(Remove-XiaoAiOwnedFiles $copy).Count) { $remaining += $directory.FullName } }
        catch { $remaining += $directory.FullName }
    }
    [pscustomobject]@{Message='Pending-file cleanup completed.';PendingRemoval=($remaining -join ', ')}
}
Export-ModuleMember -Function *-XiaoAi*
