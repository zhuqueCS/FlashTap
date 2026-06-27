<# FlashTap 一键安装主脚本 #>
# 此脚本由 一键安装FlashTap.bat 调用
# 作用：按照固定顺序执行 Ollama 安装、VS Code 安装/配置、模型下载与环境校验
# 目前实际入口文件：一键安装FlashTap.bat
# 严格按用户要求：所有配置来自用户提供的 settings.json / config.yaml / extensions.list
# 脚本只负责流程编排，不直接写入业务配置代码

$ErrorActionPreference = 'Continue'

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$PROJECT_DIR = $PSScriptRoot
if ((-not $PROJECT_DIR) -or ($PROJECT_DIR -eq '')) {
    $PROJECT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if ((-not $PROJECT_DIR) -or ($PROJECT_DIR -eq '')) {
    $PROJECT_DIR = (Get-Location).Path
}
$LOG_FILE = [System.IO.Path]::Combine($PROJECT_DIR, 'install.log')

function Write-Log {
    param([string]$Message, [string]$Color = 'White')
    $ts = Get-Date -Format 'HH:mm:ss'
    $line = "[$ts] $Message"
    Write-Host "  $line" -ForegroundColor $Color
    try {
        Add-Content -Path $LOG_FILE -Value $line -ErrorAction SilentlyContinue
    }
    catch { }
}

function Run-Script {
    param([string]$FilePath, [string]$Description)
    Write-Host ''
    Write-Host '  ────────────────────────────────────────────' -ForegroundColor Cyan
    Write-Host "    $Description" -ForegroundColor Cyan
    Write-Host '  ────────────────────────────────────────────' -ForegroundColor Cyan

    if (-not (Test-Path -LiteralPath $FilePath)) {
        Write-Log "[跳过] 未找到脚本: $FilePath" 'Yellow'
        return $false
    }

    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$FilePath`"" -Wait -NoNewWindow -PassThru
    $ec = if ($proc) { $proc.ExitCode } else { 1 }
    Write-Log "[信息] 脚本退出码: $ec"
    return ($ec -eq 0)
}

# ============================================================
# Python 环境探查（供 Run-Python 调用）
# ============================================================
function Find-PythonExecutable {
    function Test-RealPython {
        param([string]$Path)
        if ([string]::IsNullOrEmpty($Path)) { return $false }
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        if ($Path -match 'WindowsApps') { return $false }
        try {
            $fi = Get-Item -LiteralPath $Path -ErrorAction Stop
            if ($fi.Length -lt 10240) { return $false }
        } catch { return $false }
        return $true
    }

    function Test-PyLauncher {
        param([string]$Path)
        try {
            $probe = Start-Process -FilePath $Path -ArgumentList @('-3', '-c', "print('PROBE_OK')") -Wait -PassThru -NoNewWindow 2>$null
            return ($probe.ExitCode -eq 0)
        } catch { return $false }
    }

    $pyLauncher = $null
    try { $pyLauncher = Get-Command py -ErrorAction Stop } catch {}
    if ($pyLauncher) {
        if ((Test-RealPython $pyLauncher.Source) -and (Test-PyLauncher $pyLauncher.Source)) {
            return @{ Exe = $pyLauncher.Source; Type = 'py' }
        }
    }
    $pySystemPath = [System.IO.Path]::Combine($env:SystemRoot, 'py.exe')
    if ((Test-RealPython $pySystemPath) -and (Test-PyLauncher $pySystemPath)) {
        return @{ Exe = $pySystemPath; Type = 'py' }
    }

    $regPaths = @('HKLM:\Software\Python\PythonCore', 'HKCU:\Software\Python\PythonCore')
    foreach ($rp in $regPaths) {
        try {
            $versions = Get-ChildItem -Path $rp -ErrorAction SilentlyContinue |
                Where-Object { $_.PSChildName -match '^\d+\.\d+' } |
                Sort-Object { [version]$_.PSChildName } -Descending
            foreach ($ver in $versions) {
                $installPath = (Get-ItemProperty -Path "$($ver.PSPath)\InstallPath" -ErrorAction SilentlyContinue).'(default)'
                if ($installPath) {
                    $exe = [System.IO.Path]::Combine($installPath, 'python.exe')
                    if (Test-RealPython $exe) {
                        return @{ Exe = $exe; Type = 'registry' }
                    }
                }
            }
        } catch {}
    }

    $condaPaths = @(
        [System.IO.Path]::Combine($env:USERPROFILE, 'Anaconda3\python.exe'),
        [System.IO.Path]::Combine($env:USERPROFILE, 'miniconda3\python.exe'),
        [System.IO.Path]::Combine($env:USERPROFILE, 'anaconda3\python.exe'),
        [System.IO.Path]::Combine($env:ALLUSERSPROFILE, 'Anaconda3\python.exe'),
        [System.IO.Path]::Combine($env:ALLUSERSPROFILE, 'miniconda3\python.exe'),
        [System.IO.Path]::Combine($env:SystemDrive, 'Anaconda3\python.exe'),
        [System.IO.Path]::Combine($env:SystemDrive, 'miniconda3\python.exe')
    )
    foreach ($cp in $condaPaths) {
        if (Test-RealPython $cp) {
            return @{ Exe = $cp; Type = 'conda' }
        }
    }

    $whereNames = @('python', 'python3')
    foreach ($name in $whereNames) {
        try {
            $whereResult = & where.exe $name 2>&1
            if ($LASTEXITCODE -eq 0) {
                foreach ($line in ($whereResult -split '\r?\n')) {
                    $p = $line.Trim()
                    if ($p -and (Test-RealPython $p)) {
                        return @{ Exe = $p; Type = 'where' }
                    }
                }
            }
        } catch {}
    }

    foreach ($name in @('python', 'python3')) {
        try {
            $cmd = Get-Command $name -ErrorAction Stop
            if ($cmd -and (Test-RealPython $cmd.Source)) {
                return @{ Exe = $cmd.Source; Type = 'path' }
            }
        } catch {}
    }

    $pyPaths = @(
        [System.IO.Path]::Combine($env:LOCALAPPDATA, 'Programs\Python\Python313\python.exe'),
        [System.IO.Path]::Combine($env:LOCALAPPDATA, 'Programs\Python\Python312\python.exe'),
        [System.IO.Path]::Combine($env:LOCALAPPDATA, 'Programs\Python\Python311\python.exe'),
        [System.IO.Path]::Combine($env:LOCALAPPDATA, 'Programs\Python\Python310\python.exe'),
        [System.IO.Path]::Combine(${env:ProgramFiles}, 'Python313\python.exe'),
        [System.IO.Path]::Combine(${env:ProgramFiles}, 'Python312\python.exe'),
        [System.IO.Path]::Combine(${env:ProgramFiles}, 'Python311\python.exe'),
        [System.IO.Path]::Combine(${env:ProgramFiles}, 'Python310\python.exe'),
        [System.IO.Path]::Combine([Environment]::GetEnvironmentVariable("ProgramFiles(x86)"), 'Python313\python.exe'),
    [System.IO.Path]::Combine([Environment]::GetEnvironmentVariable("ProgramFiles(x86)"), 'Python312\python.exe'),
    [System.IO.Path]::Combine([Environment]::GetEnvironmentVariable("ProgramFiles(x86)"), 'Python311\python.exe'),
    [System.IO.Path]::Combine([Environment]::GetEnvironmentVariable("ProgramFiles(x86)"), 'Python310\python.exe'),
        'C:\Python313\python.exe', 'C:\Python312\python.exe', 'C:\Python311\python.exe', 'C:\Python310\python.exe',
        [System.IO.Path]::Combine($env:ProgramData, 'chocolatey\bin\python.exe'),
        'C:\Tools\Python313\python.exe', 'C:\Tools\Python312\python.exe', 'C:\Tools\Python311\python.exe',
        [System.IO.Path]::Combine($env:USERPROFILE, 'scoop\apps\python\current\python.exe'),
        [System.IO.Path]::Combine($env:USERPROFILE, 'scoop\apps\python3\current\python.exe'),
        [System.IO.Path]::Combine($env:USERPROFILE, '.pyenv\pyenv-win\versions\3.13.0\python.exe'),
        [System.IO.Path]::Combine($env:USERPROFILE, '.pyenv\pyenv-win\versions\3.12.0\python.exe'),
        [System.IO.Path]::Combine($env:USERPROFILE, '.pyenv\pyenv-win\versions\3.11.0\python.exe')
    )
    foreach ($pp in $pyPaths) {
        if (Test-RealPython $pp) {
            return @{ Exe = $pp; Type = 'scan' }
        }
    }

    $scanDirs = @(
        [System.IO.Path]::Combine($env:LOCALAPPDATA, 'Programs\Python'),
        [System.IO.Path]::Combine(${env:ProgramFiles}, 'Python')
    )
    foreach ($sd in $scanDirs) {
        try {
            if (Test-Path -LiteralPath $sd) {
                $latestDir = Get-ChildItem -LiteralPath $sd -Directory -Filter 'Python3*' -ErrorAction SilentlyContinue |
                    Sort-Object Name -Descending | Select-Object -First 1
                if ($latestDir) {
                    $exe = [System.IO.Path]::Combine($latestDir.FullName, 'python.exe')
                    if (Test-RealPython $exe) {
                        return @{ Exe = $exe; Type = 'scan' }
                    }
                }
            }
        } catch {}
    }

    return $null
}

function Run-Python {
    param([string]$FilePath, [string]$Description)
    Write-Host ''
    Write-Host '  ────────────────────────────────────────────' -ForegroundColor Cyan
    Write-Host "    $Description" -ForegroundColor Cyan
    Write-Host '  ────────────────────────────────────────────' -ForegroundColor Cyan

    if (-not (Test-Path -LiteralPath $FilePath)) {
        Write-Log "[跳过] 未找到脚本: $FilePath" 'Yellow'
        return $false
    }

    $pyInfo = Find-PythonExecutable

    if (-not $pyInfo) {
        Write-Log "[跳过] 未找到 Python 环境" 'Yellow'
        Write-Log '  请安装 Python 3.10+: https://www.python.org/downloads/' 'Yellow'
        Write-Log '  或安装 Anaconda: https://www.anaconda.com/download' 'Yellow'
        return $false
    }

    if ($pyInfo.Type -eq 'py') {
        $args = @('-3', $FilePath)
    } else {
        $args = @('-u', $FilePath)
    }

    $ec = 0
    try {
        & $pyInfo.Exe @args
        $ec = $LASTEXITCODE
    } catch {
        $ec = 1
    }
    Write-Log "[信息] 脚本退出码: $ec"
    return ($ec -eq 0)
}

# ============================================================
# 主流程
# ============================================================

Write-Host ''
Write-Host '════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host '      FlashTap · AI 编程助手 一键安装工具' -ForegroundColor Cyan
Write-Host '════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ''
Write-Host '  [信息] 本工具将自动完成以下步骤：           ' -ForegroundColor White
Write-Host '         1. Ollama 本地大模型引擎               ' -ForegroundColor White
Write-Host '         2. VS Code 编辑器 + Continue AI 编程插件  ' -ForegroundColor White
Write-Host '         3. Qwen2.5-Coder 7B 代码模型          ' -ForegroundColor White
Write-Host '         4. 全自动配置，无需任何手动操作          ' -ForegroundColor White
Write-Host ''

# ── 第一步：安装 Ollama ──
$ollamaScript = [System.IO.Path]::Combine($PROJECT_DIR, 'install-localcoder.ps1')
if (-not (Run-Script -FilePath $ollamaScript -Description '第一步：安装 Ollama 本地大模型引擎')) {
    Write-Host ''
    Write-Host '  ╔════════════════════════════════════════════╗' -ForegroundColor Red
    Write-Host '  ║        Ollama 安装失败，安装中止           ║' -ForegroundColor Red
    Write-Host '  ╚════════════════════════════════════════════╝' -ForegroundColor Red
    Write-Host ''
    Write-Host '  [原因] 同目录下未找到 OllamaSetup.exe 安装包' -ForegroundColor Yellow
    Write-Host '  [解决] 请将 OllamaSetup.exe 与脚本放在同一文件夹后重试' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '按任意键退出...' -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    exit 1
}

# 刷新 PATH（Ollama 安装器写入了注册表但当前进程 PATH 未更新）
try {
    $m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $u = [Environment]::GetEnvironmentVariable('Path', 'User')
    $merged = @()
    if ($m) { $merged += $m }
    if ($u) { $merged += $u }
    $env:Path = $merged -join ';'
    Write-Log "[成功] PATH 已刷新，ollama 命令行可用" 'Green'
} catch {
    Write-Log "[警告] PATH 刷新失败，后续步骤可能受影响" 'Yellow'
}

# ── 第二步：安装 VS Code + 扩展 + 配置 ──
$vscodeScript = [System.IO.Path]::Combine($PROJECT_DIR, 'install-vscode.ps1')
$vscodeResult = Run-Script -FilePath $vscodeScript -Description '第二步：安装 VS Code + 扩展 + 配置'
if ($vscodeResult) {
    Write-Log '[成功] VS Code 安装配置完成' 'Green'
} else {
    Write-Log '[警告] VS Code 安装配置未完全成功，将跳过，可稍后手动安装' 'Yellow'
}

# ── 第二步半：C++ 编译环境配置（不阻塞主流程） ──
$cppScript = [System.IO.Path]::Combine($PROJECT_DIR, 'setup-cpp-env.ps1')
Run-Script -FilePath $cppScript -Description 'C++ 编译环境配置（可选，不影响主流程）' | Out-Null

# ── 第三步：部署 AI 代码模型 ──
$downloadScript = [System.IO.Path]::Combine($PROJECT_DIR, 'download-models.py')
$downloadOk = Run-Python -FilePath $downloadScript -Description '第三步：部署 Qwen2.5-Coder 7B 代码模型（约 4GB，耗时较长）'
if (-not $downloadOk) {
    Write-Host ''
    Write-Host '  [警告] 模型部署未成功，Continue 插件可能无法使用' -ForegroundColor Yellow
    Write-Host '  [建议] 检查网络连接后重新运行本脚本' -ForegroundColor Yellow
    Write-Host ''
}
else {
    # 模型下载成功后，验证能否正常运行
    Write-Host ''
    Write-Log '[信息] 正在验证模型是否正常运行...' 'Cyan'
    $ollamaExe = $null
    $ollamaSearchPaths = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'),
        (Join-Path $env:ProgramFiles 'Ollama\ollama.exe'),
        (Join-Path ([Environment]::GetEnvironmentVariable("ProgramFiles(x86)")) 'Ollama\ollama.exe')
    )
    foreach ($op in $ollamaSearchPaths) {
        if (Test-Path -LiteralPath $op) { $ollamaExe = $op; break }
    }
    if (-not $ollamaExe) { $ollamaExe = 'ollama' }

    # 用简单提示测试模型
    Write-Log '  [信息] 正在测试模型响应...' 'Cyan'
    $verifyProc = Start-Process -FilePath $ollamaExe -ArgumentList 'run qwen2.5-coder:7b hi' -Wait -NoNewWindow -PassThru
    if ($verifyProc -and $verifyProc.ExitCode -eq 0) {
        Write-Log '[成功] 模型验证通过，可以正常对话' 'Green'
    } else {
        Write-Log '[警告] 模型验证未通过，Continue 可能无法正常调用' 'Yellow'
    }
}

# ── 第 3.5 步：配置 Continue 插件 ──
$configScript = [System.IO.Path]::Combine($PROJECT_DIR, 'configure-continue.py')
$configOk = Run-Python -FilePath $configScript -Description '正在配置 Continue AI 插件...'
if (-not $configOk) {
    Write-Host '  [警告] Continue 配置未成功，请手动配置' -ForegroundColor Yellow
}

# ── 第四步：打开 VS Code 工作区 ──
Write-Host ''
Write-Log '[信息] 所有安装步骤完成，准备重启 VS Code...' 'Cyan'

# ── 查找 VS Code 可执行文件 ──
$vscExe = $null
$vscCandidatePaths = @(
    [System.IO.Path]::Combine($env:LOCALAPPDATA, 'Programs\Microsoft VS Code\Code.exe'),
    [System.IO.Path]::Combine($env:ProgramFiles, 'Microsoft VS Code\Code.exe'),
    [System.IO.Path]::Combine([Environment]::GetEnvironmentVariable("ProgramFiles(x86)"), 'Microsoft VS Code\Code.exe'),
    [System.IO.Path]::Combine($env:USERPROFILE, 'AppData\Local\Programs\Microsoft VS Code\Code.exe')
)
if ($env:ProgramW6432) {
    $vscCandidatePaths += [System.IO.Path]::Combine($env:ProgramW6432, 'Microsoft VS Code\Code.exe')
}
foreach ($p in $vscCandidatePaths) {
    if (Test-Path -LiteralPath $p) {
        try {
            $item = Get-Item -LiteralPath $p -ErrorAction Stop
            if ($item.Length -gt 5242880) { $vscExe = $p; break }
        } catch {}
    }
}

# ── 检查 VS Code 运行状态（仅提示，不强制关闭用户已打开的窗口） ──
$existingCode = @(Get-Process Code -ErrorAction SilentlyContinue)
if ($existingCode.Count -gt 0) {
    Write-Log "[信息] 检测到 $($existingCode.Count) 个 VS Code 进程" 'Cyan'
} else {
    Write-Log "[信息] VS Code 未运行，将启动新实例" 'Cyan'
}

# ── 启动 VS Code（强制中文界面 + 自动连接 WSL C++ 环境） ──
if ($vscExe) {
    try {
        $vscArgs = @('--locale=zh-cn')
        $distroFile = Join-Path $PSScriptRoot '.wsl-distro-name'

        if (Test-Path $distroFile) {
            $distroName = (Get-Content $distroFile -Raw -ErrorAction SilentlyContinue).Trim()
            if ($distroName) {
                Write-Log "[信息] 准备 WSL 连接: $distroName" 'Cyan'

                # 提前获取 WSL 用户家目录（避免变量未定义）
                $wslHome = (& wsl.exe -d $distroName -- bash -c 'echo $HOME' 2>&1).Trim()
                if (-not $wslHome -or $wslHome -eq '/') {
                    Write-Log "[警告] 无法获取 WSL 用户家目录，使用默认路径" 'Yellow'
                    $wslHome = '/home/phenomenon'
                }
                $wslWorkspace = "$wslHome/lc-cpp-workspace"
                Write-Log "[信息] 工作区路径: $wslWorkspace" 'Cyan'

                $null = & wsl.exe --terminate $distroName 2>&1
                Start-Sleep 1

                $null = & wsl.exe -d $distroName -u root -- echo ready 2>&1
                Start-Sleep 2

                # ── 获取 VS Code commit ID ──
                # 纯文件读取，绝不启动 Code.exe
                # 1) product.json（多路径尝试） 2) WSL vscode-server 目录 3) 兜底自动下载
                $commitId = ''
                $vscInstallDir = if (Test-Path -LiteralPath $vscExe) {
                    (Get-Item -LiteralPath $vscExe -ErrorAction Stop).DirectoryName
                } else {
                    Split-Path -Parent $vscExe
                }
                Write-Log "[调试] vscExe: $vscExe" 'Cyan'
                Write-Log "[调试] 安装目录: $vscInstallDir" 'Cyan'

                # 多路径尝试 product.json
                $productCandidates = @(
                    (Join-Path $vscInstallDir 'resources\app\product.json'),
                    (Join-Path $vscInstallDir 'resources\app\out\product.json'),
                    (Join-Path $vscInstallDir 'product.json')
                )
                foreach ($tryPath in $productCandidates) {
                    Write-Log "[调试] 尝试: $tryPath" 'Cyan'
                    if ([System.IO.File]::Exists($tryPath)) {
                        try {
                            $rawJson = [System.IO.File]::ReadAllText($tryPath, [System.Text.Encoding]::UTF8)
                            $reMatch = [regex]::Match($rawJson, '"commit"\s*:\s*"([a-f0-9]{40})"')
                            if ($reMatch.Success) {
                                $commitId = $reMatch.Groups[1].Value
                                Write-Log "[信息] 从 product.json 提取 commit ID: $commitId" 'Cyan'
                                break
                            }
                        } catch {}
                    }
                }

                # 递归搜索（扩大深度）
                if (-not $commitId) {
                    Write-Log "[调试] 直接路径均未命中，递归搜索 product.json (Depth 5)..." 'Cyan'
                    try {
                        $found = Get-ChildItem -Path $vscInstallDir -Recurse -Filter 'product.json' -Depth 5 -ErrorAction SilentlyContinue | Select-Object -First 1
                        if ($found) {
                            Write-Log "[调试] 递归找到: $($found.FullName)" 'Cyan'
                            $rawJson = [System.IO.File]::ReadAllText($found.FullName, [System.Text.Encoding]::UTF8)
                            $reMatch = [regex]::Match($rawJson, '"commit"\s*:\s*"([a-f0-9]{40})"')
                            if ($reMatch.Success) {
                                $commitId = $reMatch.Groups[1].Value
                                Write-Log "[信息] 从 $($found.FullName) 提取 commit ID: $commitId" 'Cyan'
                            }
                        } else {
                            Write-Log "[警告] 递归搜索也未找到 product.json" 'Yellow'
                        }
                    } catch {}
                }

                if (-not $commitId) {
                    Write-Log "[信息] 尝试从 WSL 已有 vscode-server 获取 commit ID..." 'Cyan'
                    try {
                        $srvDirCheck = & wsl.exe -d $distroName -u root -- bash -c 'ls -d $HOME/.vscode-server/bin/*/ 2>/dev/null | head -1 | xargs -r basename' 2>&1
                        $srvDirCheck = "$srvDirCheck".Trim()
                        if ($srvDirCheck -match '^[a-f0-9]{40}$') {
                            $commitId = $srvDirCheck
                            Write-Log "[信息] 从 WSL vscode-server 获取 commit ID: $commitId" 'Cyan'
                        }
                    } catch {}
                }

                if (-not $commitId) {
                    Write-Log "[警告] 无法获取 commit ID，跳过预装 Server" 'Yellow'
                    Write-Log "[信息] VS Code 启动后将自动下载 Server 和扩展" 'Cyan'
                }

                if ($commitId) {
                    Write-Log "[信息] 正在安装 VS Code Server 至 WSL（约需 30-60 秒）..." 'Cyan'

                    $serverScript = @"
SERVER_DIR="`$HOME/.vscode-server/bin/$commitId"
if [ -f "`$SERVER_DIR/bin/remote-cli/code" ]; then
    echo "SERVER_EXISTS"
else
    mkdir -p "`$SERVER_DIR"
    if curl -fsSL "https://update.code.visualstudio.com/commit:$commitId/server-linux-x64/stable" -o /tmp/vs-srv.tar.gz 2>/dev/null; then
        tar -xzf /tmp/vs-srv.tar.gz -C "`$SERVER_DIR" --strip-components=1 2>/dev/null
        rm -f /tmp/vs-srv.tar.gz
        chmod -R +x "`$SERVER_DIR/bin/" 2>/dev/null
        if [ -f "`$SERVER_DIR/bin/remote-cli/code" ]; then
            echo "SERVER_OK"
        else
            echo "SERVER_EXTRACT_FAIL"
        fi
    else
        echo "SERVER_DOWNLOAD_FAIL"
    fi
fi
"@
                    $srvB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($serverScript))
                    $srvResult = & wsl.exe -d $distroName -- bash -c "echo '$srvB64' | base64 -d | bash" 2>&1
                    $srvOk = ("$srvResult" -match 'SERVER_OK' -or "$srvResult" -match 'SERVER_EXISTS')

                    if ($srvOk) {
                        Write-Log "[信息] VS Code Server 已就绪" 'Green'

                        # ── 在 WSL 内以 root 安装 unzip + python3（后续解压 VSIX 必需） ──
                        Write-Log "[信息] 安装 unzip + python3 依赖 (WSL, root)..." 'Cyan'
                        $aptResult = & wsl.exe -d $distroName -u root -- bash -c "apt-get update -qq 2>&1 && apt-get install -y -qq unzip python3 2>&1 && echo APT_OK || echo APT_FAIL" 2>&1
                        if ("$aptResult" -match 'APT_FAIL') {
                            Write-Log "[警告] unzip/python3 安装可能失败，扩展安装可能受影响" 'Yellow'
                            Write-Log "[调试] apt 输出: $aptResult" 'Cyan'
                        } else {
                            Write-Log "[成功] unzip + python3 已就绪" 'Green'
                        }

                        # ── 快速检查 C/C++ 扩展是否已安装且为 linux-x64 架构 ──
                        $extCheck = & wsl.exe -d $distroName -- bash -c 'if ls ~/.vscode-server/extensions/ms-vscode.cpptools-*/package.json >/dev/null 2>&1; then
                            pkg=$(ls -d ~/.vscode-server/extensions/ms-vscode.cpptools-*/package.json 2>/dev/null | head -1)
                            if python3 -c "import json; d=json.load(open(\"$pkg\")); tp=d.get(\"__metadata\",{}).get(\"targetPlatform\",\"\"); exit(0 if tp==\"linux-x64\" else 1)" 2>/dev/null; then
                                echo EXT_OK_LINUX
                            else
                                echo EXT_OK_NOT_LINUX
                            fi
                        else
                            echo EXT_NOT_FOUND
                        fi' 2>&1
                        if ("$extCheck" -match 'EXT_OK_LINUX') {
                            Write-Log "[成功] C/C++ 扩展已安装（linux-x64），跳过 $((123))MB 下载，修复权限..." 'Green'
                            $null = & wsl.exe -d $distroName -- bash -c 'for d in ~/.vscode-server/extensions/ms-vscode.cpptools-*; do find "$d" -type f \( -name "*.so" -o -name "cpptools" -o -name "cpptools-srv" -o -name "cpptools-wordexp" -o -name "OpenDebugAD7" \) -exec chmod +x {} \; 2>/dev/null; done' 2>&1
                            $extSuccess = $true
                        } else {
                            if ("$extCheck" -match 'EXT_OK_NOT_LINUX') {
                                Write-Log "[警告] C/C++ 扩展架构不匹配（非 linux-x64），将清理后重新安装" 'Yellow'
                                $null = & wsl.exe -d $distroName -- bash -c 'rm -rf ~/.vscode-server/extensions/ms-vscode.cpptools-*' 2>&1
                            }
                            # ── 安装固定版本 cpptools 1.21.6（兼容 VS Code 1.125，支持 console 终端配置） ──
                            Write-Log "[信息] 正在下载 C/C++ 扩展 (v1.21.6 linux-x64, ~70MB)..." 'Cyan'
                            $extSuccess = $false
                            # 将安装脚本写入临时文件，避免 base64 管道问题
                            $cppInstallSh = Join-Path $env:TEMP 'localcoder_cpp_install.sh'
                            @'
#!/bin/bash
echo "=== CPP_INSTALL_START ==="

# 固定版本 1.21.6，兼容 VS Code 1.125 + WSL，支持 console 终端配置
# 1.32.2 有严重兼容 bug：preLaunchTask 终端编译后销毁、不支持 integratedTerminal
CPPTOOLS_VER="1.21.6"
VSIX_URL="https://marketplace.visualstudio.com/_apis/public/gallery/publishers/ms-vscode/vsextensions/cpptools/${CPPTOOLS_VER}/vspackage?targetPlatform=linux-x64"
echo "URL_OK:$VSIX_URL"

# 下载 .vsix（--compressed 自动解压 gzip）
curl -sL --compressed --max-time 120 -o /tmp/cpptools.vsix "$VSIX_URL" 2>&1
if [ ! -s /tmp/cpptools.vsix ]; then
  echo "DOWNLOAD_FAIL"
  exit 0
fi
echo "DOWNLOAD_OK:$(wc -c < /tmp/cpptools.vsix) bytes"

# 2. 验证 zip
if ! python3 -c "import zipfile; zipfile.ZipFile('/tmp/cpptools.vsix')" 2>/dev/null; then
  echo "NOT_A_ZIP"
  head -c 200 /tmp/cpptools.vsix | xxd | head -5
  exit 0
fi
echo "ZIP_OK"

# 3. 解压
VERSION=$(python3 -c "
import zipfile, json
z = zipfile.ZipFile('/tmp/cpptools.vsix')
pkg = json.loads(z.read('extension/package.json'))
print(pkg['version'])
")
echo "VERSION:$VERSION"
EXT_DIR=~/.vscode-server/extensions/ms-vscode.cpptools-${VERSION}
rm -rf "$EXT_DIR"
mkdir -p "$EXT_DIR"
python3 -c "
import zipfile, os
z = zipfile.ZipFile('/tmp/cpptools.vsix')
for f in z.namelist():
    if f.startswith('extension/'):
        target = os.path.join('$EXT_DIR', f[10:])
        os.makedirs(os.path.dirname(target), exist_ok=True)
        if not f.endswith('/'):
            with open(target, 'wb') as out:
                out.write(z.read(f))
" && echo "EXTRACT_OK" || echo "EXTRACT_FAIL"

# 4. 修复权限
find "$EXT_DIR" -type f \( -name "*.so" -o -name "cpptools" -o -name "cpptools-srv" -o -name "cpptools-wordexp" -o -name "OpenDebugAD7" \) -exec chmod +x {} \; 2>/dev/null

# 5. 验证
ls "$EXT_DIR/package.json" >/dev/null 2>&1 && echo "=== CPP_INSTALL_OK ===" || echo "=== CPP_INSTALL_FAIL ==="
'@ | Out-File -FilePath $cppInstallSh -Encoding ASCII
                            # 转 WSL 路径并执行
                            $wslPath = ($cppInstallSh -replace '\\', '/') -replace '^([A-Z]):', '/mnt/$1'
                            $wslPath = $wslPath.ToLower()
                            $installResult = & wsl.exe -d $distroName -- bash "$wslPath" 2>&1
                            if ("$installResult" -match 'CPP_INSTALL_OK') {
                                Write-Log "[成功] C/C++ 扩展 (linux-x64) 安装完成" 'Green'
                                $extSuccess = $true
                            } else {
                                Write-Log "[警告] C/C++ 扩展安装未完全成功" 'Yellow'
                                Write-Log "[调试] 输出: $installResult" 'Cyan'
                            }
                            Remove-Item $cppInstallSh -Force -ErrorAction SilentlyContinue
                        }

                        if (-not $extSuccess) {
                            Write-Log "[信息] VS Code 启动后将自动同步扩展，首次连接请耐心等待" 'Cyan'
                        }

                        # locale.json
                        try {
                            $localeJson = '{"locale":"zh-cn"}'
                            $locB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($localeJson))
                            $null = & wsl.exe -d $distroName -- bash -c "mkdir -p ~/.vscode-server/data/User && echo '$locB64' | base64 -d > ~/.vscode-server/data/User/locale.json" 2>&1
                        } catch {}

                        # ── 生成 Linux GDB 调试配置 (launch.json) ──
                        Write-Log "[信息] 配置 C/C++ GDB 调试器..." 'Cyan'
                        $launchJson = @'
{
    "version": "0.2.0",
    "configurations": [
        {
            "name": "GDB 调试 (WSL)",
            "type": "cppdbg",
            "request": "launch",
            "program": "${fileDirname}/${fileBasenameNoExtension}",
            "args": [],
            "stopAtEntry": false,
            "cwd": "${fileDirname}",
            "environment": [],
            "externalConsole": false,
            "MIMode": "gdb",
            "miDebuggerPath": "/usr/bin/gdb",
            "setupCommands": [
                {
                    "description": "为 gdb 启用整齐打印",
                    "text": "-enable-pretty-printing",
                    "ignoreFailures": true
                },
                {
                    "description": "将反汇编风格设置为 Intel",
                    "text": "-gdb-set disassembly-flavor intel",
                    "ignoreFailures": true
                }
            ],
            "preLaunchTask": "C++: g++ build active file",
            "logging": {
                "engineLogging": false
            }
        }
    ]
}
'@
                        $launchB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($launchJson))
                        $null = & wsl.exe -d $distroName -- bash -c "mkdir -p $wslWorkspace/.vscode && echo '$launchB64' | base64 -d > $wslWorkspace/.vscode/launch.json" 2>&1
                        Write-Log "[成功] launch.json (WSL GDB) 已配置" 'Green'

                        # ── 生成 tasks.json（编译任务，dedicated panel 避免终端复用困扰） ──
                        $tasksJson = @'
{
    "version": "2.0.0",
    "tasks": [
        {
            "type": "shell",
            "label": "C++: g++ build active file",
            "command": "/usr/bin/g++",
            "args": [
                "-g",
                "${file}",
                "-o",
                "${fileDirname}/${fileBasenameNoExtension}",
                "-std=c++17"
            ],
            "options": {
                "cwd": "${fileDirname}"
            },
            "problemMatcher": [
                "$gcc"
            ],
            "group": {
                "kind": "build",
                "isDefault": true
            },
            "presentation": {
                "panel": "dedicated",
                "clear": true
            },
            "detail": "compiler: /usr/bin/g++"
        }
    ]
}
'@
                        $tasksB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($tasksJson))
                        $null = & wsl.exe -d $distroName -- bash -c "echo '$tasksB64' | base64 -d > $wslWorkspace/.vscode/tasks.json" 2>&1
                        Write-Log "[成功] tasks.json (编译任务) 已配置" 'Green'

                        # ── 生成 main.cpp 示例文件 ──
                        $mainCpp = @'
