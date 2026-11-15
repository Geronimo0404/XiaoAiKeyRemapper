[CmdletBinding()]
param(
    [ValidateSet('Menu','Status','Install','Configure','Uninstall','Cleanup','Test')]
    [string]$Action = 'Menu',
    [string]$TargetPath,
    [AllowEmptyString()][string]$TargetArguments = '',
    [string]$WorkingDirectory = '%USERPROFILE%',
    [ValidateSet('Install','Configure','Uninstall','Cleanup')]
    [string]$InternalAction,
    [string]$RequestFile,
    [string]$ExpectedSid
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'scripts\Manager.Core.psm1') -Force
$context = Get-XiaoAiContext $PSScriptRoot

function Invoke-ManagerOperation {
    param([string]$Operation, $Settings)
    $requestRoot = Join-Path ([IO.Path]::GetTempPath()) 'XiaoAiKey'
    Assert-XiaoAiPlainDirectory $requestRoot
    $null = New-Item -ItemType Directory -Path $requestRoot -Force
    $requestPath = Join-Path $requestRoot ('request-' + [guid]::NewGuid().ToString('N') + '.json')
    $resultPath = $requestPath + '.result.json'
    [ordered]@{Operation=$Operation;OwnerSid=$context.OwnerSid;Settings=$Settings} |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $requestPath -Encoding UTF8
    try {
        $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -InternalAction ' + $Operation + ' -RequestFile "' + $requestPath + '" -ExpectedSid ' + $context.OwnerSid
        $process = Start-Process -FilePath $powershell -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -Wait -PassThru
        if (!(Test-Path -LiteralPath $resultPath)) { throw 'The administrator operation did not return a result. The UAC request may have been cancelled.' }
        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        if (!$result.Success) { throw $result.Error }
        $result.Data
    } finally {
        foreach ($path in @($requestPath,$resultPath)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        }
    }
}
if ($InternalAction) {
    $resultPath = $null
    try {
        if (!(Test-XiaoAiAdministrator) -or $ExpectedSid -ne $context.OwnerSid) { throw 'Approve administrator access for the same Windows account.' }
        $requestRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'XiaoAiKey'))
        $fullRequest = [IO.Path]::GetFullPath($RequestFile)
        if ([IO.Path]::GetDirectoryName($fullRequest) -ne $requestRoot -or [IO.Path]::GetFileName($fullRequest) -notmatch '^request-[a-f0-9]{32}\.json$') { throw 'Unexpected request path.' }
        Assert-XiaoAiPlainDirectory $requestRoot
        $resultPath = $fullRequest + '.result.json'
        $request = Get-Content -LiteralPath $fullRequest -Raw | ConvertFrom-Json
        if ($request.Operation -ne $InternalAction -or $request.OwnerSid -ne $context.OwnerSid) { throw 'Request identity does not match.' }
        $data = switch ($InternalAction) {
            'Install' { Install-XiaoAiKey $context $request.Settings }
            'Configure' { Set-XiaoAiTarget $context $request.Settings }
            'Uninstall' { Uninstall-XiaoAiKey $context }
            'Cleanup' { Clear-XiaoAiPendingRemoval $context }
        }
        @{Success=$true;Data=$data} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $resultPath -Encoding UTF8
        exit 0
    } catch {
        if ($resultPath) { @{Success=$false;Error=$_.Exception.Message} | ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding UTF8 }
        exit 1
    }
}
if ((Test-XiaoAiAdministrator) -and $Action -ne 'Status') { throw 'Open this manager from a normal terminal. Installation will request administrator approval when needed.' }

