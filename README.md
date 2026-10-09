# codex-computer-use

让 Codex 桌面版（以及其它桌面 AI）**读屏 + 操控键鼠**的一套笔记与 PowerShell 自建工具。

> 背景：Codex 桌面版自带的 Computer Use 在 Windows 上开关状态与支持面存疑，所以这里走「自建」路线——
> 先把屏幕变成文字（UIA 无障碍树 / Windows 内置 OCR）交给 AI 读，再用一份 PowerShell 模块把「点 + 输入」补上，
> 形成 **看到 → 点到 → 输入** 的闭环。全部功能在 Windows 10/11 + PowerShell 5.1 上实测通过。

## 目录

| 路径 | 说明 |
| --- | --- |
| `1.让codex可以操控我的键盘和鼠标.md` | Codex 内置 Computer Use 的原理、开关位置、能力边界（Windows 上真实支持面） |
| `2.让codex读屏幕并一步步指导我操作.md` | 读屏两条通道：UIA 控件树（带坐标）/ Windows 内置 OCR，含实测输出 |
| `3.InputHelper 键鼠操控模块（读+点闭环）.md` | `InputHelper.psm1` 函数清单 + 实测踩到的三个坑（DPI / 前台锁 / 输入法） |
| `脚本/read-screen.ps1` | 读屏主工具：`uia` / `ocr` / `auto` / `both`，可指定窗口 |
| `脚本/capture.ps1` | 单纯截图存 PNG（全屏 / 指定窗口 / 指定区域 / 缩放） |
| `脚本/InputHelper.psm1` | 键鼠操控模块：`Click-Control` / `Type-Text` / `Send-Hotkey` / `Set-AppWindow` 等 |
| `脚本/win.ps1` | 按窗口标题子串把窗口**可靠**拉到前台，并可顺带敲一条命令 |
| `脚本/说明.md` | 脚本目录速查与已知坑 |

## 快速开始

```powershell
# 1) 读屏（auto：先试 UIA，文字太少自动转 OCR）
powershell -NoProfile -ExecutionPolicy Bypass -File ".\脚本\read-screen.ps1"

# 2) 只要控件树（带坐标，适合"告诉我点哪"）
powershell -NoProfile -ExecutionPolicy Bypass -File ".\脚本\read-screen.ps1" -Mode uia

# 3) 读指定窗口
powershell -NoProfile -ExecutionPolicy Bypass -File ".\脚本\read-screen.ps1" -Mode uia -Window msedge

# 4) 加载键鼠模块，走"看到 → 预演 → 点到 → 输入"闭环
Import-Module ".\脚本\InputHelper.psm1" -DisableNameChecking
Get-CurrentContext
Click-Control -Name "登录" -Window msedge -DryRun   # 先预演，确认坐标
Click-Control -Name "登录" -Window msedge           # 再真点
Type-Text "whoami"
Send-Hotkey "{ENTER}"
```

## 注意

- `脚本/*.ps1`、`脚本/*.psm1` **必须保存为 UTF-8 with BOM**，否则 PowerShell 5.1 会按 GBK 解析，含中文的脚本直接语法报错。仓库里的脚本都已带 BOM。
- `脚本/win.ps1` 内部引用了 `D:\agent\ScreenReader\InputHelper.psm1`，换机器使用时记得改成你自己的路径。
- 中文输入法状态下 `SendKeys` 不可靠（会把字母转成汉字）；`Type-Text` 默认走剪贴板粘贴来绕开输入法。
- 这套工具会真实抢焦点、移动光标。AI 操作期间不要同时用键鼠，也不要在同一台机器上多人并行操作。

## 来源

源自 Obsidian 笔记 `网络安全笔记/codex的配置`，2026-10-09 整理。
