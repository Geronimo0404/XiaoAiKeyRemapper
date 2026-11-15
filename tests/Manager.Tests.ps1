$modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\Manager.Core.psm1'
Import-Module $modulePath -Force
InModuleScope Manager.Core {
    Describe 'XiaoAiKey target settings' {
        BeforeEach {
            $script:settings = [pscustomobject]@{
                ExecutablePath = $env:ComSpec
                Arguments = '/d /c echo "a & b"'
                WorkingDirectory = $TestDrive
            }
            $script:configuration = Join-Path $TestDrive 'settings.xml'
        }
        It 'round-trips XML special characters without treating arguments as commands' {
            Write-XiaoAiSettings $configuration $settings
            $read = Read-XiaoAiSettings $configuration
            $read.Arguments | Should -Be $settings.Arguments
            $read.ExecutablePath | Should -Be $settings.ExecutablePath
        }
        It 'expands environment variables at validation time' {
            $settings.ExecutablePath = '%ComSpec%'
            (Resolve-XiaoAiTarget $settings).ExecutablePath | Should -Be $env:ComSpec
        }
        It 'accepts a shortcut and a directory containing spaces' {
            $shortcut = Join-Path $TestDrive 'test shortcut.lnk'
            Set-Content -LiteralPath $shortcut -Value 'fixture'
            $settings.ExecutablePath = $shortcut
            (Resolve-XiaoAiTarget $settings).ExecutablePath | Should -Be $shortcut
        }
        It 'rejects a missing executable before replacing a valid configuration' {
            Write-XiaoAiSettings $configuration $settings
            $before = Get-Content -LiteralPath $configuration -Raw
            $settings.ExecutablePath = Join-Path $TestDrive 'does-not-exist.exe'
            { Write-XiaoAiSettings $configuration $settings } | Should -Throw
            (Get-Content -LiteralPath $configuration -Raw) | Should -Be $before
        }
        It 'rejects a missing working directory and a non-program file' {
            $settings.WorkingDirectory = Join-Path $TestDrive 'missing'
            { Resolve-XiaoAiTarget $settings } | Should -Throw
            $settings.WorkingDirectory = $TestDrive
            $file = Join-Path $TestDrive 'notes.txt'
            Set-Content -LiteralPath $file -Value 'not a program'
            $settings.ExecutablePath = $file
            { Resolve-XiaoAiTarget $settings } | Should -Throw
        }
        It 'rejects an invalid XML root' {
            Set-Content -LiteralPath $configuration -Value '<Other/>'
            { Read-XiaoAiSettings $configuration } | Should -Throw
        }
    }
    Describe 'XiaoAiKey installation lifecycle' {
        BeforeEach {
            $script:oldProgramFiles = $env:ProgramFiles
            $env:ProgramFiles = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $env:ProgramFiles
            $package = Join-Path $TestDrive ('package-' + [guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path (Join-Path $package 'bin'),(Join-Path $package 'scripts')
            $script:ctx = [pscustomobject]@{
                PackageRoot=$package
                InstallRoot=(Join-Path $env:ProgramFiles 'XiaoAiKey')
                StateRoot=(Join-Path $TestDrive 'state')
                PendingRoot=(Join-Path $TestDrive 'pending')
                OwnerSid=([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
                UserName=([Security.Principal.WindowsIdentity]::GetCurrent().Name)
                TaskPath='\XiaoAiKey\'
            }
            $script:target = [pscustomobject]@{ExecutablePath=$env:ComSpec;Arguments='';WorkingDirectory=$TestDrive}
            foreach ($name in @('KeyListener.exe','FilterController.exe','PromptFilter.dll')) {
                Set-Content -LiteralPath (Join-Path $package ('bin\' + $name)) -Value 'fixture binary'
            }
            Write-XiaoAiSettings (Join-Path $package 'bin\settings.xml') $target
            foreach ($name in @('Manage.ps1','Tui.cmd','README.md','scripts\Manager.Core.psm1')) {
                Set-Content -LiteralPath (Join-Path $package $name) -Value 'fixture'
            }
            $hashes = @{}
            foreach ($name in (Get-XiaoAiPayloadNames)) { $hashes[$name]=(Get-FileHash -LiteralPath (Join-Path $package ('bin\' + $name))).Hash }
            $hashes | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $package 'checksums.json')
            $script:tasks = @{}
            $script:failRegister = $false
            Mock Test-XiaoAiHardware { }
            Mock Initialize-XiaoAiTaskFolder { }
            Mock Remove-XiaoAiTaskFolder { }
            Mock Start-Sleep { }
            Mock Get-ScheduledTask {
                foreach ($name in @($TaskName)) {
                    if ($script:tasks.ContainsKey([string]$name)) { $script:tasks[[string]$name] }
                }
            }
            Mock Register-ScheduledTask {
                if ($script:failRegister -and $TaskName -eq 'KeyListener') { throw 'fixture registration failure' }
                $script:tasks[[string]@($TaskName)[0]] = [pscustomobject]@{
                    State='Ready'
                    Actions=@($Action)
                    Principal=$Principal
                }
            }
            Mock Start-ScheduledTask { $script:tasks[[string]@($TaskName)[0]].State='Running' }
            Mock Stop-ScheduledTask { $script:tasks[[string]@($TaskName)[0]].State='Ready' }
            Mock Unregister-ScheduledTask { $script:tasks.Remove([string]@($TaskName)[0]) }
            Mock Export-ScheduledTask { '<Task/>' }
        }
        AfterEach { $env:ProgramFiles = $script:oldProgramFiles }

        It 'installs exactly two interactive tasks with separate privilege levels' {
            $null = Install-XiaoAiKey $ctx $target
            $tasks.Count | Should -Be 2
            [int]$tasks['KeyListener'].Principal.RunLevel | Should -Be 0
            [int]$tasks['PromptFilter'].Principal.RunLevel | Should -Be 1
            [int]$tasks['KeyListener'].Principal.LogonType | Should -Be 3
            (Read-XiaoAiSettings (Join-Path $ctx.InstallRoot 'settings.xml')).ExecutablePath | Should -Be $env:ComSpec
            Test-Path -LiteralPath (Join-Path $ctx.InstallRoot 'installation.json') | Should -BeTrue
        }
        It 'does not install a package with a modified binary' {
            Add-Content -LiteralPath (Join-Path $ctx.PackageRoot 'bin\PromptFilter.dll') -Value 'tampered'
            { Install-XiaoAiKey $ctx $target } | Should -Throw '*checksum*'
            Test-Path -LiteralPath $ctx.InstallRoot | Should -BeFalse
            Should -Invoke Register-ScheduledTask -Times 0
        }
        It 'rejects unsupported hardware before creating a directory or task' {
            Mock Test-XiaoAiHardware { throw 'unsupported hardware' }
            { Install-XiaoAiKey $ctx $target } | Should -Throw '*unsupported*'
            Test-Path -LiteralPath $ctx.InstallRoot | Should -BeFalse
            Should -Invoke Register-ScheduledTask -Times 0
        }
        It 'refuses to overwrite an existing installation directory' {
            $null = New-Item -ItemType Directory -Path $ctx.InstallRoot
            Set-Content -LiteralPath (Join-Path $ctx.InstallRoot 'keep.txt') -Value 'user content'
            { Install-XiaoAiKey $ctx $target } | Should -Throw '*existing directory*'
            Get-Content -LiteralPath (Join-Path $ctx.InstallRoot 'keep.txt') | Should -Be 'user content'
        }
        It 'removes created tasks after a registration failure' {
            $script:failRegister=$true
            { Install-XiaoAiKey $ctx $target } | Should -Throw '*registration failure*'
            $tasks.Count | Should -Be 0
            Should -Invoke Unregister-ScheduledTask -Times 1
        }
        It 'changes the target and restarts only the listener' {
            $null = Install-XiaoAiKey $ctx $target
            $target.Arguments='/d /c echo configured'
            $null = Set-XiaoAiTarget $ctx $target
            (Read-XiaoAiSettings (Join-Path $ctx.InstallRoot 'settings.xml')).Arguments | Should -Be $target.Arguments
            Should -Invoke Stop-ScheduledTask -ParameterFilter {$TaskName -eq 'PromptFilter'} -Times 0
            Should -Invoke Stop-ScheduledTask -ParameterFilter {$TaskName -eq 'KeyListener'} -Times 1
            $tasks['PromptFilter'].State | Should -Be 'Running'
        }
        It 'retains the old settings when the requested target is invalid' {
            $null = Install-XiaoAiKey $ctx $target
            $target.ExecutablePath=Join-Path $TestDrive 'missing.exe'
            { Set-XiaoAiTarget $ctx $target } | Should -Throw
            (Read-XiaoAiSettings (Join-Path $ctx.InstallRoot 'settings.xml')).ExecutablePath | Should -Be $env:ComSpec
            Should -Invoke Stop-ScheduledTask -Times 0
        }
        It 'uninstalls its files and tasks while retaining logs and unrelated files' {
            $null = Install-XiaoAiKey $ctx $target
            $null = New-Item -ItemType Directory -Path $ctx.StateRoot -Force
            Set-Content -LiteralPath (Join-Path $ctx.StateRoot 'listener.log') -Value 'history'
            $unrelated=Join-Path $TestDrive 'unrelated.txt'
            Set-Content -LiteralPath $unrelated -Value 'keep'
            $result=Uninstall-XiaoAiKey $ctx
            $tasks.Count | Should -Be 0
            Test-Path -LiteralPath $ctx.InstallRoot | Should -BeFalse
            Test-Path -LiteralPath $unrelated | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $ctx.StateRoot 'listener.log') | Should -BeTrue
            $result.PendingRemoval | Should -BeNullOrEmpty
        }
        It 'leaves an occupied DLL and its ownership manifest for later cleanup' {
            $null = Install-XiaoAiKey $ctx $target
            Mock Remove-Item { throw 'file in use' } -ParameterFilter {$LiteralPath -like '*PromptFilter.dll'}
            $result=Uninstall-XiaoAiKey $ctx
            $result.PendingRemoval | Should -Not -BeNullOrEmpty
            Test-Path -LiteralPath (Join-Path $result.PendingRemoval 'PromptFilter.dll') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $result.PendingRemoval 'installation.json') | Should -BeTrue
            $tasks.Count | Should -Be 0
        }
        It 'refuses to delete an unexpected file inside the installation' {
            $null = Install-XiaoAiKey $ctx $target
            $file=Join-Path $ctx.InstallRoot 'personal.txt'
            Set-Content -LiteralPath $file -Value 'keep'
            { Uninstall-XiaoAiKey $ctx } | Should -Throw '*Unexpected installation file*'
            Get-Content -LiteralPath $file | Should -Be 'keep'
            Should -Invoke Stop-ScheduledTask -Times 0
        }
        It 'reports malformed installed settings without hiding task status' {
            $null = Install-XiaoAiKey $ctx $target
            Set-Content -LiteralPath (Join-Path $ctx.InstallRoot 'settings.xml') -Value '<broken'
            $status=Get-XiaoAiStatus $ctx
            $status.Listener | Should -Be 'Running'
            $status.ConfigurationError | Should -Not -BeNullOrEmpty
        }
    }
}
