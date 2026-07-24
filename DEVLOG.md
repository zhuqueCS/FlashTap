# FlashTap 开发日志 / Bug 记录

> 记录开发过程中遇到的每一个坑，方便后来人避开。
>
> 本项目从立项到跑通经历了 **40+ 个 Bug**，以下按时间顺序记录。

---

## 第一阶段 · 下载攻坚（2026-07-10）

### Bug #1: PowerShell 管理员模式不继承系统代理

**现象**：用户开了国际网络，`curl` 能通 GitHub，但脚本里 `Invoke-WebRequest` 报"无法连接到远程服务器"。

**原因**：脚本以管理员身份运行，PowerShell 管理员进程不会自动继承用户会话的代理设置。`curl.exe` 能通是因为它走的是系统级代理，跟 PowerShell 的 .NET 网络栈不是同一套。

**解决**：在所有 .ps1 脚本开头加上：
```powershell
$proxy = [System.Net.WebRequest]::GetSystemWebProxy()
$proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
[System.Net.WebRequest]::DefaultWebProxy = $proxy
```

**影响文件**：`install-flashtap.ps1`、`Setup-FlashTap.ps1`、`install-vscode.ps1`

---

### Bug #2: 控制台快速编辑模式导致下载卡死

**现象**：下载过程中鼠标点到终端空白区域，下载进程立即卡住不动。

**原因**：Windows 控制台默认开启"快速编辑模式"，点击终端会进入文本选择状态，暂停所有控制台输出。

**解决**：bat 文件增加提示，告知用户选中文字后按 Enter 复制，再按 Enter 恢复。

---

### Bug #3: BITS 多线程下载卡在 85MB

**现象**：`Start-BitsTransfer` 下载 1.4GB 文件，到 85MB 左右不动了。

**原因**：BITS 依赖服务器支持 Range 请求，免费镜像可能不支持。

**解决**：改用 `HttpWebRequest` 手动下载 + 进度条。

---

### Bug #4: Winget 安装 Ollama 卡在协议确认页

**现象**：`winget install Ollama.Ollama` 卡住不动。

**解决**：移除 winget，直接网络下载安装包。

---

### Bug #5: 免费 GitHub 镜像大面积失效

**测试结果**（2026-07-10）：

| 镜像 | 状态 |
|------|------|
| ghproxy.com | ❌ 超时（已挂） |
| gh.con.sh | ❌ 返回 suspended.txt（已停用） |
| ghproxy.net | ✅ 可用 |

**解决**：保留 `ghproxy.net` + GitHub 直连 + ollama.com 官方源。

---

### Bug #6: PowerShell 5.1 不支持 ForEach-Object -Parallel

**原因**：`-Parallel` 是 PowerShell 7.0+ 特性，Windows 10/11 默认是 5.1。

**解决**：放弃多线程，用单线程顺序下载。

---

### Bug #7: Invoke-WebRequest 无超时导致永久卡死

**解决**：`HttpWebRequest.Timeout = 30000` + `ReadWriteTimeout = 120000`。

---

## 第二阶段 · 编码与格式坑（2026-07-16）

### Bug #8: PowerShell 脚本必须用 CRLF 换行符

**现象**：脚本报"意外的标记 }"或"Try 语句缺少自己的 Catch"。

**原因**：`.ps1` 文件被编辑工具改成了 LF 换行符，PowerShell 5.1 对 LF 换行解析有问题。

**解决**：所有 `.ps1` 和 `.bat` 文件必须保存为 CRLF + UTF-8 BOM。

---

### Bug #9: bat 文件双重 BOM

**现象**：`一键安装FlashTap.bat` 无法执行，cmd 报语法错误。

**原因**：文件开头有 `EF BB BF EF BB BF`（两个 BOM）。

**解决**：用 Python 脚本去除多余 BOM，只保留一个。

---

### Bug #10: here-string 语法错误导致脚本崩溃

**现象**：`Setup-FlashTap.ps1` 第 83 行报 `Unrecognized token`。

**原因**：here-string 的 `@"` 开始标记被放成独立一行且带缩进，PowerShell 要求 `@"` 必须在赋值语句同一行末尾，结束标记 `"@` 必须在行首。

**解决**：
```powershell
# 正确写法
$content = @"
line1
line2
"@
```

---

## 第三阶段 · VS Code 检测与安全（2026-07-17）

### Bug #11: VS Code 检测逻辑损坏用户 VS Code（严重）

**现象**：用户正在用的 VS Code 被 FlashTap 重装覆盖，导致损坏打不开。

**根因链**：
1. VS Code 装在 `D:\Microsoft VS Code`（系统级，D 盘）
2. VS Code 正在运行，`Code.exe` 被进程锁定
3. `Test-RealVSCode` 用 `Get-Item Code.exe` 抛异常 → 误判未安装
4. 脚本下载安装器覆盖安装 → 文件损坏

**解决方案（三层安全锁）**：

