<# FlashTap: Ollama 安装与配置 #>

$ErrorActionPreference = 'Continue'

Write-Host '  [启动] Ollama 安装脚本正在初始化...' -ForegroundColor Cyan

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

try {
    $proxy = [System.Net.WebRequest]::GetSystemWebProxy()
    $proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
    [System.Net.WebRequest]::DefaultWebProxy = $proxy
} catch {
    Write-Host '  [信息] 代理检测跳过（虚拟机环境可能不支持）' -ForegroundColor DarkGray
}

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
    Get-Content $envFile -Encoding UTF8 | ForEach-Object {
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
    $script:diagStart = [System.Diagnostics.Stopwatch]::StartNew()

    # 管理员权限
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')
    Write-Log "  [诊断] 管理员权限: $(if ($isAdmin) { '是' } else { '否' })"

    # PowerShell 版本
    Write-Log "  [诊断] PowerShell: $($PSVersionTable.PSVersion)"

    # 系统代理（用 Register-WaitEvent 带超时，普通电脑秒过，卡住最多等 5 秒）
    try {
        $proxyResult = $null
        $proxyJob = Start-Job -ScriptBlock {
            try {
                $p = [System.Net.WebRequest]::GetSystemWebProxy()
                return $p.GetProxy('https://github.com').ToString()
            } catch { return 'FAIL' }
        }
        $proxyDone = Wait-Job $proxyJob -Timeout 5
        if ($proxyDone) {
            $proxyResult = Receive-Job $proxyJob
            Remove-Job $proxyJob -Force -ErrorAction SilentlyContinue
            if ($proxyResult -and $proxyResult -ne 'https://github.com/' -and $proxyResult -ne 'FAIL') {
                Write-Log "  [诊断] 系统代理: $proxyResult"
            } else {
                Write-Log '  [诊断] 系统代理: 无'
            }
        } else {
            Stop-Job $proxyJob -Force -ErrorAction SilentlyContinue
            Remove-Job $proxyJob -Force -ErrorAction SilentlyContinue
            Write-Log '  [诊断] 系统代理: 检测超时（跳过）' 'Yellow'
        }
    } catch {
        Write-Log '  [诊断] 系统代理: 检测失败（跳过）' 'Yellow'
    }

    # DNS 解析（用 Start-Job 带超时，普通电脑秒过，卡住最多等 8 秒）
    try {
        $dnsJob = Start-Job -ScriptBlock {
            param($h)
            try {
                return [System.Net.Dns]::GetHostAddresses($h)[0].ToString()
            } catch { return 'FAIL' }
        } -ArgumentList 'github.com'
        $dnsDone = Wait-Job $dnsJob -Timeout 8
        if ($dnsDone) {
            $dnsResult = Receive-Job $dnsJob
            Remove-Job $dnsJob -Force -ErrorAction SilentlyContinue
            if ($dnsResult -and $dnsResult -ne 'FAIL') {
                Write-Log "  [诊断] DNS(github.com): $dnsResult"
            } else {
                Write-Log '  [诊断] DNS(github.com): 解析失败' 'Red'
            }
        } else {
            Stop-Job $dnsJob -Force -ErrorAction SilentlyContinue
            Remove-Job $dnsJob -Force -ErrorAction SilentlyContinue
            Write-Log '  [诊断] DNS(github.com): 解析超时（跳过）' 'Yellow'
        }
    } catch {
        Write-Log '  [诊断] DNS(github.com): 检测异常（跳过）' 'Yellow'
    }

    # 网络连通性（用 Test-UrlQuick 带真正可靠的超时，避免 Invoke-WebRequest 超时失效卡死）
    $code = Test-UrlQuick -Url 'https://github.com' -TimeoutSec 5
    if ($code -gt 0) {
        Write-Log "  [诊断] 直连 GitHub: 通 (HTTP $code)"
    } else {
        Write-Log "  [诊断] 直连 GitHub: 不通" 'Yellow'
    }

    $code = Test-UrlQuick -Url 'https://ghproxy.net' -TimeoutSec 5
    if ($code -gt 0) {
        Write-Log "  [诊断] ghproxy.net: 通 (HTTP $code)"
    } else {
        Write-Log "  [诊断] ghproxy.net: 不通" 'Yellow'
    }

    # 磁盘空间（检查所有可用盘符，警告低磁盘）
    try {
        $drives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue
        foreach ($drv in $drives) {
            if (-not $drv.Free) { continue }
            $freeGB = [math]::Round($drv.Free / 1GB, 1)
            $drvName = "$($drv.Name):"
            if ($freeGB -lt 5GB / 1GB) {
                Write-Log "  [诊断] ${drvName} 剩余 ${freeGB}GB（不足 5GB，可能安装失败）" 'Red'
            } else {
                Write-Log "  [诊断] ${drvName} 剩余 ${freeGB}GB"
            }
        }
        # 单独检查系统盘（Ollama + VS Code 安装位置）
        $sysDrive = $env:SystemDrive
        if ($sysDrive) {
            $sysFree = (Get-PSDrive -Name $sysDrive[0] -ErrorAction SilentlyContinue).Free
            if ($sysFree) {
                $sysFreeGB = [math]::Round($sysFree / 1GB, 1)
                if ($sysFree -lt 8GB) {
                    Write-Log "  [诊断] 系统盘 ${sysDrive} 空间不足 8GB（当前 ${sysFreeGB}GB），模型+Ollama 可能装不下" 'Red'
                }
            }
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

# ── 辅助函数：带超时的网络请求（避免 Invoke-WebRequest 超时失效导致卡死） ──
function Test-UrlQuick {
    param([string]$Url, [int]$TimeoutSec = 8)
    $job = Start-Job -ScriptBlock {
        param($u, $envPath, $timeoutMs)
        $env:Path = $envPath
        try {
            $req = [System.Net.HttpWebRequest]::Create($u)
            $req.Timeout = $timeoutMs
            $req.Method = 'HEAD'
            $req.AllowAutoRedirect = $true
            $resp = $req.GetResponse()
            $code = [int]$resp.StatusCode
            $resp.Close()
            return $code
        } catch {
            return 0
        }
    } -ArgumentList $Url, $env:Path, ($TimeoutSec * 1000)

    $completed = Wait-Job $job -Timeout ($TimeoutSec + 2)
    $result = 0
    if ($completed) {
        $result = Receive-Job $job
    } else {
        Stop-Job $job -Force
    }
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    return $result
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
        $urlCount = (@($OLLAMA_DOWNLOAD_MIRRORS) + @($OLLAMA_DOWNLOAD_URL)).Count
        Write-Log "  [信息] 将尝试 ${urlCount} 个镜像源下载 OllamaSetup.exe（约 1.4GB）"
        Write-Log '  [信息] 下载可能需要 5-30 分钟，取决于网络速度'

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

    $installerSize = [math]::Round((Get-Item $InstallerPath).Length / 1MB, 0)
    Write-Log "  [信息] 安装包大小: ${installerSize}MB"
    Write-Log '  [步骤 1/4] 正在关闭已有 Ollama 进程...'
    Kill-AllOllama
    Start-Sleep -Seconds 2
    Write-Log '  [步骤 1/4] 进程清理完成'

    Write-Log '  [步骤 2/4] 正在启动 Ollama 静默安装器...'
    $installStart = Get-Date

    $installProcess = Start-Process -FilePath $InstallerPath -ArgumentList '/verysilent /norestart /suppressmsgboxes' -PassThru -NoNewWindow
    if (-not $installProcess) {
        throw '无法启动Ollama安装程序，请检查安装包是否完整'
    }
    Write-Log "  [步骤 2/4] 安装器已启动（PID: $($installProcess.Id)）"

    # 等待安装完成（带进度提示）
    Write-Log '  [步骤 3/4] 正在安装，请耐心等待（通常 1-3 分钟）...'
    $maxWaitSeconds = 300
    $waited = 0
    $lastProgress = 0
    while ($waited -lt $maxWaitSeconds) {
        if ($installProcess.HasExited) { break }
        Start-Sleep -Seconds 2
        $waited += 2
        # 每 10 秒打印一次进度
        if ($waited - $lastProgress -ge 10) {
            $lastProgress = $waited
            $remainSec = $maxWaitSeconds - $waited
            Write-Log "  [步骤 3/4] 安装中... 已等待 ${waited}秒（最长等待 ${maxWaitSeconds}秒，剩余 ${remainSec}秒）" 'DarkGray'
        }
    }

    if (-not $installProcess.HasExited) {
        Write-Log "  [警告] 安装程序 ${maxWaitSeconds}秒 后仍未退出，强制终止 (PID: $($installProcess.Id))..." 'Yellow'
        Kill-AllOllama -Process $installProcess
    }

    # 安装完成后彻底杀掉所有 Ollama 进程（包括自动启动的 GUI 托盘程序）
    Write-Log '  [步骤 3/4] 安装器已退出，清理残留进程...'
    Kill-AllOllama -Process $installProcess
    Start-Sleep -Seconds 2
    Kill-AllOllama

    $elapsed = [math]::Round(((Get-Date) - $installStart).TotalSeconds, 0)
    $exitCode = $installProcess.ExitCode
    Write-Log "  [步骤 3/4] 安装完成，耗时 ${elapsed}秒，退出码: $exitCode"

    if ($elapsed -lt 5) {
        Write-Log "  [警告] 安装程序退出过快（${elapsed}秒），可能安装失败" 'Yellow'
    }

    if ($exitCode -ne 0) {
        Write-Log "  [错误] 安装程序返回非零退出码: $exitCode" 'Red'
    }

    Write-Log '  [步骤 4/4] 正在验证安装结果...'

    # 验证安装
    $checkPaths = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'),
        (Join-Path ${env:ProgramFiles} 'Ollama\ollama.exe'),
        (Join-Path ([Environment]::GetEnvironmentVariable("ProgramFiles(x86)")) 'Ollama\ollama.exe')
    )

    foreach ($cp in $checkPaths) {
        if (Test-Path -LiteralPath $cp) {
            Write-Log "  [步骤 4/4] 验证通过: $cp" 'Green'
            return
        }
    }

    # PATH中查找
    try {
        $found = Get-Command ollama.exe -ErrorAction SilentlyContinue
        if ($found) {
            Write-Log ("  [步骤 4/4] 验证通过（PATH）: $($found.Source)")
            return
        }
    }
    catch { }

    throw '安装后未找到ollama.exe，安装可能失败'
}

# ── 安装Ollama（总控） ──
function Install-Ollama {
    Write-Log '  [阶段 1/4] 环境诊断...'

    # 先跑环境诊断
    Write-Diagnostic

    Write-Log '  [阶段 2/4] 检测已有 Ollama 安装...'

    # 纯存在性检测：只认当前用户目录下的 Ollama，不认其他用户的
    # 空白账户隔离模式下，连系统级 Ollama 都不认（强制为当前账户装用户级副本）
    $userScopeOnly = ($env:FLASHTAP_USER_SCOPE_ONLY -eq 'true')
    Write-Log "  [调试] 当前 USERPROFILE=$env:USERPROFILE, USERNAME=$env:USERNAME, USER_SCOPE_ONLY=$userScopeOnly"

    # 用户级路径（始终检查）
    $userCheckPaths = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe')
    )
    # 系统级路径（隔离模式下跳过）
    $systemCheckPaths = @(
        (Join-Path ${env:ProgramFiles} 'Ollama\ollama.exe'),
        (Join-Path ([Environment]::GetEnvironmentVariable("ProgramFiles(x86)")) 'Ollama\ollama.exe')
    )

    # 检查用户级
    foreach ($cp in $userCheckPaths) {
        if (Test-Path -LiteralPath $cp) {
            Write-Log "  [信息] 找到当前用户的 Ollama: $cp，跳过安装"
            return
        }
    }

    # 检查系统级（隔离模式下跳过，不认系统级）
    if (-not $userScopeOnly) {
        foreach ($cp in $systemCheckPaths) {
            if (Test-Path -LiteralPath $cp) {
                Write-Log "  [信息] 跳过非当前用户的 Ollama: $cp"
            }
        }
    } else {
        Write-Log "  [信息] 空白账户隔离模式：忽略系统级 Ollama，将为当前账户安装用户级副本"
    }

    # PATH 中查找（隔离模式下只认用户目录的）
    try {
        $found = Get-Command ollama.exe -ErrorAction SilentlyContinue
        if ($found) {
            if ($found.Source -like "$env:USERPROFILE*") {
                Write-Log "  [信息] 在 PATH 中找到当前用户的 Ollama: $($found.Source)，跳过安装"
                return
            } else {
                if ($userScopeOnly) {
                    Write-Log "  [信息] 隔离模式：忽略 PATH 中的系统级 Ollama: $($found.Source)"
                } else {
                    Write-Log "  [信息] 跳过非当前用户的 PATH Ollama: $($found.Source)"
                }
            }
        }
    }
    catch { }

    Write-Log '  [阶段 3/4] 获取 Ollama 安装包...'
    Write-Log '  [信息] 开始安装 Ollama...'

    # 本地安装程序检测（同目录优先 → 抛错退出）
    $installerPath = Get-Ollama-Local-Installer

    Write-Log '  [阶段 4/4] 执行静默安装...'
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

    # 模型目录：逐个候选尝试【创建+写入】校验，第一个成功的就用
    # 虚拟机 D 盘可能只读/不存在/权限拒绝，必须实测可写性而非仅 Test-Path
    $candidates = @(
        'D:\ollama_models',
        (Join-Path $env:USERPROFILE '.ollama\models'),
        (Join-Path $env:LOCALAPPDATA 'ollama\models')
    )
    $modelsDir = $null
    foreach ($dir in $candidates) {
        $parent = Split-Path -Parent $dir
        if (-not (Test-Path -LiteralPath $parent)) { continue }
        try {
            # 实测：创建目录 + 写探测文件 + 删除，三步都成功才算可写
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
            }
            $probe = Join-Path $dir '.flashtap_write_probe'
            Set-Content -LiteralPath $probe -Value 'ok' -ErrorAction Stop
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
            $modelsDir = $dir
            Write-Log "  [信息] 模型目录可用: $dir"
            break
        } catch {
            Write-Log "  [信息] 候选目录不可用: $dir ($($_.Exception.Message))" 'DarkGray'
        }
    }
    if (-not $modelsDir) {
        $modelsDir = Join-Path $env:USERPROFILE '.ollama\models'
        Write-Log "  [信息] 所有候选不可用，兜底使用: $modelsDir" 'Yellow'
    }

    try {
        if (-not (Test-Path -LiteralPath $modelsDir)) {
            New-Item -ItemType Directory -Path $modelsDir -Force -ErrorAction Stop | Out-Null
        }
        [Environment]::SetEnvironmentVariable('OLLAMA_MODELS', $modelsDir, $envTarget)
        $env:OLLAMA_MODELS = $modelsDir
        Write-Log "  [成功] OLLAMA_MODELS = $modelsDir"
    }
    catch {
        Write-Log "  [警告] 无法创建模型目录: $($_.Exception.Message)，Ollama 将使用默认目录" 'Yellow'
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

    # 检查是否已在运行（轮询重试，适配虚拟机后台进程延迟）
    Write-Log '  [信息] 检查 Ollama 是否已在运行...'
    $alreadyRunning = $false
    $maxAttempts = 3
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            $checkJob = Start-Job -ScriptBlock {
                param($exe, $envPath, $modelsDir)
                $env:Path = $envPath
                if ($modelsDir) { $env:OLLAMA_MODELS = $modelsDir }
                & $exe list 2>&1 | Out-Null
                return $LASTEXITCODE
            } -ArgumentList $ollamaExe, $env:Path, $env:OLLAMA_MODELS

            # 每次等 10 秒（虚拟机后台进程启动慢），共 3 次 = 30 秒
            $completed = Wait-Job $checkJob -Timeout 10
            if ($completed) {
                $result = Receive-Job $checkJob
                if ($result -eq 0) {
                    $alreadyRunning = $true
                    Write-Log '  [成功] Ollama 服务已在运行'
                    break
                }
            }
            Remove-Job $checkJob -Force -ErrorAction SilentlyContinue
            if ($attempt -lt $maxAttempts) {
                Write-Log "  [信息] 第 $attempt/$maxAttempts 次检测未就绪，等待 3 秒后重试..."
                Start-Sleep -Seconds 3
            }
        } catch {
            Write-Log "  [信息] 第 $attempt 次检测异常: $($_.Exception.Message)"
        }
    }
    if (-not $alreadyRunning) {
        Write-Log '  [信息] 多次检测后确认 Ollama 未运行，准备启动'
    }

    if ($alreadyRunning) { return }

    # 后台启动（UseShellExecute=$true 独立进程，不阻塞当前脚本）
    Kill-AllOllama
    Write-Log '  [信息] 正在后台启动 Ollama serve...'
    $ollamaProc = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $ollamaExe
        $psi.Arguments = 'serve'
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.UseShellExecute = $true
        $ollamaProc = [System.Diagnostics.Process]::Start($psi)
        if ($ollamaProc) {
            Write-Log "  [信息] Ollama serve 已启动（PID: $($ollamaProc.Id)）"
        } else {
            Write-Log '  [警告] 启动 ollama serve 返回空'
        }
    }
    catch {
        Write-Log "  [警告] 后台启动失败: $($_.Exception.Message)"
        return
    }

    # ── 启动后校验服务就绪（最多等 60 秒） ──
    # 不等待会导致后续 download-models.py 调 ollama create 失败
    Write-Log '  [信息] 等待 Ollama 服务就绪...'
    $ready = $false
    for ($i = 1; $i -le 20; $i++) {
        Start-Sleep -Seconds 3
        try {
            $probeJob = Start-Job -ScriptBlock {
                param($exe, $envPath, $modelsDir)
                $env:Path = $envPath
                if ($modelsDir) { $env:OLLAMA_MODELS = $modelsDir }
                & $exe list 2>&1 | Out-Null
                return $LASTEXITCODE
            } -ArgumentList $ollamaExe, $env:Path, $env:OLLAMA_MODELS
            $done = Wait-Job $probeJob -Timeout 8
            if ($done) {
                $code = Receive-Job $probeJob
                Remove-Job $probeJob -Force -ErrorAction SilentlyContinue
                if ($code -eq 0) {
                    $ready = $true
                    Write-Log "  [成功] Ollama 服务已就绪（等待 $($i * 3) 秒后响应）"
                    break
                }
            } else {
                Remove-Job $probeJob -Force -ErrorAction SilentlyContinue
            }
        } catch {
            # 继续重试
        }
        Write-Log "  [信息] 服务未就绪，继续等待... ($($i)/20)"
    }
    if (-not $ready) {
        Write-Log '  [警告] Ollama 服务 60 秒内未就绪，后续步骤可能失败' 'Yellow'
        Write-Log '  [信息] 建议：手动运行 ollama serve 启动服务后重试' 'Yellow'
    }
}