#include <iostream>
#include <vector>
#include <string>

int main() {
    std::vector<std::string> msg = {
        "Hello, FlashTap!",
        "C++ build environment: g++ (WSL)",
        "Press F5 to build and debug."
    };

    for (const auto& line : msg) {
        std::cout << line << std::endl;
    }

    return 0;
}
'@
                        $mainB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($mainCpp))
                        $null = & wsl.exe -d $distroName -- bash -c "echo '$mainB64' | base64 -d > $wslWorkspace/main.cpp" 2>&1
                        Write-Log "[成功] main.cpp (示例代码) 已生成" 'Green'
                    } else {
                        Write-Log "[警告] Server 安装失败 ($srvResult)，跳过扩展安装" 'Yellow'
                    }
                }

                # ── 原生 VS Code 中文语言包（手动下载解压，不启动 VS Code，杜绝双窗口）──
                Write-Log "[信息] 为原生 VS Code 安装中文语言包（静默，不弹窗）..." 'Cyan'
                try {
                    $vscExtDir = Join-Path $env:USERPROFILE '.vscode\extensions'
                    # 检查是否已安装（避免重复下载）
                    $existingLang = Get-ChildItem -Path $vscExtDir -Directory -Filter 'ms-ceintl.vscode-language-pack-zh-hans-*' -ErrorAction SilentlyContinue
                    if (-not $existingLang) {
                        $langVsix = Join-Path $env:TEMP 'vscode-lang-pack.vsix'
                        $langExtract = Join-Path $env:TEMP 'vscode-lang-ext'

                        Write-Log '  [信息] 正在下载中文语言包...' 'Cyan'
                        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                        Invoke-WebRequest -Uri 'https://marketplace.visualstudio.com/_apis/public/gallery/publishers/MS-CEINTL/vsextensions/vscode-language-pack-zh-hans/latest/vspackage' -OutFile $langVsix -UseBasicParsing

                        # VSIX 本质是 ZIP，直接解压
                        Remove-Item -Path $langExtract -Recurse -Force -ErrorAction SilentlyContinue
                        Add-Type -AssemblyName System.IO.Compression.FileSystem
                        [System.IO.Compression.ZipFile]::ExtractToDirectory($langVsix, $langExtract)

                        # 读版本号，安装到扩展目录
                        $langPkg = Get-Content -Path (Join-Path $langExtract 'extension\package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
                        $langVer = $langPkg.version
                        $langTarget = Join-Path $vscExtDir "ms-ceintl.vscode-language-pack-zh-hans-$langVer"
                        Remove-Item -Path $langTarget -Recurse -Force -ErrorAction SilentlyContinue
                        New-Item -ItemType Directory -Path $langTarget -Force | Out-Null
                        Copy-Item -Path (Join-Path $langExtract 'extension\*') -Destination $langTarget -Recurse -Force

                        # 清理
                        Remove-Item -Path $langVsix, $langExtract -Recurse -Force -ErrorAction SilentlyContinue
                    }

                    # 写入 locale.json 确保中文生效
                    $vscUserDir = Join-Path $env:APPDATA 'Code\User'
                    New-Item -ItemType Directory -Path $vscUserDir -Force -ErrorAction SilentlyContinue | Out-Null
                    Set-Content -Path (Join-Path $vscUserDir 'locale.json') -Value '{"locale":"zh-cn"}' -Encoding UTF8 -ErrorAction SilentlyContinue
                    Write-Log "[成功] 原生 VS Code 中文语言包已安装" 'Green'
                } catch {
                    Write-Log "[警告] 原生 VS Code 中文安装失败，可稍后手动安装: $($_.Exception.Message)" 'Yellow'
                }

                $vscArgs = @(
                    '--locale=zh-cn',
                    '--remote',
                    "wsl+$distroName",
                    $wslWorkspace
                )
                Write-Log "[信息] 自动连接 WSL 环境: $distroName" 'Cyan'
            }
        }

        # 为确保中文界面和 Continue 配置生效，关闭当前用户的所有 VS Code 进程后重新启动
        if ($existingCode.Count -gt 0) {
            Write-Log "[信息] 关闭当前用户的 VS Code 进程以应用新配置..." 'Cyan'
            & taskkill /F /FI "USERNAME eq $env:USERNAME" /IM Code.exe 2>&1 | Out-Null
            Start-Sleep 3
        }
        Start-Process -FilePath $vscExe -ArgumentList $vscArgs
        Start-Sleep 3
        Write-Log '[成功] VS Code 已启动，中文界面 + Continue 配置已就绪' 'Green'
    } catch {
        Write-Log '[错误] VS Code 启动失败，请手动打开' 'Red'
    }
} else {
    Write-Log '[警告] 未找到 VS Code，请手动从开始菜单打开' 'Yellow'
}