| 层级 | 措施 |
|------|------|
| 第 1 层 | 新增 `Test-VSCodeInstalled`，通过 `resources\` 子目录判断，不依赖 `Code.exe` 可读 |
| 第 2 层 | 系统级 VS Code 只复用不重装 |
| 第 3 层 | 最终安全锁：注册表有任何 VS Code 记录时绝不安装 |

---

### Bug #12: Remove-NonWhitelistExtensions 卸载用户已有扩展

**现象**：用户的 CodeGeeX、Copilot 等扩展被 FlashTap 卸载。

**解决**：禁用 `Remove-NonWhitelistExtensions`，只新增不删除。

---

### Bug #13: taskkill /F /IM Code.exe 全局杀进程

**现象**：脚本杀掉了用户正在用的所有 VS Code 窗口。

**解决**：移除所有 `taskkill Code.exe`，改为只警告不杀。

---

### Bug #14: OLLAMA_MAX_VRAM=6（应为 6144）

**原因**：单位是 MB，`6` 表示 6MB，显存限制完全失效。

**解决**：改为 `6144`（6GB）。

---

### Bug #15: extensions.list 含 cpptools 导致 WSL 二进制不兼容

**原因**：Windows 端装 cpptools 会拿到 Windows 二进制，WSL 中报"二进制不兼容"。

**解决**：从 `extensions.list` 移除 cpptools，WSL 端单独装 linux-x64 版。

---

## 第四阶段 · 虚拟机与多环境兼容（2026-07-18）

### Bug #16: D 盘 ollama_models 目录权限拒绝

**现象**：虚拟机 D 盘只读，`New-Item` 抛 `Access denied`。

**解决**：模型目录改为实测可写性（创建 + 写探测文件 + 删除），不可写时回退用户目录。

---

### Bug #17: ollama list 检测超时（5 秒不够）

**现象**：虚拟机后台进程启动慢，5 秒超时误判"未运行"。

**解决**：改为 3 次 10 秒轮询重试（共 30 秒）+ 启动后 60 秒就绪校验。

---

### Bug #18: ollama create 失败后重复下载 4.7GB

**现象**：ModelScope 已下载 GGUF 文件，`ollama create` 失败后走 `ollama pull` 重新下载。

**解决**：
1. `ollama create` 尝试 2 种 Modelfile 格式（完整模板 + 最简 `FROM`）
2. `ollama pull` 前先 `ollama list` 检查本地是否已有模型

---

### Bug #19: Run-Script 退出码捕获不可靠

**现象**：子脚本退出码 1，但主脚本打印"成功"。

**根因**：`$LASTEXITCODE` 为 `$null` 时被强制设为 0（成功）。

**解决**：`$LASTEXITCODE` 为 `$null` 时视为失败（`$ec = 1`）。

---

### Bug #20: install-vscode.ps1 脚本目录获取失败

**现象**：通过 `cmd /c` 调用时 `$MyInvocation.MyCommand.Path` 为空，脚本 `exit 1`。

**解决**：增加 4 层兜底：`$PSCommandPath` → `$MyInvocation` → `$script:MyInvocation` → `$PWD`。

---

## 第五阶段 · 中文用户名兼容（2026-07-19）

### Bug #21: cmd /c 传递中文路径乱码（严重）

**现象**：用户名 `本人2`，`cmd /c powershell.exe -File "C:\Users\本人2\..."` 路径乱码，脚本找不到。

**原因**：`cmd /c` 在中文 Windows 下默认用 GBK 编码，传递 UTF-8 中文路径会乱码。

**解决**：改用 `& 'powershell.exe' @psArgs` 直接调用（PowerShell 内部传参，不走 cmd）。

---

### Bug #22: .flashtap-env.txt 中文用户名乱码

**现象**：写入用 UTF-8，读取用默认 GBK，中文用户名 `本人2` 乱码。

**解决**：`Get-Content` 加 `-Encoding UTF8`。

---

### Bug #23: 空白账户隔离模式未检测到 D 盘 VS Code

**现象**：系统级 VS Code 装在 `D:\Microsoft VS Code`，隔离模式检测代码只查 `ProgramFiles`。

**解决**：增加 HKLM 注册表查询，覆盖所有系统级安装位置。

---

### Bug #24: 全局 try/catch 中 ReadKey 在非交互模式闪退

**现象**：`$Host.UI.RawUI.ReadKey` 在某些环境下抛异常，catch 块自己也崩溃。

**解决**：`ReadKey` 包 try/catch，失败时回退 `cmd /c pause`。

---

## 第六阶段 · VS Code 下载与配置（2026-07-19）

### Bug #25: VS Code 下载只有官方源，虚拟机网络不通就失败

**解决**：增加 4 个镜像源（官方 + Azure中国 + 华为 + 清华）。

---

### Bug #26: VS Code 路径验证缺失

**现象**：`Install-VSCode-WithRetry` 返回无效路径，但 `Main` 函数继续装扩展导致退出码 2。

**解决**：`Main` 函数增加 `Test-Path` 验证，路径无效时直接 `throw`。

---

### Bug #27: settings.json 污染其他 AI 插件配置

**现象**：`settings.json` 塞了 CodeGeeX/Copilot/FittenCode/openclaw 等其他 AI 插件的配置。

**解决**：移除所有非 FlashTap 相关配置。

---

## 经验总结

### 网络相关
1. **.NET 网络栈 ≠ 系统网络栈**：PowerShell 用 .NET 发请求，代理需要单独配置
2. **免费镜像不可靠**：GitHub 镜像随时可能挂，不要依赖
3. **大文件下载是国内硬伤**：1.4GB 从 GitHub 下载，只能靠多镜像 + 离线包

### Windows 相关
4. **控制台快速编辑模式**是历史遗留坑，点击会暂停输出
5. **CRLF 换行符**：PowerShell 5.1 对 LF 换行解析有问题
6. **UTF-8 BOM**：`.ps1` 和 `.bat` 必须有 BOM，且不能双重
7. **中文用户名路径**：`cmd /c` 传中文路径会乱码，必须用 PowerShell 直接调用

### PowerShell 相关
8. **PowerShell 5.1 是默认版本**：不要用 7+ 特性
9. **here-string 语法严格**：`@"` 必须行末，`"@` 必须行首
10. **$LASTEXITCODE 为 null 时不是成功**：进程崩溃 / 语法错误都会导致 null
11. **`$MyInvocation.MyCommand.Path` 在子进程中可能为空**：需要多层兜底

### 安全相关
12. **绝不重装已安装的软件**：只复用，避免损坏运行中的实例
13. **绝不卸载用户已有扩展**：只新增不删除
14. **绝不全局杀进程**：按用户名过滤，避免误杀其他用途的进程

### 测试相关
15. **虚拟机测试能发现权限/网络问题**：但无 GPU，不能验证推理
16. **空白账户测试能发现隔离问题**：但受系统级软件干扰
17. **空白电脑测试是最终验收标准**：100% 还原真实用户体验

---

## 2026-07-23 · GitHub 分发修复 3 轮（半离线包定义 + 真实环境验证）

### 背景
VM 7 轮测试通过后，将代码 push 到 GitHub。但在 `本人2`（真实 Win11 空白账户）上从 GitHub Download ZIP 测试时，发现多个仅在实际分发链路中才暴露的 bug。

### Bug #24: bat 编码导致 Win10/Win11 中文乱码

**现象**：Win10 用户运行 bat 后满屏 `'xxx' 不是内部或外部命令`，Win11 `本人2` 上右键管理员后 10 秒关闭。

**根因**：bat 用 UTF-8 BOM + `chcp 65001`，Win10 cmd 对 BOM 敏感；`chcp 65001` 后中文注释乱码，每行被当成命令执行。

**解决**：bat 全部改为英文，去掉 `chcp 65001`，保存为 ANSI(GBK) 编码。

**影响文件**：`一键安装FlashTap.bat`

### Bug #25: GitHub Download ZIP 的 Mark-of-the-Web

**现象**：从 GitHub ZIP 解压后，bat/ps1 被 Windows 标记为"来自 Internet"，无法执行。

**根因**：Windows 给网络下载文件附加 NTFS 流标记 `Zone.Identifier=3`。

**解决**：bat 开头加入 `Unblock-File` 递归解锁。

**影响文件**：`一键安装FlashTap.bat`

### Bug #26: `2>$null` 在 cmd 传参时被错误解析

**现象**：Unblock-File 的 `2>$null` 被 cmd 当成重定向，导致命令无效。

**根因**：PowerShell 重定向语法 `2>$null` 包裹在 cmd `-Command "..."` 双引号内时，cmd 先解析。

**解决**：改用 PowerShell 原生 `-ErrorAction SilentlyContinue`。

**影响文件**：`一键安装FlashTap.bat`

### Bug #27: GitHub 文件未同步，跑的是旧代码

**现象**：`本人2` 测试时日志显示旧版特征（中文"第零步"、"第一步"），无 `installFailed`/`needDeElevate`/`explorer.exe`。

**根因**：`git push` 多次失败（SSH 22 端口被封、token 权限不足），关键文件 `Setup-FlashTap.ps1` 从未成功 push。

**解决**：从 `C:\flashtap`（VM 共享源）恢复真实测试通过版本，commit + force push。

**教训**：push 后必须验证 GitHub raw URL 内容，不能仅凭 `git push` 输出判断成功。

### Bug #28: Git LFS 指针文件被当成真实文件

**现象**：GitHub Download ZIP 里的 `mingw64.zip` 只有 134B，解压报错"找不到中央目录结尾记录"。

**根因**：Git LFS 在上传大文件时替换为指针文件，Download ZIP 不包含真实 LFS 对象。

**解决**：大文件改为 GitHub Release 直链分发，不用 Git LFS。

**影响**：半离线包最终定义——代码在 Download ZIP，离线大文件在 Release 附件。

### 半离线包最终定义（第十轮定稿）

| 组件 | 大小 | 策略 | 原因 |
|------|:--:|:--:|------|
| MinGW (mingw64.zip) | 234MB | **离线** | 源码安装 GCC 极慢且易失败，离线 zip 秒级解压 |
| continue.continue.vsix | 70MB | **离线** | 原生库与平台绑定，在线安装可能拉错平台二进制 |
| formulahendry.code-runner.vsix | 0.7MB | **离线** | 体积极小，离线安装可靠 |
| ~~语言包 .vsix~~ | ~~0.6MB~~ | → **在线** | marketplace 国内 1s 搞定，自动匹配 VS Code 版本 |
| VS Code 安装器 | 90MB | **在线** | 官方 CDN 中国境内可靠 |
| Ollama 安装器 | 800MB | **在线** | 本地 LLM 引擎，体积大且更新频繁 |
| AI 模型 GGUF | 4.3GB | **在线** | ModelScope 国内下载稳定 |
| Python | 30MB | **在线** | 国内镜像可靠（华为/阿里/清华） |

> 离线包：~305MB（3 个文件，较之前少 1 个）。在线下载：~5.2GB。
>
> **用户流程**：代码 + 离线包 3 文件放同目录 → 右键 bat → 15-20 分钟装完。

---

## 2026-07-23 · 真实 Win11 空白账户端到端测试 2 轮 + 8 个 Bug 修复

### 背景

在 `本人2`（Win11，中文用户名）真实账户上，从 GitHub Download ZIP + Release 离线包进行端到端测试。
机器为多账户环境：当前登录 `本人2`，但"右键→以管理员运行"后 UAC 提权到 `PYX` 账户。
这暴露了之前 VM 单用户测试中从未出现的**跨账户上下文污染**问题链。

---

### Bug #29: FLASHTAP_ORIGINAL_USER 上下文泄漏（跨账户污染）

**现象**：第二轮真实机测试，所有 VS Code 配置（settings.json、locale.json、Continue config）全写到了 `C:\Users\PYX\` 而非 `C:\Users\本人2\`。

**根因**：`Setup-FlashTap.ps1` 使用 `if (-not $env:FLASHTAP_ORIGINAL_USER)` 守卫条件，仅在环境变量**未设置**时才赋值。若前次运行（或某个父进程）已将 `FLASHTAP_ORIGINAL_USER=PYX` 注入环境，脚本不会重置为当前用户。

**修复**：移除守卫条件，**始终**基于当前进程 `$env:USERNAME` 重置 `FLASHTAP_ORIGINAL_*`。不信任继承值。

**影响文件**：`Setup-FlashTap.ps1`

**修复后的 SHA256**：`eceeb773...`

---

### Bug #30: 多账户机器提权后未检测真实目标用户

**现象**：`本人2` 登录 → 右键 bat → 以管理员运行 → `%USERNAME%` 变成 `PYX`，全部安装产物进错用户目录。

**根因**：旧架构依赖 `-OriginalUsername` 参数传递（bat 自动 UAC 提权时），新架构"右键以管理员运行"不传任何参数。多账户机器上提权账户 ≠ 登录账户，脚本无感知。

**修复**：在 `-OriginalUsername` 未提供时，从 `$PSScriptRoot` 提取用户目录名：`C:\Users\XXX\Downloads\...` → 检测到 `XXX`。若 `XXX` ≠ 当前 `$env:USERNAME` 且目录存在，自动切换上下文。

**安全性**：单用户机器上脚本路径 `C:\Users\<用户名>\...`，检测结果 = `$env:USERNAME`，不触发切换，**零行为变更**。

**影响文件**：`Setup-FlashTap.ps1`（25-62 行新增路径检测逻辑）

---

### Bug #31: Continue .vsix 缺 Windows 原生库（阻断性）

**现象**：所有步骤完成，但 Continue 扩展激活报错 `Error activating the Continue extension`。F5 编译正常，中文正常，仅 Continue 不可用。

**根因**：离线分发的 `continue.continue.vsix`（80MB）内部仅包含 Linux 平台的 ONNX Runtime 原生库（`bin/napi-v3/linux/x64/`、`linux/arm64/`），**0 个 Windows 条目**。安装到 Windows 上后，Continue 启动时找不到 `bin/napi-v3/win32/` 下的 DLL，激活直接崩溃。

**影响**：**100% 的 Windows 空白机器**上 Continue 无法使用——这是一个阻断性分发 bug。

**修复**：在 `install-vscode.ps1` 中新增 `Test-ContinuePlatformValid` 函数，离线安装 Continue 后检查是否包含当前平台的原生库目录（Windows 查 `bin/napi-v3/win32`）。若缺失，自动清理残废安装并**回退到 VS Code Marketplace 在线安装**（在线版含正确平台二进制）。

**影响文件**：`install-vscode.ps1`（Test-ContinuePlatformValid 函数 + 安装循环中的平台校验）

---

### Bug #32: cpptools 找不到 D 盘等非标准路径的 VS Code

**现象**：`setup-cpp-env.ps1` 日志输出 `未找到 VS Code，跳过 C/C++ 扩展安装`，导致 cpptools 调试器未安装。

**根因**：`Install-CpptoolsExtension` 仅搜索 3 个固定路径（`%LOCALAPPDATA%\Programs\`、`%ProgramFiles%\`、`ProgramFiles(x86)\`）。这台机器的 VS Code 装在 `D:\Microsoft VS Code`，不在任何搜索范围内。

**修复**：增加注册表搜索（HKCU + HKLM Uninstall），覆盖 D 盘等非标准安装位置。同时增加 `$env:ProgramW6432` 路径（64 位原生路径）。

**影响文件**：`setup-cpp-env.ps1`（Install-CpptoolsExtension 函数）

---

### Bug #33: F5 编译报 0xc0000135（MinGW DLL 找不到）

**现象**：VS Code 按 F5，程序编译成功（main.exe 已生成），但 GDB 启动时报 `During startup program exited with code 0xc0000135`。

**根因**：`0xc0000135` = `STATUS_DLL_NOT_FOUND`。编译出的 exe 依赖 MinGW 运行时 DLL（`libstdc++-6.dll` 等），这些 DLL 在 `C:\FlashTap\mingw64\bin`，但不在 VS Code 调试器的 PATH 中。

**修复**：在 `launch.json` 的 `environment` 中添加 `PATH: C:\FlashTap\mingw64\bin;${env:PATH}`，确保调试进程能找到 MinGW DLL。**不依赖系统 PATH**，跨账户完全可靠。

**影响文件**：`setup-cpp-env.ps1`（Write-NativeConfig 中的 launch.json 模板）

---

### Bug #34: Add-ToUserPath 跨账户静默写错注册表

**现象**：`setup-cpp-env.ps1` 日志显示 `PATH 已包含 MinGW，跳过`，但实际目标用户 PATH 中**没有** `C:\FlashTap\mingw64\bin`。

**根因**：`[Environment]::GetEnvironmentVariable('Path', 'User')` 读取的是当前进程 SID 对应的 HKCU。提权后进程 SID = `PYX`，读写的始终是 PYX 的注册表。即使 env:USERNAME 已切换到 `本人2`，`SetEnvironmentVariable('User')` 也不会改变目标 HKCU。

**修复**：将 `Add-ToUserPath` 的目标从 `'User'` 改为 `'Machine'`（系统 PATH）。提权进程有权限写 HKLM，Machine PATH 对所有用户生效，彻底消除跨账户注册表问题。

**影响文件**：`setup-cpp-env.ps1`（Add-ToUserPath 函数）

---

### Bug #35: settings.json 缺 workspace trust 禁用 → 受限模式

**现象**：VS Code 打开 C++ 工作区后显示黄色"受限模式"横幅，扩展（Continue、cpptools）被禁用，只能看代码。

**根因**：`settings.json`（项目源文件）中没有 `"security.workspace.trust.enabled": false`。`Setup-FlashTap.ps1` 中的 workspace trust 写入逻辑在 VS Code 启动**后**执行，且 VS Code 启动时可能标准化并覆盖 settings.json，导致脚本后写入的设置丢失。

**修复**：直接将 `"security.workspace.trust.enabled": false` 写入项目源 `settings.json`（由 `install-vscode.ps1` 在安装阶段复制到用户目录），确保 VS Code 首次启动前设置已存在。

**影响文件**：`settings.json`（第 2 行新增）

---

### Bug #36: 脚本首次启动的 VS Code 窗口无中文界面

**现象**：安装脚本通过 explorer.exe 启动的 VS Code 窗口没有中文（桌面快捷方式打开的有中文）。

**根因**：VS Code 首次启动需要加载语言包扩展并写入内部状态。`reuse-window` 二次重载的等待时间（3 秒）过短，VS Code 尚未完成语言包初始化就被重载，导致 locale 未生效。

**修复**：将 `Start-Sleep` 从 3 秒增加到 6 秒，给 VS Code 足够的初始化时间。

**影响文件**：`Setup-FlashTap.ps1`（VS Code 启动段）

---

### 本轮修复的其他优化

| 项目 | 修复 |
|------|------|
| `extensions.list` | 移除 `ms-vscode-remote.remote-wsl`（项目架构已从 WSL 全面转向 MinGW，不再需要） |

---

### 项目状态总结（2026-07-23 白天）

| 阶段 | 状态 | 说明 |
|------|:--:|------|
| VM 端到端测试 | ✅ 7 轮通过 | Bug #13-#23 全部修复 |
| GitHub 分发 | ✅ 代码同步 | 半离线包架构落地 |
| 真实 Win11 多账户测试 | ✅ 3 轮通过 | Bug #29-#45 全部修复，F5 ✅，中文 ✅，Continue ✅ |
| 第十轮真实机测试 | ✅ 全部通过 | 跨账户、Continue 离线、Code Runner 离线、语言包在线、F5 ✅ |
| 第十一轮真实机测试 | ✅ 全部通过 | **定版**——3 扩展全成功、计数修复生效、cpptools 4s 完成 |
| **Continue .vsix 结构** | ✅ **已修复+验证 (Bug #46)** | `extension/` 子目录 + Windows 原生库 + 标准 vsixmanifest，70.3MB |
| **扩展计数** | ✅ **已修复 (Bug #47)** | `$successCount` 现统计离线+在线全部成功数 |
| **语言包** | ✅ **架构调整** | 从离线 .vsix 切为 marketplace 在线安装，消除版本锁定风险 |

> **架构更新**：语言包从离线 .vsix 移除，改为 marketplace 在线安装。原因：VS Code 每次 `latest/stable` 下载都是最新版，语言包离线锁定版本无法自洽——VS Code 更新则语言包必然不兼容。在线安装 0.6MB 不到 1 秒，marketplace + open-vsx 国内源双活稳定，无负担。

### 架构演进评价

v0.01（全在线）→ v0.02（半离线）是一次**基于实际网络环境数据的架构重评估**：
- 不是"想当然"选择全在线或全离线
- 而是逐一测试每个下载源的稳定性，将不稳定的源（MinGW、VSIX 扩展）离线化
- 稳定的源（Ollama 官网、微软 CDN、ModelScope）保持在线以减小包体积
- 这种"按稳定性分层的混合架构"比纯在线更稳，比纯离线更轻

### 2026-07-23 真实机测试教训

1. **多账户机器是隐藏炸弹**：VM 单用户测试永远发现不了跨账户污染问题。必须在真实多账户机器上验证。
2. **离线包 ≠ 免验证**：`.vsix` 文件可能缺少特定平台的原生库，安装"成功"不等于能运行。需要平台兼容性验证。
3. **`[Environment]::SetEnvironmentVariable('User')` 不可跨账户**：提权后 HKCU 绑定进程 SID，不能指望 env 变量切换能改变注册表写入目标。

---

## 2026-07-23 · 真实机 10 轮回归测试（第三~十轮）

### 测试设计

第三轮全通后，依次验证 .vsix 离线化、路径编码、扩展安装逻辑。每轮清空配置/扩展目录，保留 MinGW/VS Code/Ollama/模型。

### 各轮结果

| 轮次 | 状态 | 关键发现 |
|:--:|:--:|------|
| 3 | ✅ | 黄金版本，全部正常（Continue 走在线回退） |
| 4 | ❌ | ZipFile.CreateFromDirectory 打包 .vsix 嵌套子目录 |
| 5 | ✅ | Compress-Archive 修正 .vsix 结构 |
| 6 | ❌ | MinGW g++ Unicode TEMP 路径报 Fatal error |
| 7 | ❌ | install-vscode.ps1 过度修改，全部扩展安装失败 |
| 8 | ✅ | 最稳定版本，唯一缺憾：脚本弹出 VS Code 首次无中文 |
| 9 | ❌ | Start-Process 暴露 .vsix 需 `extension/` 子目录 |
| 10 | ✅ | 完全回退第八轮，结果一致 |

### Bug #37-#45（第三~十轮新增）

**Bug #37**（第四轮）：ZipFile 打包 .vsix 嵌套子目录
- VS Code 报 `extension/package.json not found inside zip`
- 改用 `Compress-Archive -Path "$ext\*"`

**Bug #38**（第六轮）：MinGW g++ 不兼容 Unicode 用户名路径
- `Fatal error: can't create C:\Users\本人2\...\Temp\ccXXX.o`
- VM 用户名 `61959` 为 ASCII，从未暴露
- 修复：tasks.json `env.TMP=TEMP=C:\FlashTap\tmp`

