<# FlashTap: Ollama 安装与配置 #>

$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 禁用控制台快速编辑模式，防止鼠标误点导致下载卡死
# 保留复制粘贴和右键功能，只禁用"点击暂停输出"这个行为
Add-Type -Name ConsoleUtil -Namespace Win32 -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@
$handle = [Win32.ConsoleUtil]::GetStdHandle(-10)
$mode = 0
[Win32.ConsoleUtil]::GetConsoleMode($handle, [ref]$mode) | Out-Null
$ENABLE_QUICK_EDIT = 0x0040
[Win32.ConsoleUtil]::SetConsoleMode($handle, $mode -band (-bnot $ENABLE_QUICK_EDIT)) | Out-Null

# 自动继承系统代理设置（不用管理员模式也能走国际网络）
$proxy = [System.Net.WebRequest]::GetSystemWebProxy()
$proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
[System.Net.WebRequest]::DefaultWebProxy = $proxy

# ── 脚本目录检测 ──
$PROJECT_DIR = $PSScriptRoot
if ((-not $PROJECT_DIR) -or ($PROJECT_DIR -eq '')) {
    $PROJECT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if ((-not $PROJECT_DIR) -or ($PROJECT_DIR -eq '')) {
    $PROJECT_DIR = (Get-Location).Path
}
$LOG_FILE = Join-Path $PROJECT_DIR 'install.log'

# ── OllamaSetup.exe 下载地址（发布 Release 后填入实际 URL） ──
$OLLAMA_DOWNLOAD_URL = 'https://ollama.com/download/OllamaSetup.exe'
$OLLAMA_DOWNLOAD_MIRRORS = @(
    'https://github.com/ollama/ollama/releases/latest/download/OllamaSetup.exe',
    'https://ghproxy.net/https://github.com/ollama/ollama/releases/latest/download/OllamaSetup.exe'
)

# ── 日志函数 ──
function Write-Log {
    param([string]$Message, [string]$Color = 'White')
    $ts = Get-Date -Format 'HH:mm:ss'
    $line = "[$ts] $Message"
    Write-Host "  $line" -ForegroundColor $Color
    try { Add-Content -Path $LOG_FILE -Value $line -ErrorAction SilentlyContinue } catch { }
}

# ── 终极杀Ollama全部进程（PID + 通配符 + taskkill 三管齐下） ──
function Kill-AllOllama {
    param([System.Diagnostics.Process]$Process = $null)

    # 1) 直接杀传入的进程对象（最可靠，不依赖进程名）
    if ($Process) {
        try {
            if (-not $Process.HasExited) {
                $Process.Kill()
            }
        } catch { }
    }

    # 2) 通配符匹配杀所有 Ollama 相关进程
    Get-Process -Name '*Ollama*' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-Process -Name '*ollama*' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    # 3) taskkill 杀进程树（/t 杀所有子进程，/f 强制）
    try {
        $null = cmd /c 'taskkill /f /im OllamaSetup.exe /t 2>nul'
        $null = cmd /c 'taskkill /f /im ollama.exe /t 2>nul'
        $null = cmd /c 'taskkill /f /im "ollama app.exe" /t 2>nul'
    } catch { }
}

# ── 有效可执行文件校验 ──
function Test-ValidExe {
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        $fi = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($fi.Length -lt 1024) { return $false }
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -lt 2) { return $false }
        # PE文件头校验 (MZ)
        return ($bytes[0] -eq 0x4D -and $bytes[1] -eq 0x5A)
    }
    catch { return $false }
}

