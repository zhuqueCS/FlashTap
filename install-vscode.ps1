# FlashTap: VS Code 安装与配置
# 1. 静默安装 VS Code
# 2. 按顺序逐个安装扩展，30秒超时，绝不并发
# 3. settings.json 原封不动复制
# 4. config.yaml 原封不动复制
# 5. 不做其他任何多余操作

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'Continue'

# 获取脚本所在目录（必须最先执行，后续依赖 PROJECT_DIR）
# 通过 cmd /c 调用时 $MyInvocation.MyCommand.Path 可能为空，需要多个兜底
$PROJECT_DIR = $null
try {
    # 方式1：$PSCommandPath（PowerShell 3.0+，最可靠）
    if ($PSCommandPath) {
        $PROJECT_DIR = [System.IO.Path]::GetDirectoryName($PSCommandPath)
    }
}
catch {}
if ($PROJECT_DIR -eq $null -or $PROJECT_DIR -eq "") {
    try {
        # 方式2：$MyInvocation.MyCommand.Path
        if ($MyInvocation -ne $null -and $MyInvocation.MyCommand -ne $null -and $MyInvocation.MyCommand.Path -ne $null) {
            $PROJECT_DIR = [System.IO.Path]::GetDirectoryName($MyInvocation.MyCommand.Path)
        }
    }
    catch {}
}
if ($PROJECT_DIR -eq $null -or $PROJECT_DIR -eq "") {
    try {
        # 方式3：$script:MyInvocation
        if ($script:MyInvocation -ne $null -and $script:MyInvocation.MyCommand -ne $null -and $script:MyInvocation.MyCommand.Path -ne $null) {
            $PROJECT_DIR = [System.IO.Path]::GetDirectoryName($script:MyInvocation.MyCommand.Path)
        }
    }
    catch {}
}
if ($PROJECT_DIR -eq $null -or $PROJECT_DIR -eq "") {
    try {
        # 方式4：当前工作目录兜底
        if ($PWD -ne $null -and $PWD.Path -ne $null) {
            $PROJECT_DIR = $PWD.Path
        }
    }
    catch {}
}
if ($PROJECT_DIR -eq $null -or $PROJECT_DIR -eq "") {
    Write-Host "[错误] 无法获取脚本目录" -ForegroundColor Red
    exit 1
}

# 从文件读取目标用户信息（Start-Process 子进程无法可靠继承环境变量）
# 必须放脚本目录，不要放 %TEMP%——提权后 TEMP 指向不同用户，读不到！
$envFile = Join-Path $PROJECT_DIR '.flashtap-env.txt'
if (Test-Path $envFile) {
    # 必须用 -Encoding UTF8 读取（写入时是 UTF8，中文用户名否则会乱码）
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

# 确保 TLS 1.2 可用（旧版 PowerShell 默认不开启）
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
try { $p = [System.Net.WebRequest]::GetSystemWebProxy(); $p.Credentials = [System.Net.CredentialCache]::DefaultCredentials; [System.Net.WebRequest]::DefaultWebProxy = $p } catch {}

$LOG_FILE = [System.IO.Path]::Combine($PROJECT_DIR, 'vscode-install.log')

$VSCODE_DOWNLOAD_URLS = @(
    'https://update.code.visualstudio.com/latest/win32-x64-user/stable',
    'https://vscode.cdn.azure.cn/stable/488a1f239235055e34e673291fb8d8e7d741a67a/VSCodeUserSetup-x64-1.95.3.exe',
    'https://mirrors.huaweicloud.com/visual-studio-code/1.95.3/VSCodeUserSetup-x64-1.95.3.exe',
    'https://mirrors.tuna.tsinghua.edu.cn/vscode/1.95.3/VSCodeUserSetup-x64-1.95.3.exe'
)

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $LogLine = "[$Timestamp] [$Level] $Message"
    Write-Host $LogLine
    try { Add-Content -Path $LOG_FILE -Value $LogLine -ErrorAction SilentlyContinue } catch {}
}

function Test-Admin {
    $CurrentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $AdminPrincipal = New-Object Security.Principal.WindowsPrincipal($CurrentUser)
    return $AdminPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-RealVSCode {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        # VS Code 二进制至少几 MB
        if ($item.Length -lt 5242880) { return $false }
    } catch {
        return $false
    }
    return $true
}

# 辅助：判断路径是否指向真实存在的 VS Code（即使文件被运行中进程锁定也能判断）
# 优先用目录存在性 + 同目录下 bin\ 或 resources\ 子目录存在性，不依赖 Code.exe 可读
function Test-VSCodeInstalled {
    param([string]$ExePath)
    if ([string]::IsNullOrEmpty($ExePath)) { return $false }
    $dir = Split-Path -Parent $ExePath
    if (-not (Test-Path -LiteralPath $dir)) { return $false }
    # VS Code 安装目录必有 resources\ 子目录（不依赖 Code.exe 是否被锁定）
    $resourcesDir = Join-Path $dir 'resources'
    if (Test-Path -LiteralPath $resourcesDir) { return $true }
    # 兜底：Code.exe 本身可读且够大
    return (Test-RealVSCode -Path $ExePath)
}

