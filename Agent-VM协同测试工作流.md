# FlashTap Agent-VM 协同测试与开发工作流

> 版本：2026-07-25 | 记录"AI Agent + 人类开发者"通过 VirtualBox VM 进行端到端协同测试与修复的方法论。

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

关键差异：Agent 承担"分析、修改、同步、恢复、监控"的机械化工作，人只需做"肉眼验证 + 决策"。

---

## 1. 环境架构

```
┌─────────────────────────────────────────────────────────────┐
│                        宿主机器 (Host)                        │
│                                                             │
│  ┌──────────────┐    robocopy /MIR    ┌───────────────┐    │
│  │ 项目代码目录    │ ──────────────────→ │  VM 共享源     │    │
│  │ (开发工作区)   │    Agent 同步       │               │    │
│  └──────────────┘                     └──────┬────────┘    │
│                                             │ 共享文件夹     │
│                          ┌──────────────────┘              │
│                          ▼ Z: 映射                           │
│                    ┌──────────────┐                        │
│                    │  VirtualBox  │  VBoxManage guestcontrol│
│                    │  flashtap_   │←─ Agent 后台监控产物 ──│
│                    │  test (VM)   │                         │
│                    │  Z:\一键安装  │  ← 人肉眼验证           │
│                    └──────────────┘                        │
└─────────────────────────────────────────────────────────────┘
```

### 核心机制

| 组件 | 作用 |
|------|------|
| 共享文件夹 | 宿主代码目录 ↔ VM `Z:\`，Agent 改完代码 sync 后 VM 立即可见 |
| 快照 | 干净基线，每轮测试后恢复，确保轮次间不相互污染 |
| guestcontrol | Agent 通过 `VBoxManage guestcontrol run` 直接核查 VM 内产物 |
| 实时日志 | 安装脚本写入 `install.log` → Agent 实时读取 |

---

## 2. 标准协同流程

### Step 1：改代码（Agent，30秒-3分钟）

Agent 分析日志/用户反馈 → 定位根因 → 修改相关文件。

案例：
- Bug #17（RunAsUser 弹窗）：分析到 `-Verb RunAsUser` 在 VM 账户上下文无意义 → 加条件判断
- Bug #23（F5 编译失败）：回溯 DEVLOG 发现历史遗留 MinGW 路径问题 → 修正 task type

### Step 2：同步到 VM 共享源（Agent，5秒）

```powershell
robocopy "{项目代码目录}" "{VM共享源路径}" /MIR /XF *.log /XD __pycache__ models vsix_stage
copy "{项目代码目录}\文件" "{VM共享源路径}\文件"
```

### Step 3：恢复 VM 到干净快照 + 开机（Agent，30秒）

```powershell
VBoxManage controlvm flashtap_test poweroff
VBoxManage snapshot flashtap_test restore {快照名}
VBoxManage startvm flashtap_test
```

### Step 4：人在 VM 中一键启动（人，10秒）

1. 登录 VM（使用设定的 VM 账户）
2. 右键 bat → 以管理员方式运行
3. 回复 Agent："开始了"

### Step 5：Agent 实时监控（Agent，后台持续）

```powershell
# 读安装日志尾行
Get-Content '{日志路径}\install.log' -Encoding UTF8 -Tail 5

# 核查 VM 内真实产物（如扩展目录）
VBoxManage guestcontrol flashtap_test run --username {VM账户} --password {VM密码} \
    --exe C:\Windows\System32\cmd.exe --wait-stdout -- \
    cmd /c "dir C:\Users\{VM账户}\.vscode\extensions /b"
