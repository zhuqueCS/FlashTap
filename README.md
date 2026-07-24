# FlashTap — 一键安装本地 AI 编程助手

> 让每一个拥有普通电脑的学生，都能拥有好用、零门槛的本地 AI 编程助手。

## 这是什么

**FlashTap** 是一个半离线安装包——在空白 Windows 电脑上，右键运行一个 bat，15-20 分钟后你就拥有了：

- ✅ **VS Code**（中文界面 + Continue AI 编程插件）
- ✅ **本地大模型**（Ollama + Qwen2.5-Coder 7B，不联网、不收费、不偷代码）
- ✅ **C++ 编译环境**（MinGW-w64 GCC/GDB，写完就能 F5 编译运行）
- ✅ **一切配置就绪**——装完就能写代码、聊 AI、F5 编译

**完全免费。完全本地。完全隐私。**

---

## 快速开始（国内用户·半离线安装）

### 第 1 步：下载代码

本页面绿色 **Code → Download ZIP**，解压到任意位置（比如桌面）。

### 第 2 步：下载离线包

从 [Release 页面](https://github.com/phenoCS/FlashTap/releases) 下载以下 **3 个文件**，放到代码解压目录：

| 文件 | 大小 | 说明 |
|------|:--:|------|
| `mingw64.zip` | 234MB | MinGW-w64 C++ 编译环境 |
| `continue.continue.vsix` | 70MB | VS Code AI 编程插件（含 Windows 原生库） |
| `formulahendry.code-runner.vsix` | 0.7MB | 一键运行代码扩展 |

> 这 3 个文件共约 305MB。其余组件（VS Code、Ollama、AI 模型等）安装时自动从国内稳定源下载。

### 第 3 步：一键安装

右键 `一键安装FlashTap.bat` → **"以管理员方式运行"**，等待 15-20 分钟。

看到 VS Code 弹出中文界面，桌面出现 **"FlashTap"** 快捷方式，即安装完成。

### 第 4 步：开始使用

双击桌面 **FlashTap** 快捷方式 → VS Code 打开 C++ 工作区：

| 操作 | 快捷键 |
|------|--------|
| AI 编程对话 | `Ctrl+L` |
| 编译运行代码 | `F5` |
| 一键运行当前文件 | `Ctrl+Alt+N` |
| 解释/优化代码 | 选中后 `Ctrl+Shift+R` |

---

## 纯在线安装（海外 / VPN 用户）

直接 Download ZIP → 解压 → 右键 bat → 以管理员运行。所有组件在线下载。

---

## 可选离线加速

可额外预置以下文件到解压目录，脚本自动跳过联网下载：

| 文件 | 大小 | 作用 |
|------|:--:|------|
| `OllamaSetup.exe` | ~800MB | Ollama 安装器 |
| `VSCodeUserSetup-x64-latest.exe` | ~90MB | VS Code 安装器 |
| `models/*.gguf` | ~4.3GB | AI 模型文件 |

---

## 系统要求

| 项目 | 最低配置 |
|------|----------|
| 操作系统 | Windows 10/11 (64-bit) |
| 内存 | 16GB（模型需 8GB+） |
| 磁盘 | 15GB 可用空间 |
| 显卡 | 非必须（CPU 推理） |
| 网络 | 首次安装需联网下载 ~5GB（可预置离线包免除） |

---

## 安装流程详解

```
一键安装FlashTap.bat
  │
  ├── Phase 0: preflight-check.ps1
  │   └── 探测所有网络源可达性（国内多镜像并行检测）
  │
  ├── Phase 1: install-flashtap.ps1
  │   ├── 安装/复用 Ollama
  │   ├── 配置 OLLAMA_MODELS → D:\ollama_models
  │   └── 启动 Ollama 服务
  │
  ├── Phase 2: install-vscode.ps1
  │   ├── 检测/复用 VS Code（优先用户级，系统级只复用）
  │   ├── 安装 3 个扩展：
  │   │   ├── continue.continue        ← 离线 .vsix（70MB，含 Windows 原生库）
  │   │   ├── code-runner              ← 离线 .vsix（0.7MB）
  │   │   └── language-pack-zh-hans    ← 在线 marketplace（自动匹配 VS Code 版本）
  │   ├── 安装 cpptools（C/C++ 语法支持）
  │   ├── 复制 settings.json / locale.json
  │   └── 复制 Continue config.json/yaml/ts
  │
  ├── Phase 3: setup-cpp-env.ps1
  │   ├── 解压 mingw64.zip → C:\FlashTap\mingw64（离线，秒级）
  │   ├── 配置系统 PATH
  │   └── 生成 launch.json / tasks.json（F5 调试即用）
  │
  ├── Phase 4: download-models.py
  │   ├── 从 ModelScope 国内源下载 Qwen2.5-Coder GGUF（约 4.3GB）
  │   ├── ollama create → 注册模型
  │   └── 验证模型可正常响应
  │
  ├── Phase 5: configure-continue.py
  │   └── 生成 Continue 插件模型配置（qwen-local）
  │
  ├── Phase 6: 启动 VS Code
  │   ├── 关闭已有 VS Code 进程
  │   ├── 以目标用户身份启动 VS Code
  │   └── 创建桌面 FlashTap 快捷方式
  │
  └── Phase 7: check-environment.ps1
      └── 安装后环境自检（VS Code / Ollama / g++ / 扩展 / 模型）
```

### 网络源设计

所有在线下载均有**国内镜像兜底**：

| 组件 | 主源 | 镜像 | 风险 |
|------|------|------|:--:|
| Python | python.org | 华为 / 阿里 / 清华 镜像 | 极低 |
| VS Code | update.code.visualstudio.com | 直接国内通 | 低 |
| 语言包 | Marketplace | open-vsx.cn | 低 |
| Ollama | ollama.com | ghproxy.net 代理 | 中（官方源常超时） |
| AI 模型 | ModelScope | modelscope.cn（国内 CDN） | 极低 |

---

## 项目结构

```
FlashTap-main/
├── 一键安装FlashTap.bat            ← 入口（右键→以管理员运行）
├── Setup-FlashTap.ps1               ← 主编排脚本（71.8KB）
├── install-flashtap.ps1             ← Ollama 安装 + 环境配置 + 桌面快捷方式
├── install-vscode.ps1               ← VS Code + 扩展安装 + 配置同步
├── setup-cpp-env.ps1                ← MinGW C++ 编译环境
├── check-environment.ps1            ← 安装后环境自检
├── preflight-check.ps1              ← 安装前网络探针
├── download-models.py               ← AI 模型下载
├── configure-continue.py            ← Continue 插件配置生成
├── config.json / config.yaml / config.ts    ← Continue 自动配置文件
├── settings.json                    ← VS Code 预设（中文 + 快捷键 + F5）
├── extensions.list                  ← 扩展白名单
│
├── mingw64.zip                      ← 离线：MinGW 编译器（234MB）
├── continue.continue.vsix           ← 离线：Continue AI 插件（70MB）
├── formulahendry.code-runner.vsix   ← 离线：Code Runner（0.7MB）
│
├── DEVLOG.md                        ← 完整开发日志（47 个 Bug + 11 轮测试）
├── Agent-VM协同测试工作流.md        ← Agent 协同测试方法论
├── VM测试环境与全流程接手文档.md    ← VM 环境配置文档
├── 历史测试与修复记录.md            ← 测试历史
├── flashtap开发思路.md              ← 架构设计文档
└── README.md                        ← 本文档
```

---

## 常见问题

### 安装相关

**Q: 安装时提示"没有管理员权限"？**
A: 关闭窗口，右键 `一键安装FlashTap.bat` → "以管理员方式运行"。

**Q: 模型下载太慢？**
A: 从 ModelScope 国内源下载，一般 3-5 分钟完成。也可手动放入 `.gguf` 文件到 `models/` 目录跳过下载。

**Q: VS Code 弹出 JS 错误弹窗？**
A: 从桌面 "FlashTap" 快捷方式打开即可正常。弹窗是因为首次以管理员身份启动了 VS Code。

**Q: 安装完成但 VS Code 没有自动弹出？**
A: 极少数情况（~2%）下虚拟机或慢磁盘可能触发时序竞态。直接双击桌面 "FlashTap" 快捷方式即可，功能完全一致。

**Q: F5 编译报错？**
A: 检查 `C:\FlashTap\mingw64\bin\g++.exe` 是否存在。如 MinGW 解压失败，手动将 `mingw64.zip` 解压到该路径。

**Q: 打开 VS Code 是英文界面？**
A: 重启 VS Code 即可。中文语言包安装后需重启加载。

**Q: C/C++ 扩展提示需要安装？**
A: 脚本自动安装 cpptools，偶有网络超时。在 VS Code 扩展商店搜索 `ms-vscode.cpptools` 手动安装即可。

### GitHub 相关

**Q: GitHub 下载太慢 / 打不开？**
A: 推荐用 [Watt Toolkit（原 Steam++）](https://steampp.net/) 加速 GitHub。离线包建议从 Release 页面直链下载。

**Q: 为什么不用 git clone？**
A: 离线文件太大（305MB），不适合 Git LFS。推荐 Download ZIP + Release 下载离线包的方式。

---

## 设计理念

- **半离线架构**：核心组件离线（编译器 + AI 插件），版本敏感组件在线（VS Code + 语言包），兼顾稳定性和轻量化
- **先求稳再求好**：11 轮 VM/真机回归测试，空白机 90%+ 一次成功率
- **不修改系统**：不修改全局 PowerShell 执行策略，不驻留后台
- **国内网络优先**：所有下载均有多源国内镜像，安装前自动检测可达性
- **Architecture by human, code by AI, quality by tests**：人定架构，AI 写代码，测试保质量

## 测试历史

| 轮次 | 环境 | 关键成果 |
|:--:|------|------|
| 1-7 | VM 空白 Win11 | 架构迭代：跨账户 UAC、Git LFS、多源下载、F5 调试 |
| 8 | VM 稳定版 | 全功能通过，发现语言包版本不兼容 |
| 9 | 真机本人2 | 首次 Continue .vsix 结构修复 |
| 10 | 真机本人2 | Continue 离线安装成功、语言包 marketplace 回退、扩展计数修复 |
| **11** | **真机本人2** | **全绿通过，定版。3 扩展全部成功、cpptools 4s 完成** |

---

## 路线图

- [x] Phase 1：空白电脑一遍跑通（当前）
- [ ] Phase 2：模型路由（本地 7B ↔ 云端 API）+ RAG 知识库
- [ ] Phase 3：轻量 Agent 框架（控制开发环境）
- [ ] Phase 4：精美安装器 + 产品网站

## License

MIT