function Invoke-RobustDownload {
    param([string]$Url, [string]$OutFile)

    Write-Log "[信息] 正在下载 VS Code: $Url"

    # 移除旧文件
    if (Test-Path $OutFile) { Remove-Item $OutFile -Force }

    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Timeout = 60000          # 连接超时 60 秒（虚拟机网络慢）
        $req.ReadWriteTimeout = 120000 # 读写间隔超时 120 秒
        $req.AllowAutoRedirect = $true
        $resp = $req.GetResponse()
        $totalBytes = $resp.ContentLength
        $respStream = $resp.GetResponseStream()
        $fs = [System.IO.File]::Create($OutFile)
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
            if (((Get-Date) - $lastRead).TotalSeconds -gt 60) {
                throw '下载卡死，60秒无数据'
            }
        }
        $fs.Close()
        $respStream.Close()
        $resp.Close()
        Write-Host ''

        $outItem = Get-Item -LiteralPath $OutFile -ErrorAction Stop
        if ($outItem.Length -gt 10MB) {
            Write-Log "[信息] 下载完成: $([math]::Round($outItem.Length / 1MB, 0)) MB"
            return $true
        }
        Write-Log "[警告] 下载文件异常（$($outItem.Length) 字节）"
        if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
        return $false
    } catch {
        Write-Host ''
        Write-Log "[警告] 下载失败: $($_.Exception.Message)"
        if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
        return $false
    }
}

