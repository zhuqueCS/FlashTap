<# FlashTap 一键安装主脚本 #>
# 此脚本由 一键安装FlashTap.bat 调用
# 作用：按照固定顺序执行 Ollama 安装、VS Code 安装/配置、模型下载与环境校验
# 目前实际入口文件：一键安装FlashTap.bat
# 严格按用户要求：所有配置来自用户提供的 settings.json / config.yaml / extensions.list
# 脚本只负责流程编排，不直接写入业务配置代码

param(
    [string]$OriginalUsername,
    [string]$OriginalUserProfile
)

# 如果通过 UAC 提权后用户身份变了（多用户场景），
# 把环境变量切换回原始用户，保证 VS Code/配置装在正确用户下
if ($OriginalUsername -and $OriginalUsername -ne $env:USERNAME) {
    $env:USERNAME = $OriginalUsername
    $env:USERPROFILE = $OriginalUserProfile
    $env:LOCALAPPDATA = Join-Path $OriginalUserProfile 'AppData\Local'
    $env:APPDATA = Join-Path $OriginalUserProfile 'AppData\Roaming'
    $env:HOMEPATH = "\Users\$OriginalUsername"
    $env:HOMEDRIVE = ($OriginalUserProfile -split ':')[0] + ':'
    Write-Host "  [信息] 已切换到目标用户: $OriginalUsername" -ForegroundColor Cyan
}