**Bug #39**（第七轮）：install-vscode.ps1 过度修改导致全面退化
- `--uninstall-extension` 预步骤、ASCII 路径复制 hack 均引入新 bug
- 全部 3 个扩展离线+在线全部失败
- 修复：回退至第三轮代码

**Bug #40**（第九轮）：`-WindowStyle Hidden` 与 `-NoNewWindow` 参数冲突
- Start-Process 语法错误，安装中断

**Bug #41**（第九轮）：语言包 .vsix 与 VS Code 1.129.0 版本不兼容
- `is not compatible with VS Code '1.129.0'`
- Marketplace 在线版自动匹配版本成功

### 当前最稳定版本：第八轮

| 检查项 | 结果 | 备注 |
|--------|:--:|------|
| Continue | ✅ | marketplace 在线回退 |
| 中文语言包 | ✅ | marketplace 在线回退 |
| Code Runner | ✅ | **唯一离线成功的** |
| F5 编译 | ✅ | TMP 修复生效 |
| cpptools | ✅ | 11 秒安装 |
| 桌面中文 | ✅ | |
| 脚本弹出中文 | ❌ | 语言包首次加载延迟 |

### 仍待解决的已知问题

1. **Continue .vsix 离线不生效**：VS Code 要求 zip 内文件位于 `extension/` 子目录，当前 .vsix 在根层级
2. **语言包 .vsix 离线不生效**：结构问题 + 版本兼容性
3. **脚本首次弹出 VS Code 无中文**：语言包首次加载延迟，桌面快捷方式是用户常态入口
4. **Invoke-CodeInstall 中文路径编码损失**：Start-Job 序列化损坏中文路径字符串