# ── 第五步：安装完成 ──
Write-Host ''
Write-Host '════════════════════════════════════════════════════════' -ForegroundColor Green
Write-Host '      FlashTap 安装完成！' -ForegroundColor Green
Write-Host '════════════════════════════════════════════════════════' -ForegroundColor Green
Write-Host ''
Write-Host '  【新手快速上手 3 步】' -ForegroundColor Cyan
Write-Host ''
Write-Host '  第 1 步：打开 VS Code 后，按 Ctrl+Shift+P，输入' -ForegroundColor White
Write-Host '          > Continue: Focus on Chat' -ForegroundColor Yellow
Write-Host '          在右侧面板中即可看到 Continue 对话窗口' -ForegroundColor White
Write-Host ''
Write-Host '  第 2 步：在 Continue 窗口底部输入框（或快捷键 Ctrl+L）' -ForegroundColor White
Write-Host '          直接输入你的编程问题，例如：' -ForegroundColor White
Write-Host '          用 C 语言写一个冒泡排序' -ForegroundColor Yellow
Write-Host ''
Write-Host '  第 3 步：按 Enter 发送，AI 会调用本地 Qwen2.5-Coder' -ForegroundColor White
Write-Host '          模型为你生成代码，全程无需联网，完全免费' -ForegroundColor White
Write-Host ''
Write-Host '  【常用快捷键】' -ForegroundColor Cyan
Write-Host ''
Write-Host '  Ctrl+L        在侧边栏打开 Continue 对话' -ForegroundColor White
Write-Host '  Ctrl+I        在编辑器内行内提问（Inline Chat）' -ForegroundColor White
Write-Host '  Ctrl+Shift+R  选中代码后，让 AI 解释/优化' -ForegroundColor White
Write-Host '  Ctrl+Alt+N    使用 Code Runner 一键运行当前代码' -ForegroundColor White
Write-Host '  F5            启动调试（C/C++ 需要先配置 launch.json）' -ForegroundColor White
Write-Host ''
Write-Host '  【如果 AI 没有反应，请按顺序排查】' -ForegroundColor Cyan
Write-Host ''
Write-Host '  1. 检查右下角任务栏是否有 Ollama 图标（羊驼）' -ForegroundColor White
Write-Host '     没有 → 开始菜单搜索 Ollama 并启动' -ForegroundColor Yellow
Write-Host ''
Write-Host '  2. 打开 PowerShell，输入：ollama list' -ForegroundColor White
Write-Host '     看到 qwen2.5-coder:7b → 模型正常' -ForegroundColor Yellow
Write-Host '     看不到 → 运行 download-models.py 重新下载' -ForegroundColor Yellow
Write-Host ''
Write-Host '  3. 在 Continue 面板右下角，确认选择了 qwen-local' -ForegroundColor White
Write-Host '     没有 → 按 Ctrl+Shift+P →' -ForegroundColor White
Write-Host '     Continue: Select Model → 选择 qwen-local' -ForegroundColor Yellow
Write-Host ''
Write-Host '  4. 如果仍不工作，重启 VS Code 再试' -ForegroundColor White
Write-Host ''
Write-Host '════════════════════════════════════════════════════════' -ForegroundColor Green
Write-Host ''
Write-Host '按任意键退出...' -ForegroundColor Cyan
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
exit 0