# ── 自动从脚本路径检测目标用户（多账户机器提权跨账户场景）──
# 场景：多用户 Windows 机器上，"右键→以管理员运行"后提权到了另一个管理员账户，
#       导致 %USERNAME% 与脚本所在用户目录不一致。
#       例如：脚本在 C:\Users\本人2\Downloads\ → 本人2 是目标用户，
#       但提权后 $env:USERNAME 变成了 PYX。
# 安全：在空白单用户机器上（脚本路径 = 当前用户目录），检测 = $env:USERNAME，
#       不会触发任何切换，对原有行为零影响。
if (-not $OriginalUsername) {
    $detectedUser = $null
    # 使用 $PSScriptRoot（脚本启动即可用，无需等 PROJECT_DIR 赋值）
    $scriptRoot = $PSScriptRoot
    if ((-not $scriptRoot) -or ($scriptRoot -eq '')) {
        $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
    if ($scriptRoot) {
        $normalizedPath = $scriptRoot -replace '\\', '/'
        if ($normalizedPath -match '/Users/([^/]+)/') {
            $candidate = $matches[1]
            $candidateProfile = "C:\Users\$candidate"
            # 仅当检测到的用户目录确实存在时生效（防止误匹配非用户路径）
            if ((Test-Path -LiteralPath $candidateProfile) -and $candidate -ne $env:USERNAME) {
                $detectedUser = $candidate
                Write-Host "  [信息] 从脚本路径检测到目标用户: $detectedUser (当前提权用户: $env:USERNAME)" -ForegroundColor Cyan
            }
        }
    }
    if ($detectedUser) {
        $OriginalUsername = $detectedUser
        $OriginalUserProfile = $candidateProfile
        # 切换环境变量到目标用户（与上方 param 切换逻辑保持一致）
        $env:USERNAME = $OriginalUsername
        $env:USERPROFILE = $OriginalUserProfile
        $env:LOCALAPPDATA = Join-Path $OriginalUserProfile 'AppData\Local'
        $env:APPDATA = Join-Path $OriginalUserProfile 'AppData\Roaming'
        $env:HOMEPATH = "\Users\$detectedUser"
        $env:HOMEDRIVE = ($OriginalUserProfile -split ':')[0] + ':'
        Write-Host "  [信息] 已切换到目标用户: $detectedUser" -ForegroundColor Cyan
    }
}

# 确保 FLASHTAP_ORIGINAL_* 环境变量已设置（子进程靠这个恢复用户上下文）
# CRITICAL: Always reset based on current process user — never trust inherited values.
# Previous runs may have set these as persistent env vars, causing context bleed
# across different user accounts (e.g. PYX → 本人2).
$env:FLASHTAP_ORIGINAL_USER = $env:USERNAME
$env:FLASHTAP_ORIGINAL_PROFILE = $env:USERPROFILE
Write-Host "  [调试] FLASHTAP_ORIGINAL_USER=$env:FLASHTAP_ORIGINAL_USER, FLASHTAP_ORIGINAL_PROFILE=$env:FLASHTAP_ORIGINAL_PROFILE" -ForegroundColor DarkGray

$ErrorActionPreference = 'Continue'
$script:installFailed = $false   # 跟踪是否有关键步骤失败，用于最终退出码

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 自动继承系统代理设置
$proxy = [System.Net.WebRequest]::GetSystemWebProxy()
$proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
[System.Net.WebRequest]::DefaultWebProxy = $proxy

$PROJECT_DIR = $PSScriptRoot
if ((-not $PROJECT_DIR) -or ($PROJECT_DIR -eq '')) {
    $PROJECT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if ((-not $PROJECT_DIR) -or ($PROJECT_DIR -eq '')) {
    $PROJECT_DIR = (Get-Location).Path
}
$LOG_FILE = [System.IO.Path]::Combine($PROJECT_DIR, 'install.log')

# ── 空白账户隔离检测 ──
# 检测当前账户是否为"空白账户"（没有用户级 Ollama/VS Code，但有系统级的）
# 如果是，则强制为当前账户安装用户级副本，不受系统级软件干扰
$env:FLASHTAP_USER_SCOPE_ONLY = 'false'
$userOllama = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
$userVSCode = Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\Code.exe'

$userHasOllama = Test-Path -LiteralPath $userOllama
$userHasVSCode = Test-Path -LiteralPath $userVSCode

# 检测系统级软件：查标准路径 + 注册表（含 D 盘等非标准位置）
$sysHasOllama = $false
$sysHasVSCode = $false

# 系统级 Ollama
$sysOllamaPaths = @(
    (Join-Path ${env:ProgramFiles} 'Ollama\ollama.exe'),
    (Join-Path ([Environment]::GetEnvironmentVariable("ProgramFiles(x86)")) 'Ollama\ollama.exe')
)
foreach ($p in $sysOllamaPaths) {
    if (Test-Path -LiteralPath $p) { $sysHasOllama = $true; break }
}

# 系统级 VS Code：标准路径 + HKLM 注册表（含 D 盘等非标准位置）
$sysVSCodePaths = @(
    (Join-Path ${env:ProgramFiles} 'Microsoft VS Code\Code.exe'),
    (Join-Path ([Environment]::GetEnvironmentVariable("ProgramFiles(x86)")) 'Microsoft VS Code\Code.exe')
)
foreach ($p in $sysVSCodePaths) {
    if (Test-Path -LiteralPath $p) { $sysHasVSCode = $true; break }
}
if (-not $sysHasVSCode) {
    # 查 HKLM 注册表（系统级安装可能在 D 盘等非标准位置）
    try {
        $hklmEntries = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue
        foreach ($entry in $hklmEntries) {
            if ($entry.DisplayName -like '*Visual Studio Code*') { $sysHasVSCode = $true; break }
        }
    } catch {}
}

if ((-not $userHasOllama -and $sysHasOllama) -or (-not $userHasVSCode -and $sysHasVSCode)) {
    $env:FLASHTAP_USER_SCOPE_ONLY = 'true'
    Write-Host "  [信息] 检测到系统级软件存在但当前账户无用户级副本，启用空白账户隔离模式" -ForegroundColor Cyan
    Write-Host "         将为当前账户安装独立的用户级副本，不受系统级软件干扰" -ForegroundColor DarkGray
    Write-Host "  [调试] 用户级 Ollama=$userHasOllama VSCode=$userHasVSCode | 系统级 Ollama=$sysHasOllama VSCode=$sysHasVSCode" -ForegroundColor DarkGray
}

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
    param([string]$FilePath, [string]$Description, [string[]]$ArgumentList = @())
    Write-Host ''
    Write-Host '  ────────────────────────────────────────────' -ForegroundColor Cyan
    Write-Host "    $Description" -ForegroundColor Cyan
    Write-Host '  ────────────────────────────────────────────' -ForegroundColor Cyan

    if (-not (Test-Path -LiteralPath $FilePath)) {
        Write-Log "[跳过] 未找到脚本: $FilePath" 'Yellow'
        return $false
    }

    # FLASHTAP_ORIGINAL_* 环境变量在 Start-Process 子进程中不可靠
    # 改用文件传递，彻底绕过进程继承问题
    # 必须放脚本目录（%~dp0），不要放 %TEMP%——提权后 TEMP 指向不同用户，读不到！
    $envFile = Join-Path $PROJECT_DIR '.flashtap-env.txt'
    $envContent = @"
FLASHTAP_ORIGINAL_USER=$env:FLASHTAP_ORIGINAL_USER
FLASHTAP_ORIGINAL_PROFILE=$env:FLASHTAP_ORIGINAL_PROFILE
FLASHTAP_USER_SCOPE_ONLY=$env:FLASHTAP_USER_SCOPE_ONLY
"@
    $envContent | Out-File -FilePath $envFile -Encoding UTF8 -Force
    Write-Log "[调试] 写入环境文件: $envFile" 'DarkGray'

    # 用 & 直接调用 powershell.exe（同窗口，日志直接输出到当前终端）
    # 不用 cmd /c（中文路径在 cmd 下会乱码）
    # 用 -Command 方式调用，路径用单引号包裹避免特殊字符问题
    $psArgs = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $FilePath)
    if ($ArgumentList.Count -gt 0) {
        $psArgs += $ArgumentList
    }

    $ec = 1  # 默认失败
    try {
        # 用 Start-Process -PassThru 可靠获取子进程退出码
        # （不能用 $global:LASTEXITCODE：& 调用设置的是函数局部作用域，取不到真实退出码）
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs -Wait -PassThru -NoNewWindow -ErrorAction Stop
        $ec = $proc.ExitCode
    } catch {
        $ec = 1
        Write-Log "[错误] 执行子脚本异常: $($_.Exception.Message)" 'Red'
    }
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

# 全局错误捕获：任何未处理异常都打印出来，避免闪退看不到错误
try {

Write-Host ''
Write-Host '════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host '      FlashTap · AI 编程助手 一键安装工具' -ForegroundColor Cyan
Write-Host '════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ''
Write-Host '  [信息] 本工具将自动完成以下步骤：           ' -ForegroundColor White
Write-Host '         0. Python 运行环境（如未安装则自动装）  ' -ForegroundColor White
Write-Host '         1. Ollama 本地大模型引擎               ' -ForegroundColor White
Write-Host '         2. VS Code 编辑器 + Continue AI 编程插件  ' -ForegroundColor White
Write-Host '         3. Qwen2.5-Coder 7B 代码模型          ' -ForegroundColor White
Write-Host '         4. 全自动配置，无需任何手动操作          ' -ForegroundColor White
Write-Host ''

# ── 第零步：确保 Python 可用（如未安装则自动下载安装） ──
Write-Host '  ────────────────────────────────────────────' -ForegroundColor Cyan
Write-Host '    第零步：检测 Python 运行环境' -ForegroundColor Cyan
Write-Host '  ────────────────────────────────────────────' -ForegroundColor Cyan

$pyInfo = Find-PythonExecutable
if (-not $pyInfo) {
    Write-Log '[信息] 未检测到 Python，开始自动下载安装...' 'Yellow'

    $pyInstaller = Join-Path $env:TEMP 'python-3.12.7-amd64.exe'

    # 本地优先：离线包场景，打包目录已含 Python 安装器则直接复用，零网络
    $localPy = Join-Path $PROJECT_DIR 'python-3.12.7-amd64.exe'
    if (Test-Path $localPy) {
        try {
            $lb = [System.IO.File]::ReadAllBytes($localPy)
            if ($lb.Length -gt 30MB -and $lb[0] -eq 0x4D -and $lb[1] -eq 0x5A) {
                Unblock-File -Path $localPy -ErrorAction SilentlyContinue
                Write-Log "[信息] 使用本地 Python 安装器（离线）: $localPy"
                $pyInstaller = $localPy
                $pyDownloaded = $true
            } else {
                Write-Log '[警告] 本地 Python 安装器无效，改用在线下载' 'Yellow'
            }
        } catch {
            Write-Log '[警告] 本地 Python 安装器读取失败，改用在线下载' 'Yellow'
        }
    }

    # 华为镜像优先（国内快），官方源兜底
    $pyUrls = @(
        'https://mirrors.huaweicloud.com/python/3.12.7/python-3.12.7-amd64.exe',
        'https://registry.npmmirror.com/-/binary/python/3.12.7/python-3.12.7-amd64.exe',
        'https://mirrors.tuna.tsinghua.edu.cn/python/3.12.7/python-3.12.7-amd64.exe',
        'https://www.python.org/ftp/python/3.12.7/python-3.12.7-amd64.exe'
    )

    if (-not $pyDownloaded) {
        foreach ($url in $pyUrls) {
        Write-Log "[信息] 正在下载 Python 3.12.7: $url"
        try {
            $req = [System.Net.HttpWebRequest]::Create($url)
            $req.Timeout = 90000
            $req.ReadWriteTimeout = 180000
            $resp = $req.GetResponse()
            $totalBytes = $resp.ContentLength
            $respStream = $resp.GetResponseStream()
            $fs = [System.IO.File]::Create($pyInstaller)
            $buffer = New-Object byte[] 65536
            $downloaded = 0L
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            while (($read = $respStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $fs.Write($buffer, 0, $read)
                $downloaded += $read
                if ($sw.ElapsedMilliseconds -ge 500 -and $totalBytes -gt 0) {
                    $pct = [math]::Round($downloaded * 100 / $totalBytes)
                    Write-Host "`r  下载进度: $pct% ($([math]::Round($downloaded/1MB,0))MB / $([math]::Round($totalBytes/1MB,0))MB)   " -NoNewline
                    $sw.Restart()
                }
            }
            $fs.Close()
            $respStream.Close()
            $resp.Close()
            Write-Host ''

            if ((Test-Path $pyInstaller) -and (Get-Item $pyInstaller).Length -gt 20MB) {
                Write-Log '[信息] Python 安装包下载完成'
                $pyDownloaded = $true
                break
            }
        } catch {
            Write-Host ''
            Write-Log "[警告] 下载失败: $($_.Exception.Message)"
            Remove-Item $pyInstaller -Force -ErrorAction SilentlyContinue
        }
    }
    }

    if ($pyDownloaded) {
        Write-Log '[信息] 正在静默安装 Python 3.12.7（为所有用户，自动加入 PATH）...'
        Write-Log '[信息] 安装可能需要 1-3 分钟，请耐心等待...' 'Cyan'
        try {
            # 用 Start-Process 启动并等待退出
            # InstallAllUsers=1 需要管理员权限（bat 已提权，OK）
            # PrependPath=1 自动加入 PATH
            # Include_test=0 不装测试套件（省空间）
            # 解除 Mark-of-the-Web，防止空白机 SmartScreen/Defender 拦截静默安装导致卡死
            Unblock-File -Path $pyInstaller -ErrorAction SilentlyContinue
            $pyProc = Start-Process -FilePath $pyInstaller -ArgumentList '/quiet', 'InstallAllUsers=1', 'PrependPath=1', 'Include_test=0' -Wait -PassThru
            $pyExitCode = if ($pyProc) { $pyProc.ExitCode } else { -1 }

            if ($pyExitCode -eq 0) {
                Write-Log '[成功] Python 安装完成' 'Green'

                # 刷新当前进程 PATH（安装器写入了注册表但当前进程 PATH 未更新）
                $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
                $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
                $env:Path = "$machinePath;$userPath"

                # 重新检测（等待注册表刷新）
                Start-Sleep -Seconds 2
                $pyInfo = Find-PythonExecutable
                if ($pyInfo) {
                    Write-Log "[成功] Python 已就绪: $($pyInfo.Exe) ($($pyInfo.Type))" 'Green'
                } else {
                    # 兜底：直接验证 python.exe 是否存在于标准路径
                    $fallbackPy = Join-Path ${env:ProgramFiles} 'Python312\python.exe'
                    if (Test-Path -LiteralPath $fallbackPy) {
                        $pyInfo = @{ Exe = $fallbackPy; Type = 'fallback' }
                        Write-Log "[成功] Python 已就绪（兜底路径）: $fallbackPy" 'Green'
                    } else {
                        Write-Log '[警告] Python 安装完成但未能检测到，后续 Python 脚本可能无法运行' 'Yellow'
                    }
                }
            } else {
                Write-Log "[警告] Python 安装返回非零退出码: $pyExitCode" 'Yellow'
                Write-Log '[信息] 可能原因：权限不足、磁盘空间不够、或安装器被安全软件拦截' 'Yellow'
            }
        } catch {
            Write-Log "[警告] Python 安装异常: $($_.Exception.Message)" 'Yellow'
        }
        # 清理安装包
        Remove-Item $pyInstaller -Force -ErrorAction SilentlyContinue
    } else {
        Write-Log '[警告] Python 下载失败，后续需要 Python 的步骤将跳过' 'Yellow'
        Write-Log '[信息] 请手动安装 Python 3.10+: https://www.python.org/downloads/' 'Yellow'
    }
} else {
    Write-Log "[成功] Python 已就绪: $($pyInfo.Exe) ($($pyInfo.Type))" 'Green'
}
Write-Host ''

# ── 第一步：安装 Ollama ──
$ollamaScript = [System.IO.Path]::Combine($PROJECT_DIR, 'install-flashtap.ps1')
if (-not (Run-Script -FilePath $ollamaScript -Description '第一步：安装 Ollama 本地大模型引擎')) {
    Write-Host ''
    Write-Host '  ╔════════════════════════════════════════════╗' -ForegroundColor Red
    Write-Host '  ║        Ollama 安装失败，安装中止           ║' -ForegroundColor Red
    Write-Host '  ╚════════════════════════════════════════════╝' -ForegroundColor Red
    Write-Host ''
    Write-Host '  [原因] Ollama 安装异常，请查看上方日志中的 [错误] 行' -ForegroundColor Yellow
    Write-Host '  [解决] 常见问题：网络不稳定导致下载失败、安装被安全软件拦截' -ForegroundColor Yellow
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
    $script:installFailed = $true
    Write-Log '[错误] VS Code 安装配置失败，后续步骤可能无法完成' 'Red'
    Write-Log '[信息] 将继续执行后续步骤（模型下载等），请稍后手动安装 VS Code' 'Yellow'
}

# ── 第二步半：C++ 编译环境配置（必装项：F5 编译调试必需） ──
$CppWorkspace = 'C:\FlashTap\cpp-workspace'
$cppScript = [System.IO.Path]::Combine($PROJECT_DIR, 'setup-cpp-env.ps1')
Write-Log '[信息] 开始配置 C++ 编译环境（MinGW-w64，必装）...' 'Cyan'
$cppResult = Run-Script -FilePath $cppScript -Description 'C++ 编译环境配置'
if ($cppResult) {
    Write-Log '[成功] C++ 编译环境配置完成（按 F5 即可编译调试）' 'Green'
} else {
    # 关键修复：C++ 编译环境失败（如离线包缺失/下载失败）时，不再中断整个安装，
    # 否则 VS Code 不会启动，用户看到"啥也没弹出来"。VS Code + 本地 AI 对话是核心功能，
    # 即使 F5 调试暂不可用也应保证可用。
    Write-Log '[警告] C++ 编译环境配置失败（F5 编译调试可能暂不可用）。' 'Yellow'
    Write-Log '[信息] 不影响 VS Code + 本地 AI 对话，将继续启动 VS Code。' 'Yellow'
    Write-Log '[信息] 如需 F5 调试，请把 mingw64.zip（MinGW-w64）放到 FlashTap 目录后重新运行本脚本。' 'Yellow'
}

# ── 第三步：部署 AI 代码模型 ──
$downloadScript = [System.IO.Path]::Combine($PROJECT_DIR, 'download-models.py')
$downloadOk = Run-Python -FilePath $downloadScript -Description '第三步：部署 Qwen2.5-Coder 7B 代码模型（约 4GB，耗时较长）'
if (-not $downloadOk) {
    # Python 不可用时，直接用 ollama pull 兜底
    Write-Host ''
    Write-Log '[信息] Python 不可用，使用 ollama pull 直接下载模型...' 'Yellow'
    $ollamaExeForPull = $null
    $ollamaPullPaths = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'),
        (Join-Path $env:ProgramFiles 'Ollama\ollama.exe'),
        (Join-Path ([Environment]::GetEnvironmentVariable("ProgramFiles(x86)")) 'Ollama\ollama.exe')
    )
    foreach ($op in $ollamaPullPaths) {
        if (Test-Path -LiteralPath $op) { $ollamaExeForPull = $op; break }
    }
    if (-not $ollamaExeForPull) { $ollamaExeForPull = 'ollama' }

    try {
        Write-Log '[信息] 正在执行 ollama pull qwen2.5-coder:7b（约 4GB，需 10-30 分钟）...' 'Cyan'
        $pullProc = Start-Process -FilePath $ollamaExeForPull -ArgumentList 'pull', 'qwen2.5-coder:7b' -Wait -NoNewWindow -PassThru
        if ($pullProc -and $pullProc.ExitCode -eq 0) {
            Write-Log '[成功] 模型下载完成' 'Green'
            $downloadOk = $true
        } else {
            Write-Log '[警告] ollama pull 失败，模型未部署' 'Yellow'
        }
    } catch {
        Write-Log "[警告] ollama pull 异常: $($_.Exception.Message)" 'Yellow'
    }
}
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
# 隔离模式下只查用户级，非隔离模式查所有注册表（含系统级 D 盘等非标准位置）
$vscExe = $null
$vscCandidatePaths = @(
    [System.IO.Path]::Combine($env:LOCALAPPDATA, 'Programs\Microsoft VS Code\Code.exe'),
    [System.IO.Path]::Combine($env:USERPROFILE, 'AppData\Local\Programs\Microsoft VS Code\Code.exe')
)

# 非隔离模式才查系统级路径
if ($env:FLASHTAP_USER_SCOPE_ONLY -ne 'true') {
    $vscCandidatePaths += [System.IO.Path]::Combine($env:ProgramFiles, 'Microsoft VS Code\Code.exe')
    $vscCandidatePaths += [System.IO.Path]::Combine([Environment]::GetEnvironmentVariable("ProgramFiles(x86)"), 'Microsoft VS Code\Code.exe')
    if ($env:ProgramW6432) {
        $vscCandidatePaths += [System.IO.Path]::Combine($env:ProgramW6432, 'Microsoft VS Code\Code.exe')
    }
}

# 注册表查找：隔离模式只查 HKCU，非隔离模式查 HKCU + HKLM
$regPaths = @('HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
if ($env:FLASHTAP_USER_SCOPE_ONLY -ne 'true') {
    $regPaths += 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $regPaths += 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
}
foreach ($regPath in $regPaths) {
    try {
        $entries = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
        foreach ($entry in $entries) {
            if ($entry.DisplayName -like '*Visual Studio Code*' -and $entry.UninstallString) {
                $uninstStr = $entry.UninstallString -replace '^"', '' -replace '"$', ''
                $instDir = Split-Path -Parent $uninstStr
                $codeExe = Join-Path $instDir 'Code.exe'
                if ($codeExe -notin $vscCandidatePaths) {
                    $vscCandidatePaths += $codeExe
                }
                Write-Log "[信息] 注册表找到 VS Code: $instDir" 'Cyan'
            }
        }
    } catch {}
}

# 遍历候选路径，找到可用的 VS Code
# 不依赖 Get-Item 读取文件大小（VS Code 运行中文件可能被锁），
# 改用目录存在性 + resources\ 子目录判断
foreach ($p in $vscCandidatePaths) {
    $vscDir = Split-Path -Parent $p
    if (Test-Path -LiteralPath $p) {
        # 优先检查 resources\ 子目录（不依赖 Code.exe 可读）
        $resourcesDir = Join-Path $vscDir 'resources'
        if (Test-Path -LiteralPath $resourcesDir) {
            $vscExe = $p
            Write-Log "[信息] 使用 VS Code: $p" 'Green'
            break
        }
        # 兜底：尝试 Get-Item（文件未锁定时可用）
        try {
            $item = Get-Item -LiteralPath $p -ErrorAction Stop
            if ($item.Length -gt 5242880) {
                $vscExe = $p
                Write-Log "[信息] 使用 VS Code: $p" 'Green'
                break
            }
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
        # R3 修复：非 WSL（Windows MinGW）分支也必须打开本地 C++ 工作区，
        # 否则安装结束自动启动的 VS Code 是空白窗（没有示例工程、没有 F5 调试模板）。
        # 桌面快捷方式已带 $CppWorkspace，这里保持一致。
        $vscArgs = @('--locale=zh-cn', "`"$CppWorkspace`"")

        # R5 修复：WSL 分支已废弃（setup-cpp-env 不再生成 .wsl-distro-name，架构统一 Windows MinGW）。
        # 用 $false 永久禁用 WSL 远程工作区逻辑，消除其与 Windows MinGW 配置矛盾的"炸弹"；
        # 同时把原 WSL 分支内的 $RealAppData/$RealUserProfile 定义提升到此处，供下方信任设置段使用。
        # 注：主脚本提权运行，开头已把 $env:USERPROFILE/$env:APPDATA 重定义为目标用户，
        # 因此这里直接用 $env:APPDATA 即指向真实运行 VS Code 的用户目录。
        $RealUserProfile = if ($OriginalUserProfile) { $OriginalUserProfile } else { $env:USERPROFILE }
        $RealAppData     = if ($OriginalUserProfile) { Join-Path $OriginalUserProfile 'AppData\Roaming' } else { $env:APPDATA }

        if ($false) {
            $distroName = (Get-Content $distroFile -Raw -ErrorAction SilentlyContinue).Trim()
            if ($distroName) {
                Write-Log "[信息] 准备 WSL 连接: $distroName" 'Cyan'

                # 使用固定工作区路径（与 setup-cpp-env.ps1 保持一致）
                $wslWorkspace = '/home/lc-cpp-workspace'
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
            "name": "g++ 调试运行",
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
            "preLaunchTask": "C/C++: g++ 生成活动文件",
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

                        # ── 生成 tasks.json（编译任务，reveal: silent 避免弹窗） ──
                        $tasksJson = @'
{
    "version": "2.0.0",
    "tasks": [
        {
            "type": "shell",
            "label": "C/C++: g++ 生成活动文件",
            "command": "/usr/bin/g++",
            "args": [
                "-g",
                "${file}",
                "-o",
                "${fileDirname}/${fileBasenameNoExtension}",
                "-std=c++11",
                "-lcurl",
                "-pthread"
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
                "reveal": "silent"
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

                # 关键修复：主安装脚本以管理员（提权）身份运行，此时 $env:USERPROFILE/$env:APPDATA
                # 指向 Administrator；而 VS Code 实际以【原始普通用户】(-Verb RunAsUser) 启动并读取
                # 该用户目录下的配置。因此所有 VS Code 用户级路径（扩展目录 / locale.json /
                # settings.json）必须指向原始用户目录，否则配置"写了但不生效"，表现为：
                # 中文不生效、工作区信任关不掉、打开本地工作区仍进"受限模式（保护模式）"，
                # 扩展（Continue、C/C++）全被禁用，只能看代码。
                $RealUserProfile = if ($OriginalUserProfile) { $OriginalUserProfile } else { $env:USERPROFILE }
                $RealAppData     = if ($OriginalUserProfile) { Join-Path $OriginalUserProfile 'AppData\Roaming' } else { $env:APPDATA }

                try {
                    $vscExtDir = Join-Path $RealUserProfile '.vscode\extensions'
                    # 检查是否已安装（避免重复下载）
                    $existingLang = Get-ChildItem -Path $vscExtDir -Directory -Filter 'ms-ceintl.vscode-language-pack-zh-hans-*' -ErrorAction SilentlyContinue
                    if (-not $existingLang) {
                        $langVsix = Join-Path $env:TEMP 'vscode-lang-pack.vsix'
                        $langExtract = Join-Path $env:TEMP 'vscode-lang-ext'

                        Write-Log '  [信息] 正在下载中文语言包...' 'Cyan'
                        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 自动继承系统代理设置
$proxy = [System.Net.WebRequest]::GetSystemWebProxy()
$proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
[System.Net.WebRequest]::DefaultWebProxy = $proxy
                        # 关键修复：必须加 -TimeoutSec，否则 marketplace 不可达时 Invoke-WebRequest
                        # 会无限挂起（try/catch 救不了无限挂起），整个安装看起来"卡死"。
                        # 超时后转为异常被外层 catch 捕获，仅跳过中文包并继续安装，不中断。
                        Invoke-WebRequest -Uri 'https://marketplace.visualstudio.com/_apis/public/gallery/publishers/MS-CEINTL/vsextensions/vscode-language-pack-zh-hans/latest/vspackage' -OutFile $langVsix -UseBasicParsing -TimeoutSec 60 -MaximumRedirection 5

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
                    $vscUserDir = Join-Path $RealAppData 'Code\User'
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

            # ── 真正关闭 VS Code 工作区信任（修复"受限模式 / 保护模式"）──
            # 这是"桌面快捷方式打开 VS Code 后只能看代码、所有功能用不了"的根因。
            # 工作区信任是【用户级】策略，必须写入原始用户的
            # $RealAppData\Code\User\settings.json 的 security.workspace.trust.enabled=false。
            # 注意：之前注释里写的"已关闭工作区信任（settings.json）"从未真正执行，
            # 且即便执行也写到了 Administrator 目录而非实际运行 VS Code 的普通用户目录。
            try {
                $trustUserDir = Join-Path $RealAppData 'Code\User'
                New-Item -ItemType Directory -Path $trustUserDir -Force -ErrorAction SilentlyContinue | Out-Null
                $trustSettingsPath = Join-Path $trustUserDir 'settings.json'
                $trustSettings = @{}
                if (Test-Path -LiteralPath $trustSettingsPath) {
                    try {
                        # PS 5.1 兼容：ConvertFrom-Json 无 -AsHashtable 参数，改用 PSObject 转哈希表，
                        # 否则在 Windows 默认 PS 5.1 上抛异常、被 catch 吞掉，信任追加静默失败。
                        $raw = Get-Content -Path $trustSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
                        $raw.PSObject.Properties | ForEach-Object { $trustSettings[$_.Name] = $_.Value }
                    } catch { $trustSettings = @{} }
                }
                if ($null -eq $trustSettings) { $trustSettings = @{} }
                $trustSettings['security.workspace.trust.enabled'] = $false
                $trustSettings | ConvertTo-Json -Depth 10 | Set-Content -Path $trustSettingsPath -Encoding UTF8 -ErrorAction SilentlyContinue
                Write-Log '[成功] 已关闭 VS Code 工作区信任（受限模式），打开本地工作区不再禁用扩展' 'Green'
            } catch {
                Write-Log "[警告] 关闭工作区信任失败（可手动在 VS Code 设置中关闭 Workspace Trust）: $($_.Exception.Message)" 'Yellow'
            }
        }

        # 为确保中文界面和 Continue 配置生效，关闭目标用户的 VS Code 进程后重新启动
        # 用提权前的原始用户名过滤，避免提权后 $env:USERNAME 变成 Administrator 误杀
        $targetUserForKill = if ($OriginalUsername) { $OriginalUsername } else { $env:USERNAME }
        if ($existingCode.Count -gt 0) {
            Write-Log "[信息] 关闭目标用户 [$targetUserForKill] 的 VS Code 进程以应用新配置..." 'Cyan'
            & taskkill /F /FI "USERNAME eq $targetUserForKill" /IM Code.exe 2>&1 | Out-Null
            Start-Sleep 3
        }
        # 关键修复：VS Code 必须以非管理员身份运行。
        # 右键"以管理员运行"后脚本进程是提权的 → 直接 Start-Process 让 VS Code 继承
        # 管理员上下文 → Electron 主进程 JS 崩溃（"r.toLowerCase is not a function"）。
        # -Verb RunAsUser 在已以真实用户(61959)运行时会弹"以其他用户身份运行"安全窗口。
        # 正确方案：通过 explorer.exe 中转。explorer.exe 始终以非提权身份运行，通过它
        # 打开 .lnk 快捷方式启动 VS Code，即可保证 VS Code 以普通用户权限运行。
        $launchArgs = $vscArgs + @("--user-data-dir=$RealAppData\Code")
        # 将参数数组转为单个参数字符串（空格分隔，含空格者加引号）
        $launchArgsStr = ($launchArgs | ForEach-Object {
            if ($_ -match '\s') { "`"$_`"" } else { $_ }
        }) -join ' '
        $needDeElevate = ($OriginalUsername -and $OriginalUsername -ne $env:USERNAME)

        if ($needDeElevate) {
            # 旧流程：Administrator → 切换回真实用户，用 RunAsUser
            Write-Log '   [信息] 使用 RunAsUser 降权到目标用户启动 VS Code...' 'Cyan'
            try {
                Start-Process -FilePath $vscExe -ArgumentList $launchArgs -Verb RunAsUser -ErrorAction Stop
            } catch {
                Write-Log '   [警告] RunAsUser 失败，退回 explorer 中转启动' 'Yellow'
            }
        } else {
            # 新流程：通过 explorer + .lnk 以普通用户身份启动 VS Code
            Write-Log '   [信息] 通过 explorer 以普通用户身份启动 VS Code...' 'Cyan'
            $lnkPath = Join-Path $env:TEMP "flashtap_vscode_$(Get-Date -Format 'yyyyMMddHHmmss').lnk"
            $ws = New-Object -ComObject WScript.Shell
            $lnk = $ws.CreateShortcut($lnkPath)
            $lnk.TargetPath = $vscExe
            $lnk.Arguments = $launchArgsStr
            $lnk.Save()
            Start-Process explorer.exe -ArgumentList $lnkPath
            Start-Sleep 12
            Remove-Item $lnkPath -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep 6
        # 已关闭工作区信任（settings.json），打开任意文件夹都不会再进入"保护模式"禁用 Continue。
        # 二次以 --reuse-window 复用同一窗口并强制重载，确保中文语言包在首窗即生效。
        # 注意：--locale=zh-cn 已在首启的 $launchArgs/$vscArgs 中，此处不重复添加
        # （否则 VS Code 警告 "locale is defined more than once"）。
        try {
            if ($needDeElevate) {
                $codeCli = Join-Path (Split-Path -Parent $vscExe) 'bin\code.cmd'
                if (-not (Test-Path -LiteralPath $codeCli)) { $codeCli = Join-Path (Split-Path -Parent $vscExe) 'code.cmd' }
                if (-not (Test-Path -LiteralPath $codeCli)) { $codeCli = $vscExe }
                $reuseArgs = @('--reuse-window') + $launchArgs
                try {
                    Start-Process -FilePath $codeCli -ArgumentList $reuseArgs -Verb RunAsUser -ErrorAction Stop
                } catch {
                    Start-Process -FilePath $codeCli -ArgumentList $reuseArgs -ErrorAction SilentlyContinue
                }
            } else {
                # 新流程：同样通过 explorer + .lnk 中转（已运行的 VS Code 是非提权的，复用窗口即可）
                $lnkPath2 = Join-Path $env:TEMP "flashtap_vscode_r_$(Get-Date -Format 'yyyyMMddHHmmss').lnk"
                $ws2 = New-Object -ComObject WScript.Shell
                $lnk2 = $ws2.CreateShortcut($lnkPath2)
                $lnk2.TargetPath = $vscExe
                $lnk2.Arguments = "--reuse-window $launchArgsStr"
                $lnk2.Save()
                Start-Process explorer.exe -ArgumentList $lnkPath2
                Start-Sleep 10
                Remove-Item $lnkPath2 -Force -ErrorAction SilentlyContinue
            }
        } catch {}
        Start-Sleep 2
        Write-Log '[成功] VS Code 已启动，中文界面 + Continue 配置已就绪（已关闭工作区信任）' 'Green'
    } catch {
        Write-Log '[错误] VS Code 启动失败，请手动打开' 'Red'
    }
} else {
    Write-Log '[警告] 未找到 VS Code，请手动从开始菜单打开' 'Yellow'
}

# ── 在桌面创建 FlashTap 快捷方式（指向已配置的 VS Code，打开即用、含全套环境）──
try {
    if ($vscExe -and (Test-Path -LiteralPath $vscExe)) {
        if (-not (Test-Path -LiteralPath $CppWorkspace)) { New-Item -ItemType Directory -Path $CppWorkspace -Force | Out-Null }
        $wshell = New-Object -ComObject WScript.Shell
        $desktop = [Environment]::GetFolderPath('Desktop')
        $lnkPath = Join-Path $desktop 'FlashTap.lnk'
        $shortcut = $wshell.CreateShortcut($lnkPath)
        $shortcut.TargetPath = $vscExe
        # R1/R4 加固：--user-data-dir 指向目标用户标准目录，确保双击快捷方式启动的 VS Code
        # 与安装扩展时同一用户数据，避免跨账户 UAC 提权时读不到扩展/配置（只能看代码）。
        # 使用 $RealAppData（在 VS Code 启动段中已根据 OriginalUserProfile 计算），
        # 而非 $env:APPDATA（提权后可能指向 Administrator）。
        $shortcut.Arguments = "--locale=zh-cn `"$CppWorkspace`" --user-data-dir=`"$RealAppData\Code`""
        $shortcut.WorkingDirectory = $CppWorkspace
        $shortcut.Description = 'FlashTap - 中文 VS Code + 本地 AI + C++ 调试'
        # 图标：默认用 VS Code 自带图标；后期换皮可改为自己的 .ico 路径（全链路开源，无版权问题）
        $iconPath = Join-Path (Split-Path -Parent $vscExe) 'resources\app\resources\win32\code.ico'
        if (-not (Test-Path -LiteralPath $iconPath)) { $iconPath = $vscExe }
        $shortcut.IconLocation = "$iconPath,0"
        $shortcut.Save()
        # 去除快捷方式可能的网络标记（Mark-of-the-Web），避免 Windows 弹"来自网络"安全警告
        try { Unblock-File -Path $lnkPath -ErrorAction SilentlyContinue } catch {}
        Write-Log '[成功] 桌面已创建 FlashTap 快捷方式（打开即用，含全部环境）' 'Green'
    } else {
        Write-Log '[警告] 未找到 VS Code，跳过桌面快捷方式创建' 'Yellow'
    }
} catch {
    Write-Log "[警告] 桌面快捷方式创建失败（不影响使用）: $($_.Exception.Message)" 'Yellow'
}

# ── 第四步半：环境自检（README 步骤10，非阻塞） ──
$checkScript = [System.IO.Path]::Combine($PROJECT_DIR, 'check-environment.ps1')
if (Test-Path -LiteralPath $checkScript) {
    Write-Host ''
    Write-Host '  ────────────────────────────────────────────' -ForegroundColor Cyan
    Write-Host '    环境自检' -ForegroundColor Cyan
    Write-Host '  ────────────────────────────────────────────' -ForegroundColor Cyan
    try {
        # 本应静默运行：用 -WindowStyle Hidden 隐藏窗口执行环境自检，
        # 避免安装结束前又弹出一个可见的 PowerShell 窗口（自检结果已写入日志）。
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$checkScript`"" -Wait
    } catch {
        Write-Log "[警告] 环境自检执行异常: $($_.Exception.Message)" 'Yellow'
    }
} else {
    Write-Log '[信息] 未找到 check-environment.ps1，跳过环境自检' 'Cyan'
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
Write-Host '  F5            启动调试（C/C++ 已预配置，打开桌面 FlashTap 图标进 C++ 示例直接按 F5）' -ForegroundColor White
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
try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { cmd /c pause >nul }

} catch {
    # 全局错误捕获：打印完整错误信息，避免闪退
    Write-Host ''
    Write-Host '════════════════════════════════════════════════════════' -ForegroundColor Red
    Write-Host '  [严重错误] 安装过程中发生异常，流程中断' -ForegroundColor Red
    Write-Host '════════════════════════════════════════════════════════' -ForegroundColor Red
    Write-Host ''
    Write-Host "  错误信息: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "  错误位置: $($_.InvocationInfo.PositionMessage)" -ForegroundColor Yellow
    Write-Host "  脚本行号: $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  完整堆栈:' -ForegroundColor DarkGray
    Write-Host "  $($_.ScriptStackTrace)" -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  请将以上错误信息截图反馈' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '按任意键退出...' -ForegroundColor Cyan
    try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { cmd /c pause >nul }
    $script:installFailed = $true
}
# 退出码反映整体安装结果：0=全部成功, 1=有失败步骤或异常
$finalExitCode = if ($script:installFailed) { 1 } else { 0 }
Write-Log "[信息] 安装器最终退出码: $finalExitCode" 'Cyan'
exit $finalExitCode