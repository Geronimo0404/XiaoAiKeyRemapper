# XiaoAiKeyRemapper

XiaoAiKeyRemapper 是一个 Windows 小工具，用来把部分小米笔记本的超级小爱键改成启动你选择的程序。

它监听小爱键事件，并过滤小爱未安装时出现的下载提示。亮度、音量、投屏和键盘背光等其他快捷键仍由小米原厂组件处理。

## 注意事项

**这是实验性项目，兼容性尚未充分验证。** 按键监听和下载提示过滤曾在小米 Book Pro 14、电脑管家 6.0.2.30 上测试；完整的安装、卸载、重启、休眠唤醒以及厂商软件更新后的表现，还需要在真实设备上进一步验证。其他机型或版本不一定能使用。

程序需要 Windows x64、小米热键组件提供的 `HID_EVENT20` 事件源。它会创建两个登录任务：按键监听器以普通用户权限运行，提示过滤器以管理员权限运行，并在验证小米热键进程后对其加载过滤代码。原厂文件、服务和 BIOS 不会被修改，但厂商更新可能使过滤失效或造成兼容性问题。

安装、修改已安装配置、卸载和清理残余文件时需要管理员确认，且必须由同一个 Windows 账户完成确认，不能切换到另一个管理员账户。本程序目前只支持由本机一个账户管理安装。

## 安装

1. 从 [Actions](https://github.com/Geronimo0404/XiaoAiKeyRemapper/actions) 中选择主分支上成功的 Windows 构建，下载 `XiaoAiKey-tui-windows-x64` 并解压。完整运行包应包含 `Tui.cmd`、`Manage.ps1`、`scripts`、`bin`、`checksums.json` 及许可证文件。
2. 在普通用户权限下运行 `Tui.cmd`。也可以在程序包目录打开普通 PowerShell，运行：

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\Manage.ps1
   ```

3. 在菜单中选择启动目标。默认是 Windows 自带的 PowerShell 5.1，也可以选择 Windows Terminal 或填写自定义程序、快捷方式及参数。
4. 可先选择“测试所选目标”，确认程序能够打开。这个测试不会模拟按下物理小爱键。
5. 选择“安装并设置登录启动”，按提示完成管理员确认。安装后再试按小爱键。

只选择目标不会保存设置：首次使用需要执行“安装”，已安装后修改目标需要执行“保存到已安装配置”。自定义目标支持 `.exe`、`.com`、`.cmd`、`.bat` 和 `.lnk`；路径、参数和起始目录可以使用环境变量。

下载和解压不会设置自动启动。完成安装后，后台组件会在登录 Windows 时自动运行，所选目标程序仅在按下小爱键时打开。

安装目录为 `C:\Program Files\XiaoAiKey`。安装前会检查事件源及程序包的 SHA-256 校验值。校验值用于发现文件损坏或不一致，不能代替可信下载来源或数字签名。此版本不提供覆盖升级；若曾手动安装旧版，请先自行备份并处理旧安装，菜单不会接管它。已有安装的启动目标也不会因为仓库默认值变化而自动更新。

## 卸载

重新运行下载包中的 `Tui.cmd`，选择“卸载并恢复原厂行为”。卸载会停止并移除本程序的两个登录任务；已经打开的终端不会被关闭，日志会保留。

如果过滤 DLL 仍被小米进程占用，它会暂时留在 `%ProgramData%\XiaoAiKey\PendingRemoval`。重启后再次运行下载包中的菜单，选择“清理卸载残余”。

菜单可以查看监听器、提示过滤器和配置状态，也可以查看日志末尾。登录后过滤器需要短暂准备；显示任务正在运行，并不代表当前机型一定兼容。日志和就绪状态位于 `%LOCALAPPDATA%\XiaoAiKey`。日志不记录键盘输入内容，但会记录启动程序的路径和参数等信息，分享日志前请检查是否包含个人信息或敏感参数。

只读查看状态：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Manage.ps1 -Action Status
```

安装后生效的配置文件为 `C:\Program Files\XiaoAiKey\settings.xml`，其中 `ExecutablePath`、`Arguments` 和 `WorkingDirectory` 分别表示启动程序、参数和起始目录。

## 构建

需要 Windows x64、.NET Framework C# 编译器和 64 位 MinGW GCC。配置好 GCC 后运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Build.ps1
```

构建完成后运行 `Tui.cmd`。详细步骤见[构建说明](docs/BUILDING.md)。

## 声明

本项目自行编写的代码和文档使用 [MIT 许可证](LICENSE)。编译运行库保留各自的许可，说明和原文见 [第三方说明](THIRD_PARTY_NOTICES.md) 及 `third_party/licenses`。

本项目不是小米官方产品，也不包含小米电脑管家的程序文件。产品名称仅用于说明兼容对象，不表示厂商认可或担保。