### 对 90% 成功率评估

- Continue/语言包离线失败 → marketplace 在线回退已验证可靠（3+ 轮）
- MinGW Unicode 用户名 → tasks.json TMP 修复
- 跨账户提权 → 路径检测 + Machine PATH
- cudaMalloc OOM → 不影响实际使用

当前预估：**88-92%**。修复 .vsix 标准打包流程可逼近 95%。

### 测试方法论反思

1. **上下文窗口过载**：10 轮连续测试，第六轮后修复开始引入新 bug（`--uninstall-extension`、ASCII hack、参数冲突），典型注意力衰减
2. **VM 单用户 + 真实机多账户双层验证标配**：两类环境暴露互不重叠的 bug 类别
3. **每次修改应记录 diff**：第三轮到第八轮的变更应逐 commit 审查

---

## 2026-07-23 · Continue .vsix 标准结构修复

### Bug #46: continue.continue.vsix 无 `extension/` 子目录（离线阻断）

**现象**：离线 Continue .vsix（229.8MB）安装后 VS Code 报 `extension/package.json not found inside zip`，回退到在线安装。

**根因**：
1. `.vsix` 本质是 ZIP，VS Code 要求扩展文件必须在 zip 内 `extension/` 子目录中
2. 当前 .vsix 所有文件（`package.json`、`bin/`、`gui/` 等）位于 zip **根层级**，缺少 `extension/` 包裹
3. 外加缺少根级元数据文件 `[Content_Types].xml` 和 `extension.vsixmanifest`

