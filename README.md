# FlashTap — 本地 AI 编程助手 一键安装

适配：**RTX 5060 8GB 显存笔记本** | 支持：**Windows 10 / Windows 11** | 网络：**纯国内源**

---

## 📦 安装前准备（用户只需这一步）

1. ✅ **确认硬件**：你的电脑必须有 **RTX 5060 8GB** 显存显卡
2. ✅ **安装 Python 3.10+**：  
   下载地址：https://www.python.org/downloads/  
   **⚠️ 关键：安装时一定要勾选 "Add Python to PATH"**

---

## 🚀 傻瓜式安装（一步到位）

1. 把整个 FlashTap 文件夹解压到你想要安装的位置（比如 `D:\FlashTap\`）
2. 找到文件 **`一键安装FlashTap.bat`**
3. **右键点击 → 选择【以管理员身份运行】**
4. 等待约 10 分钟，全程自动完成，不用管

---

## 📁 文件清单

| 文件名 | 说明 |
|--------|------|
| `一键安装FlashTap.bat` | 启动入口，用户双击（右键管理员）这个 |
| `Setup-FlashTap.ps1` | 主控制脚本，按顺序执行安装 |
| `install-flashtap.ps1` | 子脚本：安装 Ollama + 配置显存限制 6GB |
| `download-models.py` | 子脚本：从魔搭下载模型 |
| `install-vscode.ps1` | 子脚本：静默安装 VS Code + Continue 扩展 |
| `configure-continue.py` | 子脚本：配置 Continue 对接本地 Ollama |
| `check-environment.ps1` | 子脚本：安装后环境自检 |

---

## ⚙️ 自动完成了什么

| 步骤 | 内容 |
|------|------|
| 1️⃣ | 检测管理员权限 |
| 2️⃣ | 解锁所有文件，清除 Windows 网络锁定标记 |
| 3️⃣ | 静默安装 Ollama，配置 `OLLAMA_MAX_VRAM=6144` 显存限制 |
| 4️⃣ | 重启 Ollama 服务 |
| 5️⃣ | 从阿里魔搭下载 Qwen2.5-Coder-7B-Instruct-Q4_K_M 模型 |
| 6️⃣ | 导入模型到 Ollama |
| 7️⃣ | 静默安装 VS Code，关闭遥测和同步 |
| 8️⃣ | 自动安装 Continue 扩展 |
| 9️⃣ | 写入 Continue 配置，对接本地 Ollama |
| 🔟 | 环境自检，输出检测结果 |

---

## ✅ 安装完成后怎么用

1. 打开 VS Code
2. 按 `Ctrl+Shift+P`，输入 `Continue: Open Chat`
3. 开始用 FlashTap 写代码！

快捷键：默认 `Ctrl+L` 打开对话

---

## ❌ 常见问题及解决方法

### Q1: 一闪就没了（闪退）

**原因**：
- 不是用"以管理员身份运行"
- 缺少 Python 或没勾 Add to PATH
- 换行符错误（打包时已修复）

**解决**：
1. 必须右键 → 以管理员身份运行 `一键安装FlashTap.bat`
2. 确认 Python 已安装，且在安装时勾选了 "Add Python to PATH"
3. 如果还是不行，打开 `cmd`，输入 `python --version`，看能不能输出版本号，不能就是没加 PATH

---

### Q2: 报错 "意外的标记 `}`" 或 "Try 语句缺少自己的 Catch"

**原因**：打包时换行符不对

**解决**：用本文档顶部给你的方法已经修复了。如果重新打包，记住所有 `.ps1` 文件必须是 **CRLF** 换行符，不是 LF。

---

### Q3: 模型下载很慢

**原因**：网络问题

**说明**：脚本自动用魔搭国内源，比 HuggingFace 快很多。如果还是慢，请检查网络连接，脚本支持断点续传，断开再开就能继续。

---

### Q4: Ollama 安装完了，但说找不到 `ollama` 命令

**原因**：环境变量没更新

**解决**：这是正常现象，安装完 Ollama 后 PATH 需要重启终端才会更新，脚本已经处理了，不用管。

---

### Q5: VS Code 安装完了，Continue 扩展没装上

**原因**：`code` 命令不在 PATH

**解决**：重启 VS Code，或者手动在扩展商店搜索 `Continue` 安装一次。

---

### Q6: 提示 "磁盘空间不足"

**原因**：模型 + Ollama + VS Code 大约需要 15GB 空间

**解决**：换个空间够的磁盘放 FlashTap 文件夹。

---

### Q7: 显存溢出报错

**原因**：你的显卡显存小于 8GB，或者 Ollama 显存限制没生效

**解决**：
- 本项目只适配 **RTX 5060 8GB**，更小显存跑不了
- 如果确实是 8GB 还溢出，请确认 `OLLAMA_MAX_VRAM` 环境变量已设置为 `6144`

---

## 🔧 技术细节

- 模型：Qwen2.5-Coder-7B-Instruct-Q4_KM（约 5GB）
- 向量模型：bge-m3（嵌入模型）
- 推理：Ollama 本地运行，不连外网
- 前端：VS Code + Continue.dev 扩展
- 镜像：pip 用清华源，模型用阿里魔搭，全程国内网络
- 安全：不修改系统全局执行策略，只在当前进程绕过，用完即走

---

## 📝 许可证

MIT