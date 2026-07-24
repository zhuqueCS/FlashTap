# FlashTap Agent-VM 协同测试与开发工作流

> **作者**：2026-07-22 会话
> **价值**：本文档记录了"AI Agent + 人类开发者"通过 VirtualBox VM 进行端到端协同测试与修复的完整方法论，是一套可复制、可推广的协作范式。

---

## 0. 核心理念

传统软件开发-测试循环：

```
改代码 → 手动部署 → 手动跑 → 肉眼看结果 → 报错 → 猜原因 → 改代码 ...
```

Agent 协同循环：

```
人/Agent 发现 bug → Agent 分析根因 → Agent 改代码 → Agent 同步到 VM 共享源
     → Agent 恢复干净快照 → 人一键启动安装 → Agent 实时监控日志
     → 人/Agent 验证产物 → Agent 总结 → 进入下轮
```

**关键差异**：Agent 承担了"分析、修改、同步、恢复、监控"的机械化工作，人只需做"肉眼验证 + 决策"这最后一公里。

---

## 1. 环境架构

```
┌─────────────────────────────────────────────────────────────┐
│                        宿主机器 (Host)                        │
│                                                             │
│  ┌──────────────┐    robocopy /MIR    ┌───────────────┐    │
│  │ 桌面副本       │ ──────────────────→ │  C:\flashtap  │    │
│  │ (开发工作区)   │    Agent 同步       │  (VM 共享源)   │    │
│  └──────────────┘                     └──────┬────────┘    │
│                                             │ 共享文件夹     │
│                          ┌──────────────────┘              │
│                          ▼ Z: 映射                           │
│                    ┌──────────────┐                        │
│                    │  VirtualBox  │  VBoxManage guestcontrol│
│                    │  flashtap_   │←─ Agent 后台监控产物 ──│
│                    │  test (VM)   │                         │
│                    │              │                         │
│                    │  用户: 61959 │  ← 人肉眼验证           │
│                    │  Z:\一键安装  │                         │
│                    └──────────────┘                        │
└─────────────────────────────────────────────────────────────┘
```

### 核心机制

| 组件 | 作用 |
|------|------|
| **共享文件夹 Z:** | 宿主 `C:\flashtap` ↔ VM `Z:\` ，Agent 改完代码 sync 后 VM 立即可见 |
| **快照** | `pre-e2e-baseline-v2`（干净 Win11 + 最新代码），每轮测试后恢复 |
| **guestcontrol** | Agent 通过 `VBoxManage guestcontrol run` 直接核查 VM 内产物（不依赖日志） |
| **实时日志** | 安装脚本写入 `Z:\install.log` → Agent 在宿主侧实时读取 |

---

## 2. 标准协同流程（一轮测试 ≈ 15 分钟）

### Step 1：改代码（Agent，30秒-3分钟）

```
Agent 分析日志/用户反馈 → 定位根因 → edit 相关文件
```

**案例**：
- Bug #17（RunAsUser 弹窗）：Agent 分析到 `-Verb RunAsUser` 在 61959 上下文无意义 → 加 `$needDeElevate` 条件判断
- Bug #23（F5 编译失败）：Agent 回溯 DEVLOG 发现这是历史上首次 MinGW 路径开荒 → 改 `type: shell` → `type: process`

### Step 2：同步到 VM 共享源（Agent，5秒）

```powershell
robocopy "c:\Users\PYX\Desktop\flashtap_V0.01 - 副本" "C:\flashtap" /MIR /XF *.log /XD __pycache__ models vsix_stage
```

或用逐文件 copy：
```powershell
copy "桌面副本\setup-cpp-env.ps1" "C:\flashtap\setup-cpp-env.ps1"
```

### Step 3：恢复 VM 到干净快照 + 开机（Agent，30秒）

```powershell
VBoxManage controlvm flashtap_test poweroff
VBoxManage snapshot flashtap_test restore pre-e2e-baseline-v2
VBoxManage startvm flashtap_test
```

**为什么必须恢复快照**：每轮测试会修改 VM 的注册表、文件系统、环境变量。不恢复会导致轮次间相互污染。

### Step 4：人在 VM 中一键启动（人，10秒）

1. 登录 `61959` / `123`
2. 右键 `Z:\一键安装FlashTap.bat` → **以管理员方式运行**
3. 回复 Agent：**"开始了"**

### Step 5：Agent 实时监控（Agent，后台持续）

```powershell
# 每 N 秒读一次安装日志尾行
Get-Content 'C:\flashtap\install.log' -Encoding UTF8 -Tail 5

# 核查 VM 内真实产物（如扩展目录）
VBoxManage guestcontrol flashtap_test run --username 61959 --password 123 \
    --exe C:\Windows\System32\cmd.exe --wait-stdout -- \
    cmd /c "dir C:\Users\61959\.vscode\extensions /b"
