# FlashTap 开发日志 / Bug 记录

> 记录开发过程中遇到的每一个坑，方便后来人避开。

---

## 2026-07-10 · Ollama 下载攻坚日

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

**现象**：下载过程中鼠标不小心点到终端空白区域，下载进程立即卡住不动。

**原因**：Windows 控制台默认开启"快速编辑模式"，点击终端会进入文本选择状态，暂停所有控制台输出。而脚本用 `\r` 实时刷新进度条，输出被阻塞后整个下载流程卡死。

**尝试方案**：用 kernel32.dll 的 `SetConsoleMode` 禁用快速编辑模式。
**放弃原因**：禁用后用户无法复制粘贴日志，反而影响调试。

**最终方案**：接受这个行为，不显示实时进度条，改用简单日志输出。用户需要复制日志时正常操作，下载期间不要点击终端即可。

---

### Bug #3: BITS 多线程下载卡在 85MB

**现象**：用 `Start-BitsTransfer` 下载 1.4GB 文件，到 85MB 左右不动了。

**原因**：BITS 依赖服务器支持 Range 请求，且对网络中断处理较差。免费镜像服务器（ghproxy）可能不支持或不稳定。

**解决**：放弃 BITS，改用 `Invoke-WebRequest -OutFile`，最稳定。

---

### Bug #4: Winget 安装 Ollama 失败

**现象**：`winget install Ollama.Ollama` 卡在协议确认页面。

**尝试方案**：加 `--accept-package-agreements --accept-source-agreements --force`。
**结果**：依然失败，winget 底层也是从 GitHub 下载，没有加速效果。

**最终方案**：移除 winget 尝试，直接网络下载。

---

### Bug #5: 免费 GitHub 镜像大面积失效

**测试结果**（2026-07-10）：

| 镜像 | 状态 |
|------|------|
| ghproxy.com | ❌ 超时（已挂） |
| gh.con.sh | ❌ 返回 suspended.txt（已停用） |
| gh.llkk.cc | 未测试 |
| gitdl.cn | 未测试 |
| gh.api.99988866.xyz | 未测试 |
| ghproxy.net | ✅ 唯一可用，速度约 186KB/s |

**教训**：免费镜像不稳定，随时可能挂。不要依赖太多镜像，保留 1-2 个有效 + GitHub 直连即可。

---

### Bug #6: `ForEach-Object -Parallel` 在 PowerShell 5.1 不兼容

**现象**：尝试用 `$chunks | ForEach-Object -Parallel { ... }` 实现多线程分块下载，脚本直接报错。

**原因**：`-Parallel` 参数是 PowerShell 7.0+ 才引入的，Windows 10/11 默认的 PowerShell 5.1 不支持。

**解决**：放弃多线程分块下载，回退到单线程 `Invoke-WebRequest`。

---

### Bug #7: `Register-ObjectEvent` 回调中变量作用域问题

**现象**：用 `$wc.DownloadFileAsync()` + `Register-ObjectEvent` 显示下载进度，事件回调中无法访问外部变量 `$sw`（秒表）。

**原因**：`Register-ObjectEvent -Action` 脚本块在独立 Runspace 中运行，无法访问调用方的局部变量。

**解决**：放弃异步下载 + 事件回调，改用同步 `Invoke-WebRequest`。

---

### Bug #8: `Invoke-WebRequest` 无超时导致永久卡死

**现象**：`Invoke-WebRequest` 连接镜像源时无限等待，没有任何错误提示。

**原因**：默认不设超时，连接不上会一直等。

**解决**：加 `-TimeoutSec 600`（10 分钟），超时后自动跳到下一个镜像。
```powershell
Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing -TimeoutSec 600
```

---

### Bug #9: HEAD 请求测速反而卡住下载

**现象**：用 `HttpWebRequest.Method = 'HEAD'` 逐个测 7 个镜像的响应时间，结果测速阶段就卡住，下载永远不开始。

**原因**：`HttpWebRequest.Timeout` 在某些网络环境下对 HEAD 请求不生效，导致 `GetResponse()` 阻塞。

**解决**：去掉测速环节，直接按顺序尝试镜像下载。

---

### Bug #10: GitHub 国内访问不稳定（非代码问题）

**现象**：同一份代码，有时候 10 秒 push 成功，有时候 30 分钟 push 不上去。OllamaSetup.exe 下载速度波动极大（50KB/s ~ 500KB/s）。

**原因**：中国到 GitHub 的国际出口带宽有限，受运营商、时段、国际线路拥堵等因素影响，属于基础设施问题，代码无法解决。

**缓解措施**：
- 允许用户提前下载 `OllamaSetup.exe` 放同目录跳过下载
- README 中说明预计 1-2 小时，让用户有心理预期
- 建议用户开启国际网络加速

---

## 经验总结

1. **.NET 网络栈 ≠ 系统网络栈**：PowerShell 用 .NET 发请求，和 `curl.exe` 走不同路径，代理设置需要单独配置。
2. **Windows 控制台有很多历史遗留问题**：快速编辑模式、CRLF 换行符、UTF-8 BOM 等都是坑。
3. **PowerShell 5.1 是 Windows 默认版本**：不要用 PowerShell 7+ 才有的特性（`-Parallel`、三元运算符等）。
4. **免费的东西不可靠**：GitHub 镜像随时可能挂，不要依赖。
5. **大文件下载在国内是硬伤**：1.4GB 从 GitHub 下载，MVP 阶段只能接受慢，后续有钱了上 CDN。