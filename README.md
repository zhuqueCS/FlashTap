# FlashTap — 一键安装本地 AI 编程助手

> 让每一个拥有普通显卡的学生，都能拥有好用、零门槛的本地 AI 编程助手。

## 这是什么

**FlashTap** 是一个半离线安装包——在空白 Windows 电脑上，右键运行一个 bat，15 分钟后你就拥有了：

- ✅ **VS Code**（中文界面）
- ✅ **Continue 插件**（AI 编程对话，像 Cursor 一样用）
- ✅ **本地大模型**（Ollama + Qwen2.5-Coder 7B，不联网、不收费、不偷代码）
- ✅ **C++ 编译环境**（MinGW-w64 GCC/GDB，写完就能 F5 编译运行）
- ✅ **一切配置就绪**——装完就能写代码、聊 AI、F5 编译

**完全免费。完全本地。完全隐私。**

## 快速开始

### 半离线安装（推荐，国内用户）

1. **下载代码**：本页面绿色 **Code → Download ZIP**，解压到任意位置
2. **下载离线文件**：从 [Release v0.02](https://github.com/phenoCS/FlashTap/releases/tag/v0.02) 下载 `mingw64.zip` + 3 个 `.vsix` 文件，放到代码解压目录
3. **右键** `一键安装FlashTap.bat` → **"以管理员方式运行"**
4. 等待 15–20 分钟，看到 VS Code 弹出即完成
5. 双击桌面 **"FlashTap"** 快捷方式，开始编程

> MinGW 编译器和 VS Code 扩展已离线，无需联网下载。Ollama、VS Code 安装器、AI 模型从稳定源在线下载。

### 纯在线安装（有 VPN / 海外用户）

直接 Download ZIP → 解压 → 右键 bat → 以管理员运行。所有组件在线下载。

### 可选离线加速

可额外预置以下文件到解压目录，脚本自动跳过联网下载：

| 文件 | 作用 | 大小 |
|------|------|:--:|
| `OllamaSetup.exe` | Ollama 安装器 | ~800MB |
| `VSCodeUserSetup-x64.exe` | VS Code 安装器 | ~90MB |
| `models/*.gguf` | 本地 AI 模型 | ~4GB |

## 系统要求

| 项目 | 最低配置 |
|------|----------|
| 操作系统 | Windows 10/11 (64-bit) |
| 内存 | 16GB（模型需 8GB+） |
| 磁盘 | 15GB 可用空间 |
| 显卡 | 非必须（CPU 推理可用，速度较慢） |
| 网络 | 首次安装需联网（可预置离线包免除） |

## 安装后

```
桌面 → FlashTap 快捷方式 → VS Code 打开 C++ 工作区
                                │
                                ├── main.cpp（F5 编译运行）
                                └── Ctrl+L → Continue AI 对话
```

在 Continue 聊天框里直接问：
- "帮我写一个冒泡排序"
- "解释这段代码"
- "修复这个 bug"

## 项目结构

```
├── 一键安装FlashTap.bat      ← 入口（右键→以管理员运行）
├── Setup-FlashTap.ps1         ← 主编排脚本
├── install-flashtap.ps1       ← Ollama 安装
├── install-vscode.ps1         ← VS Code + 扩展
├── setup-cpp-env.ps1          ← MinGW C++ 环境
├── download-models.py         ← AI 模型下载
├── configure-continue.py      ← Continue 配置生成
├── config.json/yaml/ts        ← Continue 自动配置
├── settings.json              ← VS Code 预设
├── DEVLOG.md                  ← 完整开发日志（23 个 bug 修复记录）
├── Agent-VM协同测试工作流.md  ← Agent 协同测试方法论
└── README.md                  ← 本文档
```

## 常见问题

**Q: 安装时提示"没有管理员权限"？**
A: 关闭窗口，右键 `一键安装FlashTap.bat` → "以管理员方式运行"。

**Q: 模型下载太慢？**
A: 脚本自动尝试多个国内镜像（ModelScope、ghproxy）。也可以预置 `.gguf` 文件到 `models/` 目录。

**Q: VS Code 弹出 JS 错误弹窗？**
A: 从桌面 "FlashTap" 快捷方式打开即可正常。弹窗是因为首次以管理员身份启动了 VS Code。

**Q: F5 编译报错？**
A: 确保 `C:\FlashTap\mingw64\bin\g++.exe` 存在。如果网络不稳导致 MinGW 下载失败，手动放置 `mingw64.zip` 到脚本目录。

**Q: GitHub 下载太慢 / 打不开？**
A: 国内网络访问 GitHub 经常玄学卡顿。推荐用免费加速工具 [Watt Toolkit（原 Steam++）](https://steampp.net/)，一键加速 GitHub 访问和下载。也可以从 [Release v0.02](https://github.com/phenoCS/FlashTap/releases/tag/v0.02) 直链下载离线文件。

**Q: 显卡是 AMD/Intel 能用吗？**
A: 可以。模型默认用 CPU 推理（通过 Ollama），不需要 NVIDIA 显卡。

## 设计理念

- **不联网也能用**：预置离线包后，核心功能（VS Code + 编译器 + AI 模型）完全本地
- **不修改系统**：不修改全局 PowerShell 执行策略，不驻留后台
- **先求稳再求好**：在空白电脑一遍跑通之前不做大规模重构
- **Architecture by human, code by AI, quality by tests**：人定架构，AI 写代码，测试保质量

## 路线图

- [x] Phase 1：空白电脑一遍跑通（当前）
- [ ] Phase 2：模型路由（本地 7B ↔ 云端 API）+ RAG 知识库
- [ ] Phase 3：轻量 Agent 框架（控制开发环境）
- [ ] Phase 4：精美安装器 + 产品网站

## License

MIT
