<# FlashTap: Ollama 安装与配置 #>

$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 自动继承系统代理设置（不用管理员模式也能走国际网络）
$proxy = [System.Net.WebRequest]::GetSystemWebProxy()
$proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
[System.Net.WebRequest]::DefaultWebProxy = $proxy

# ── 脚本目录检测（必须最先执行，后续依赖 PROJECT_DIR） ──
$PROJECT_DIR = $PSScriptRoot
if ((-not $PROJECT_DIR) -or ($PROJECT_DIR -eq '')) {
    $PROJECT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if ((-not $PROJECT_DIR) -or ($PROJECT_DIR -eq '')) {
    $PROJECT_DIR = (Get-Location).Path
}
$LOG_FILE = Join-Path $PROJECT_DIR 'install.log'

# 从文件读取目标用户信息（Start-Process 子进程无法可靠继承环境变量）
# 必须放脚本目录，不要放 %TEMP%——提权后 TEMP 指向不同用户，读不到！
$envFile = Join-Path $PROJECT_DIR '.flashtap-env.txt'
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        $key, $value = $_ -split '=', 2
        if ($key -and $value) { Set-Item "env:$key" $value }
    }
    $OriginalUserProfile = $env:FLASHTAP_ORIGINAL_PROFILE
    $OriginalUsername = $env:FLASHTAP_ORIGINAL_USER
} else {
    $OriginalUserProfile = $null
    $OriginalUsername = $null
}

if ($OriginalUsername -and $OriginalUsername -ne $env:USERNAME) {
    $env:USERNAME = $OriginalUsername
    $env:USERPROFILE = $OriginalUserProfile
    $env:LOCALAPPDATA = Join-Path $OriginalUserProfile 'AppData\Local'
    $env:APPDATA = Join-Path $OriginalUserProfile 'AppData\Roaming'
    $env:HOMEPATH = "\Users\$OriginalUsername"
    $env:HOMEDRIVE = ($OriginalUserProfile -split ':')[0] + ':'
}

# ── OllamaSetup.exe 下载地址（发布 Release 后填入实际 URL） ──
$OLLAMA_DOWNLOAD_URL = 'https://ollama.com/download/OllamaSetup.exe'
$OLLAMA_DOWNLOAD_MIRRORS = @(
    'https://gh.con.sh/https://github.com/ollama/ollama/releases/latest/download/OllamaSetup.exe',
    'https://ollama.com/download/OllamaSetup.exe',
    'https://github.com/ollama/ollama/releases/latest/download/OllamaSetup.exe',
    'https://ghproxy.net/https://github.com/ollama/ollama/releases/latest/download/OllamaSetup.exe',
    'https://mirror.ghproxy.com/https://github.com/ollama/ollama/releases/latest/download/OllamaSetup.exe',
    'https://ghp.ci/https://github.com/ollama/ollama/releases/latest/download/OllamaSetup.exe'
)

# ── 日志函数 ──
function Write-Log {
    param([string]$Message, [string]$Color = 'White')
    $ts = Get-Date -Format 'HH:mm:ss'
    $line = "[$ts] $Message"
    Write-Host "  $line" -ForegroundColor $Color
    try { Add-Content -Path $LOG_FILE -Value $line -ErrorAction SilentlyContinue } catch { }
}

