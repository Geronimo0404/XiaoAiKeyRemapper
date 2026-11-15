# 第三方组件与许可

项目代码的 MIT 许可不改变第三方组件的许可。以下文件应随运行包一同分发。

## MinGW-w64 与 GCC

原生控制器和过滤 DLL 使用 MinGW-w64 GCC 构建。即使只显式链接 Windows 系统 API，编译结果也可能包含编译器支持代码及 MinGW-w64 运行库代码；`-static-libgcc` 也不能解释为“没有第三方依赖”。

- MinGW-w64 运行库的综合许可声明：`third_party/licenses/MinGW-w64-runtime.txt`。
- MinGW-w64 项目、声明及版权信息：同目录中的 `MinGW-w64-COPYING.txt`、`MinGW-w64-DISCLAIMER.txt`、`MinGW-w64-DISCLAIMER-PD.txt`。
- GCC 运行库相关文本：`GCC-Runtime-Library-Exception-3.1.txt` 和 `GPL-3.0.txt`。运行库例外适用于符合条件的编译过程，并不自动将本项目代码变为 GPL。

这些许可文本按上游原文保留，覆盖范围可能大于本项目实际链接的代码。它们不是逐个对象文件的许可证清单，也不能证明所有历史二进制都已满足再分发要求。更换工具链、增加依赖或链接选项时，应重新检查适用许可。程序包从本仓库源码生成，更早的实验二进制不包含在本仓库中。

上游来源（文件内容固定在对应 Git blob）：

- [MinGW-w64 runtime 原文 blob](https://api.github.com/repos/mingw-w64/mingw-w64/git/blobs/776d5f1034240f6dae0ce59d592f9c6f4ad29e7d)
- [MinGW-w64 项目](https://github.com/mingw-w64/mingw-w64)
- [GCC 运行库例外](https://www.gnu.org/licenses/gcc-exception-3.1.html)
- [GCC 许可文件](https://github.com/gcc-mirror/gcc)

## Windows 和 .NET Framework

监听器引用系统提供的 .NET Framework `System.Management`；原生组件调用 Windows 系统 API。运行包不分发 Windows、.NET Framework、PowerShell、Windows Terminal 或 Git。它们由使用者的系统提供或自行安装，许可由各自供应方规定。

## 开发与自动测试工具

GitHub Actions 使用 `actions/checkout`、`actions/upload-artifact` 和 Pester。这些是构建、测试工具，不作为本程序运行依赖打进下载包。其许可证分别见各上游项目：
[checkout](https://github.com/actions/checkout)、[upload-artifact](https://github.com/actions/upload-artifact)、[Pester](https://github.com/pester/Pester)。

## 厂商组件与商标

本项目不包含或修改磁盘上的小米程序。运行时会向经过位置和签名检查的原厂热键进程加载提示过滤 DLL。小米、Windows、Git 等名称和商标归各自权利人所有；本项目与这些厂商没有隶属或背书关系。
