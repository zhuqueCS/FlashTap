# FlashTap VM 测试环境与全流程接手文档

> 用途：给后续接手本项目的 AI / 开发者看，省去重新摸索环境、路径、VirtualBox 管道的半天时间。
> 最后更新：2026-07-22
> 更新：2026-07-25

---

## 0. 一句话记住核心规则（最重要）

**改代码只在桌面副本，测试前必须把副本整体同步到 `C:\flashtap`，VM 跑的就是 `C:\flashtap`。**

切忌直接改 `C:\flashtap` 里的脚本——那是 VM 共享源，不在你的工作区，改了也跟你的版本管理脱节。（本人曾踩坑：在副本改完，VM 跑的是旧 `C:\flashtap`，误以为"修复成功"实则没生效。）

### 0.1 🔴 致命陷阱：桌面上有两个同名文件夹，同步错了全部白干

桌面上存在**两个极易混淆的 flashtap 文件夹**：

| 文件夹 | 路径 | 性质 | bat 文件大小 |
|--------|------|------|:--:|
| **旧版废弃代码** ⚠️ | 桌面旧文件夹 | 不要使用 | - |
| **当前工作区** ✅ | `{项目代码路径}` | 开发工作区（改这里） | - |

**如果你把 robocopy 路径写成 `flashtap_V0.01` 而不是 `flashtap_V0.01 - 副本`，你会把旧版代码同步到 `C:\flashtap`，VM 跑的就是过期代码，所有修改全部失效。**（2026-07-22 本次会话实测踩坑：发现 `C:\flashtap` 里的 bat 是 2,308 字节旧版，而桌面副本是 2,912 字节新版——差 604 字节，少了整个管理员检测逻辑。）

**正确同步命令（直接抄，不要自己手打路径）：**
```powershell
robocopy "{项目代码路径}" "C:\flashtap" /MIR /XF *.log /XD __pycache__ models vsix_stage
```

**快速验证是否同步正确：**
```powershell
# 对比两个 bat 文件大小，必须一致
dir "C:\flashtap\一键安装FlashTap.bat"
dir "c:\Users\{DevUser}\Desktop\flashtap_V0.01 - 副本\一键安装FlashTap.bat"
```

> 📌 建议：把 `flashtap_V0.01` 重命名为 `flashtap_V0.01_OLD_DO_NOT_USE` 或直接删除，从源头杜绝混淆。

---

## 1. 环境架构

| 角色 | 位置 | 说明 |
|------|------|------|
| **开发真源 / 工作区**（改这里） | `{项目代码路径}` | AI 的工作目录，所有脚本修改在此 |
| **VM 共享源**（测试跑这里） | 宿主 `C:\flashtap\` | 被 VirtualBox 共享给 VM |
| **VM 内共享盘** | VM 内 `Z:` = `\\VBoxSvr\flashtap` | 安装器全程从 `Z:` 读脚本 |
| **VM 内安装产物目录** | VM 内 `C:\FlashTap\`（注意大写 F，与上面小写不同！） | mingw64、cpp-workspace、日志写这里 |
| **VirtualBox VM** | 名称 `flashtap_test` | 客户机 Windows |
| **VM 登录账户** | `{VMUser}` / 密码 `{VMPassword}` | 用户实际使用此账户 |
| **运行方式** | 右键 `一键安装FlashTap.bat` → "以管理员方式运行" | 统一入口，不再自动 UAC 提权（避免跨用户上下文丢失） |

> ⚠️ 大小写陷阱：`C:\flashtap`（宿主共享源，小写 f）≠ `C:\FlashTap`（VM 内安装目录，大写 F）。两者完全无关，别搞混。

---

## 2. 测试前必做：同步副本 → C:\flashtap

每次修改完桌面副本、准备在 VM 重测前，必须执行（在**宿主机** PowerShell / cmd 跑）：

```powershell
robocopy "c:\Users\{DevUser}\Desktop\flashtap_V0.01 - 副本" "C:\flashtap" /MIR /XF *.log /XD __pycache__ models
```

- `/MIR`：镜像同步（副本有、C:\flashtap 没有的会新增；副本删了的会删掉）。
- `/XF *.log`：排除日志文件（避免覆盖/误删 VM 写回的诊断日志；且 /XF 排除项在 /MIR 下不会被删除）。
- `/XD __pycache__ models`：排除 Python 缓存和 models 大文件（含 `.incomplete`）。

同步完，VM 内的 `Z:` 自动看到最新副本（Z: 是实时共享，无需重启 VM）。

---

## 3. 用 guestcontrol 进 VM 核查真实产物（管道）

不要信宿主机上的日志"成功"字样——日志与用户真实体验常脱节。必须进 VM 看**真实产物**。

### 3.1 通用命令模板

```bat
"C:\Program Files\VBoxManage.exe" guestcontrol flashtap_test run ^
  --username {VMUser} --password {VMPassword} ^
  --exe "C:\Windows\System32\cmd.exe" --wait-stdout -- ^
  cmd /c "<要执行的命令>"