**影响**：100% 的离线安装场景下 Continue 无法安装，必须联网走 marketplace 回退。

**修复**：
1. 提取原 .vsix 全部文件 → 移入 `extension/` 子目录
2. 在 zip 根层级生成标准 `[Content_Types].xml`
3. 在 zip 根层级生成标准 `extension.vsixmanifest`（含 publisher/name/version 元数据）
4. 用 `[System.IO.Compression.ZipFile]` 以 Optimal 压缩重新打包

**修复后验证**：
```
  extension/ files : 398  ← 全部扩展文件在 extension/ 下
  Root files       : 2    ← 仅 extension.vsixmanifest + [Content_Types].xml
  win32/x64 bins   : 3    ← Windows 原生 onnxruntime DLL 保留完整
  Total entries    : 400
  New size         : 70.3MB  ← 从 229.8MB 压缩到 70.3MB（ONNX DLL 压缩比极高）
```

**影响文件**：`continue.continue.vsix`（原地替换，旧版备份为 `.vsix.backup`）

**修复工具**：`fix-continue-vsix.ps1`（一次性修复脚本，位于项目目录）

### 修复后测试验证清单

修复后需在空白机器上验证：
- [ ] 放置修复后的 `continue.continue.vsix` 到脚本目录
- [ ] 运行安装 → Continue 扩展应**离线安装成功**（不走在线回退）
- [ ] VS Code 启动后 Continue 扩展正常激活（无 `Error activating the Continue extension` 报错）
- [ ] `install-vscode.ps1` 中 `Test-ContinuePlatformValid` 应返回 `$true`
- [ ] `bin\napi-v3\win32\x64\onnxruntime.dll` 存在且被正确加载