function Get-CurrentTarget {
    $installed = Join-Path $context.InstallRoot 'settings.xml'
    if (Test-Path -LiteralPath $installed) {
        try { return Read-XiaoAiSettings $installed } catch { }
    }
    $template = Join-Path $PSScriptRoot 'bin\settings.xml'
    if (Test-Path -LiteralPath $template) { return Read-XiaoAiSettings $template }
    [pscustomobject]@{ExecutablePath='%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe';Arguments='';WorkingDirectory='%USERPROFILE%'}
}
function Read-Target {
    Write-Host ''
    Write-Host '1  Windows PowerShell（系统自带，默认目标）'
    Write-Host '2  Windows Terminal 中的 Git Bash（需先在终端中配置同名配置文件）'
    Write-Host '3  Windows Terminal 默认配置'
    Write-Host '4  自定义程序或快捷方式'
    Write-Host '0  返回'
    $choice = Read-Host '选择启动目标'
    switch ($choice) {
        '1' { $settings = [pscustomobject]@{ExecutablePath='%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe';Arguments='';WorkingDirectory='%USERPROFILE%'} }
        '2' { $settings = [pscustomobject]@{ExecutablePath='%LOCALAPPDATA%\Microsoft\WindowsApps\wt.exe';Arguments='-w new new-tab -p "Git Bash" -d "%USERPROFILE%"';WorkingDirectory='%USERPROFILE%'} }
        '3' { $settings = [pscustomobject]@{ExecutablePath='%LOCALAPPDATA%\Microsoft\WindowsApps\wt.exe';Arguments='-w new';WorkingDirectory='%USERPROFILE%'} }
        '4' {
            $path = (Read-Host '程序或 .lnk 快捷方式的完整路径').Trim().Trim('"')
            $arguments = Read-Host '启动参数（可以留空）'
            $directory = Read-Host '起始目录（留空为用户主目录）'
            if ([string]::IsNullOrWhiteSpace($directory)) { $directory = '%USERPROFILE%' }
            $settings = [pscustomobject]@{ExecutablePath=$path;Arguments=$arguments;WorkingDirectory=$directory.Trim().Trim('"')}
        }
        default { return $null }
    }
    $null = Resolve-XiaoAiTarget $settings
    $settings
}
function Show-Status {
    $status = Get-XiaoAiStatus $context
    Write-Host ('监听器：' + $status.Listener)
    Write-Host ('下载提示拦截：' + $status.Filter)
    Write-Host ('拦截已就绪：' + $status.Ready)
    if ($status.Settings) {
        Write-Host ('启动程序：' + $status.Settings.ExecutablePath)
        Write-Host ('参数：' + $status.Settings.Arguments)
        Write-Host ('起始目录：' + $status.Settings.WorkingDirectory)
    }
    if ($status.ConfigurationError) { Write-Host ('配置错误：' + $status.ConfigurationError) -ForegroundColor Red }
    Write-Host ('运行日志：' + $context.StateRoot)
}
function Test-Target {
    param($Settings)
    $resolved = Resolve-XiaoAiTarget $Settings
    $parameters = @{FilePath=$resolved.ExecutablePath;WorkingDirectory=$resolved.WorkingDirectory}
    if ($resolved.Arguments.Length) { $parameters.ArgumentList = $resolved.Arguments }
    $null = Start-Process @parameters
    Write-Host '已按普通用户权限发起启动。本次测试不模拟物理按键。'
}
function Show-Result {
    param($Result)
    Write-Host $Result.Message
    if ($Result.PendingRemoval) { Write-Host ('仍被使用的文件保留在：' + $Result.PendingRemoval + '。重启后可选择“清理卸载残余”。') }
}
if ($Action -ne 'Menu') {
    if ($Action -eq 'Status') { Get-XiaoAiStatus $context | ConvertTo-Json -Depth 4; exit 0 }
    $settings = $null
    if ($Action -in @('Install','Configure','Test')) {
        $settings = if ($TargetPath) { [pscustomobject]@{ExecutablePath=$TargetPath;Arguments=$TargetArguments;WorkingDirectory=$WorkingDirectory} } else { Get-CurrentTarget }
        $null = Resolve-XiaoAiTarget $settings
    }
    if ($Action -eq 'Test') { Test-Target $settings } else { Show-Result (Invoke-ManagerOperation $Action $settings) }
    exit 0
}
$selection = Get-CurrentTarget
while ($true) {
    Clear-Host
    Write-Host 'XiaoAiKey  /  小爱键启动目标'
    Write-Host '---------------------------'
    Show-Status
    Write-Host ''
    Write-Host '1  选择启动目标（尚未保存）'
    Write-Host '2  测试所选目标'
    Write-Host '3  安装并设置登录启动'
    Write-Host '4  保存到已安装配置'
    Write-Host '5  卸载并恢复原厂行为'
    Write-Host '6  查看运行日志末尾'
    Write-Host '7  清理卸载残余'
    Write-Host '0  退出'
    Write-Host ('当前选择：' + $selection.ExecutablePath + ' ' + $selection.Arguments)
    $choice = Read-Host '选择'
    if ($choice -eq '0') { break }
    try {
        switch ($choice) {
            '1' { $newTarget = Read-Target; if ($newTarget) { $selection = $newTarget } }
            '2' { Test-Target $selection }
            '3' { Show-Result (Invoke-ManagerOperation 'Install' $selection) }
            '4' { Show-Result (Invoke-ManagerOperation 'Configure' $selection) }
            '5' {
                if ((Read-Host '卸载会移除本程序的登录任务。输入 Y 确认') -eq 'Y') { Show-Result (Invoke-ManagerOperation 'Uninstall' $null) }
            }
            '6' {
                foreach ($name in @('listener.log','controller.log')) {
                    Write-Host ('--- ' + $name + ' ---')
                    $path = Join-Path $context.StateRoot $name
                    if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Tail 12 -Encoding UTF8 } else { Write-Host '暂无日志' }
                }
            }
            '7' { Show-Result (Invoke-ManagerOperation 'Cleanup' $null) }
        }
    } catch { Write-Host ('操作失败：' + $_.Exception.Message) -ForegroundColor Red }
    $null = Read-Host '按回车返回菜单'
}