# ── 环境诊断 ──
function Write-Diagnostic {
    Write-Log '────────── 环境诊断 ──────────'

    # 管理员权限
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')
    Write-Log "  [诊断] 管理员权限: $(if ($isAdmin) { '是' } else { '否' })"

    # PowerShell 版本
    Write-Log "  [诊断] PowerShell: $($PSVersionTable.PSVersion)"

    # 系统代理
    $sysProxy = [System.Net.WebRequest]::GetSystemWebProxy()
    $proxyUri = $sysProxy.GetProxy('https://github.com')
    Write-Log "  [诊断] 系统代理: $(if ($proxyUri -ne 'https://github.com') { $proxyUri } else { '无' })"

    # DNS 解析
    try {
        $ips = [System.Net.Dns]::GetHostAddresses('github.com')
        Write-Log "  [诊断] DNS(github.com): $($ips[0])"
    } catch {
        Write-Log '  [诊断] DNS(github.com): 解析失败' -Color 'Red'
    }

    # 网络连通性
    try {
        $r = Invoke-WebRequest -Uri 'https://github.com' -Method Head -TimeoutSec 5 -UseBasicParsing
        Write-Log "  [诊断] 直连 GitHub: 通 (HTTP $($r.StatusCode))"
    } catch {
        Write-Log "  [诊断] 直连 GitHub: 不通" -Color 'Yellow'
    }

    try {
        $r = Invoke-WebRequest -Uri 'https://ghproxy.net' -Method Head -TimeoutSec 5 -UseBasicParsing
        Write-Log "  [诊断] ghproxy.net: 通 (HTTP $($r.StatusCode))"
    } catch {
        Write-Log "  [诊断] ghproxy.net: 不通" -Color 'Yellow'
    }

    # 磁盘空间
    try {
        $drive = (Get-Location).Drive.Name
        $free = (Get-PSDrive $drive).Free
        $freeGB = [math]::Round($free / 1GB, 1)
        Write-Log "  [诊断] 磁盘剩余: ${freeGB}GB"
        if ($free -lt 5GB) {
            Write-Log "  [诊断] 磁盘空间不足 (不足5GB)，可能安装失败" -Color 'Red'
        }
    } catch { }

    # 已安装的 Ollama
    $ollamaFound = Get-Command ollama.exe -ErrorAction SilentlyContinue
    if ($ollamaFound) {
        Write-Log "  [诊断] 已安装 Ollama: $($ollamaFound.Source)"
    } else {
        Write-Log '  [诊断] 未安装 Ollama'
    }

    Write-Log '──────────────────────────────'
}