```

Agent 在监控中实时告诉用户当前进度：
```
Ollama ✅，进入 VS Code 安装…
VS Code ✅，进入 C++ 环境…
C++ ✅，模型下载中（8-10分钟）…
```

### Step 6：人验证+反馈（人，1分钟）

安装完成后，人肉眼验证：
- VS Code 有没有弹出？
- 有没有报错弹窗？
- Continue 能不能聊？
- **F5 能不能编译？**
- 快捷方式进入是否同样正常？

反馈给 Agent → Agent 分析 → 进入 Step 1（下一轮）或完成。

---

## 3. 实际 7 轮协同记录

| 轮次 | 耗时 | 人的反馈 | Agent 的响应 | 结果 |
|:--:|------|------|------|:--:|
| 1 | 15min | 手动启动 | 发现 C1/C2/M2/N7 | 架构重构 |
| 2 | 18min | "弹出了 RunAsUser 窗口" | 加条件跳过 RunAsUser | 去掉弹窗但引出 P2 |
| 3 | — | "VM 重启了" | 判断是 Windows Update | 恢复快照 |
| 4 | 10min | "怎么这么慢" | 发现 cpptools 卡死 | 加 90 秒超时 |
| 5 | 15min | "弹窗没了，但 JS 报错 + locale 警告" | explorer 中转方案 | 3 交互 bug 消除 |
| 6 | 18min | "F5 报 program not exist" | 回溯 DEVLOG 发现历史遗留 | type: shell → process |
| 7 | 15min | "**F5 可以了！全部通过！**" | 记录里程碑 | ✅ 完成 |

---

## 4. 关键技巧

### 4.1 日志监控时机

| 阶段 | 等待时间 | 原因 |
|------|:--:|------|
| Python + 网络 | 10秒 | 瞬间完成 |
| Ollama 配置 | 15秒 | 检测现有安装 |
| VS Code 安装 | 30秒 | 扩展下载 |
| C++ 环境 | 1-2分钟 | mingw64 解压 + cpptools |
| 模型下载 | 30秒 | 缓存命中 |
| ollama create | 8-10分钟 | 4.36GB GGUF 导入 |
| Continue 配置 | 5秒 | 复制文件 |

### 4.2 哈希校验（确保 VM 跑的是真代码）

```powershell
# 宿主机算副本哈希
certutil -hashfile "桌面副本\Setup-FlashTap.ps1" SHA256

# VM 内算 Z: 哈希（或直接算 C:\flashtap 宿主机侧）
certutil -hashfile "C:\flashtap\Setup-FlashTap.ps1" SHA256
# 两者必须完全一致
```

### 4.3 Guest Additions 超时处理

VM 刚开机时 guestcontrol 不可用（约需 40-60 秒 GA 服务初始化）：
```powershell
# 轮询等待 GA 就绪
VBoxManage guestproperty get flashtap_test "/VirtualBox/GuestAdd/Version"
# No value → 继续等；返回版本号 → 就绪
```

### 4.4 不要用远程桌面（RDP），直接弹窗

```powershell
# 普通窗口模式（不要 --type headless）
VBoxManage startvm flashtap_test
```
窗口直接弹出在宿主桌面，最像真机，无 RDP 黑屏/卡顿问题。

---

## 5. 为什么这套工作流有价值

### 5.1 对开发效率

| 传统方式 | Agent 协同方式 |
|------|------|
| 改代码 → 手动复制到 VM → 手动回退快照 → 手动跑脚本 → 肉眼盯日志 | 改代码 → Agent 自动同步/恢复/开窗口 → 人一键跑 |
| 编译报错 → 看代码猜 → 改 → 再跑 | Agent 看日志 + 查 VM 产物 → 精准定位 → 改 → 人验证 |
| 测试一次 = 30+ 分钟（大量手动操作） | 测试一次 = 15 分钟（人只需点点鼠标 + 验证） |

### 5.2 对知识传递

- 每轮的结果自动写入 DEVLOG，附带根因分析和修复方案
- 新人无需"扒代码 + 看历史 commit"就能理解每个 bug 的来龙去脉
- 合并/精简文档后项目结构清晰，一页 `DEVLOG.md` 包含全部历史

### 5.3 可推广性

这套方法论不局限于 FlashTap 项目。任何涉及"开发 → VM/容器测试 → 修复"循环的项目都可复用：
- 嵌入式固件测试（QEMU/板子）
- 跨平台安装包验证
- Docker 镜像迭代测试
- CI/CD 失败的本地复现

核心要素就三个：
1. **共享文件系统**（Agent 改的代码测试环境立即可见）
2. **快照/还原**（每轮从相同干净状态开始）
3. **Agent 监控**（Agent 读日志 + 进 VM 验产物，人只需做最后决策）

---

## 6. 快速启动检查清单

对新加入的开发者/Agent：

```
□ 确认 VM 状态：VBoxManage showvminfo flashtap_test --machinereadable | findstr VMState
□ 确认共享文件夹：dir C:\flashtap\一键安装FlashTap.bat
□ 同步最新代码：robocopy "桌面副本" "C:\flashtap" /MIR /XF *.log /XD __pycache__ models vsix_stage
□ 确认哈希一致：certutil -hashfile "C:\flashtap\Setup-FlashTap.ps1" SHA256
□ 恢复干净快照：VBoxManage snapshot flashtap_test restore pre-e2e-baseline-v2
□ 窗口模式启动：VBoxManage startvm flashtap_test
□ 人登录 61959/123，右键 Z:\一键安装FlashTap.bat → 管理员运行
□ 人说"开始了"，Agent 开始监控 C:\flashtap\install.log
□ 人验证后反馈结果，Agent 记录 DEVLOG
```

---

## 7. 附录：Agent 可用工具速查

```powershell
# === VM 控制 ===
VBoxManage showvminfo flashtap_test --machinereadable       # 状态
VBoxManage controlvm flashtap_test poweroff                  # 关机
VBoxManage snapshot flashtap_test restore pre-e2e-baseline-v2 # 恢复快照
VBoxManage startvm flashtap_test                             # 窗口启动