```

> 注意：`--wait-stdout --` 后面跟 `cmd /c "..."`。命令里的路径用 VM 内路径（如 `C:\FlashTap\...`、`Z:\...`）。管道输出可能乱码，属正常。

### 3.2 常用核查命令（直接抄）

```bat
REM 1) 看 VM 内安装产物目录
cmd /c "dir /b C:\FlashTap"

REM 2) 看 {VMUser} 账户装了哪些 VS Code 扩展（关键：有无 cpptools / 中文包）
cmd /c "dir /b C:\Users\{VMUser}\.vscode\extensions"

REM 3) 看 {VMUser} 的 locale.json（空=英文界面）
cmd /c "type \"C:\Users\{VMUser}\AppData\Roaming\Code\User\locale.json\""

REM 4) 看 C++ 工作区的 launch/tasks 配置（确认 Windows 还是 WSL 编译）
cmd /c "type C:\FlashTap\cpp-workspace\.vscode\launch.json & type C:\FlashTap\cpp-workspace\.vscode\tasks.json"

REM 5) 看 MinGW 编译器是否真装上
cmd /c "dir /b C:\FlashTap\mingw64\bin\g++.exe"

REM 6) 看 WSL 是否装了发行版（影响主脚本走 WSL 还是 Windows 分支）
cmd /c "wsl --list --verbose"