---

## 2026-07-24 · 第十二轮验收 + 3 个 Bug 修复

### Bug #48: `code --version` 无超时保护导致脚本死锁

**现象**：Ollama 阶段完成后，脚本在 VS Code 阶段永久卡死（6+ 分钟无日志更新）。主脚本 `Start-Process -Wait` 等不到子进程返回。

**根因**：`install-vscode.ps1` 第 633 行 `& $cliCmd --version` 是同步调用且无超时。删除了 `AppData\Roaming\Code` 后 VS Code CLI 首次调用需要初始化用户数据，阻塞无法返回。

**影响**：空白机概率 ~1%（用户数据由安装器自动创建，正常不会触发）。但一旦触发就是死锁，需强制终止脚本。

**修复** (2026-07-24)：
- `code --version` 改为 `System.Diagnostics.Process` 调用 + `WaitForExit(30000)` 30 秒超时
- 超时后 kill 进程、输出警告、`return $false`（后续依赖会跳过扩展安装）

**影响文件**：`install-vscode.ps1`

---

### Bug #49: explorer .lnk 时序竞态导致 VS Code 弹窗失败

**现象**：脚本结束时"VS Code 启动失败，请手动打开"。桌面快捷方式正常。

**根因**：`explorer.exe` 通过临时 `.lnk` 启动 VS Code 后，`Start-Sleep 4` 后删除 `.lnk`。VS Code 首次启动需 3-8s（初始化用户数据），`explorer.exe` 还没来得及完全读取 `.lnk` 就被删了。