# === VM 内执行（不依赖远程桌面） ===
VBoxManage guestcontrol flashtap_test run --username 61959 --password 123 \
    --exe "C:\Windows\System32\cmd.exe" --wait-stdout -- cmd /c "<命令>"

# === 文件同步 ===
robocopy "桌面副本" "C:\flashtap" /MIR /XF *.log /XD __pycache__ models vsix_stage
copy "桌面副本\文件" "C:\flashtap\文件"

# === 日志监控 ===
Get-Content C:\flashtap\install.log -Encoding UTF8 -Tail 10

# === 哈希校验 ===
certutil -hashfile "C:\flashtap\Setup-FlashTap.ps1" SHA256
```

---

## 8. 无共享文件夹工作流（2026-07-25 收网测试新增）

> 适用场景：需验证"用户在无任何 Agent 辅助的空白电脑上独立完成安装"的真实流程

### 8.1 与标准流程的差异

| 标准流程 (§2) | 无共享文件夹流程 |
|------|------|
| 共享文件夹 Z: 映射 | `VBoxManage guestcontrol copyto` 注入文件 |
| Agent 改代码 → robocopy 同步 | 代码不改，验证 GitHub 现有代码 |
| 日志在宿主机读 `C:\flashtap\install.log` | 日志在 VM 内，通过 guestcontrol `type` 读取 |
| 人一键运行共享文件夹中的 bat | 人从桌面文件夹手动运行 |

### 8.2 渐进验收法

每一步验证两个东西：
1. **下载源可达**（让脚本自然发起连接，日志记录 HTTP 状态码）
2. **本地离线文件可用**（源验证通过后注入预下载文件 → 脚本检测到已有文件 → 跳过下载）

流程：人启动 bat → Agent 监控日志 → 脚本进入下载阶段 → 日志显示"尝试: xxx源" → HTTP 200 → 源验证完成 → Agent 注入预下载文件 → 脚本跳过下载 → 进入下一阶段。

### 8.3 guestcontrol copyto 注入

```powershell
VBoxManage guestcontrol flashtap_test copyto --username 61959 --password 123 \
    "宿主文件完整路径" "VM内完整目标路径"
```

已知限制：大文件（>1GB）传输时间取决于宿主→VM I/O 带宽；中文路径编码问题；WScript.Shell COM 不可用（快捷方式需 VBS 中转）。

### 8.4 子脚本直接执行（避开死锁）

当 Bug #51 (`Start-Process -Wait`) 死锁在 VM 中 100% 复现时，直接按顺序执行子脚本：

```powershell
VBoxManage guestcontrol flashtap_test run --username 61959 --password 123 \
    --exe "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" --wait-stdout -- \
    -NoProfile -ExecutionPolicy Bypass -Command "
        $env:FLASHTAP_ORIGINAL_USER='61959';
        cd 'C:\Users\61959\Desktop\FlashTap-test';
        .\install-vscode.ps1;
        .\setup-cpp-env.ps1;
    "
```

效果：子脚本在同一进程内顺序执行，不存在进程间 `-Wait` 死锁。

### 8.5 本轮核心发现

1. **快照"干净"需核实**：`pre-final-clean` 声称干净但残留 Ollama/VS Code
2. **Bug #51 仅在真空白 + 慢 I/O 触发**：历史 7 轮"秒过"是因为快照中软件已预装
3. **渐进验收法**：从"等 2 小时下载"变为"5 秒验证源 + 1 秒注入文件 + 2 分钟安装"
4. **所有下载源验证通过**：ModelScope, GitHub, ghproxy, ollama.com, pip 清华镜像全部可达
5. **VS Code 幽灵路径**：`D:\Microsoft VS Code` 是快照残留，真装后路径为 `C:\Users\<user>\AppData\Local\Programs\Microsoft VS Code`