REM 7) 看当前 VS Code 进程、用户 PATH
cmd /c "tasklist /fi \"imagename eq code.exe\""
cmd /c "reg query \"HKCU\Environment\" /v Path"
```

---

## 4. 已知根因清单（本次会话已定位，后续直接修）

以下问题导致"日志成功、实际失败"：

| # | 症状 | 根因 | 关键文件/行 |
|---|------|------|------------|
| R1 | F5 用不了（无 C/C++ 调试器） | `ms-vscode.cpptools` 没装进 **{VMUser}** 账户（装到了 Administrator 或被网络挡掉）；`extensions.list` 注释说 cpptools "在 WSL 远端单独装"，但 VM **没 WSL** | `extensions.list`、`setup-cpp-env.ps1` 的 `Install-CpptoolsExtension`（用 `Code.exe` 直接装，没重置 env 到 {VMUser}） |
| R2 | VS Code 是英文 | 中文包 `ms-ceintl.vscode-language-pack-zh-hans` 在 {VMUser} 下，但 `locale.json` 没写/为空 | `install-vscode.ps1` 的 locale 写入逻辑、主脚本启动参数 |
| R3 | 桌面快捷方式打开"不可用的空白 VS Code" | 最终 VS Code 启动只带 `--locale=zh-cn`、**没带任何文件夹**；`.wsl-distro-name` 不存在导致 WSL 分支跳过、Windows 分支又不带文件夹 | `Setup-FlashTap.ps1` 约 677 行 `vscArgs = @('--locale=zh-cn')`、约 1114 行快捷方式 |
| R4 | 提权装错账户 | 安装器 UAC 提权以 Administrator 跑，`code --install-extension` 和写 PATH 都进了 Administrator，而非 {VMUser} | `setup-cpp-env.ps1`、`Setup-FlashTap.ps1` 的提权段 |
| R5 | 架构自相矛盾 | 主脚本把 C++ 工作区写死成 WSL 路径 `/home/lc-cpp-workspace` 并以 `--remote wsl+` 启动；但 `setup-cpp-env.ps1` 装的是 **Windows 原生 MinGW**，给 `cpp-workspace` 写 Windows 版 launch.json | `Setup-FlashTap.ps1` 约 686 行、`setup-cpp-env.ps1` |
| R6 | 安装阶段被跳过 | 若检测到"已配置"则跳过 VS Code / C++ 阶段，导致重跑也不修复 | `Setup-FlashTap.ps1` 的 VS Code 阶段判断 |

---

## 5. 关键文件职责（别改错文件）

| 文件 | 职责 | 注意 |
|------|------|------|
| `一键安装FlashTap.bat` | 用户入口 | 调用根目录 `Setup-FlashTap.ps1` |
| `Setup-FlashTap.ps1`（**根目录**版本） | **主编排脚本**，VM 实际跑这个 | **`LocalCoder_project/` 下还有一份不同版本**，`.bat` 用的是根目录的，别被误导 |
| `setup-cpp-env.ps1` | C++ 环境（MinGW、cpptools、launch.json） | 用 `Code.exe` 装扩展 → 装错账户（见 R1/R4） |
| `install-vscode.ps1` | VS Code 安装 + 4 个扩展 + locale | 69-75 行重置 `$env:USERPROFILE`/`APPDATA` 到 {VMUser}，**这是正确范式**，cpptools/locale 应复用此机制 |
| `extensions.list` | 扩展清单 | 注释说 cpptools 不在此列表（假定 WSL 装），但 VM 无 WSL → 矛盾（R1） |
| `.flashtap-env.txt` | 目标用户信息（{VMUser} 等） | `install-vscode.ps1` 从中读用户并重设 env |
| `config.json` / `config.yaml` / `config.ts` / `continue-config.*` | 配置 | 多份配置并存，留意一致性 |

---

## 6. 测试验证清单（重跑后逐项确认）

- [ ] VM 内 `C:\Users\{VMUser}\.vscode\extensions` 含 `ms-vscode.cpptools`
- [ ] `C:\Users\{VMUser}\AppData\Roaming\Code\User\locale.json` 内容为 `{"locale":"zh-cn"}`
- [ ] 打开 VS Code 为**中文界面**
- [ ] 桌面快捷方式打开的是**带 C++ 工作区的 VS Code**（非空窗口），F5 可用 cppdbg 调试
- [ ] `C:\FlashTap\mingw64\bin\g++.exe` 存在，`cpp-workspace\.vscode\launch.json` 指向 Windows MinGW（非 WSL）
- [ ] 不弹 VS / 不弹空白不可用窗口

---

## 7. 给后续 AI 的建议操作顺序

1. 在桌面副本 `flashtap_V0.01 - 副本` 修 R1–R5（重点：让 cpptools + locale.json 走 `install-vscode.ps1` 的 {VMUser} env 重置范式；让主脚本 Windows 分支也带文件夹启动 VS Code；统一 MinGW/Windows 编译路径）。
2. 跑第 2 节的 `robocopy` 同步到 `C:\flashtap`。
3. 在 VM 内重跑安装器（或单独重跑 VS Code / C++ 阶段）。
4. 用第 3.2 节的 guestcontrol 命令核查真实产物，对照第 6 节清单。
5. 不要只看日志"成功"就下结论，必须核真实产物。

---

## 8. 坑位警告（血泪）

- ❌ 不要在 `C:\flashtap` 直接改——改了之后桌面副本一同步就被覆盖，且脱离版本管理。
- ❌ 不要信"日志说成功"——本次日志全程"成功"但用户实际全失败。
- ❌ 别把 `C:\flashtap` 和 `C:\FlashTap` 搞混（大小写）。
- ❌ 别被 `LocalCoder_project/` 里的同名 `Setup-FlashTap.ps1` 迷惑，VM 跑的是根目录那份。
- ⚠️ VM 联网可能受限，VSIX 下载失败会导致扩展装不上——核查时优先看"真实装上没有"，而非"下没下载"。

---

## 附录 A：真实人工端到端测试 SOP（你点击 + 我看日志/产物）

### A.0 为什么需要这节

之前的 AI 在 VM 里"找了半天说没安装"——根因是它不知道：VM 名 `flashtap_test`、Z: 共享（`\\VBoxSvr\flashtap` → 宿主 `C:\flashtap`）、guestcontrol 管道、真实产物路径（`C:\FlashTap`、`C:\Users\{VMUser}`）。本节把"人点 + AI 查"的完整动作写死，**照做即可，无需重新摸索**。

### A.1 角色分工

- **你（用户）**：在 VM 内手动操作——双击安装 bat、双击桌面快捷方式、按 F5。
- **我（AI）**：在宿主机用 guestcontrol + 读 `C:\flashtap\*.log` 核查 VM 真实产物，记录真实症状。

### A.2 回到"空白环境"基线（每次重测前做）

VM 已为你备好空白快照（用 `VBoxManage snapshot flashtap_test list` 可查）：

- `pre-ga-clean+GAs`：**空白 Win11 + 已装 GAs + Z: 共享自动挂载**（推荐基线）
- `pre-e2e-20260721`：端到端测试前的安全快照

恢复命令（**需 VM 先关机**）：

```bat
REM 1) 关机
"C:\Program Files\VBoxManage.exe" controlvm flashtap_test poweroff
REM 2) 恢复到空白基线
"C:\Program Files\VBoxManage.exe" snapshot flashtap_test restore pre-ga-clean+GAs
REM 3) 开机（headless 无界面，用 guestcontrol 交互）
"C:\Program Files\VBoxManage.exe" startvm flashtap_test --type headless
```

> ⚠️ 恢复快照会**丢弃 VM 内所有改动**（含上次安装残留 `C:\FlashTap`），正是我们要的"空白"。恢复后第一次开机可能较慢。

### A.2.1 禁 Windows Update + 拍基线快照（一次性，避免恢复快照被更新硬控）

实测：恢复快照时常被 Windows 更新"硬控"很久，拖慢测试。解决办法（一次性）：

1. 在 VM 内 **Win+R → `cmd` → Ctrl+Shift+Enter 以管理员运行**，执行：
   ```bat
   sc config wuauserv start= disabled & net stop wuauserv & sc config UsoSvc start= disabled & net stop UsoSvc & reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /t REG_DWORD /d 1 /f & echo DONE
   ```
   > ⚠️ 权限坑：`{VMUser}` 令牌被 UAC 过滤，改不了系统服务（`拒绝访问`）；`Administrator` guestcontrol 又登不进。所以**必须用户在 VM 内手动以管理员运行**，AI 无法自动完成这一步。
2. 已拍好基线快照 **`pre-e2e-noupdate`**（空白 Win11 + 已禁更新 + `Z:` 共享指向桌面副本）。以后每次重测前 `restore pre-e2e-noupdate` 即可，不再卡更新。

### A.3 同步副本 → C:\flashtap（见正文第 2 节）

恢复快照后、安装前，把最新桌面副本同步过去：

```powershell
robocopy "c:\Users\{DevUser}\Desktop\flashtap_V0.01 - 副本" "C:\flashtap" /MIR /XF *.log /XD __pycache__ models
```

Z: 是实时共享，同步完 VM 内 `Z:` 立即看到最新脚本。

### A.4 你在 VM 内的操作（人工测试，逐步记录）

1. 登录 VM（账户 `{VMUser}` / `{VMPassword}`）。
2. 打开 `Z:` 盘（= 宿主 `C:\flashtap`），**双击 `一键安装FlashTap.bat`**。
3. 全程观察并告诉我：
   - 是否弹出 VS / VS 安装界面；
   - 弹出的终端窗口是**中文**还是英文；
   - 桌面是否生成 `FlashTap` 快捷方式；
   - 中途有无报错 / 卡死 / 弹出"不可用"窗口。
4. 安装结束后，**双击桌面 `FlashTap` 快捷方式**：
   - 打开的是否是**带 C++ 工作区的 VS Code**（而非空白"不可用的"窗口）；
   - 界面是否**中文**；
   - 打开一个 `.cpp`，按 **F5**：能否启动 cppdbg 调试（而非报错"找不到调试器/配置"）。

### A.5 我（AI）在宿主机的核查（对照你的观察）

安装中/后，我用正文第 3.2 节的 guestcontrol 命令查 VM 真实产物，重点：

- `C:\Users\{VMUser}\.vscode\extensions` 是否含 `ms-vscode.cpptools`（R1）
- `C:\Users\{VMUser}\AppData\Roaming\Code\User\locale.json` 内容（R2）
- `C:\FlashTap\cpp-workspace\.vscode\launch.json` 是否指向 Windows MinGW（R3/R5）
- 宿主日志 `C:\flashtap\install.log` / `vscode-install.log` / `cpp-env.log`（**仅参考**，以真实产物为准）

### A.6 真实症状记录模板（每轮测试填）

| 现象 | 你的观察 | AI 核查结果 | 对应根因 |
|------|---------|------------|---------|
| F5 调试 | ？ | ？ | R1 |
| 界面语言 | ？ | ？ | R2 |
| 快捷方式窗口 | ？ | ？ | R3 |
| MinGW 编译 | ？ | ？ | R5 |
| 提权装错账户 | — | ？ | R4 |

### A.7 之前 AI 失败的原因（避免重蹈）

它默认"VM 没装 / 找不到 VM"，是因为：

1. 不知道 VM 叫 `flashtap_test`，也没用 guestcontrol 进 VM；
2. 不知道安装产物在 VM 内 `C:\FlashTap`（不是宿主 `C:\flashtap`，两者大小写都不同）；
3. 不知道用户实际登录账户是 `{VMUser}`，而安装器提权把东西装到了 Administrator；
4. 只信了日志"成功"字样，没核真实产物。

本文件已补齐以上全部管道、路径与真实核查方法。

---

## 附录 B：VBoxManage 被"僵尸快照锁死"的诊断 + 当前基线 + 新对话衔接

### B.1 现象（曾卡住整轮测试）

某次执行 `snapshot take pre-e2e-noupdate` 时，前端显示命令"被跳过"，但**后端仍在后台跑快照**，VM 卡在 `OnlineSnapshotting` 状态。此后**所有** `VBoxManage` 命令（连 `showvminfo` 查状态）全部阻塞无响应——因为 VirtualBox 是单会话锁模型，一个未释放的快照操作会堵死后续全部命令。

> 这不是 AI/对话上下文的问题，也不是 VM 内部慢，纯粹是宿主侧 VBox 会话锁被占死。

### B.2 解锁（强制释放会话锁）

在**宿主机** PowerShell/cmd 执行（杀掉占锁的后台进程，VM 当前反正要重来，无害）：

```bat
taskkill /f /im VBoxSVC.exe
taskkill /f /im VBoxHeadless.exe
taskkill /f /im VBoxVM.exe
```

杀完 `VBoxSVC` 会被下次 `VBoxManage` 调用自动重启。验证是否解锁：`VBoxManage showvminfo flashtap_test --machinereadable | findstr VMState` 能秒回即正常。

### B.3 当前干净基线快照（新对话请认准这个）

- `pre-e2e-noupdate` **已失效**：它是被强杀快照操作时回滚清除的（创建未完成）。**不要再用它**。
- 当前有效基线 = **`pre-e2e-baseline`**（UUID 见 `snapshot list`），描述：空白 Win11 + 禁更新 + `C:\FlashTap` 已清空 + `Z:` 共享指向桌面副本。
- ⚠️ 若强杀快照后 `VBoxManage` 报"找不到快照/状态异常"，先执行 B.2 解锁，再 `snapshot list` 确认真实快照列表。

### B.4 快照过多会拖慢 VM（已验证现象）

当前快照链偏长（test1 → test2 → pre-e2e-20260721 → pre-ga-clean → pre-ga-clean+GAs → pre-e2e-baseline）。VirtualBox 用差分磁盘，链越长写放大越严重，VM 内磁盘 I/O 越慢，表现为"VM 很卡"。

建议清理无用的孤立早期快照（VM 必须 `poweroff` 后执行）：

```bat
"C:\Program Files\VBoxManage.exe" controlvm flashtap_test poweroff
"C:\Program Files\VBoxManage.exe" snapshot flashtap_test delete test1
"C:\Program Files\VBoxManage.exe" snapshot flashtap_test delete test2
```

> 仅删 `test1/test2` 这类无子节点的孤立快照，安全且能缩短链。主线 `pre-e2e-20260721 → pre-ga-clean → pre-ga-clean+GAs → pre-e2e-baseline` 保留，勿删祖先节点。

### B.5 新对话衔接 SOP（照做即可，不重蹈卡死）

1. **第一步先确认命令通畅**（避免被僵尸锁卡）：
   ```bat
   "C:\Program Files\VBoxManage.exe" showvminfo flashtap_test --machinereadable | findstr VMState
   ```
   若阻塞无响应 → 执行 B.2 解锁后再试。
2. 若 VM 不在 `pre-e2e-baseline`：先 `poweroff`，再 `snapshot flashtap_test restore pre-e2e-baseline`。
3. 测试前同步副本（正文第 2 节 robocopy）。
4. 用户在 VM 内双击 `Z:\一键安装FlashTap.bat`，AI 用 guestcontrol 核查真实产物（附录 A）。
5. 每轮重测前：`poweroff` → `restore pre-e2e-baseline` → 同步副本 → 开机，回到干净基线。

---

## 附录 C：VM 黑屏 / 卡顿真凶与修复（显示链路，实测）

> ⚠️ **重要更正**：此前几轮对"VM 黑屏/卡顿"的判断（内存 swap、快照链过长、机械盘、硬件分配不足）**均为误判**——这些指标都正常，根因不在计算/磁盘资源。
> **真凶是 VirtualBox 的显示链路**，已找到并修复。本节为正确结论，照做即可。

### C.1 真凶：headless 无显示后端 + VM 内 RDP 合成失败（实测）

- **现象**：VM 内操作间歇性**黑屏 + 卡顿**，但宿主机看 VM 进程 CPU/内存**全空闲**——"资源闲却卡"是这个组合的典型特征。
- **根因**：
  1. VM 以 **`--type headless`** 启动，且 **`vrde=off`** → VirtualBox **自己的显示后端未激活**，没有稳定的帧缓冲渲染。
  2. 你能看到画面，全靠 **VM 内部 Windows 自带的 RDP（3389）** 顶着。
  3. 在"headless 无 VBox 显示后端 + VM 内 RDP"组合下，远程桌面的帧来自一个**半休眠的显示层**，合成时不时失败 → 间歇性黑屏 + 卡顿。
- **为什么之前误判**：黑屏/卡顿的直觉是"资源不够/磁盘慢"，于是去查内存 swap、快照链、机械盘——但这些指标都正常；根因在**显示链路**而非计算资源。

### C.2 修复：开启 VirtualBox 自带 VRDE（端口 3390）（实测，根上解决）

- **做法**：把 VM 的 `vrde` 打开并设端口 **3390**，由 VirtualBox **直接渲染帧缓冲**，从根上绕开"VM 内 RDP"那条不稳的链路。
- **VRDE 端口 3390 已写入 VM 配置**，以后 `startvm` 默认就有稳定远程显示，无需再走 VM 内 RDP。

```bat
REM 启用 VRDE 并设置端口（一次性，写入 VM 配置）
"C:\Program Files\VBoxManage.exe" modifyvm flashtap_test --vrde on
"C:\Program Files\VBoxManage.exe" modifyvm flashtap_test --vrdeport 3390
REM 之后照常开机（可 headless，VRDE 已接管显示）
"C:\Program Files\VBoxManage.exe" startvm flashtap_test --type headless
```

- 验证：`VBoxManage showvminfo flashtap_test --machinereadable | findstr VRDE` 应显示 `VRDE="on"`、`VRDEPort=3390`；你连上后 `VRDEActiveConnection` 变 `on`。

### C.3 怎么连（稳定画面）

- **连 VRDE（推荐）**：远程桌面客户端连 **`localhost:3390`**（宿主本机）或 **`宿主IP:3390`**（远程连宿主）。
  - 登录账户 **`{VMUser}` / `{VMPassword}`**。
  - 连上后**先点一下窗口获取鼠标焦点**；若提示"按 Ctrl+Alt+Del"，在远程桌面客户端按 **Ctrl+Alt+End**（不是 Del）。
  - **判断标准**：画面**不再黑屏/卡顿**即说明链路稳了。
- 🚫 **不要连旧端口 3389**（那是 VM 内 Windows RDP，正是被绕开的不稳链路）。

### C.4 兜底方案：普通窗口模式（不依赖任何远程桌面）

- 若 VRDE 仍"连上却点不进去"（会话输入未注入 / 卡在登录等待界面），换**最直觉**方案：直接让 VirtualBox 在宿主机桌面弹出 VM 窗口，像用真电脑一样操作。
- 关机后**不带 `--type headless`** 启动，即在宿主桌面弹 `flashtap_test` 窗口：

```bat
"C:\Program Files\VBoxManage.exe" controlvm flashtap_test poweroff
"C:\Program Files\VBoxManage.exe" startvm flashtap_test
```

- **情况 A（你在宿主本机前）**：直接在弹出窗口里登录 `{VMUser}` / `{VMPassword}`，双击 `Z:\一键安装FlashTap.bat`。最像真机，无黑屏/卡顿。
- **情况 B（你远程桌面连到宿主）**：普通窗口在宿主本机桌面，你的远程会话可能看不到。这种情况改用 C.3 的 `localhost:3390`。

### C.5 进 VM 后的关键校验（确保跑的是真副本，避免再误测）

> 之前曾误把改动写到非副本位置，导致测的不是真副本。本轮用哈希确凿比对。

- 桌面副本 `Setup-FlashTap.ps1` 的**基准哈希已算好**：`b154ea88...`（以实际 `certutil` 比对为准）。
- 进 VM 登录、`Z:` 映射好后，立即比对 VM 内 `Z:\Setup-FlashTap.ps1` 哈希，确认一致：

```bat
REM 宿主机算副本哈希
certutil -hashfile "c:\Users\{DevUser}\Desktop\flashtap_V0.01 - 副本\Setup-FlashTap.ps1" SHA256
REM VM 内（guestcontrol 或窗口里）算 Z: 哈希，两者应一致
certutil -hashfile "Z:\Setup-FlashTap.ps1" SHA256
```

- 并确认 VM 内安装产物目录为空：`dir C:\FlashTap`（恢复空白快照后应为空）。
- 校验通过 → 你在窗口里双击 `Z:\一键安装FlashTap.bat` 跑真实安装。

### C.6 一句话流程（新对话照做）

1. VM 已开 VRDE(3390) → 远程桌面连 `localhost:3390`（或 宿主IP:3390），登录 `{VMUser}/{VMPassword}`。
2. 画面稳（不黑屏/不卡）？稳了告诉我，我比对 `Z:\Setup-FlashTap.ps1` 哈希 + 确认 `C:\FlashTap` 空。
3. 若 VRDE 连上却点不进去 → 改用 C.4 普通窗口模式（宿主桌面弹窗）。
4. 校验通过 → 你双击 `Z:\一键安装FlashTap.bat` 跑真安装。

> 📌 另：VBoxManage 命令被"僵尸快照锁"卡死（与画面卡顿无关，是宿主侧锁）的处置见 **附录 B.2**，此处不重复。
