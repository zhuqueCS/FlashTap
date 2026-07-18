<div align="center">

# FlashTap

### 本地 AI 编程助手 · 一键部署

**零配置 · 零依赖 · 零网络要求（离线包模式）· 全自动**

Windows 10 / 11 上一键安装完整的本地 AI 编程环境：Ollama + Qwen2.5-Coder-7B + VS Code + Continue，全程不联网推理，数据不出本机。

</div>

---

## ✨ 核心特性

| 特性 | 说明 |
|------|------|
| 🖱️ **真正一键** | 双击 `.bat`，自动提权，自动安装全部组件，无需任何命令行操作 |
| 🔒 **完全本地** | AI 推理跑在本机 GPU 上，代码不上传云端，零隐私泄露 |
| 🚫 **零依赖** | 不预装 Python / VS Code / Ollama 也能跑，脚本全部自动搞定 |
| 🛡️ **安全隔离** | 不破坏用户已有环境，不卸载已有扩展，多账户互不干扰 |
| 🌐 **多镜像兜底** | Ollama / VS Code / Python 均内置国内镜像源，网络再差也能下 |
| 📊 **环境自检** | 安装完成后自动检测所有组件状态，一眼确认是否成功 |

---

## 📋 系统要求

| 要求 | 最低 | 推荐 |
|------|------|------|
| 操作系统 | Windows 10 1809+ | Windows 11 |
| 显卡 | NVIDIA 6GB 显存 | NVIDIA 8GB+ 显存 |
| 磁盘空间 | 10GB 可用 | 20GB 可用 |
| 内存 | 8GB | 16GB |
| 网络 | 首次安装需要联网 | — |

> 💡 **没有 NVIDIA 显卡？** 也能装，模型会跑在 CPU 上，速度较慢但功能完整。

---

## 🚀 快速开始

### 三步完成安装

```
1. 下载    →  从 GitHub 下载 ZIP 压缩包并解压
2. 运行    →  双击「一键安装FlashTap.bat」
3. 等待    →  约 15-30 分钟，全自动完成
```

### 安装流程

```
双击 bat
  │
  ├─ 第 0 步  检测 Python（未安装则自动下载安装）
  ├─ 第 1 步  安装 Ollama + 配置环境变量 + 启动服务
  ├─ 第 2 步  安装 VS Code + Continue 扩展 + 中文语言包
  ├─ 第 3 步  下载 Qwen2.5-Coder-7B 模型 + 导入 Ollama
  ├─ 第 4 步  配置 Continue 插件 + 复制配置文件
  ├─ 第 5 步  启动 VS Code + 环境自检
  │
  └─ ✅ 安装完成，VS Code 自动打开
```

### 首次使用

安装完成后，VS Code 会自动打开。按 `Ctrl+L` 唤出 Continue 对话面板，输入你的编程问题即可：

```
> 用 C 语言写一个冒泡排序
> 帮我解释这段代码的逻辑
> 优化这个函数的性能
```

---

## 📁 项目结构

```
FlashTap/
├── 一键安装FlashTap.bat        # 启动入口（用户双击此文件）
├── Setup-FlashTap.ps1          # 主控制脚本（流程编排 + Python 自动安装）
├── install-flashtap.ps1        # Ollama 安装 + 多镜像下载 + 环境配置
├── install-vscode.ps1          # VS Code 安装/复用 + 扩展 + 配置
├── download-models.py          # Qwen 模型下载 + Ollama 导入
├── configure-continue.py       # Continue 插件配置生成
├── setup-cpp-env.ps1           # C++ 编译环境（WSL + g++，可选）
├── check-environment.ps1       # 安装后环境自检
├── settings.json               # VS Code 用户配置
├── extensions.list             # 扩展白名单
├── config.yaml                 # Continue 配置（AUTODETECT 模式）
├── config.json / config.ts     # Continue 配置（兼容多版本）
└── .gitignore
```

---

## ⚙️ 自动安装内容

| 组件 | 版本 | 大小 | 说明 |
|------|------|------|------|
| Python | 3.12.7 | ~25MB | 华为镜像优先，官方源兜底 |
| Ollama | Latest | ~1.4GB | 6 镜像源自动切换，支持离线包 |
| Qwen2.5-Coder-7B | Instruct GGUF | ~4.7GB | 阿里魔搭下载，支持断点续传 |
| VS Code | Latest | ~90MB | 4 镜像源（官方 + Azure中国 + 华为 + 清华） |
| Continue 扩展 | Latest | ~5MB | VS Code 扩展商店直装 |
| 中文语言包 | Latest | ~3MB | VS Code 扩展商店直装 |

### 环境变量配置

| 变量 | 值 | 说明 |
|------|----|------|
| `OLLAMA_HOST` | `127.0.0.1:11434` | 仅本机访问 |
| `OLLAMA_MAX_VRAM` | `6144` | 显存限制 6GB（适配 8GB 显卡） |
| `OLLAMA_MODELS` | 自动选择 | D 盘优先，不可写时回退用户目录 |
| `OLLAMA_ORIGINS` | `*` | 允许 Continue 跨域调用 |