# ── 终极杀Ollama全部进程（PID + 进程名 + taskkill 三管齐下） ──
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

    # 2) 精确匹配杀 Ollama 运行时进程（不杀安装程序 OllamaSetup.exe）
    Get-Process -Name 'ollama' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-Process -Name 'ollama app' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    # 3) taskkill 杀进程树（/t 杀所有子进程，/f 强制）
    try {
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
        # 大小校验：完整 OllamaSetup.exe 约 1.4GB，低于 1.3GB 视为下载不完整
        $minSize = 1300 * 1MB
        if ($fi.Length -lt $minSize) {
            Write-Log "  [警告] OllamaSetup.exe 大小 $([math]::Round($fi.Length/1MB,0))MB，低于 1300MB，可能下载不完整，删除重下" -Color 'Yellow'
            Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
            return $false
        }
        # PE文件头校验 (MZ) — 只读前2字节，避免加载1.4GB到内存
        $bytes = New-Object byte[] 2
        $fs = [System.IO.File]::OpenRead($Path)
        $read = $fs.Read($bytes, 0, 2)
        $fs.Close()
        if ($read -lt 2) { return $false }
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

                $req = [System.Net.HttpWebRequest]::Create($url)
                $req.Timeout = 30000
                $req.ReadWriteTimeout = 30000
                $req.AllowAutoRedirect = $true
                $resp = $req.GetResponse()
                $totalBytes = $resp.ContentLength
                $respStream = $resp.GetResponseStream()
                $fs = [System.IO.File]::Create($installer)
                $buffer = New-Object byte[] 65536
                $downloaded = 0L
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                $totalSw = [System.Diagnostics.Stopwatch]::StartNew()
                $lastRead = Get-Date

                while (($read = $respStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $fs.Write($buffer, 0, $read)
                    $downloaded += $read
                    $lastRead = Get-Date
                    if ($sw.ElapsedMilliseconds -ge 200) {
                        $pct = if ($totalBytes -gt 0) { [math]::Round($downloaded * 100 / $totalBytes) } else { 0 }
                        $speed = if ($totalSw.Elapsed.TotalSeconds -gt 0) { [math]::Round($downloaded / 1MB / $totalSw.Elapsed.TotalSeconds, 1) } else { 0 }
                        $barLen = 30
                        $filled = [math]::Max(0, [math]::Round($pct * $barLen / 100))
                        $empty = $barLen - $filled
                        $bar = '[' + ('#' * $filled) + ('-' * $empty) + ']'
                        $downMB = [math]::Round($downloaded / 1MB, 1)
                        $totalMB = if ($totalBytes -gt 0) { [math]::Round($totalBytes / 1MB, 1) } else { '?' }
                        $eta = if ($speed -gt 0 -and $totalBytes -gt 0) {
                            [math]::Round(($totalBytes - $downloaded) / 1MB / $speed / 60, 1)
                        } else { '?' }
                        Write-Host "`r  $bar $pct%  $downMB/$totalMB MB  ${speed}MB/s  剩余${eta}min  " -NoNewline
                        $sw.Restart()
                    }
                    # 超过 60 秒没收到数据，视为卡死，放弃此源
                    if (((Get-Date) - $lastRead).TotalSeconds -gt 60) {
                        throw '下载卡死，60秒无数据'
                    }
                }
                $fs.Close()
                $respStream.Close()
                $resp.Close()
                Write-Host ''  # 换行

                if ((Test-Path -LiteralPath $installer) -and (Test-ValidExe -Path $installer)) {
                    $sizeMB = [math]::Round((Get-Item $installer).Length / 1MB, 1)
                    Write-Log "  [成功] OllamaSetup.exe 下载完成 (${sizeMB}MB)"
                    $downloadOk = $true
                    return $installer
                }
            } catch {
                Write-Host ''
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

    $installStart = Get-Date

    $installProcess = Start-Process -FilePath $InstallerPath -ArgumentList '/verysilent /norestart /suppressmsgboxes' -PassThru
    if (-not $installProcess) {
        throw '无法启动Ollama安装程序，请检查安装包是否完整'
    }

    # 等待安装完成
    $maxWaitSeconds = 300
    $waited = 0
    while ($waited -lt $maxWaitSeconds) {
        if ($installProcess.HasExited) { break }
        Start-Sleep -Seconds 2
        $waited += 2
    }

    if (-not $installProcess.HasExited) {
        Write-Log "  [警告] 安装程序 ${maxWaitSeconds}秒 后仍未退出，强制终止 (PID: $($installProcess.Id))..."
        Kill-AllOllama -Process $installProcess
    }

    # 安装完成后彻底杀掉所有 Ollama 进程（包括自动启动的 GUI 托盘程序）
    Kill-AllOllama -Process $installProcess
    Start-Sleep -Seconds 2
    Kill-AllOllama

    $elapsed = [math]::Round(((Get-Date) - $installStart).TotalSeconds, 0)
    $exitCode = $installProcess.ExitCode
    Write-Log "  [信息] 安装程序退出，耗时 ${elapsed}秒，退出码: $exitCode"

    if ($elapsed -lt 5) {
        Write-Log "  [警告] 安装程序退出过快（${elapsed}秒），可能安装失败" -Color 'Yellow'
    }

    if ($exitCode -ne 0) {
        Write-Log "  [错误] 安装程序返回非零退出码: $exitCode" -Color 'Red'
    }

    Write-Log '  [信息] 正在验证安装...'

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

    # 先跑环境诊断
    Write-Diagnostic

    # 纯存在性检测：只认当前用户目录下的 Ollama，不认其他用户的
    Write-Log "  [调试] 当前 USERPROFILE=$env:USERPROFILE, USERNAME=$env:USERNAME"
    $checkPaths = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'),
        (Join-Path ${env:ProgramFiles} 'Ollama\ollama.exe'),
        (Join-Path ([Environment]::GetEnvironmentVariable("ProgramFiles(x86)")) 'Ollama\ollama.exe')
    )

    foreach ($cp in $checkPaths) {
        if (Test-Path -LiteralPath $cp) {
            # 只认当前用户目录下的，其他用户的跳过
            if ($cp -like "$env:USERPROFILE*") {
                Write-Log "  [信息] 找到当前用户的 Ollama: $cp，跳过安装"
                return
            } else {
                Write-Log "  [信息] 跳过非当前用户的 Ollama: $cp"
            }
        }
    }

    # PATH 中查找（也过滤非当前用户目录的）
    try {
        $found = Get-Command ollama.exe -ErrorAction SilentlyContinue
        if ($found) {
            if ($found.Source -like "$env:USERPROFILE*") {
                Write-Log "  [信息] 在 PATH 中找到当前用户的 Ollama: $($found.Source)，跳过安装"
                return
            } else {
                Write-Log "  [信息] 跳过非当前用户的 PATH Ollama: $($found.Source)"
            }
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
        [Environment]::SetEnvironmentVariable('OLLAMA_MAX_VRAM', '6144', $envTarget)
        [Environment]::SetEnvironmentVariable('OLLAMA_NUM_PARALLEL', '2', $envTarget)
        Write-Log '  [成功] 环境变量已设置'
    }
    catch {
        Write-Log "  [警告] 环境变量设置失败: $($_.Exception.Message)"
    }

    # 模型目录

    # 智能选择模型目录：D盘可用则用D盘，否则用用户目录
    # 增加驱动器存在性检查、中文用户名检测、多重兜底机制（与 download-models.py 保持一致）
    $modelsDir = $null

    # 优先尝试 D 盘（虚拟机可能没有 D 盘）
    $dDrivePath = 'D:\ollama_models'
    if (Test-Path 'D:\') {
        try {
            $null = New-Item -ItemType Directory -Path $dDrivePath -Force -ErrorAction Stop
            # 验证目录是否真的可写
            $testFile = Join-Path $dDrivePath '.write_test'
            Set-Content -Path $testFile -Value 'test' -ErrorAction Stop
            Remove-Item -Path $testFile -Force -ErrorAction SilentlyContinue
            $modelsDir = $dDrivePath
            Write-Log "  [成功] 模型目录已创建: $dDrivePath (D盘)"
        } catch {
            Write-Log "  [信息] D盘不可用或无法写入: $($_.Exception.Message)"
        }
    } else {
        Write-Log '  [信息] D盘驱动器不存在，跳过'
    }

    # 兜底：使用用户目录（确保路径无中文）
    if (-not $modelsDir) {
        $userModelsPath = [System.IO.Path]::Combine($env:USERPROFILE, '.ollama\models')
        # 检查用户名是否包含中文
        $username = Split-Path -Leaf $env:USERPROFILE
        $hasChinese = $username -match '[\u4e00-\u9fff]'

        if ($hasChinese) {
            # 中文用户名，使用 C 盘根目录下的无中文路径
            Write-Log '  [信息] 检测到中文用户名，使用 C 盘无中文路径'
            $modelsDir = 'C:\ollama_models'
        } else {
            $modelsDir = $userModelsPath
        }

        try {
            $null = New-Item -ItemType Directory -Path $modelsDir -Force -ErrorAction Stop
            # 验证目录是否真的可写
            $testFile = Join-Path $modelsDir '.write_test'
            Set-Content -Path $testFile -Value 'test' -ErrorAction Stop
            Remove-Item -Path $testFile -Force -ErrorAction SilentlyContinue
            Write-Log "  [成功] 模型目录已创建: $modelsDir"
        } catch {
            # 最后兜底：使用临时目录
            Write-Log "  [警告] 无法创建默认模型目录: $($_.Exception.Message)"
            $tempPath = [System.IO.Path]::Combine($env:TEMP, 'ollama_models')
            try {
                $null = New-Item -ItemType Directory -Path $tempPath -Force -ErrorAction Stop
                $modelsDir = $tempPath
                Write-Log "  [成功] 使用临时目录: $tempPath"
            } catch {
                Write-Log "  [错误] 无法创建任何模型目录，Ollama 将使用默认路径"
            }
        }
    }

    Write-Log "  [信息] 模型目录: $modelsDir"

    try {
        [Environment]::SetEnvironmentVariable('OLLAMA_MODELS', $modelsDir, $envTarget)
        Write-Log "  [成功] OLLAMA_MODELS = $modelsDir"
    }
    catch {
        Write-Log "  [警告] 无法设置 OLLAMA_MODELS: $($_.Exception.Message)"
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

    # 快速检查是否已在运行（用 Job 实现超时，避免 ReadToEnd 死锁）
    Write-Log '  [信息] 检查 Ollama 是否已在运行...'
    $alreadyRunning = $false
    try {
        $checkJob = Start-Job -ScriptBlock {
            param($exe)
            & $exe list 2>&1 | Out-Null
            return $LASTEXITCODE
        } -ArgumentList $ollamaExe

        $completed = Wait-Job $checkJob -Timeout 5
        if ($completed) {
            $result = Receive-Job $checkJob
            if ($result -eq 0) {
                $alreadyRunning = $true
                Write-Log '  [成功] Ollama服务已在运行'
            }
        } else {
            Write-Log '  [信息] ollama list 超时，假设未运行'
        }
        Remove-Job $checkJob -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Log '  [信息] 检查失败，继续启动'
    }

    if ($alreadyRunning) { return }

    # 后台启动（UseShellExecute=$true 独立进程，不阻塞当前脚本）
    Kill-AllOllama
    Write-Log '  [信息] 正在后台启动 Ollama serve...'
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $ollamaExe
        $psi.Arguments = 'serve'
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.UseShellExecute = $true
        $ollamaProc = [System.Diagnostics.Process]::Start($psi)
        if ($ollamaProc) {
            Write-Log "  [信息] Ollama serve 已启动（PID: $($ollamaProc.Id)），不等待初始化完成"
        } else {
            Write-Log '  [警告] 启动 ollama serve 返回空'
        }
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