param([string]$GccPath)
$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot 'src'
$bin=Join-Path $PSScriptRoot 'bin'
$csc=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if(!$GccPath){
 $compiler=Get-Command gcc.exe -ErrorAction SilentlyContinue
 if(!$compiler){throw 'Add 64-bit MinGW GCC to PATH or pass -GccPath.'}
 $GccPath=$compiler.Source
}
$gcc=(Get-Item -LiteralPath $GccPath -ErrorAction Stop).FullName
$env:PATH=(Split-Path $gcc -Parent)+';'+$env:PATH
& $csc /nologo /optimize+ /target:winexe /r:System.Management.dll "/out:$bin\KeyListener.exe" "$source\KeyListener.cs"
if($LASTEXITCODE -ne 0){throw 'Listener compilation failed.'}
& $gcc -Wall -Wextra -Werror -Wno-cast-function-type -O2 -shared -static-libgcc -o "$bin\PromptFilter.dll" "$source\PromptFilter.c" -luser32
if($LASTEXITCODE -ne 0){throw 'Filter compilation failed.'}
& $gcc -Wall -Wextra -Werror -Wno-cast-function-type -O2 -municode -mwindows -static-libgcc -o "$bin\FilterController.exe" "$source\FilterController.c" -luser32 -lshell32 -lwintrust -lcrypt32 -ladvapi32
if($LASTEXITCODE -ne 0){throw 'Controller compilation failed.'}

$manifest=@{}
foreach($name in @('KeyListener.exe','FilterController.exe','PromptFilter.dll','settings.xml')){
 $manifest[$name]=(Get-FileHash -LiteralPath (Join-Path $bin $name) -Algorithm SHA256).Hash
}
$manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'checksums.json') -Encoding UTF8