---

## 🔧 技术架构

```
┌─────────────────────────────────────────┐
│              用户双击 bat                │
│                 ↓                       │
│  ┌─────────────────────────────────┐    │
│  │     Setup-FlashTap.ps1          │    │
│  │     (主控脚本 · 流程编排)        │    │
│  └──────────┬──────────────────────┘    │
│             │                           │
│     ┌───────┼───────┬───────┬─────┐     │
│     ↓       ↓       ↓       ↓     │     │
│  Ollama  VS Code  模型   Continue │     │
│  安装     安装    下载    配置     │     │
│     │       │       │       │     │     │
│     └───────┴───────┴───────┴─────┘     │
│                 ↓                       │
│  ┌─────────────────────────────────┐    │
│  │      环境自检 + 启动 VS Code     │    │
│  └─────────────────────────────────┘    │
└─────────────────────────────────────────┘

推理链路: VS Code → Continue → HTTP → Ollama → GPU/CPU → Qwen 模型
```

---

## 🛡️ 安全设计

### 不破坏用户环境

- **VS Code 三层安全锁**：检测到已安装的 VS Code 只复用不重装，避免损坏运行中的实例
- **扩展零删除**：绝不卸载用户已有的任何 VS Code 扩展
- **配置可回滚**：复制配置文件前自动备份用户原有配置
- **进程零误杀**：不使用 `taskkill /F /IM Code.exe`，只按用户名过滤

### 空白账户隔离模式

当检测到当前账户没有用户级软件但系统级有时，自动启用隔离模式：
- 忽略系统级 Ollama / VS Code
- 为当前账户安装独立的用户级副本
- 多账户互不干扰，测试完可独立清理

---

## ❓ 常见问题

<details>
<summary><b>双击后闪退</b></summary>

1. 确保是**双击运行**（脚本会自动请求管理员权限，不需要右键）
2. 查看 `install.log` 和 `vscode-install.log` 的最后几行错误信息
3. 如果是网络问题，检查网络连接后重试

</details>

<details>
<summary><b>Ollama 下载太慢或失败</b></summary>

- 脚本内置 6 个镜像源，会自动切换尝试
- **离线加速**：提前下载 `OllamaSetup.exe`（[下载地址](https://ollama.com/download/OllamaSetup.exe)）放在脚本同目录，自动跳过下载
- 约 1.4GB，首次下载预计 10-30 分钟（视网络而定）

</details>

<details>
<summary><b>模型下载慢</b></summary>

- 模型从阿里魔搭（ModelScope）下载，国内速度有保障
- 支持断点续传，中断后重新运行脚本即可继续
- 约 4.7GB，正常网速 5-15 分钟

</details>

<details>
<summary><b>VS Code 安装失败（退出码 5）</b></summary>

- 原因：VS Code 正在运行，文件被锁定
- 解决：关闭所有 VS Code 窗口后重新运行脚本
- 脚本已内置安全锁，不会损坏正在运行的 VS Code

</details>

<details>
<summary><b>安装后 Continue 没反应</b></summary>

1. 检查右下角任务栏是否有 Ollama 图标（羊驼）
2. 在 PowerShell 输入 `ollama list`，确认看到 `qwen2.5-coder:7b`
3. 按 `Ctrl+Shift+P` → `Continue: Select Model` → 选择 `qwen-local`
4. 重启 VS Code 再试

</details>

<details>
<summary><b>显存溢出报错</b></summary>

- 本项目需要 8GB+ 显存的 NVIDIA 显卡
- 确认环境变量 `OLLAMA_MAX_VRAM` 已设置为 `6144`
- 没有 NVIDIA 显卡也能用，会自动回退到 CPU 推理（速度较慢）

</details>

---

## 📊 快捷键

| 快捷键 | 功能 |
|--------|------|
| `Ctrl+L` | 侧边栏打开 Continue 对话 |
| `Ctrl+I` | 编辑器内行内提问（Inline Chat） |
| `Ctrl+Shift+R` | 选中代码后让 AI 解释 / 优化 |
| `Ctrl+Alt+N` | Code Runner 一键运行当前代码 |
| `F5` | 启动调试（C/C++ 需先配置 `launch.json`） |

---

## 🔬 技术栈

| 层 | 技术 |
|----|------|
| AI 模型 | Qwen2.5-Coder-7B-Instruct（GGUF Q4_K_M 量化） |
| 推理引擎 | Ollama（llama.cpp 后端） |
| 编辑器 | Visual Studio Code |
| AI 插件 | Continue.dev（AUTODETECT 模式） |
| 脚本 | PowerShell 5.1 + Python 3.12 |
| 下载源 | ModelScope + GitHub + 华为镜像 + 清华镜像 + Azure中国 |

---

## 📝 许可证

MIT License — 可自由使用、修改、分发。

---

## 🤝 贡献

欢迎提交 Issue 和 PR。

- 开发日志：[DEVLOG.md](DEVLOG.md)
- Bug 记录：每个 Bug 都有详细的现象、原因、解决方案

---

<div align="center">

**如果这个项目对你有帮助，请点个 ⭐ Star**

</div>
