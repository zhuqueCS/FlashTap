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

### 半离线包最终定义

| 组件 | 大小 | 策略 | 分发方式 |
|------|:--:|:--:|------|
| MinGW (mingw64.zip) | 234MB | 离线 | GitHub Release |
| 3个VSIX扩展 | 83MB | 离线 | GitHub Release |
| Ollama 安装器 | 800MB | 在线 | 脚本自动下载 |
| VS Code 安装器 | 90MB | 在线 | 脚本自动下载 |
| AI 模型 GGUF | 4.3GB | 在线 | ModelScope 自动下载 |
| Python | <1MB | 在线 | 镜像自动下载 |

**用户流程**：Download ZIP（50KB）+ Release 下载 4 个文件（312MB）→ 放同目录 → 右键 bat → 15 分钟装完。

### 项目状态总结（2026-07-23 凌晨）

| 阶段 | 状态 | 说明 |
|------|:--:|------|
| VM 端到端测试 | ✅ 7 轮通过 | Bug #13-#23 全部修复，F5 MinGW 编译史上首次通过 |
| GitHub 分发 | ✅ 代码同步 | 半离线包架构落地，Release 附件就绪 |
| 真实 Win11 测试 | ⚠️ 待验证 | `本人2` 账户半离线包完整测试（预计 07-23 白天） |

### 架构演进评价

v0.01（全在线）→ v0.02（半离线）是一次**基于实际网络环境数据的架构重评估**：
- 不是"想当然"选择全在线或全离线
- 而是逐一测试每个下载源的稳定性，将不稳定的源（MinGW、VSIX 扩展）离线化
- 稳定的源（Ollama 官网、微软 CDN、ModelScope）保持在线以减小包体积
- 这种"按稳定性分层的混合架构"比纯在线更稳，比纯离线更轻