function Install-VSCode {
    # 空白账户隔离模式：忽略系统级 VS Code，强制为当前账户安装用户级副本
    $userScopeOnly = ($env:FLASHTAP_USER_SCOPE_ONLY -eq 'true')
    if ($userScopeOnly) {
        Write-Log '[信息] 空白账户隔离模式：忽略系统级 VS Code，将为当前账户安装用户级副本'
    } else {
        Write-Log '[信息] 检查是否已有可用的 VS Code（优先用户级，其次系统级只复用）...'
    }

    # 候选路径：先用户级，再系统级
    $userCandidates = @(
        [System.IO.Path]::Combine($env:LOCALAPPDATA, 'Programs\Microsoft VS Code\Code.exe'),
        [System.IO.Path]::Combine($env:USERPROFILE, 'AppData\Local\Programs\Microsoft VS Code\Code.exe')
    )
    $systemCandidates = @()
    if (-not $userScopeOnly) {
        # 非隔离模式才查系统级
        $systemCandidates = @(
            [System.IO.Path]::Combine($env:ProgramFiles, 'Microsoft VS Code\Code.exe'),
            [System.IO.Path]::Combine([Environment]::GetEnvironmentVariable("ProgramFiles(x86)"), 'Microsoft VS Code\Code.exe')
        )
        if ($env:ProgramW6432) {
            $systemCandidates += [System.IO.Path]::Combine($env:ProgramW6432, 'Microsoft VS Code\Code.exe')
        }
    }

    # 注册表查找：隔离模式只查 HKCU，非隔离模式查 HKCU + HKLM
    $regRoots = @(
        @{Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'; Scope = 'user'}
    )
    if (-not $userScopeOnly) {
        $regRoots += @{Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'; Scope = 'system'}
        $regRoots += @{Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'; Scope = 'system'}
    }
    foreach ($regRoot in $regRoots) {
        try {
            $entries = Get-ItemProperty -Path $regRoot.Path -ErrorAction SilentlyContinue
            foreach ($entry in $entries) {
                if ($entry.DisplayName -like '*Visual Studio Code*' -and $entry.UninstallString) {
                    $uninstStr = $entry.UninstallString -replace '^"', '' -replace '"$', ''
                    $instDir = Split-Path -Parent $uninstStr
                    $codeExe = Join-Path $instDir 'Code.exe'
                    if ($codeExe.StartsWith($env:USERPROFILE, [System.StringComparison]::OrdinalIgnoreCase)) {
                        if ($codeExe -notin $userCandidates) { $userCandidates += $codeExe }
                        Write-Log "[信息] 用户级注册表找到: $instDir"
                    } else {
                        # VS Code 装在非用户目录（如 D: 盘等非默认位置）：按系统级候选复用，
                        # 不再强求注册表根必须是 HKLM（User 版安装器常把路径写在 HKCU 但装在别的盘）
                        if ($codeExe -notin $systemCandidates) { $systemCandidates += $codeExe }
                        Write-Log "[信息] 注册表找到(非用户目录，按系统级复用): $instDir"
                    }
                }
            }
        } catch {}
    }

    # 辅助：从候选路径提取 code.cmd
    $getCmdPath = {
        param([string]$exePath)
        $binDir = Split-Path -Parent $exePath
        $cmdPath = [System.IO.Path]::Combine($binDir, 'bin\code.cmd')
        if (-not (Test-Path $cmdPath)) {
            $cmdPath = [System.IO.Path]::Combine($binDir, 'code.cmd')
        }
        if (Test-Path $cmdPath) { return $cmdPath }
        return $exePath
    }

    # 优先级 1：用户级 VS Code（直接复用）
    foreach ($cand in $userCandidates) {
        if (Test-VSCodeInstalled -ExePath $cand) {
            Write-Log "[信息] 复用用户级 VS Code: $cand"
            return & $getCmdPath $cand
        }
    }

    # 优先级 2：系统级 VS Code（只复用，不重装 —— 避免与运行中进程冲突导致退出码 5）
    foreach ($cand in $systemCandidates) {
        if (Test-VSCodeInstalled -ExePath $cand) {
            Write-Log "[信息] 复用系统级 VS Code: $cand（不重装，直接配置扩展）"
            return & $getCmdPath $cand
        }
    }

    # ── 致命安全锁：如果注册表里有任何 VS Code 记录，但上面没复用到（可能 Code.exe 被锁），
    # 绝不重装！重装会损坏正在运行的 VS Code。改为直接用注册表里的路径返回 code.cmd。
    # 隔离模式下只检查用户级候选，不检查系统级
    if ($userCandidates.Count -gt 0 -or (-not $userScopeOnly -and $systemCandidates.Count -gt 0)) {
        $allCandidates = @($userCandidates)
        if (-not $userScopeOnly) { $allCandidates += $systemCandidates }
        # 只返回真实存在的路径：优先 code.cmd，其次 Code.exe。
        # 绝不返回不存在的死路径（旧逻辑会返回 $allCandidates[0] 导致后续 Test-Path 抛异常）。
        foreach ($cand in $allCandidates) {
            $binDir = Split-Path -Parent $cand
            $cmdPath = Join-Path $binDir 'bin\code.cmd'
            $codeExe = Join-Path $binDir 'Code.exe'
            if (Test-Path -LiteralPath $cmdPath) {
                Write-Log "[信息] VS Code 已安装（注册表确认），复用 code.cmd: $cmdPath"
                return $cmdPath
            }
            if (Test-Path -LiteralPath $codeExe) {
                Write-Log "[信息] VS Code 已安装（注册表确认），复用 Code.exe: $codeExe"
                return $codeExe
            }
        }
        # 所有候选路径都不存在（注册表残留/损坏）：不返回死路径，交由后续最终安全锁处理
        Write-Log '[警告] 注册表报告了 VS Code 但所有候选路径均不存在，将按损坏处理' 'WARNING'
    }

    Write-Log '[信息] 目标用户无 VS Code，开始下载安装...'

    # ── 最终安全锁：再次注册表扫描，只要有任何 VS Code 就绝不安装 ──
    # 隔离模式下只扫 HKCU（用户级），非隔离模式扫 HKCU + HKLM
    $anyVSCodeFound = $false
    $finalCheckRegRoots = @(
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    if (-not $userScopeOnly) {
        $finalCheckRegRoots += 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        $finalCheckRegRoots += 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    }
    foreach ($regRoot in $finalCheckRegRoots) {
        try {
            $entries = Get-ItemProperty -Path $regRoot -ErrorAction SilentlyContinue
            foreach ($entry in $entries) {
                if ($entry.DisplayName -like '*Visual Studio Code*') {
                    $anyVSCodeFound = $true
                    Write-Log "[警告] 最终安全锁：注册表发现已安装的 VS Code（$($entry.DisplayName)），中止安装以防损坏" 'Yellow'
                    # 直接复用，不安装
                    $uninstStr = $entry.UninstallString -replace '^"', '' -replace '"$', ''
                    if ($uninstStr) {
                        $instDir = Split-Path -Parent $uninstStr
                        $codeExe = Join-Path $instDir 'Code.exe'
                        $cmdPath = Join-Path $instDir 'bin\code.cmd'
                        if (Test-Path -LiteralPath $cmdPath) { return $cmdPath }
                        if (Test-Path -LiteralPath $codeExe) { return $codeExe }
                    }
                    break
                }
            }
        } catch {}
        if ($anyVSCodeFound) { break }
    }
    if ($anyVSCodeFound) {
        # 注册表有但找不到可执行文件，说明 VS Code 损坏，但不能由 FlashTap 重装（用户自己处理）
        Write-Log '[错误] 检测到 VS Code 已安装但可执行文件缺失，请用户手动重装 VS Code，FlashTap 不会自动重装' 'Red'
        throw '检测到已安装的 VS Code 但可执行文件缺失，为安全起见中止安装，请手动处理 VS Code 后重试'
    }

    $installerPath = [System.IO.Path]::Combine($env:TEMP, 'VSCodeUserSetup-x64-latest.exe')

    # ── 强制清理：删除可能损坏的旧安装器和残留（之前失败安装留下的）──
    # 这些残留会导致新的安装器解压出损坏的 dll 报错
    try {
        Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
        # 清理 VS Code 安装日志
        Remove-Item -LiteralPath (Join-Path $env:TEMP 'vscode-install-log.log') -Force -ErrorAction SilentlyContinue
    } catch {}

    # 校验已有安装器是否完整（VS Code 安装器约 90MB+）
    $installerValid = $false

    # 本地优先：离线包场景，打包目录已含 VS Code 安装器则直接复用，零网络
    $localVSCode = Join-Path $PROJECT_DIR 'VSCodeUserSetup-x64-latest.exe'
    if (Test-Path $localVSCode) {
        try {
            $lb = [System.IO.File]::ReadAllBytes($localVSCode)
            if ($lb.Length -gt 80MB -and $lb[0] -eq 0x4D -and $lb[1] -eq 0x5A) {
                Unblock-File -Path $localVSCode -ErrorAction SilentlyContinue
                Write-Log "[信息] 使用本地 VS Code 安装器（离线）: $localVSCode"
                $installerPath = $localVSCode
                $installerValid = $true
            } else {
                Write-Log '[警告] 本地 VS Code 安装器无效，改用在线下载' 'Yellow'
            }
        } catch {
            Write-Log '[警告] 本地 VS Code 安装器读取失败，改用在线下载' 'Yellow'
        }
    }

    if (Test-Path $installerPath) {
        $item = Get-Item -LiteralPath $installerPath -ErrorAction SilentlyContinue
        if ($item -and $item.Length -gt 80MB) {
            # PE 文件头校验
            try {
                $bytes = New-Object byte[] 2
                $fs = [System.IO.File]::OpenRead($installerPath)
                $read = $fs.Read($bytes, 0, 2)
                $fs.Close()
                if ($read -eq 2 -and $bytes[0] -eq 0x4D -and $bytes[1] -eq 0x5A) {
                    $installerValid = $true
                    Write-Log "[信息] 安装器已存在且有效 ($([math]::Round($item.Length / 1MB, 0)) MB)，跳过下载"
                } else {
                    Write-Log '[警告] 安装器 PE 头校验失败，删除残骸重新下载'
                }
            } catch {
                Write-Log '[警告] 安装器校验出错，删除残骸重新下载'
            }
        } else {
            Write-Log "[警告] 安装器文件不完整 ($(if ($item) { $item.Length } else { 0 }) 字节)，删除残骸重新下载"
        }
        if (-not $installerValid) {
            Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not $installerValid) {
        $ok = $false
        foreach ($url in $VSCODE_DOWNLOAD_URLS) {
            if (Invoke-RobustDownload -Url $url -OutFile $installerPath) {
                $ok = $true
                break
            }
        }
        if (-not $ok) {
            throw "无法下载 VS Code 安装器，请检查网络连接"
        }
    }

    Write-Log '[信息] 正在静默安装 VS Code（最长等待 10 分钟）...'
    Write-Log "[信息] 安装器路径: $installerPath"

    # 安装前检查是否有 VS Code 进程在运行
    # 注意：走到这里说明注册表里没有 VS Code，如果有 Code 进程说明状态异常
    # 此时绝不杀进程（可能属于其他用户/其他用途），只警告
    $codeList = @(Get-Process -Name 'Code' -ErrorAction SilentlyContinue)
    if ($codeList.Count -gt 0) {
        Write-Log "[警告] 检测到 $($codeList.Count) 个 VS Code 进程在运行，但注册表无 VS Code 记录" 'Yellow'
        Write-Log '[信息] 不杀进程（可能属于其他用户/其他用途），安装器自带 /closeapplications 会处理冲突' 'Yellow'
    }

    # very silent + no restart + don't run after install + close applications
    $installLog = [System.IO.Path]::Combine($env:TEMP, 'vscode-install-log.log')
    try {
        # 解除 Mark-of-the-Web，防止空白机 SmartScreen/Defender 拦截静默安装导致卡死
        Unblock-File -Path $installerPath -ErrorAction SilentlyContinue
        $process = Start-Process -FilePath $installerPath -ArgumentList '/verysilent', '/norestart', '/mergetasks=!runcode', '/closeapplications', "/LOG=`"$installLog`"" -PassThru
        $finished = $process.WaitForExit(600000)
        if (-not $finished) {
            Write-Log '[错误] VS Code 安装超时，强制终止'
            $process.Kill()
            throw 'VS Code 安装 10 分钟未完成，请检查安装包或网络'
        }
        $ec = $process.ExitCode
    }
    catch {
        throw "VS Code 安装程序运行失败: $($_.Exception.Message)"
    }

    if ($ec -ne 0) {
        Write-Log "[错误] VS Code 安装失败，退出码: $ec" 'ERROR'
        if (Test-Path $installLog) {
            $logContent = Get-Content $installLog -Raw -ErrorAction SilentlyContinue
            if ($logContent -match '.*Error.*|failed|aborted') {
                Write-Log "[错误] 安装日志包含错误信息:" 'ERROR'
                Write-Log $logContent 'ERROR'
            }
        }
        throw "VS Code 安装失败（错误 $ec）"
    }

    Write-Log '[成功] VS Code 安装完成'

    # 重新查找安装好的 VS Code
    # 注意：$vscCandidates 由前文 userCandidates + systemCandidates 组成，
    # 两者在此函数作用域内始终有效（未提前 return 即走到了新安装路径）
    Start-Sleep -Seconds 2
    $vscCandidates = @($userCandidates) + @($systemCandidates)
    foreach ($cand in $vscCandidates) {
        if (Test-RealVSCode -Path $cand) {
            $binDir = Split-Path -Parent $cand
            $cmdPath = [System.IO.Path]::Combine($binDir, 'bin\code.cmd')
            if (-not (Test-Path $cmdPath)) {
                $cmdPath = [System.IO.Path]::Combine($binDir, 'code.cmd')
            }
            if (Test-Path $cmdPath) {
                Write-Log "[信息] 找到安装后的 code.cmd: $cmdPath"
                return $cmdPath
            }
            return $cand
        }
    }

    $userVSCodeExe = [System.IO.Path]::Combine($env:LOCALAPPDATA, 'Programs\Microsoft VS Code\Code.exe')
    if (Test-RealVSCode -Path $userVSCodeExe) {
        $binDir = Split-Path -Parent $userVSCodeExe
        $cmdPath = [System.IO.Path]::Combine($binDir, 'bin\code.cmd')
        if (-not (Test-Path $cmdPath)) {
            $cmdPath = [System.IO.Path]::Combine($binDir, 'code.cmd')
        }
        if (Test-Path $cmdPath) {
            return $cmdPath
        }
        return $userVSCodeExe
    }

    throw 'VS Code 安装后未找到可执行文件，请手动安装'
}

function Install-VSCode-WithRetry {
    $maxRetries = 2
    for ($i = 0; $i -le $maxRetries; $i++) {
        try {
            $cmd = Install-VSCode
            return $cmd
        } catch {
            Write-Log "[警告] VS Code 安装失败（第 $($i+1)/$($maxRetries+1) 次）: $($_.Exception.Message)" 'WARNING'
            if ($i -lt $maxRetries) {
                Start-Sleep -Seconds 5
            }
        }
    }
    throw 'VS Code 安装多次失败，请检查网络后重试'
}

# ── 扩展白名单（Windows + MinGW 路线，仅 3 个）──
# 说明：WSL 路线才需要 ms-vscode-remote.remote-wsl，本路线不装；
#       ms-vscode.cpptools 也不在白名单——Windows 路线用 MinGW 的 gdb/gcc，无需 cpptools
$EXTENSION_WHITELIST = @(
    'continue.continue',
    'ms-ceintl.vscode-language-pack-zh-hans',
    'formulahendry.code-runner'
)

# 辅助：检查扩展是否已安装（通过目录存在性判定，不依赖 code --install-extension 的退出码）
function Test-ExtensionInstalled {
    param([string]$ExtensionId, [string]$ExtRoot)
    if (-not (Test-Path -LiteralPath $ExtRoot)) { return $false }
    try {
        $found = @(Get-ChildItem -Path $ExtRoot -Directory -Filter "$ExtensionId-*" -ErrorAction SilentlyContinue)
        return ($found.Count -gt 0)
    } catch {
        return $false
    }
}

# 验证 Continue 扩展是否包含当前平台的原生二进制（Windows/Linux/macOS）。
# Continue 依赖 ONNX Runtime 原生库，若 .vsix 缺少对应平台的 bin/ 目录，
# 扩展虽安装成功但激活时会崩溃。此函数防止离线 .vsix 跨平台不兼容。
function Test-ContinuePlatformValid {
    param([string]$ExtRoot)
    try {
        $continueDirs = @(Get-ChildItem -Path $ExtRoot -Directory -Filter 'continue.continue-*' -ErrorAction SilentlyContinue)
        if ($continueDirs.Count -eq 0) { return $true }  # 未安装，不作判断
        $latest = $continueDirs | Sort-Object Name -Descending | Select-Object -First 1
        # Continue v2.1+ 原生库在 bin/napi-v3/<platform>/<arch>/
        # 非 Windows 平台（Linux/macOS）也会检查对应架构
        $winBin = Join-Path $latest.FullName 'bin\napi-v3\win32'
        $linuxBin = Join-Path $latest.FullName 'bin\napi-v3\linux'
        $darwinBin = Join-Path $latest.FullName 'bin\napi-v3\darwin'
        if ($IsWindows -or (-not $IsLinux -and -not $IsMacOS)) {
            # Windows: 必须有 win32 目录
            return (Test-Path -LiteralPath $winBin)
        } elseif ($IsLinux) {
            return (Test-Path -LiteralPath $linuxBin)
        } elseif ($IsMacOS) {
            return (Test-Path -LiteralPath $darwinBin)
        }
        return $false
    } catch {
        return $false
    }
}

# 辅助：通过 code CLI 安装扩展，带 120s 超时保护（防止 marketplace 不可达时无限挂起）
# 注意：参数必须以【数组】传入并用 @a 展开，否则 & $c $a 会把整串当作单个参数传给 code，导致安装静默失败。
function Invoke-CodeInstall {
    param([string]$CliCmd, [string[]]$Arguments)
    # R1/R4 加固：显式指定目标用户 user-data-dir，确保扩展装到目标用户目录，
    # 不受提权进程 SID 影响（否则跨账户 UAC 提权时扩展落到管理员账户，真实用户读不到→只能看代码）。
    # $env:APPDATA 在本脚本开头已重定义为目标用户（见 73 行），故指向真实运行用户。
    $userDataDir = Join-Path $env:APPDATA 'Code'
    $allArgs = $Arguments + @("--user-data-dir=$userDataDir")
    # (,$allArgs) 用一元逗号把数组包成单元素，避免 Start-Job -ArgumentList 把数组展平成多个 param
    $job = Start-Job -ScriptBlock { param($c, $a) & $c @a 2>&1 } -ArgumentList $CliCmd, (, $allArgs)
    if ($job | Wait-Job -Timeout 120) {
        $null = Receive-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
    } else {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        throw 'code install timed out (120s)'
    }
}

# 辅助：从国内镜像 open-vsx.org 下载扩展的 .vsix 到本地
# 返回 $true 表示成功拿到有效 vsix（magic=PK），否则 $false
function Get-OpenVsxVsix {
    param([string]$ExtensionId, [string]$OutPath)
    try {
        $parts = $ExtensionId.Split('.')
        if ($parts.Count -lt 2) { return $false }
        $pub = $parts[0]; $name = $parts[1]
        [Net.ServicePointManager]::SecurityProtocol = 'Tls12,Tls11,Tls'
        $body = '{"filters":[{"criteria":[{"filterType":7,"value":"' + $ExtensionId + '"}]}],"flags":2151,"assetTypes":["Microsoft.VisualStudio.Code.Manifest","Microsoft.VisualStudio.Services.VSIXPackage"]}'
        $r = Invoke-WebRequest -Uri 'https://open-vsx.org/vscode/gallery/extensionquery' -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 25 -UseBasicParsing -ErrorAction Stop
        $j = $r.Content | ConvertFrom-Json
        $ext = $j.results[0].extensions[0]
        if ($ext -eq $null -or $ext.versions -eq $null -or $ext.versions.Count -eq 0) { return $false }
        $ver = $ext.versions[0].version
        if ([string]::IsNullOrEmpty($ver)) { return $false }
        $dl = "https://open-vsx.org/vscode/gallery/publishers/$pub/vsextensions/$name/$ver/vspackage"
        Invoke-WebRequest -Uri $dl -OutFile $OutPath -TimeoutSec 120 -MaximumRedirection 10 -UseBasicParsing -ErrorAction Stop
        $bytes = [System.IO.File]::ReadAllBytes($OutPath)
        if ($bytes.Length -gt 2 -and $bytes[0] -eq 80 -and $bytes[1] -eq 75) { return $true }
        return $false
    } catch {
        return $false
    }
}

# 1. 扩展安装：逐个安装。
#    主路径：marketplace（code --install-extension，VS Code 自带 Node 客户端，国内通常可用）
#    兜底路径：国内镜像 open-vsx.org 直链下载 .vsix 后本地安装（解决 marketplace 在部分国内网络被墙的问题）
#    通过检查扩展目录真实存在来判定成功，不依赖退出码。
function Install-All-Extensions {
    param([string]$VSCodeCmd = 'code')
    Write-Log '[信息] 正在安装 VS Code 扩展...'

    # 确保通过 code.cmd 执行（CLI 模式，不弹出 VS Code 窗口）
    $cliCmd = $VSCodeCmd
    if ($cliCmd -match '\\Code\.exe$') {
        $parentDir = Split-Path -Parent $cliCmd
        $candidate = Join-Path $parentDir 'bin\code.cmd'
        if (-not (Test-Path $candidate)) {
            $candidate = Join-Path $parentDir 'code.cmd'
        }
        if (Test-Path $candidate) {
            $cliCmd = $candidate
        }
    }

    # 预检：code CLI 是否可用（30s 超时保护，防止用户数据未初始化时挂死）
    try {
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo.FileName = $cliCmd
        $proc.StartInfo.Arguments = '--version'
        $proc.StartInfo.UseShellExecute = $false
        $proc.StartInfo.RedirectStandardOutput = $true
        $proc.StartInfo.RedirectStandardError = $true
        $proc.StartInfo.CreateNoWindow = $true
        $proc.Start() | Out-Null
        $proc.WaitForExit(30000) | Out-Null
        if ($proc.HasExited) {
            $codeVer = $proc.StandardOutput.ReadToEnd().Split("`n") | Where-Object { $_ -ne '' }
            $stderr = $proc.StandardError.ReadToEnd()
            if ($proc.ExitCode -ne 0) {
                Write-Log "[警告] code CLI 不可用，扩展安装将跳过: $stderr" 'WARNING'
                return $false
            }
            Write-Log "[信息] code CLI 就绪: $($codeVer[0])" 'INFO'
        } else {
            $proc.Kill()
            Write-Log "[警告] code CLI 超时无响应（30s），扩展安装将跳过" 'WARNING'
            return $false
        }
        $proc.Dispose()
    } catch {
        Write-Log "[警告] code CLI 调用失败，扩展安装将跳过: $($_.Exception.Message)" 'WARNING'
        return $false
    }

    $extRoot = [System.IO.Path]::Combine($env:USERPROFILE, '.vscode', 'extensions')
    $successCount = 0
    $failCount = 0
    $errorLog = @()

    foreach ($extId in $EXTENSION_WHITELIST) {
        $installed = $false

        # 本地优先：离线包场景，打包目录存在 <extId>.vsix 则直接离线安装，零网络
        $localVsix = Join-Path $PROJECT_DIR ($extId + '.vsix')
        if (Test-Path $localVsix) {
            try {
                Unblock-File -Path $localVsix -ErrorAction SilentlyContinue
                Write-Log "[信息] 发现本地扩展包，离线安装: $extId"
                Invoke-CodeInstall -CliCmd $cliCmd -Arguments @('--install-extension', $localVsix, '--force')
                if (Test-ExtensionInstalled -ExtensionId $extId -ExtRoot $extRoot) {
                    # Continue 专项检查：验证离线 .vsix 包含当前平台原生库
                    # 常见陷阱：.vsix 只有 Linux 二进制却装到 Windows上 → 激活报错
                    if ($extId -eq 'continue.continue' -and -not (Test-ContinuePlatformValid -ExtRoot $extRoot)) {
                        Write-Log '[警告] 离线 Continue .vsix 缺少当前平台原生库（如 win32），将回退在线安装' 'Yellow'
                        # 清理残废的离线安装，避免阻塞后续在线安装
                        $badDirs = @(Get-ChildItem -Path $extRoot -Directory -Filter 'continue.continue-*' -ErrorAction SilentlyContinue)
                        foreach ($d in $badDirs) { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue }
                        # $installed 保持 $false，触发下方在线安装回退
                    } else {
                        Write-Log "[成功] 本地扩展安装成功: $extId" 'Green'
                        $successCount++; $installed = $true
                    }
                } else {
                    Write-Log '[警告] 本地扩展安装后校验失败，回退在线安装' 'Yellow'
                }
            } catch {
                Write-Log '[警告] 本地扩展安装异常，回退在线安装' 'Yellow'
            }
        }
        if ($installed) { continue }

        # ── 主路径：marketplace（最多 3 次）──
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                Invoke-CodeInstall -CliCmd $cliCmd -Arguments @('--install-extension', $extId, '--force')
            } catch {
                # 超时或异常，忽略，后续通过目录存在性判定
            }
            Start-Sleep -Seconds 1
            if (Test-ExtensionInstalled -ExtensionId $extId -ExtRoot $extRoot) {
                Write-Log "  [成功] $extId (marketplace)" 'INFO'
                $successCount++; $installed = $true; break
            }
            if ($attempt -lt 3) {
                Write-Log "  [信息] ${extId} marketplace 第 $attempt 次未检测到，重试..." 'WARNING'
                Start-Sleep -Seconds 2
            }
        }

        # ── 兜底路径：国内镜像 open-vsx 直链下载 vsix 后本地安装 ──
        if (-not $installed) {
            Write-Log "  [信息] ${extId} 主路径失败，尝试国内镜像 open-vsx 兜底..." 'WARNING'
            $tmpVsix = Join-Path $env:TEMP ($extId.Replace('.', '_') + '.vsix')
            if (Get-OpenVsxVsix -ExtensionId $extId -OutPath $tmpVsix) {
                try {
                    Invoke-CodeInstall -CliCmd $cliCmd -Arguments @('--install-extension', $tmpVsix, '--force')
                } catch {}
                Start-Sleep -Seconds 1
                if (Test-ExtensionInstalled -ExtensionId $extId -ExtRoot $extRoot) {
                    Write-Log "  [成功] $extId (open-vsx 国内镜像)" 'INFO'
                    $successCount++; $installed = $true
                } else {
                    Write-Log "  [错误] ${extId} (marketplace 与 open-vsx 本地安装均未成功)" 'ERROR'
                    $errorLog += $extId
                }
            } else {
                Write-Log "  [错误] ${extId} (marketplace 失败，且 open-vsx 无此扩展或不可达)" 'ERROR'
                $errorLog += $extId
            }
            if (Test-Path $tmpVsix) { Remove-Item $tmpVsix -Force -ErrorAction SilentlyContinue }
        }

        if (-not $installed) { $failCount++ }
    }

    if ($errorLog.Count -gt 0) {
        Write-Log "[警告] 安装失败的扩展: $($errorLog -join ', ')" 'WARNING'
    }

    Write-Log "[信息] 扩展安装结果: 成功 $successCount 个 / 失败 $failCount 个"
    return ($failCount -eq 0)
}

# 1b. 扩展清理：已禁用
# 原实现会卸载用户已有的全部非白名单扩展（CodeGeeX/Copilot/FittenCode 等），
# 对在用 VS Code 做开发的用户是灾难性破坏。FlashTap 只应【新增】自己需要的扩展，
# 绝不应该删除用户已有的任何扩展。如需清理，由用户自己在 VS Code 内手动操作。
function Remove-NonWhitelistExtensions {
    Write-Log '[信息] 扩展清理已禁用（保护用户已有扩展不被误删）' 'INFO'
}

# 2. 原封不动复制 settings.json 到 VS Code 用户配置
function Copy-SettingsJson {
    Write-Log '[信息] 正在同步 settings.json 配置文件...'

    $srcPath = [System.IO.Path]::Combine($PROJECT_DIR, 'settings.json')
    if (-not (Test-Path -LiteralPath $srcPath)) {
        throw "找不到源 settings.json: $srcPath"
    }

    # VS Code 用户配置目录：%APPDATA%\Code\User\settings.json
    $targetDir = [System.IO.Path]::Combine($env:APPDATA, 'Code', 'User')
    $targetPath = [System.IO.Path]::Combine($targetDir, 'settings.json')

    # 创建目录
    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        Write-Log "[信息] 已创建目录: $targetDir"
    }

    # 备份已有配置
    if (Test-Path -LiteralPath $targetPath) {
        $backup = "$targetPath.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item -LiteralPath $targetPath -Destination $backup -Force -ErrorAction Stop
        Write-Log "[信息] 已备份现有配置到: $backup"
    }

    # 纯搬运：直接复制，不修改任何字节
    Copy-Item -LiteralPath $srcPath -Destination $targetPath -Force -ErrorAction Stop
    Write-Log "[成功] settings.json 已复制到: $targetPath" 'INFO'

    return $true
}

# 2b. 写入 locale.json，确保中文语言包安装后 VS Code 首次启动就是中文界面
function Write-LocaleJson {
    Write-Log '[信息] 正在写入语言区域配置...'

    $targetDir = [System.IO.Path]::Combine($env:APPDATA, 'Code', 'User')
    $targetPath = [System.IO.Path]::Combine($targetDir, 'locale.json')

    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    $localeContent = '{"locale":"zh-cn"}'
    try {
        Set-Content -LiteralPath $targetPath -Value $localeContent -Encoding UTF8 -Force
        Write-Log "[成功] locale.json 已写入: $targetPath" 'INFO'
    } catch {
        Write-Log "[警告] locale.json 写入失败: $($_.Exception.Message)" 'WARNING'
    }
}

# 3. 复制 Continue 配置文件（config.json + config.yaml）
function Copy-ContinueConfig {
    Write-Log '[信息] 正在同步 Continue 配置文件...'

    $continueDir = [System.IO.Path]::Combine($env:USERPROFILE, '.continue')

    if (-not (Test-Path $continueDir)) {
        New-Item -ItemType Directory -Path $continueDir -Force | Out-Null
        Write-Log "[信息] 已创建 Continue 目录: $continueDir"
    }

    $allOk = $true
    $configFiles = @('config.json', 'config.yaml', 'config.ts')

    foreach ($cfgName in $configFiles) {
        $srcPath = [System.IO.Path]::Combine($PROJECT_DIR, $cfgName)
        $targetPath = [System.IO.Path]::Combine($continueDir, $cfgName)

        if (-not (Test-Path -LiteralPath $srcPath)) {
            Write-Log "  [信息] 跳过 $cfgName（源文件不存在）"
            continue
        }

        # 备份已有配置
        if (Test-Path -LiteralPath $targetPath) {
            $backup = "$targetPath.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Copy-Item -LiteralPath $targetPath -Destination $backup -Force -ErrorAction Stop
            Write-Log "  [信息] 已备份 $cfgName 到: $backup"
        }

        # 复制
        Copy-Item -LiteralPath $srcPath -Destination $targetPath -Force -ErrorAction Stop
        Write-Log "  [成功] $cfgName 已复制到: $targetPath"
    }

    return $allOk
}

# 2c. 语言包自愈：确保中文语言包已安装且未被 VS Code 因版本不兼容而禁用。
# 若被禁用（engines 不匹配当前 VS Code），则重装匹配版本，彻底杜绝“界面英文”问题。
function Repair-LanguagePack {
    param([string]$CliCmd, [string]$ExtRoot)
    $extId = 'ms-ceintl.vscode-language-pack-zh-hans'
    $extJson = Join-Path $ExtRoot 'extensions.json'
    $disabled = $false
    $disabledReason = ''
    if (Test-Path -LiteralPath $extJson) {
        try {
            $j = Get-Content -LiteralPath $extJson -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($e in $j) {
                if ($e.identifier -and $e.identifier.id -like "$extId*") {
                    if ($e.disabled) {
                        $disabled = $true
                        $disabledReason = ($e.disabled | ConvertTo-Json -Compress)
                    }
                }
            }
        } catch {}
    }
    if (-not $disabled -and (Test-ExtensionInstalled -ExtensionId $extId -ExtRoot $ExtRoot)) {
        Write-Log '[成功] 中文语言包已安装且启用（版本与 VS Code 兼容）' 'INFO'
        return $true
    }
    if (-not $disabled) {
        Write-Log '[警告] 未检测到中文语言包目录，尝试重新安装' 'WARNING'
    } else {
        Write-Log "[警告] 中文语言包被 VS Code 禁用（疑似版本不兼容）：$disabledReason" 'WARNING'
        Write-Log '[信息] 尝试重新安装与当前 VS Code 版本匹配的语言包...' 'INFO'
    }
    # 主路径：marketplace 重装最新（通常与最新 VS Code 匹配）
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try { Invoke-CodeInstall -CliCmd $CliCmd -Arguments @('--install-extension', $extId, '--force') } catch {}
        Start-Sleep -Seconds 1
        $stillDisabled = $false
        if (Test-Path -LiteralPath $extJson) {
            try {
                $j2 = Get-Content -LiteralPath $extJson -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($e2 in $j2) {
                    if ($e2.identifier -and $e2.identifier.id -like "$extId*" -and $e2.disabled) { $stillDisabled = $true }
                }
            } catch {}
        }
        if ((Test-ExtensionInstalled -ExtensionId $extId -ExtRoot $ExtRoot) -and -not $stillDisabled) {
            Write-Log '[成功] 中文语言包已重装并启用' 'INFO'
            return $true
        }
        if ($attempt -lt 3) { Start-Sleep -Seconds 2 }
    }
    # 兜底：国内镜像 open-vsx 直链
    $tmpVsix = Join-Path $env:TEMP ($extId.Replace('.', '_') + '.vsix')
    if (Get-OpenVsxVsix -ExtensionId $extId -OutPath $tmpVsix) {
        try { Invoke-CodeInstall -CliCmd $CliCmd -Arguments @('--install-extension', $tmpVsix, '--force') } catch {}
        Start-Sleep -Seconds 1
    }
    if (Test-Path -LiteralPath $tmpVsix) { Remove-Item -LiteralPath $tmpVsix -Force -ErrorAction SilentlyContinue }
    $ok = Test-ExtensionInstalled -ExtensionId $extId -ExtRoot $ExtRoot
    if ($ok) { Write-Log '[成功] 中文语言包经国内镜像修复完成' 'INFO' } else { Write-Log '[错误] 中文语言包修复失败，界面可能为英文' 'ERROR' }
    return $ok
}