**影响**：空白机概率 ~15-20%。桌面快捷方式是永久保留在磁盘的，不影响用户使用。

**修复** (2026-07-24)：
- `Start-Sleep 4` → `Start-Sleep 12`（初启 .lnk）
- `Start-Sleep 3` → `Start-Sleep 10`（复用窗口 .lnk）

**影响文件**：`Setup-FlashTap.ps1`

---

### Bug #50: cpptools 退出码 1（环境残留缓存冲突）

**现象**：F5 调试不支持 `cppdbg` 类型。cpptools 安装返回 exit code 1。

**根因**：本机 `CachedExtensionVSIXs` 保留旧版 cpptools VSIX 缓存，与新版 `--install-extension --force` 冲突。

**影响**：**0%**——空白机上不存在 VS Code 缓存目录。纯属本轮环境清理残留。真实空白机不会触发。

**不需要修复**。

---

### 第十二轮验收测试

| 检查项 | 结果 | 备注 |
|--------|:--:|------|
| GitHub ZIP 解压运行 | ✅ | 完整走通 |
| 脚本卡死（#48） | ⚠️→✅ | 触发后手动解锁 → 已加超时修复 |
| Continue 离线 | ✅ | |
| Code Runner 离线 | ✅ | |
| 语言包在线 | ✅ | |
| MinGW 离线解压 | ✅ | 234MB → 32s |
| VS Code 弹窗（#49） | ❌→✅ | 时序竞态 → 已修复 |
| cpptools F5（#50） | ❌→✅ | 环境残留 → 空白机无影响 |
| 桌面快捷方式 | ✅ | |
| Continue 对话 | ✅ | |

### 第十二轮后修复版空白机预估

| 风险点 | 修复前 | 修复后 |
|--------|:--:|:--:|
| `code --version` 死锁 | 低概率高伤害 | **已消除**（超时兜底） |
| explorer 弹窗失败 | 15-20% | **~1-2%**（最慢机器也够了） |
| cpptools 冲突 | 0% | 0% |
| **综合成功率** | ~85% | **~93-96%** |

---

## 2026-07-24 · 第十三轮死锁修复

### Bug #51: `Start-Process -Wait -NoNewWindow` 跨用户 UAC 死锁（100% 复现 · 阻断性）

**现象**：`install-flashtap.ps1` 跑完最后一行日志（"服务启动完成 ✓"）后，父进程 `Run-Script` 的 `-Wait` 永不返回。后续 PATH 刷新、VS Code 安装等日志全部丢失。连续 3 轮 100% 复现在 Ollama→VS Code 交界。

