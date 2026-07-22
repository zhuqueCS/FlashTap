# FlashTap: C++ 编译环境自动配置
# 优先级：系统 g++ > WSL发行版(自动安装编译工具) > 手动安装提示
# 非强制模块：任何失败仅输出提示，绝不中断主安装流程

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

$PROJECT_DIR = $PSScriptRoot
if ((-not $PROJECT_DIR) -or ($PROJECT_DIR -eq '')) {
    $PROJECT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if ((-not $PROJECT_DIR) -or ($PROJECT_DIR -eq '')) {
    $PROJECT_DIR = (Get-Location).Path
}
$LOG_FILE = [System.IO.Path]::Combine($PROJECT_DIR, 'cpp-env.log')
$DISTRO_FILE = [System.IO.Path]::Combine($PROJECT_DIR, '.wsl-distro-name')

function Write-Log {
    param([string]$Msg, [string]$Clr)
    $ts = Get-Date -Format 'HH:mm:ss'
    $line = "[$ts] $Msg"
    if ($Clr) {
        Write-Host "  $line" -ForegroundColor $Clr
    } else {
        Write-Host "  $line"
    }
    try {
        $utf8 = New-Object System.Text.UTF8Encoding $true
        [System.IO.File]::AppendAllText($LOG_FILE, $line + [Environment]::NewLine, $utf8)
    } catch { }
}

function Test-GppOnPath {
    $ErrorActionPreference = 'Stop'
    try {
        $null = Get-Command g++.exe -ErrorAction Stop
    } catch {
        $ErrorActionPreference = 'SilentlyContinue'
        return $false
    }
    $ErrorActionPreference = 'SilentlyContinue'
    $raw = & g++ --version 2>&1
    $ver = ''
    if ($raw) {
        $lines = @("$raw" -split [Environment]::NewLine)
        if ($lines.Count -gt 0) { $ver = $lines[0].Trim() }
    }
    if ($ver -eq '') { $ver = '未知版本' }
    Write-Log "系统已安装 g++: $ver" 'Green'
    return $true
}

function Test-WslExe {
    try {
        $null = Get-Command wsl.exe -ErrorAction Stop
    } catch {
        return $false
    }
    # wsl.exe 存在不代表 WSL 功能已启用，必须实测 --status
    try {
        $null = & wsl.exe --status 2>$null 1>$null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Get-WslDistros {
    if (-not (Test-WslExe)) { return @() }
    $ErrorActionPreference = 'SilentlyContinue'
    $raw = & wsl.exe --list --quiet 2>$null
    $result = [System.Collections.Generic.List[string]]::new()
    if ($raw) {
        if ($raw -isnot [array]) {
            $raw = @($raw)
        }
        foreach ($line in $raw) {
            $t = [string]$line
            $t = $t.Trim() -replace "`0", ''
            if ($t.Length -gt 0) {
                [void]$result.Add($t)
            }
        }
    }
    return ,$result.ToArray()
}

function Test-WslGpp {
    param([string]$Distro)
    $ErrorActionPreference = 'SilentlyContinue'
    $out = & wsl.exe -d $Distro -u root -- which g++ 2>&1
    if ($out) {
        $path = "$out".Trim()
        if ($path -ne '') {
            Write-Log "WSL ($Distro) 已安装 g++: $path"
            return $true
        }
    }
    return $false
}

function Install-WslBuildTools {
    param([string]$Distro)

    Write-Log "正在 WSL ($Distro) 中安装 C++ 编译工具链，请稍候..."
    Write-Log '  将安装: gcc g++ cmake build-essential gdb'

    try {
        $ErrorActionPreference = 'SilentlyContinue'

        Write-Log '  [1/2] 正在执行 sudo apt update...'
        $null = & wsl.exe -d $Distro -u root -- bash -c 'DEBIAN_FRONTEND=noninteractive apt update -y 2>&1'

        Write-Log '  [2/2] 正在执行 apt install gcc g++ cmake build-essential gdb...'
        $null = & wsl.exe -d $Distro -u root -- bash -c 'DEBIAN_FRONTEND=noninteractive apt install -y gcc g++ cmake build-essential gdb 2>&1'

        Write-Log '  验证 g++ 安装结果...'
        $verOut = & wsl.exe -d $Distro -u root -- bash -c 'g++ --version 2>&1'
        if ($verOut) {
            $verLine = @("$verOut" -split [Environment]::NewLine)
            if ($verLine.Count -gt 0) {
                Write-Log "  WSL g++: $($verLine[0].Trim())" 'Green'
            }
        }
    } catch {
        Write-Log "  安装异常: $($_.Exception.Message)" 'Yellow'
        return $false
    }

    $ErrorActionPreference = 'SilentlyContinue'
    return $true
}

function Try-AutoInstallDistro {
    Write-Log '未检测到 Linux 发行版，正在尝试静默安装 Ubuntu...'
    Write-Log '  下载约 500MB，预计 1-3 分钟，请耐心等待...'

    try {
        $ErrorActionPreference = 'SilentlyContinue'

        Write-Log '  启动安装进程（后台静默模式）...'

        $proc = Start-Process -FilePath wsl.exe -ArgumentList '--install -d Ubuntu' `
            -NoNewWindow -PassThru -WindowStyle Hidden

        $maxWaitSec = 180
        $pollIntervalSec = 5
        $elapsed = 0

        while ($elapsed -lt $maxWaitSec) {
            Start-Sleep -Seconds $pollIntervalSec
            $elapsed += $pollIntervalSec

            if ($proc.HasExited) {
                Write-Log "  安装进程已退出 (exit code: $($proc.ExitCode))"
                break
            }

            $distros = Get-WslDistros
            if ($distros.Count -gt 0) {
                Write-Log '  发行版已安装，终止安装助手界面...'
                try {
                    $proc.Kill()
                } catch { }
                Start-Sleep -Seconds 2
                $ErrorActionPreference = 'SilentlyContinue'
                return $true
            }

            if ($elapsed % 15 -eq 0) {
                Write-Log "  仍在下载中... (已等待 $elapsed 秒)"
            }
        }

        if (-not $proc.HasExited) {
            Write-Log "  安装超时 (${maxWaitSec}秒)，终止进程..."
            try {
                $proc.Kill()
            } catch { }
        }

        $distros = Get-WslDistros
        if ($distros.Count -gt 0) {
            Write-Log "  发行版已可用: $($distros -join ', ')" 'Green'
            return $true
        }

        Write-Log '  安装未在预期时间内完成，发行版未就绪' 'Yellow'
        Write-Log '  可能原因：网络较慢或需管理员权限' 'Yellow'
        Write-Log '  请重新以管理员身份运行本脚本，或手动执行:' 'Yellow'
        Write-Log '    wsl --install -d Ubuntu' 'Yellow'
        return $false
    } catch {
        Write-Log "  自动安装异常: $($_.Exception.Message)" 'Yellow'
        return $false
    }

    $ErrorActionPreference = 'SilentlyContinue'
    return $false
}

function Setup-WslDevEnv {
    param([string]$Distro)

    Write-Log "正在 WSL ($Distro) 中配置 C++ 开发模板..."

    try {
        $ErrorActionPreference = 'SilentlyContinue'

        $wsDir = '/home/lc-cpp-workspace'
        $vscDir = "$wsDir/.vscode"

        Write-Log '  创建工作目录...'
        $null = & wsl.exe -d $Distro -u root -- bash -c "mkdir -p $vscDir 2>&1"

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

        $tasksB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($tasksJson))
        $launchB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($launchJson))
        $mainB64   = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($mainCpp))

        Write-Log '  写入 tasks.json (编译任务)...'
        $null = & wsl.exe -d $Distro -u root -- bash -c "echo '$tasksB64' | base64 -d > $vscDir/tasks.json"

        Write-Log '  写入 launch.json (调试配置)...'
        $null = & wsl.exe -d $Distro -u root -- bash -c "echo '$launchB64' | base64 -d > $vscDir/launch.json"

        Write-Log '  写入 main.cpp (示例代码)...'
        $null = & wsl.exe -d $Distro -u root -- bash -c "echo '$mainB64' | base64 -d > $wsDir/main.cpp"

        Write-Log '  修正文件权限...'
        $null = & wsl.exe -d $Distro -u root -- bash -c "chown -R 1000:1000 $wsDir 2>&1; chmod -R 755 $wsDir 2>&1"

        Write-Log '  创建 VS Code 工作区文件 (自动连接 WSL)...'
        $workspaceJson = @"
{
    "folders": [
        {
            "uri": "vscode-remote://wsl+$Distro/home/lc-cpp-workspace",
            "name": "FlashTap C++ (WSL)"
        }
    ],
    "settings": {
        "remote.autoForwardPorts": false,
        "terminal.integrated.defaultProfile.linux": "bash"
    },
    "extensions": {
        "recommendations": [
            "ms-vscode.cpptools",
            "ms-vscode.cpptools-extension-pack"
        ]
    }
}
"@
        $workspaceFile = [System.IO.Path]::Combine($PROJECT_DIR, 'FlashTap-CPP.code-workspace')
        $utf8noBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($workspaceFile, $workspaceJson, $utf8noBom)

        Write-Log '  C++ 开发模板配置完成' 'Green'
    } catch {
        Write-Log "  开发模板配置异常: $($_.Exception.Message)" 'Yellow'
        return $false
    }

    $ErrorActionPreference = 'SilentlyContinue'
    return $true
}

function Initialize-WslUser {
    param([string]$Distro)

    Write-Log "正在初始化 WSL ($Distro) 用户环境..."

    try {
        $ErrorActionPreference = 'SilentlyContinue'

        $userName = & wsl.exe -d $Distro -u root -- bash -c 'id -un 1000 2>/dev/null || echo ""' 2>&1
        $userName = ($userName -join '').Trim()

        if ($userName -eq '') {
            Write-Log '  未检测到普通用户，正在创建默认用户: localcoder'
            $null = & wsl.exe -d $Distro -u root -- bash -c 'useradd -m -s /bin/bash localcoder 2>&1'
            $null = & wsl.exe -d $Distro -u root -- bash -c 'passwd -d localcoder 2>&1'
            $userName = 'localcoder'
        } else {
            Write-Log "  检测到已有用户: $userName"
        }

        $null = & wsl.exe -d $Distro -u root -- bash -c "printf '[user]\ndefault=%s\n' '$userName' > /etc/wsl.conf"
        Write-Log "  已配置 /etc/wsl.conf 默认用户: $userName"

        $null = & wsl.exe --terminate $Distro 2>&1
        Start-Sleep 2
        Write-Log '  WSL 用户环境初始化完成' 'Green'
    } catch {
        Write-Log "  用户初始化异常: $($_.Exception.Message)" 'Yellow'
        return $false
    }

    $ErrorActionPreference = 'SilentlyContinue'
    return $true
}

function Main {
    Write-Log '=== 检测 C++ 编译环境 ==='

    if (Test-GppOnPath) {
        Write-Log 'C++ 编译环境已就绪 (系统 g++)' 'Green'
        return 0
    }

    if (-not (Test-WslExe)) {
        Write-Log '系统未安装 WSL，C++ 编译环境未配置' 'Yellow'
        Write-Log '------------------------------------------------------------' 'Cyan'
        Write-Log '  请按以下步骤手动安装 WSL + Ubuntu：' 'Cyan'
        Write-Log '  1. 右键开始菜单，选择 Windows PowerShell (管理员)' 'Cyan'
        Write-Log '  2. 执行命令: wsl --install' 'Cyan'
        Write-Log '  3. 安装完成后重启电脑' 'Cyan'
        Write-Log '  4. 重新运行本脚本，将自动安装 gcc/g++/cmake/gdb' 'Cyan'
        Write-Log '------------------------------------------------------------' 'Cyan'
        return 1
    }

    $distros = Get-WslDistros
    if ($distros.Count -eq 0) {
        Write-Log 'WSL 已启用但未安装 Linux 发行版' 'Yellow'

        $autoOk = Try-AutoInstallDistro
        if (-not $autoOk) {
            Write-Log 'C++ 编译环境未配置，可重启电脑后重试' 'Yellow'
            return 1
        }

        $distros = Get-WslDistros
        if ($distros.Count -eq 0) {
            Write-Log '发行版安装未生效，C++ 编译环境未配置' 'Yellow'
            return 1
        }
    }

    Write-Log "检测到 WSL 发行版: $($distros -join ', ')"
    $targetDistro = [string]($distros | Select-Object -First 1)
    Write-Log "使用发行版: $targetDistro"

    if (Test-WslGpp -Distro $targetDistro) {
        Write-Log 'C++ 编译环境已就绪 (WSL g++)' 'Green'
        Setup-WslDevEnv -Distro $targetDistro
        Initialize-WslUser -Distro $targetDistro
        try {
            Set-Content -Path $DISTRO_FILE -Value $targetDistro -Encoding UTF8 -ErrorAction SilentlyContinue
        } catch { }
        return 0
    }

    Write-Log "WSL ($targetDistro) 中未安装 g++，正在自动安装编译工具..."
    $installOk = Install-WslBuildTools -Distro $targetDistro

    if ($installOk -and (Test-WslGpp -Distro $targetDistro)) {
        Write-Log 'C++ 编译环境安装完成 (WSL) - gcc g++ cmake gdb 已全部就绪' 'Green'
        Setup-WslDevEnv -Distro $targetDistro
        Initialize-WslUser -Distro $targetDistro
        try {
            Set-Content -Path $DISTRO_FILE -Value $targetDistro -Encoding UTF8 -ErrorAction SilentlyContinue
        } catch { }
        return 0
    }

    Write-Log 'C++ 编译工具安装可能未完全成功，请检查网络连接后重试' 'Yellow'
    Write-Log "手动验证: wsl -d $targetDistro -- g++ --version" 'Yellow'
    return 1
}

try {
    $ErrorActionPreference = 'SilentlyContinue'
    exit (Main)
} catch {
    Write-Log "C++ 环境配置已跳过 (错误): $($_.Exception.Message)" 'Yellow'
    exit 0
}