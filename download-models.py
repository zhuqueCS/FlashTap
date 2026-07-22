#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Model download and Ollama import for FlashTap.
Supports modelscope snapshot download with resume.
"""

import sys
import os
import json
import subprocess
import time
import traceback
import urllib.request
import re
from pathlib import Path

BASE_DIR = Path(__file__).parent.resolve()
LOG_FILE = BASE_DIR / "download.log"
MODELS_DIR = BASE_DIR / "models"

QWEN_MODEL_ID = "qwen/Qwen2.5-Coder-7B-Instruct-GGUF"
QWEN_MODEL_FILE = "qwen2.5-coder-7b-instruct-q4_k_m.gguf"

PIP_MIRROR = "https://pypi.tuna.tsinghua.edu.cn/simple"


def write_log(message: str, level: str = "INFO"):
    timestamp = time.strftime("%H:%M:%S")
    log_line = f"[{timestamp}] {message}"
    try:
        print(log_line)
    except UnicodeEncodeError:
        print(log_line.encode("ascii", errors="replace").decode("ascii"))
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(log_line + "\n")
    except Exception:
        pass


def install_deps():
    write_log("正在安装 Python 依赖...")
    try:
        import modelscope  # type: ignore
        write_log("依赖已存在")
        return
    except ImportError:
        pass

    try:
        subprocess.check_call([
            sys.executable, "-m", "pip", "install", "modelscope",
            "-i", PIP_MIRROR, "--trusted-host", "pypi.tuna.tsinghua.edu.cn",
            "--no-cache-dir", "-q"
        ])
        write_log("依赖安装完成")
    except Exception as e:
        write_log(f"依赖安装失败: {e}")
        raise


def download_with_modelscope():
    """Download model via modelscope snapshot_download (supports resume)."""
    write_log("通过 ModelScope 下载模型...")
    from modelscope import snapshot_download  # type: ignore
    start_time = time.time()

    model_dir = snapshot_download(
        QWEN_MODEL_ID,
        cache_dir=str(MODELS_DIR),
        allow_file_pattern=[QWEN_MODEL_FILE],
        revision="master"
    )

    model_path = Path(model_dir) / QWEN_MODEL_FILE
    if not model_path.exists():
        raise Exception("模型下载后未找到模型文件，请检查网络后重试")

    elapsed = int(time.time() - start_time)
    write_log(f"模型下载完成 ({elapsed}s)")
    return model_path


def download_model():
    write_log("正在下载 Qwen2.5-Coder-7B（约 5GB），可能需要几分钟...")
    try:
        return download_with_modelscope()
    except Exception as e:
        write_log(f"模型下载失败: {e}")
        raise


def create_ollama_model(model_path: Path):
    write_log("正在将模型导入 Ollama...")
    file_size = model_path.stat().st_size
    if file_size < 1024 * 1024 * 1024:
        raise RuntimeError(
            f"GGUF 文件异常（体积：{file_size / 1024 / 1024:.1f} MB），"
            "可能下载了 git LFS 指针文件而非实际模型，请检查 modelscope 配置"
        )
    write_log(f"GGUF 文件大小: {file_size / 1024 / 1024 / 1024:.2f} GB")

    # ── GGUF 兼容性预检：检查 Ollama 版本是否支持此 GGUF 格式 ──
    skip_gguf = False
    try:
        ver_result = subprocess.run(
            ["ollama", "--version"],
            capture_output=True, encoding='utf-8', errors='replace', timeout=10
        )
        ver_str = (ver_result.stdout or "").strip()
        write_log(f"Ollama 版本: {ver_str}")
        # 版本 < 0.3.0 的 llama-quantize 可能不兼容新版 GGUF，直接跳过本地导入
        if ver_str:
            m = re.search(r'(\d+)\.(\d+)\.(\d+)', ver_str)
            if m:
                major, minor = int(m.group(1)), int(m.group(2))
                if major == 0 and minor < 3:
                    write_log("Ollama 版本过旧（< 0.3.0），跳过本地 GGUF 导入，直接走远程拉取")
                    skip_gguf = True
    except Exception:
        write_log("无法获取 Ollama 版本，继续尝试本地导入...")

    if not skip_gguf:
        # 尝试多种 Modelfile 格式，从完整到最简，提高 ollama create 成功率
        modelfile_variants = [
            # 格式1：完整模板（含 TEMPLATE 和 PARAMETER）
            f'''FROM {model_path}
TEMPLATE """{{{{ if .System }}}}<|im_start|>system
{{{{ .System }}}}<|im_end|>
{{{{ end }}}}{{{{ if .Prompt }}}}<|im_start|>user
{{{{ .Prompt }}}}<|im_end|>
{{{{ end }}}}<|im_start|>assistant
"""
PARAMETER stop "<|im_end|>"
PARAMETER stop "<|im_start|>"
PARAMETER num_ctx 4096
PARAMETER num_batch 512
''',
            # 格式2：最简形式（只有 FROM，让 ollama 用默认模板）
            f'''FROM {model_path}
''',
        ]

        for variant_idx, modelfile_content in enumerate(modelfile_variants, 1):
            modelfile_path = MODELS_DIR / "Modelfile.qwen"
            with open(modelfile_path, "w", encoding="utf-8") as f:
                f.write(modelfile_content)

            write_log(f"正在执行 ollama create（格式{variant_idx}，约 2-5 分钟）...")
            try:
                result = subprocess.run([
                    "ollama", "create", "qwen2.5-coder:7b", "-f", str(modelfile_path)
                ], capture_output=True, encoding='utf-8', errors='replace', timeout=600)

                if result.returncode == 0:
                    write_log("Ollama 模型导入完成")
                    return  # 本地导入成功，不需要走 pull

                # 打印完整错误信息，便于诊断
                stderr = result.stderr or ""
                stdout = result.stdout or ""
                write_log(f"ollama create 失败（格式{variant_idx}）")
                write_log(f"  退出码: {result.returncode}")
                if stderr:
                    write_log(f"  stderr: {stderr[:500]}")
                if stdout:
                    write_log(f"  stdout: {stdout[:500]}")
            except subprocess.TimeoutExpired:
                write_log(f"ollama create 超时（格式{variant_idx}，10分钟）")
            except Exception as e:
                write_log(f"本地 GGUF 导入失败（格式{variant_idx}）: {e}")

        write_log("所有 Modelfile 格式均失败，将尝试远程拉取")
    else:
        write_log("已跳过本地 GGUF 导入（版本不兼容）")

    # ── 兜底：远程拉取（不阻塞，失败则继续） ──
    write_log("尝试通过 ollama pull 从远程仓库拉取模型...")
    _pull_from_registry()


def _pull_from_registry():
    # 先检查本地是否已有模型（ollama create 可能部分成功）
    try:
        list_result = subprocess.run(["ollama", "list"], capture_output=True, encoding='utf-8', errors='replace', timeout=10)
        if list_result.returncode == 0 and "qwen2.5-coder:7b" in (list_result.stdout or ""):
            write_log("模型已存在于本地，跳过远程拉取")
            return
    except Exception:
        pass

    write_log("尝试通过 ollama pull 从远程仓库拉取模型...")
    max_retries = 1
    for attempt in range(1, max_retries + 1):
        try:
            write_log(f"ollama pull 第 {attempt}/{max_retries} 次尝试（超时 15 分钟，请耐心等待）...")
            # 不捕获输出，让用户看到下载进度条
            result = subprocess.run(
                ["ollama", "pull", "qwen2.5-coder:7b"],
                timeout=900
            )
            if result.returncode != 0:
                write_log(f"pull 返回非零退出码: {result.returncode}")
                if attempt < max_retries:
                    write_log("准备重试...")
                    continue
                write_log("ollama pull 失败，模型将不可用，但安装流程继续")
                write_log("建议：稍后手动执行 'ollama pull qwen2.5-coder:7b'")
                return

            write_log("通过 ollama pull 导入成功")
            return
        except subprocess.TimeoutExpired:
            write_log("ollama pull 超时（15分钟），可能网络较慢")
            if attempt < max_retries:
                write_log("准备重试...")
                continue
            write_log("模型下载超时，安装流程继续，请稍后手动执行 'ollama pull qwen2.5-coder:7b'")
            return
        except FileNotFoundError:
            write_log("未找到 ollama 命令，跳过模型部署")
            return
        except Exception as e:
            write_log(f"ollama pull 异常: {e}")
            write_log("安装流程继续，请稍后手动执行 'ollama pull qwen2.5-coder:7b'")
            return


def verify_model():
    write_log("正在验证 Ollama 中的模型...")
    try:
        result = subprocess.run(["ollama", "list"], capture_output=True, encoding='utf-8', errors='replace', timeout=15)
        stdout = result.stdout or ""
        if "qwen2.5-coder:7b" not in stdout:
            write_log("模型中未找到 qwen2.5-coder:7b，模型未部署")
            return False

        write_log("模型验证通过（ollama list 确认 qwen2.5-coder:7b 已就绪）")
        return True
    except Exception as e:
        write_log(f"模型验证失败: {e}")
        return False


def get_latest_ollama_version():
    """通过 GitHub API 获取 Ollama 最新版本号，版本号缓存在本地文件避免重复请求。"""
    version_cache = BASE_DIR / ".ollama_latest_version"
    cache_max_age = 3600  # 1 小时

    # 如果缓存未过期，直接返回
    if version_cache.exists():
        age = time.time() - version_cache.stat().st_mtime
        if age < cache_max_age:
            cached = version_cache.read_text().strip()
            if cached.startswith("v"):
                write_log(f"使用缓存的远程版本号: {cached}")
                return cached

    api_urls = [
        "https://api.github.com/repos/ollama/ollama/releases/latest",
        "https://gh-proxy.com/https://api.github.com/repos/ollama/ollama/releases/latest",
        "https://ghproxy.net/https://api.github.com/repos/ollama/ollama/releases/latest",
    ]

    for url in api_urls:
        try:
            write_log(f"查询最新版本: {url}")
            req = urllib.request.Request(url, headers={
                "User-Agent": "Mozilla/5.0",
                "Accept": "application/vnd.github+json",
            })
            with urllib.request.urlopen(req, timeout=30) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                tag = data.get("tag_name", "")
                if tag:
                    write_log(f"远程最新版本: {tag}")
                    version_cache.write_text(tag)
                    return tag
        except Exception as e:
            write_log(f"  查询失败: {e}")
            continue

    # 如果 API 全部失败，检查过期缓存
    if version_cache.exists():
        cached = version_cache.read_text().strip()
        write_log(f"API 查询失败，使用过期缓存版本: {cached}")
        return cached

    write_log("无法获取远程版本号")
    return None


def check_and_update_ollama():
    """检查 Ollama 版本，若 < 0.5.0 则自动下载并更新。"""
    try:
        ver_result = subprocess.run(
            ["ollama", "--version"],
            capture_output=True, encoding='utf-8', errors='replace', timeout=10
        )
        ver_str = (ver_result.stdout or "").strip()
        write_log(f"Ollama 版本: {ver_str}")

        m = re.search(r'(\d+)\.(\d+)\.(\d+)', ver_str)
        if not m:
            write_log("无法解析 Ollama 版本号，跳过版本检查")
            return

        major, minor, patch = int(m.group(1)), int(m.group(2)), int(m.group(3))
        # 0.30.x 是 2026 年真实版本号，不是异常
        if (major, minor, patch) < (0, 5, 0):
            write_log(f"Ollama 版本过旧（{major}.{minor}.{patch} < 0.5.0），需要更新")
        else:
            write_log("Ollama 版本满足要求，无需更新")
            return

        write_log("正在检查 Ollama 版本...")

        # ── winget 已弃用（DEVLOG Bug#4 证明会卡死在协议确认页），直接跳过 ──
        # 直接走下载安装包的方式

        # ── 先查最新版本号，再拼带版本号的下载链接（避免代理缓存旧版）──
        # 注意：DEVLOG Bug#5 测试 ghproxy.com 和 gh.con.sh 已挂，不再使用
        latest_tag = get_latest_ollama_version()
        if latest_tag:
            # 带版本号的直接链接，代理无法用旧缓存糊弄
            versioned_path = f"download/{latest_tag}/OllamaSetup.exe"
            download_urls = [
                ("GitHub 代理 gh-proxy.com (版本直链)", f"https://gh-proxy.com/https://github.com/ollama/ollama/releases/{versioned_path}"),
                ("GitHub 代理 ghproxy.net (版本直链)", f"https://ghproxy.net/https://github.com/ollama/ollama/releases/{versioned_path}"),
                ("GitHub Releases (版本直链)", f"https://github.com/ollama/ollama/releases/{versioned_path}"),
                ("ollama.com", "https://ollama.com/download/OllamaSetup.exe"),
            ]
        else:
            # 查不到版本号就用 /latest/ 兜底，加时间戳破缓存
            ts = int(time.time())
            download_urls = [
                ("GitHub 代理 gh-proxy.com", f"https://gh-proxy.com/https://github.com/ollama/ollama/releases/latest/download/OllamaSetup.exe?t={ts}"),
                ("GitHub 代理 ghproxy.net", f"https://ghproxy.net/https://github.com/ollama/ollama/releases/latest/download/OllamaSetup.exe?t={ts}"),
                ("GitHub Releases", f"https://github.com/ollama/ollama/releases/latest/download/OllamaSetup.exe?t={ts}"),
                ("ollama.com", "https://ollama.com/download/OllamaSetup.exe"),
            ]

        installer_path = BASE_DIR / "OllamaSetup.exe"

        # ── 如果已缓存安装包且大小正确，跳过下载 ──
        if installer_path.exists() and installer_path.stat().st_size > 1000 * 1024 * 1024:
            write_log(f"安装包已缓存 ({installer_path.stat().st_size // (1024*1024)}MB)，跳过下载")
            downloaded = True
        else:
            downloaded = False

        if not downloaded:
            for idx, (source_name, url) in enumerate(download_urls, start=2):
                write_log(f"尝试方法 {idx}/{1 + len(download_urls)}: 从 {source_name} 下载...")
                try:
                    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
                    with urllib.request.urlopen(req, timeout=120) as resp:
                        total_size = int(resp.headers.get("Content-Length", 0))
                        dl_bytes = 0
                        last_pct = -1
                        with open(installer_path, "wb") as f:
                            while True:
                                chunk = resp.read(1024 * 1024)
                                if not chunk:
                                    break
                                f.write(chunk)
                                dl_bytes += len(chunk)
                                if total_size > 0:
                                    pct = dl_bytes * 100 // total_size
                                    if pct - last_pct >= 10:
                                        write_log(f"  下载进度: {pct}% ({dl_bytes // (1024*1024)}MB / {total_size // (1024*1024)}MB)")
                                        last_pct = pct
                    write_log(f"从 {source_name} 下载完成")
                    downloaded = True
                    break
                except Exception as e:
                    write_log(f"从 {source_name} 下载失败: {e}")
                    try:
                        installer_path.unlink()
                    except Exception:
                        pass
                    continue

        if not downloaded:
            write_log("所有下载方式均失败，将跳过 Ollama 更新")
            write_log("模型可能无法加载，请手动更新 Ollama 后重试")
            return

        # ── 彻底停止 Ollama 服务，避免文件被锁定导致安装器跳过覆盖 ──
        write_log("正在停止 Ollama 服务...")
        for stop_cmd in [
            ["sc", "stop", "ollama"],
            ["net", "stop", "ollama"],
            ["taskkill", "/f", "/im", "ollama.exe"],
            ["taskkill", "/f", "/im", "ollama app.exe"],
        ]:
            try:
                subprocess.run(stop_cmd, capture_output=True, timeout=10)
            except Exception:
                pass
        time.sleep(5)
        write_log("Ollama 服务已停止")

        # 从环境变量提取 Ollama 安装目录
        ollama_dir = os.environ.get("OLLAMA_INSTALL", "")
        if not ollama_dir:
            # 回退：从 ollama.exe 所在目录推断
            try:
                where = subprocess.run(
                    ["where", "ollama"],
                    capture_output=True, encoding="utf-8", errors="replace", timeout=5
                )
                if where.returncode == 0:
                    ollama_path = Path(where.stdout.strip().splitlines()[0])
                    ollama_dir = str(ollama_path.parent)
            except Exception:
                pass
        if not ollama_dir:
            user_profile = os.environ.get("USERPROFILE", "C:\\Users\\本人")
            ollama_dir = os.path.join(user_profile, "AppData", "Local", "Programs", "Ollama")
        write_log(f"Ollama 安装目录: {ollama_dir}")

        # 静默安装，按框架顺序尝试
        write_log("正在静默安装（请勿触碰任何弹窗）...")
        installed = False
        flag_sets = [
            ("Inno Setup /VERYSILENT + /DIR", ["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", f"/DIR={ollama_dir}"]),
            ("Inno Setup /VERYSILENT 无DIR", ["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART"]),
            ("MSI /quiet", ["/quiet", "/norestart"]),
            ("MSI /passive", ["/passive", "/norestart"]),
            ("NSIS /S", ["/S"]),
        ]
        for desc, flags in flag_sets:
            write_log(f"尝试: {desc}")
            result = subprocess.run(
                [str(installer_path)] + flags,
                timeout=600
            )
            if result.returncode == 0:
                installed = True
                write_log(f"安装成功（{desc}）")
                break
            else:
                write_log(f"  {desc} 退出码: {result.returncode}")

        if not installed:
            write_log("警告: 所有静默安装方式均失败，安装包已保留在项目目录")
            write_log(f"请手动运行安装包: {installer_path}")
            write_log("手动安装完成后重新运行本脚本即可")
            return

        # 等待 Ollama 服务就绪
        write_log("等待 Ollama 服务启动...")
        for i in range(30):
            time.sleep(2)
            try:
                probe = subprocess.run(
                    ["ollama", "list"],
                    capture_output=True, timeout=5
                )
                if probe.returncode == 0:
                    write_log("Ollama 服务已就绪")
                    break
            except Exception:
                pass
        else:
            write_log("警告: Ollama 服务可能未完全启动，继续执行...")

        # 比对安装前后版本
        ver_result2 = subprocess.run(
            ["ollama", "--version"],
            capture_output=True, encoding='utf-8', errors='replace', timeout=10
        )
        new_ver = (ver_result2.stdout or "").strip()
        write_log(f"更新后 Ollama 版本: {new_ver}")

        # 对比版本是否真正变化
        old_ver = (ver_result.stdout or "").strip()
        if old_ver == new_ver:
            write_log("警告: 版本未变化，安装包可能是旧版本（代理缓存）")
            write_log("将删除缓存安装包，下次运行重新下载")
            try:
                installer_path.unlink()
            except Exception:
                pass
            write_log("建议: 手动下载最新版 Ollama → https://ollama.com/download")
            write_log("或尝试关闭代理/换网络后重新运行")
        else:
            write_log("版本已更新，继续模型部署")
            # 版本更新后重新拉模型，删除旧的失败模型
            try:
                subprocess.run(["ollama", "rm", "qwen2.5-coder:7b"],
                               capture_output=True, timeout=10)
            except Exception:
                pass

    except Exception as e:
        write_log(f"Ollama 版本检查/更新失败: {e}")
        write_log("将继续使用当前版本，但模型可能无法加载")


def ensure_ollama_paths():
    r"""确保 Ollama 使用无中文路径，避免 llama.cpp 编码问题。
    Ollama Windows 服务以 SYSTEM 账户运行，看不到用户级环境变量，
    默认使用 %USERPROFILE%\.ollama，中文用户名会导致 llama.cpp 崩溃。

    策略：优先用 install-flashtap.ps1 已设置的 OLLAMA_MODELS 环境变量；
    若不可写则按候选列表回退；最后重启服务或 spawn ollama serve。"""
    # 候选目录：环境变量优先 → D盘 → 用户目录 → LOCALAPPDATA
    candidates = []
    env_models = os.environ.get("OLLAMA_MODELS", "").strip()
    if env_models:
        candidates.append(env_models)
    candidates.extend([
        r"D:\ollama_models",
        os.path.join(os.environ.get("USERPROFILE", r"C:\Users\Default"), ".ollama", "models"),
        os.path.join(os.environ.get("LOCALAPPDATA", r"C:\Users\Default\AppData\Local"), "ollama", "models"),
    ])

    # 逐个实测可写性（创建+写探测文件+删除）
    models_dir = None
    for d in candidates:
        if not d:
            continue
        try:
            os.makedirs(d, exist_ok=True)
            probe = os.path.join(d, ".flashtap_write_probe")
            with open(probe, "w") as f:
                f.write("ok")
            os.remove(probe)
            models_dir = d
            write_log(f"模型目录可用: {d}")
            break
        except Exception as e:
            write_log(f"候选目录不可用: {d} ({e})")
    if not models_dir:
        models_dir = os.path.join(os.environ.get("USERPROFILE", r"C:\Users\Default"), ".ollama", "models")
        write_log(f"所有候选不可用，兜底使用: {models_dir}")

    home_dir = os.path.join(os.path.dirname(models_dir), "home")
    try:
        os.makedirs(home_dir, exist_ok=True)
    except Exception:
        home_dir = models_dir  # 兜底

    # 1. 停止所有 ollama 进程
    write_log("正在停止 Ollama 进程...")
    subprocess.run(["sc", "stop", "ollama"], capture_output=True)
    subprocess.run(["taskkill", "/f", "/im", "ollama.exe"], capture_output=True)
    subprocess.run(["taskkill", "/f", "/im", "ollama app.exe"], capture_output=True)
    time.sleep(3)

    # 2. 设置当前进程环境变量
    os.environ["OLLAMA_MODELS"] = models_dir
    os.environ["OLLAMA_HOME"] = home_dir

    # 3. 设置机器级环境变量（尽量设，失败不阻塞）
    try:
        subprocess.run(["setx", "OLLAMA_MODELS", models_dir, "/M"],
                       capture_output=True, timeout=10)
        subprocess.run(["setx", "OLLAMA_HOME", home_dir, "/M"],
                       capture_output=True, timeout=10)
        write_log(f"已设置机器级环境变量: OLLAMA_MODELS={models_dir}, OLLAMA_HOME={home_dir}")
    except Exception:
        pass

    # 4. 尝试通过 Windows 服务启动
    write_log("正在启动 Ollama 服务...")
    sr = subprocess.run(["sc", "start", "ollama"], capture_output=True, timeout=15)
    if sr.returncode == 0:
        write_log("Ollama Windows 服务已启动")
    else:
        write_log(f"Windows 服务不可用（退出码 {sr.returncode}），改用后台进程启动")
        try:
            ps_cmd = (
                f'$env:OLLAMA_MODELS="{models_dir}"; '
                f'$env:OLLAMA_HOME="{home_dir}"; '
                f'Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden'
            )
            subprocess.run(
                ["powershell", "-NoProfile", "-Command", ps_cmd],
                capture_output=True, timeout=10,
            )
            write_log("ollama serve 已通过 PowerShell 后台启动")
        except Exception as e:
            write_log(f"ollama serve 启动失败: {e}")

    # 5. 等待服务就绪（最多 90 秒，虚拟机可能较慢）
    write_log("等待 Ollama 服务就绪...")
    for i in range(30):
        time.sleep(3)
        try:
            r = subprocess.run(["ollama", "list"], capture_output=True, timeout=8)
            if r.returncode == 0:
                write_log(f"Ollama 服务已就绪（等待 {(i+1)*3} 秒）")
                return True
        except subprocess.TimeoutExpired:
            pass
        except Exception:
            pass
        if (i + 1) % 5 == 0:
            write_log(f"  仍在等待... ({(i+1)*3}/90 秒)")

    write_log("警告: Ollama 服务 90 秒内未就绪，继续尝试部署...")
    return False


def main():
    write_log("=" * 50)
    write_log("模型部署开始")
    write_log("=" * 50)
    main_start = time.time()

    try:
        write_log("[步骤 1/6] 创建模型目录...")
        MODELS_DIR.mkdir(exist_ok=True)
        write_log(f"  模型目录: {MODELS_DIR}")

        write_log("[步骤 2/6] 安装 Python 依赖...")
        install_deps()

        write_log("[步骤 3/6] 确保 Ollama 路径和服务就绪...")
        ensure_ollama_paths()

        write_log("[步骤 4/6] 检查 Ollama 版本...")
        check_and_update_ollama()

        write_log("[步骤 5/6] 下载 Qwen2.5-Coder-7B 模型（约 4.7GB）...")
        write_log("  下载源: 阿里魔搭（ModelScope），国内速度快")
        write_log("  支持断点续传，中断后重新运行即可继续")
        model_path = download_model()

        write_log("[步骤 6/6] 导入模型到 Ollama + 验证...")
        create_ollama_model(model_path)
        ok = verify_model()

        elapsed = int(time.time() - main_start)
        write_log(f"========== 模型部署完成（总耗时 {elapsed} 秒）==========")

        if ok:
            write_log("模型部署成功，接下来将进行 Continue 配置。")
        else:
            write_log("模型部署未完成，Continue 可能无法使用，但安装流程继续")
        return 0 if ok else 1
    except Exception as e:
        write_log(f"部署失败: {e}")
        write_log("异常堆栈（用于排查）:")
        for line in traceback.format_exc().strip().split('\n'):
            write_log(f"  {line}")
        return 1
    finally:
        write_log("脚本退出")
        sys.stdout.flush()
        sys.stderr.flush()


if __name__ == "__main__":
    sys.exit(main())