# ── Main ──
function Main {
    # Step 1: 安装 VS Code（或找到已安装）
    $codeCmd = Install-VSCode-WithRetry
    Write-Log "[信息] VS Code: $codeCmd"

    # 验证返回的路径真实存在（防止返回无效路径导致后续扩展安装失败）
    if (-not $codeCmd -or -not (Test-Path -LiteralPath $codeCmd)) {
        throw "VS Code 安装后路径无效或不存在: $codeCmd"
    }
    Write-Log "[成功] VS Code 路径验证通过" 'INFO'

    # Step 2: 安装白名单扩展（5个，逐个安装，60s超时，重试2次）
    $extSuccess = Install-All-Extensions -VSCodeCmd $codeCmd

    # Step 2c: 语言包自愈（防版本不兼容导致英文界面）
    $extRoot = [System.IO.Path]::Combine($env:USERPROFILE, '.vscode', 'extensions')
    Repair-LanguagePack -CliCmd $codeCmd -ExtRoot $extRoot

    # Step 2b: 清理非白名单扩展
    Remove-NonWhitelistExtensions -VSCodeCmd $codeCmd

    # Step 3: 复制 settings.json 原封不动
    Copy-SettingsJson

    # Step 3b: 写入 locale.json（VS Code 1.90+ 通过此文件决定显示语言）
    Write-LocaleJson

    # Step 4: 复制 Continue config.yaml 原封不动
    $continueSuccess = Copy-ContinueConfig

    Write-Log '[成功] VS Code 配置完成' 'INFO'

    return @{
        CodeCmd = $codeCmd
        ExtSuccess = $extSuccess
        ContinueSuccess = $continueSuccess
    }
}

# 直接执行，返回结果供 Setup-FlashTap.ps1 调用
$mainResult = Main
if (-not $mainResult.ExtSuccess) {
    Write-Log '[警告] 部分扩展安装失败，请检查上方日志' 'WARNING'
    exit 2
}
exit 0