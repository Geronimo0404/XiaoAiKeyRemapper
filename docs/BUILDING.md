# 源码与构建

只想使用程序时，可以下载主分支成功构建生成的运行包。GitHub 的“Download ZIP”提供的是源码，不包含已编译程序；需要自行构建后才能运行 `Tui.cmd`。

## 构建环境

- Windows x64。
- .NET Framework C# 编译器。`Build.ps1` 使用系统目录中的 `%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe`。
- 面向 Windows x64 的 MinGW GCC。将 `gcc.exe` 所在目录加入 PATH，或通过下面的参数指定路径。

## 构建步骤

在源码根目录打开普通 PowerShell，运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Build.ps1
```

如果 GCC 没有加入 PATH，可以指定其实际位置。例如：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Build.ps1 -GccPath "C:\mingw64\bin\gcc.exe"
```

示例中的 GCC 路径需要按自己的安装位置调整。构建不需要管理员权限，也不会安装程序或创建登录任务。

构建成功后，`bin` 目录会生成：

- `KeyListener.exe`：按键事件监听器。
- `FilterController.exe`：原厂进程验证与过滤器控制程序。
- `PromptFilter.dll`：下载提示过滤器。

源码根目录的 `checksums.json` 也会生成或更新。`bin/settings.xml` 是默认启动目标配置。完成构建后，在普通用户权限下运行根目录的 `Tui.cmd`；安装和配置步骤见 [README](../README.md)。

## 主要文件

| 文件 | 用途 |
| --- | --- |
| `src/KeyListener.cs` | 监听 WMI 按键事件，以普通用户权限启动目标 |
| `src/FilterController.c`、`src/PromptFilter.c` | 验证原厂进程并过滤指定下载提示 |
| `scripts/Manager.Core.psm1`、`Manage.ps1` | 配置、安装、卸载和终端菜单 |
| `tests/Manager.Tests.ps1` | 使用模拟计划任务接口的隔离测试 |
| `Build.ps1` | 编译程序并更新校验清单 |
| `.github/workflows/windows.yml` | 云端构建、测试与下载包生成 |

## CI 下载包与验证范围

GitHub Actions 会重新编译程序，并生成 `XiaoAiKey-tui-windows-x64` 下载包。包内包含许可证附件，以及 `build-info.json`，记录源码提交号、编译器版本、构建时间和源码及程序的校验值。

`build-info.json` 由 CI 打包步骤生成，单独运行 `Build.ps1` 不会生成它。这些记录用于追溯来源，不是可复现构建或代码签名的证明。

自动化测试覆盖脚本解析、编译和部分配置与安装生命周期逻辑，不能模拟实体小爱键，也不能代替真机测试。具体范围见[测试记录](TESTING.md)。

如果自行分发程序包，请保留 `LICENSE`、`THIRD_PARTY_NOTICES.md` 和 `third_party/licenses`；第三方许可说明见[这里](../THIRD_PARTY_NOTICES.md)。