# ── 主函数 ──
function Main {
    [Console]::TreatControlCAsInput = $false
    $env:OLLAMA_HOST = '127.0.0.1:11434'
    $mainStart = Get-Date

    Write-Log '========== Ollama 安装流程开始 =========='

    # ── 步骤 A：安装 Ollama ──
    Write-Log '[步骤 A/3] 安装 Ollama 引擎...'
    try {
        Install-Ollama
        Write-Log '[步骤 A/3] Ollama 安装完成 ✓'
    }
    catch {
        Write-Log ('[步骤 A/3] Ollama 安装失败: ' + $_.Exception.Message) 'Red'
        Write-Host ''
        Write-Host '  *** 如需反馈此错误，请复制上方包含[错误]的那一行 ***'
        Write-Host ''
        exit 1
    }

    # ── 步骤 B：配置环境变量 + 模型目录 ──
    Write-Log '[步骤 B/3] 配置 Ollama 环境变量...'
    try {
        Configure-Ollama
        Write-Log '[步骤 B/3] 环境配置完成 ✓'
    }
    catch {
        Write-Log ('[步骤 B/3] 环境配置失败: ' + $_.Exception.Message) 'Yellow'
    }

    # ── 步骤 C：启动 Ollama 服务 ──
    Write-Log '[步骤 C/3] 启动 Ollama 服务...'
    try {
        Start-Ollama
        Write-Log '[步骤 C/3] 服务启动完成 ✓'
    }
    catch {
        Write-Log ('[警告] ' + $_.Exception.Message)
    }

    Write-Host '  [成功] Ollama 安装完成，继续后续步骤...' -ForegroundColor Green
}

try {
    Main
} catch {
    Write-Host ''
    Write-Host '  ════════════════════════════════════════════' -ForegroundColor Red
    Write-Host '    [严重错误] install-flashtap.ps1 发生异常' -ForegroundColor Red
    Write-Host '  ════════════════════════════════════════════' -ForegroundColor Red
    Write-Host "  错误信息: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "  错误位置: $($_.InvocationInfo.PositionMessage)" -ForegroundColor Yellow
    Write-Host "  脚本行号: $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Yellow
    Write-Host "  堆栈: $($_.ScriptStackTrace)" -ForegroundColor DarkGray
    Write-Host ''
    exit 1
}
exit 0