```

Agent 实时汇报进度：

```
Ollama ✅，进入 VS Code 安装…
VS Code ✅，进入 C++ 环境…
C++ ✅，模型下载中…
```

### Step 6：人验证+反馈（人，1分钟）

安装完成后，人肉眼验证：VS Code 弹出、无报错、Continue 可用、F5 编译正常、快捷方式可用。

反馈给 Agent → 分析 → 下一轮或完成。

---

## 3. 实际协同记录

| 轮次 | 耗时 | 人的反馈 | Agent 的响应 | 结果 |
|:--:|------|------|------|:--:|
| 1 | 15min | 手动启动 | 发现 C1/C2/M2/N7 | 架构重构 |
| 2 | 18min | "弹出了 RunAsUser 窗口" | 加条件跳过 RunAsUser | 去掉弹窗 |
| 3 | — | "VM 重启了" | 判断是 Windows Update | 恢复快照 |
| 4 | 10min | "怎么这么慢" | 发现 cpptools 卡死 | 加 90 秒超时 |
| 5 | 15min | "弹窗没了，但 JS 报错" | explorer 中转方案 | 3 交互 bug 消除 |
| 6 | 18min | "F5 报错" | 回溯 DEVLOG 修正 task type | 修复 |
| 7 | 15min | "F5 可以了！全部通过！" | 记录里程碑 | ✅ 完成 |

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
| ollama create | 8-10分钟 | GGUF 导入 |
| Continue 配置 | 5秒 | 复制文件 |

### 4.2 哈希校验

```powershell
certutil -hashfile "{项目代码目录}\Setup-FlashTap.ps1" SHA256
certutil -hashfile "{VM共享源路径}\Setup-FlashTap.ps1" SHA256  # 必须一致
```

### 4.3 Guest Additions 超时处理

VM 刚开机时 guestcontrol 不可用（约需 40-60 秒 GA 初始化）：

```powershell
VBoxManage guestproperty get flashtap_test "/VirtualBox/GuestAdd/Version"
# No value → 继续等；返回版本号 → 就绪
```

### 4.4 不要用远程桌面

```powershell
VBoxManage startvm flashtap_test  # 窗口模式，最像真机
```

---

## 5. 可达性检查清单

对新加入的开发者/Agent：

```
□ 确认 VM 状态：VBoxManage showvminfo flashtap_test --machinereadable | findstr VMState
□ 确认共享文件夹：dir "{VM共享源路径}\一键安装FlashTap.bat"
□ 同步最新代码：robocopy "{项目代码目录}" "{VM共享源路径}" /MIR /XF *.log /XD __pycache__
□ 确认哈希一致
□ 恢复干净快照：VBoxManage snapshot flashtap_test restore {基线快照名}
□ 窗口模式启动：VBoxManage startvm flashtap_test
□ 人登录，右键 bat → 管理员运行
□ 人说"开始了"，Agent 开始监控
□ 人验证后反馈，Agent 记录 DEVLOG
```

---

## 6. 附录：Agent 可用工具速查

```powershell
# === VM 控制 ===
VBoxManage showvminfo flashtap_test --machinereadable
VBoxManage controlvm flashtap_test poweroff
VBoxManage snapshot flashtap_test restore {快照名}
VBoxManage startvm flashtap_test

# === VM 内执行 ===
VBoxManage guestcontrol flashtap_test run --username {VM账户} --password {VM密码} \
    --exe "C:\Windows\System32\cmd.exe" --wait-stdout -- cmd /c "<命令>"

# === 文件同步 ===
robocopy "{项目代码目录}" "{VM共享源路径}" /MIR /XF *.log /XD __pycache__

# === 日志监控 ===
Get-Content {日志路径}\install.log -Encoding UTF8 -Tail 10

# === 哈希校验 ===
certutil -hashfile "{文件路径}" SHA256
```

---

## 7. 无共享文件夹工作流（2026-07-25 新增）

适用场景：需验证"用户在无任何 Agent 辅助的空白电脑上独立完成安装"的真实流程。

### 7.1 与标准流程的差异

| 标准流程 | 无共享文件夹流程 |
|------|------|
| 共享文件夹 Z: 映射 | `VBoxManage guestcontrol copyto` 注入文件 |
| Agent 改代码 → robocopy 同步 | 代码不改，验证 GitHub 现有代码 |
| 日志在宿主机读 | 日志在 VM 内，通过 guestcontrol `type` 读取 |
| 人一键运行共享文件夹中的 bat | 人从桌面文件夹手动运行 |

### 7.2 渐进验收法

每一步验证两个东西：
1. 下载源可达（让脚本自然发起连接，日志记录 HTTP 状态码）
2. 本地离线文件可用（源验证通过后注入预下载文件 → 脚本跳过下载）

流程：人启动 bat → Agent 监控日志 → 脚本进入下载阶段 → 日志显示"尝试: xxx源" → HTTP 200 → Agent 注入预下载文件 → 脚本跳过下载 → 进入下一阶段。

### 7.3 guestcontrol copyto 注入

```powershell
VBoxManage guestcontrol flashtap_test copyto --username {VM账户} --password {VM密码} \
    "宿主文件完整路径" "VM内完整目标路径"