# ── 本地安装程序检测（仅检查同目录） ──
function Get-Ollama-Local-Installer {

    $installer = Join-Path $PROJECT_DIR 'OllamaSetup.exe'

    if ((Test-Path -LiteralPath $installer) -and (Test-ValidExe -Path $installer)) {
        Write-Log '  [信息] 同目录下找到 OllamaSetup.exe，使用本地版本'
        return $installer
    }

    # 本地没有，从网络下载
    Write-Log '  [信息] 同目录未找到 OllamaSetup.exe'
    if ($OLLAMA_DOWNLOAD_URL -and ($OLLAMA_DOWNLOAD_URL -notmatch 'USER/REPO')) {
        Write-Log '  [信息] 正在自动下载 OllamaSetup.exe（约 1.4GB）...'

        $downloadOk = $false
        $urls = @($OLLAMA_DOWNLOAD_MIRRORS) + @($OLLAMA_DOWNLOAD_URL)

        foreach ($url in $urls) {
            if ($downloadOk) { break }
            Write-Log "  [信息] 尝试: $url"
            try {
                Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
                $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop

                if ((Test-Path -LiteralPath $installer) -and (Test-ValidExe -Path $installer)) {
                    $sizeMB = [math]::Round((Get-Item $installer).Length / 1MB, 1)
                    Write-Log "  [成功] OllamaSetup.exe 下载完成 (${sizeMB}MB)"
                    $downloadOk = $true
                    return $installer
                }
            } catch {
                Write-Log "  [警告] 下载失败: $($_.Exception.Message)"
                Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Write-Log '  [错误] 未能获取 OllamaSetup.exe'
    Write-Log '  [信息] 请将 OllamaSetup.exe 放在脚本同目录，或配置正确的下载地址'
    throw '未找到 OllamaSetup.exe，请将安装包与脚本放在同一文件夹'
}

# ── 运行安装程序 ──
function Install-Ollama-From-Exe {
    param([string]$InstallerPath)

    if (-not (Test-Path -LiteralPath $InstallerPath) -or -not (Test-ValidExe -Path $InstallerPath)) {
        throw '安装程序文件不存在或损坏'
    }

    Write-Log '  [信息] 正在静默安装 Ollama...'
    Kill-AllOllama

    $installProcess = Start-Process -FilePath $InstallerPath -ArgumentList '/verysilent /norestart /suppressmsgboxes' -PassThru
    if (-not $installProcess) {
        throw '无法启动Ollama安装程序，请检查安装包是否完整'
    }

    # 等待安装完成，只杀自动启动的 ollama app，不杀安装程序本身
    $maxWaitSeconds = 300
    $waited = 0
    while ($waited -lt $maxWaitSeconds) {
        if ($installProcess.HasExited) { break }
        # 只杀 ollama 辅助进程，不杀安装程序 OllamaSetup.exe
        Get-Process -Name 'ollama' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Get-Process -Name 'ollama app' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        $waited += 2
    }

    if (-not $installProcess.HasExited) {
        Write-Log "  [警告] 安装程序 ${maxWaitSeconds}秒 后仍未退出，强制终止..."
        $installProcess.Kill()
    }

    # 安装完成后杀掉 ollama 后台进程，但不再杀安装程序
    Start-Sleep -Seconds 2
    Get-Process -Name 'ollama' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-Process -Name 'ollama app' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    Write-Log '  [成功] Ollama 安装完成'

    # 验证安装
    $checkPaths = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'),
        (Join-Path ${env:ProgramFiles} 'Ollama\ollama.exe'),
        (Join-Path ([Environment]::GetEnvironmentVariable("ProgramFiles(x86)")) 'Ollama\ollama.exe')
    )

    foreach ($cp in $checkPaths) {
        if (Test-Path -LiteralPath $cp) {
            Write-Log ("  [成功] 找到: $cp")
            return
        }
    }

    # PATH中查找
    try {
        $found = Get-Command ollama.exe -ErrorAction SilentlyContinue
        if ($found) {
            Write-Log ("  [成功] 在PATH中找到: $($found.Source)")
            return
        }
    }
    catch { }

    throw '安装后未找到ollama.exe，安装可能失败'
}

# ── 安装Ollama（总控） ──
function Install-Ollama {

    # 纯存在性检测：只要 ollama.exe 存在于已知路径，即视为已安装，跳过
    $checkPaths = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'),
        (Join-Path ${env:ProgramFiles} 'Ollama\ollama.exe'),
        (Join-Path ([Environment]::GetEnvironmentVariable("ProgramFiles(x86)")) 'Ollama\ollama.exe')
    )

    foreach ($cp in $checkPaths) {
        if (Test-Path -LiteralPath $cp) {
            Write-Log "  [信息] 找到 Ollama: $cp，跳过安装"
            return
        }
    }

    # PATH 中查找
    try {
        $found = Get-Command ollama.exe -ErrorAction SilentlyContinue
        if ($found) {
            Write-Log "  [信息] 在 PATH 中找到 Ollama: $($found.Source)，跳过安装"
            return
        }
    }
    catch { }

    Write-Log '[信息] 开始安装 Ollama...'

    # 本地安装程序检测（同目录优先 → 抛错退出）
    $installerPath = Get-Ollama-Local-Installer

    # 安装
    Install-Ollama-From-Exe -InstallerPath $installerPath

    # 简单验证：确认 ollama.exe 存在
    $ollamaExe = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
    if (Test-Path -LiteralPath $ollamaExe) {
        Write-Log '[成功] Ollama 安装完成'
    } else {
        throw 'Ollama 安装后未找到可执行文件，安装可能失败'
    }
}

# ── 配置环境变量 ──
function Configure-Ollama {

    $envTarget = [EnvironmentVariableTarget]::User

    Write-Log '  [信息] 正在配置 Ollama 环境变量...'

    try {
        [Environment]::SetEnvironmentVariable('OLLAMA_HOST', '127.0.0.1:11434', $envTarget)
        [Environment]::SetEnvironmentVariable('OLLAMA_ORIGINS', '*', $envTarget)
        [Environment]::SetEnvironmentVariable('OLLAMA_MAX_VRAM', '6', $envTarget)
        [Environment]::SetEnvironmentVariable('OLLAMA_NUM_PARALLEL', '2', $envTarget)
        Write-Log '  [成功] 环境变量已设置'
    }
    catch {
        Write-Log "  [警告] 环境变量设置失败: $($_.Exception.Message)"
    }

    # 模型目录

    # 智能选择模型目录：D盘可用则用D盘，否则用用户目录
    $modelsDir = $null
    $preferredDirs = @(
        'D:\ollama_models',
        [System.IO.Path]::Combine($env:USERPROFILE, '.ollama\models'),
        [System.IO.Path]::Combine($env:LOCALAPPDATA, 'ollama\models')
    )
    foreach ($dir in $preferredDirs) {
        try {
            $parent = Split-Path -Parent $dir
            if (Test-Path -LiteralPath $parent) {
                $modelsDir = $dir
                break
            }
        } catch {}
    }
    if (-not $modelsDir) {
        $modelsDir = [System.IO.Path]::Combine($env:USERPROFILE, '.ollama\models')
    }

    Write-Log "  [信息] 模型目录: $modelsDir"

    try {
        if (-not (Test-Path -LiteralPath $modelsDir)) {
            New-Item -ItemType Directory -Path $modelsDir -Force -ErrorAction Stop | Out-Null
            Write-Log '  [成功] 模型目录已创建'
        }
        else {
            Write-Log '  [信息] 模型目录已存在'
        }
        [Environment]::SetEnvironmentVariable('OLLAMA_MODELS', $modelsDir, $envTarget)
        Write-Log "  [成功] OLLAMA_MODELS = $modelsDir"
    }
    catch {
        Write-Log "  [警告] 无法创建模型目录: $($_.Exception.Message)"
        Write-Log "  [警告] Ollama 将使用默认模型目录" 'Yellow'
    }
}

# ── 启动Ollama服务 ──
function Start-Ollama {

    # 查找ollama.exe
    $ollamaExe = $null
    $searchPaths = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'),
        (Join-Path ${env:ProgramFiles} 'Ollama\ollama.exe'),
        (Join-Path ([Environment]::GetEnvironmentVariable("ProgramFiles(x86)")) 'Ollama\ollama.exe')
    )
    foreach ($p in $searchPaths) {
        if (Test-Path -LiteralPath $p) { $ollamaExe = $p; break }
    }
    if (-not $ollamaExe) {
        try { $ollamaExe = (Get-Command ollama.exe -ErrorAction Stop).Source } catch { }
    }
    if (-not $ollamaExe) {
        Write-Log '  [警告] 未找到ollama.exe，无法启动服务'
        return
    }

    Write-Log ("  [信息] 使用: $ollamaExe")

    # 快速检查是否已在运行（使用独立进程，不共享控制台，绝不阻塞）
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $ollamaExe
        $psi.Arguments = 'list'
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $checkProc = [System.Diagnostics.Process]::Start($psi)
        if ($checkProc) {
            $checkProc.WaitForExit(10000) | Out-Null
            $checkStdout = $checkProc.StandardOutput.ReadToEnd()
            $checkStderr = $checkProc.StandardError.ReadToEnd()
            if ($checkProc.ExitCode -eq 0) {
                Write-Log '  [成功] Ollama服务已在运行'
                return
            }
        }
    }
    catch { }

    # 尝试Windows服务
    try {
        $svc = Get-Service -Name 'ollama' -ErrorAction SilentlyContinue
        if ($svc) {
            if ($svc.Status -ne 'Running') {
                Write-Log '  [信息] 正在启动 Ollama Windows 服务...'
                Start-Service -Name 'ollama' -ErrorAction Stop
                Write-Log '  [成功] Windows服务已启动'
                return
            }
            Write-Log '  [成功] Windows服务已在运行'
            return
        }
    }
    catch {
        Write-Log "  [警告] Windows服务启动失败: $($_.Exception.Message)"
    }

    # 后台启动（UseShellExecute=$true 确保进程独立，不受父进程退出影响）
    Kill-AllOllama
    Write-Log '  [信息] 正在后台启动 Ollama（独立进程）...'
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $ollamaExe
        $psi.Arguments = 'serve'
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.UseShellExecute = $true
        $ollamaProc = [System.Diagnostics.Process]::Start($psi)
        if ($ollamaProc) {
            Write-Log "  [信息] Ollama serve 已启动（PID: $($ollamaProc.Id)）"
        }
        Start-Sleep -Seconds 5
        Write-Log '  [信息] 服务启动完成，后续步骤将自动验证'
    }
    catch {
        Write-Log "  [警告] 后台启动失败: $($_.Exception.Message)"
    }
}

# ── 主函数 ──
function Main {
    [Console]::TreatControlCAsInput = $false
    $env:OLLAMA_HOST = '127.0.0.1:11434'

    try {
        Install-Ollama
    }
    catch {
        Write-Log ('[错误] ' + $_.Exception.Message)
        Write-Host ''
        Write-Host '  *** 如需反馈此错误，请复制上方包含[错误]的那一行 ***'
        Write-Host ''
        exit 1
    }

    try {
        Configure-Ollama
    }
    catch {
        Write-Log ('[警告] ' + $_.Exception.Message)
    }

    try {
        Start-Ollama
    }
    catch {
        Write-Log ('[警告] ' + $_.Exception.Message)
    }

    Write-Host '  [成功] Ollama 安装完成，继续后续步骤...' -ForegroundColor Green
}

Main
exit 0