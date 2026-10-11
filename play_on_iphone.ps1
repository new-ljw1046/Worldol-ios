# 在 iPhone 上直接玩世界OL单机版（不需要 Mac、不需要 IPA、不需要签名）
#
# 原理：这个游戏本身就是一套纯静态网页（Egret H5）。
# 用本机起一个 HTTP 服务，让 iPhone 的 Safari 通过局域网访问即可。
#
#   iPhone Safari -> http://<本机IP>:8099/client/standalone.html
#
# 玩起来之后点 Safari 的「分享 -> 添加到主屏幕」，桌面会多一个图标，
# 以后点开就是全屏游戏，和装了个 App 基本没区别。

[CmdletBinding()]
param(
    [int]$Port = 8099,
    [string]$Webroot,
    [switch]$LocalOnly
)

$ErrorActionPreference = 'Stop'

# 解析脚本所在目录（$PSScriptRoot 在 param 默认值里可能为空，所以放到函数体里算）
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) {
    if ($MyInvocation.MyCommand.Path) {
        $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    } else {
        $ScriptDir = (Get-Location).Path
    }
}
if (-not $Webroot) { $Webroot = Join-Path $ScriptDir 'work\webroot' }

$Webroot = [System.IO.Path]::GetFullPath($Webroot)
$entry = Join-Path $Webroot 'client\standalone.html'

if (-not (Test-Path $entry)) {
    Write-Host ""
    Write-Host "[错误] 找不到游戏资源：$entry" -ForegroundColor Red
    Write-Host ""
    Write-Host "请先在项目根目录解包：" -ForegroundColor Yellow
    Write-Host "  python tools\worldol_archive.py join archive work\www.bin"
    Write-Host "  python -m pip install pycryptodome"
    Write-Host "  python tools\worldol_archive.py extract work\www.bin work\webroot"
    Write-Host ""
    exit 1
}

# ---- 找 Python -------------------------------------------------------------
$py = $null
foreach ($candidate in @(
    (Join-Path $env:USERPROFILE '.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe')
)) {
    if (Test-Path $candidate) { $py = $candidate; break }
}
if (-not $py) {
    foreach ($name in @('python', 'py', 'python3')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { $py = $cmd.Source; break }
    }
}
if (-not $py) {
    Write-Host "[错误] 找不到 Python。请手动运行：" -ForegroundColor Red
    Write-Host "  python -m http.server $Port --bind 0.0.0.0 --directory `"$Webroot`""
    exit 1
}

# ---- 找局域网地址（排除 VMware / Hyper-V / VirtualBox 等虚拟网卡）----------
$virtualPattern = 'VMware|VirtualBox|Hyper-V|Loopback|Bluetooth|TAP-|vEthernet|Npcap|Docker|WSL'
$ips = @()
try {
    $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object {
            $_.IPAddress -notlike '127.*' -and
            $_.IPAddress -notlike '169.254.*' -and
            $_.PrefixOrigin -ne 'WellKnown' -and
            $_.InterfaceAlias -notmatch $virtualPattern
        } |
        ForEach-Object { $_.IPAddress }
    $ips = @($ips | Select-Object -Unique)
} catch {
    $ips = @(
        ipconfig | Select-String 'IPv4' |
            ForEach-Object { ($_ -split ':')[-1].Trim() } |
            Where-Object { $_ -notlike '127.*' -and $_ -notlike '169.254.*' }
    ) | Select-Object -Unique
}
if (-not $ips -or $ips.Count -eq 0) { $ips = @('<本机IP>') }

$bind = if ($LocalOnly) { '127.0.0.1' } else { '0.0.0.0' }

Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  世界OL 单机版 · 局域网服务" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host " 资源目录 : $Webroot"
Write-Host " 监听     : ${bind}:$Port"
Write-Host ""
if ($LocalOnly) {
    Write-Host " 本机浏览器打开：" -ForegroundColor Green
    Write-Host "   http://127.0.0.1:$Port/client/standalone.html"
} else {
    Write-Host " 在 iPhone 的 Safari 里打开下面这个地址：" -ForegroundColor Green
    Write-Host "   （手机需和这台电脑连同一个 Wi-Fi）" -ForegroundColor DarkGray
    Write-Host ""
    foreach ($ip in $ips) {
        Write-Host "   http://${ip}:$Port/client/standalone.html" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host " 本机自测：http://127.0.0.1:$Port/client/standalone.html" -ForegroundColor DarkGray
}
Write-Host ""
Write-Host " 进入游戏后：Safari 分享按钮 -> 添加到主屏幕（变成全屏图标）" -ForegroundColor Green
Write-Host " 注意：桌面图标和 Safari 的存档是分开的，建议固定用同一种方式进入。" -ForegroundColor DarkGray
Write-Host ""
Write-Host " 按 Ctrl+C 停止服务" -ForegroundColor DarkGray
Write-Host ""

if (-not $LocalOnly) {
    # 检查 Windows 防火墙是否放行了本端口，没放行的话 iPhone 会连不上。
    $allowed = $false
    try {
        $rules = Get-NetFirewallPortFilter -ErrorAction Stop |
            Where-Object { $_.LocalPort -eq $Port -or $_.LocalPort -eq 'Any' }
        foreach ($r in $rules) {
            $rule = $r | Get-NetFirewallRule -ErrorAction SilentlyContinue
            if ($rule -and $rule.Enabled -eq 'True' -and $rule.Direction -eq 'Inbound' -and $rule.Action -eq 'Allow') {
                $allowed = $true; break
            }
        }
    } catch { }

    if (-not $allowed) {
        Write-Host " [提示] Windows 防火墙可能还没放行 $Port 端口。" -ForegroundColor Yellow
        Write-Host "        首次在 iPhone 上打开时若弹出『允许访问』请点允许；" -ForegroundColor Yellow
        Write-Host "        若一直连不上，用【管理员身份】运行下面这行再重试：" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "        netsh advfirewall firewall add rule name=`"WorldOL $Port`" dir=in action=allow protocol=TCP localport=$Port" -ForegroundColor White
        Write-Host ""
    }
}

& $py -m http.server $Port --bind $bind --directory $Webroot