```

已知限制：大文件（>1GB）传输时间取决于宿主→VM I/O 带宽；中文路径编码问题；WScript.Shell COM 不可用（快捷方式需 VBS 中转）。

### 7.4 子脚本直接执行（避开死锁）

当 Bug #51 (`Start-Process -Wait`) 死锁在 VM 中 100% 复现时，直接顺序执行子脚本：

```powershell
VBoxManage guestcontrol flashtap_test run --username {VM账户} --password {VM密码} \
    --exe "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" --wait-stdout -- \
    -NoProfile -ExecutionPolicy Bypass -Command "
        cd '{项目目录}';
        .\install-vscode.ps1;
        .\setup-cpp-env.ps1;
    "
```

子脚本在同一进程内顺序执行，不存在进程间 `-Wait` 死锁。

### 7.5 本轮核心发现

1. 快照"干净"需核实：声称干净的快照可能残留 Ollama/VS Code
2. Bug #51 仅在真空白 + 慢 I/O 触发：历史轮次"秒过"是因快照中软件已预装
3. 渐进验收法：从"等 2 小时下载"变为"5 秒验证源 + 1 秒注入文件 + 2 分钟安装"
4. 所有下载源验证通过：ModelScope, GitHub, ghproxy, ollama.com, pip 清华镜像全部可达
5. VS Code 幽灵路径：某些安装器检测到的路径是快照残留

---

## 8. AI 协同开发的身份边界（2026-07-25）

### 8.1 背景

在项目收网测试后，项目作者向两个不同的 AI 模型问了同一个问题：

> "项目一直是 AI 协同开发，自己没写过一行代码——需要学到什么程度？项目含金量如何？"

两个 AI 模型给出了截然不同的评估框架。

### 8.2 模型 A 的回答（教练型）

**框架**：以"下一步该做什么"为核心。

- 零基础不是缺陷，反而是独特优势
- 需要学的不是写代码，而是"当项目经理"——知道组件做什么、能看日志定位问题、能描述症状喂给 AI
- 给的是 10 小时学习路线 + 真机测试方案
- 项目的含金量在于"证明一个人能用 AI 做出能用的产品"

### 8.3 模型 B 的回答（评审型）

**框架**：以"当前状态打几分"为核心。

- 展现了"资深架构师/AI 编排者"水准，但不是"徒手写代码的工程师"
- 代码本身暴露 AI 生成痕迹：防御性 try/except 泛滥、"撒网式"兼容写法、机器路径泄漏
- 项目含金量 6/10：工程价值真实，但技术原创性为零，代码 hygiene 差
- 建议：清理仓库、补自动化测试、不要说"独立开发"

### 8.4 解读：两个答案都对，但站在不同阶段

| | 模型 A（教练） | 模型 B（评审） |
|------|------|------|
| 对话立场 | 带你迈下一步 | 给你当前打分 |
| 时间尺度 | 接下来一周 | 接下来一年 |
| 评价对象 | AI 协同者的能力 | 独立开发者的能力 |
| 风险框架 | 怕你因"不会写代码"放弃 | 怕你因"AI 写的代码"误判自己 |

### 8.5 启示

1. **"能做出复杂系统"比"会写代码"值钱**。系统级直觉、验证纪律、知识沉淀——这三样在任何团队都是高级能力。
2. **同一个项目，价值取决于谁来解读**。对外讲"AI 辅助开发"是诚实且足够的；追求技术深度时，另一个模型的技术清单就是路线图。
3. **两种 AI 的对立本身就是这个时代的原始史料**。2026 年，一个人用 AI 做出了产品，两个 AI 争论这个人算不算"开发者"——这个过程本身就值得记录。