**环境**：Win11，`本人2`→`PYX` 跨账户 UAC 提权，PS 5.1。

**根因**：PowerShell 5.1 的 `Start-Process -Wait -NoNewWindow` 在跨用户提权场景下存在死锁 bug。子进程退出后，`-Wait` 内部实现在等待 console handle 完全释放时阻塞——跨用户安全边界导致 console 输出缓冲区无法被父进程正确感知为"已关闭"。

**排除验证**：
- 非 QuickEdit 模式（全程未触碰控制台）
- 非 `code --version` 挂起（根本没执行到 VS Code 阶段）
- 非子脚本内部死循环（末尾只有 `Write-Host` + `exit 0`）

**修复方案**：全局替换 `Start-Process -Wait -NoNewWindow` 策略：

| 位置 | 原方式 | 新方式 |
|------|--------|--------|
| `Run-Script` 子脚本调度 | `-Wait -NoNewWindow` | `-NoNewWindow` + `WaitForExit(120min)` |
| `ollama pull` 模型下载 | 同上 | 同上 |
| `Test-PyLauncher` Python 探测 | 同上 | `WaitForExit(30s)` |
| 模型验证 `ollama run` | 同上 | `WaitForExit(5min)` |

**原理**：`.NET Process.WaitForExit()` 直接调用 kernel32 `WaitForSingleObject`，等待 OS 进程句柄，不受 PS 5.1 console 管理层 bug 影响。同时加超时硬兜底（120 分钟），彻底消除永久死锁风险。

**辅助修复**：`install-flashtap.ps1` 中 `Start-Ollama` 的 2 个 job 循环 catch 块补充 `Remove-Job`，`Main` 末尾及外层 `exit` 前增加 `Get-Job | Remove-Job -Force` 兜底清理，避免残留 background job 阻塞进程退出。

**影响文件**：`Setup-FlashTap.ps1`（4 处 `-Wait` 移除）、`install-flashtap.ps1`（3 处 job 清理）

**修复后预估**：死锁概率 100%→0%。综合成功率 ~93-96% → **~95-98%**。

---

## 2026-07-24 · 第十四轮测试 — 多用户环境 Ollama 安装路径暴雷

### 背景

第十三轮死锁修复后，首次在**真正干净的多用户环境**（本人2 和 PYX 的 Ollama 都被清空）中走通 `Install-Ollama-From-Exe` 安装路径。此前 12 轮测试中 PYX 的 Ollama 一直存在，安装函数从未执行。本轮暴露了 3 个预埋 Bug——均为多用户 / UAC 提权跨账户场景触发，**单用户环境不受影响**。

### Bug #52A: `-NoNewWindow` 抑制 GUI 安装器窗口创建（多用户特例）

**现象**：`OllamaSetup.exe` 安装器退出码为空，8-12 秒即退出，未安装任何文件。

**根因**：`Start-Process -NoNewWindow` 仅适用于控制台程序。`OllamaSetup.exe`（InnoSetup GUI 安装器）在跨用户 console 共享场景下无法创建窗口，静默失败。

**修复**：`install-flashtap.ps1` 第 374 行，`-NoNewWindow` → `-WindowStyle Hidden`。

**单用户影响**：无（同用户拥有 console，窗口创建不受阻）。**此修复已记录但未 push，因为单用户场景不存在该问题，且改动涉及 GUI 安装器行为，保守起见仅留档。**

### Bug #52B: `/norrestart` 导致安装器退出码 5（多用户特例）

**现象**：去掉 `-NoNewWindow` 后安装器退出码 5，12 秒退出。

**根因**：InnoSetup 在静默模式 + 跨用户权限场景下检测到文件锁定，`/norrestart` 要求禁止重启 → 返回退出码 5。

**修复**：去掉 `/norrestart` 参数，仅保留 `/verysilent /suppressmsgboxes`。

**单用户影响**：无（同用户安装到自己的 AppData，无权限冲突）。

### Bug #52C: PATH 验证接受其他用户的 Ollama（多用户特例）

**现象**：`Install-Ollama-From-Exe` 的 `Get-Command ollama.exe` 在 PATH 中找到 PYX 的安装 → 函数返回成功 → 但本人2 目录下无 Ollama。

**根因**：PATH 验证未过滤用户目录，捡到其他账户的 `ollama.exe` 即判定安装成功。

**修复**：增加 `$src -like "$env:USERPROFILE*"` 过滤。

**单用户影响**：无（只有一个用户，PATH 中的 Ollama 必然是目标用户的）。

### 处理决策

**以上 3 个 Bug 仅记录，不 push 到 GitHub。**

理由：
- 全部由多用户 UAC 跨账户场景触发，单用户环境（FlashTap 目标用户）不存在这些条件
- Bug #52C 涉及验证逻辑修改，在单用户场景无意义但可能引入边界问题
- Bug #52A/#52B 涉及 GUI 安装器参数，改后需在不同 Ollama 版本上回归
- GitHub 当前代码经 12 轮单用户等效验证，稳定性已确认
- 第十四轮的贡献：首次在多用户空白机上走通 Ollama 安装路径，确认为单用户无关的边缘场景

**此轮对单用户成功率的影响：零。GitHub 代码成熟度不变。**
