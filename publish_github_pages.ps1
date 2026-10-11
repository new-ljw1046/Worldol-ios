# 一键把世界OL单机版发布到 GitHub Pages —— 之后 iPhone 完全独立运行，电脑可以关机。
#
# ⚠️ 仓库名必须是 <你的用户名>.github.io
#    因为游戏内部用根绝对路径（/data/xxx.json），必须部署在【域名根目录】。
#    项目站 https://用户名.github.io/仓库名/ 是子目录，会全部 404（已实测）。
#
# 用法：
#   1) 先在 GitHub 网页上新建仓库，仓库名填  你的用户名.github.io
#   2) 然后运行：
#        .\publish_github_pages.ps1 -Repo https://github.com/你的用户名/你的用户名.github.io.git
#
# 首次会要求输入 GitHub 用户名和 Personal Access Token 作为密码。

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Repo,

    [string]$Webroot,
    [string]$Branch = 'main',
    [string]$UserName,
    [string]$UserEmail
)

$ErrorActionPreference = 'Stop'

# ---- 定位 webroot ----------------------------------------------------------
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) {
    if ($MyInvocation.MyCommand.Path) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    else { $ScriptDir = (Get-Location).Path }
}
if (-not $Webroot) { $Webroot = Join-Path $ScriptDir 'work\webroot' }
$Webroot = [System.IO.Path]::GetFullPath($Webroot)

if (-not (Test-Path (Join-Path $Webroot 'client\standalone.html'))) {
    Write-Host "[错误] 找不到 $Webroot\client\standalone.html，请先解包。" -ForegroundColor Red
    exit 1
}

# ---- 检查仓库名 ------------------------------------------------------------
$repoName = ($Repo -replace '\.git$', '') -split '/' | Select-Object -Last 1
if ($repoName -notmatch '\.github\.io$') {
    Write-Host ""
    Write-Host "[警告] 仓库名是 '$repoName'，不是 <用户名>.github.io 形式的【用户站】。" -ForegroundColor Yellow
    Write-Host "       用户站会部署到 https://$repoName/ 根目录，游戏才能跑。" -ForegroundColor Yellow
    Write-Host "       如果是项目站（子目录），游戏内的 /data/*.json 会全部 404。" -ForegroundColor Yellow
    Write-Host ""
    $ans = Read-Host "仍要继续吗？(y/N)"
    if ($ans -notmatch '^[Yy]') { exit 1 }
}

# ---- 检查 git --------------------------------------------------------------
$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) {
    Write-Host "[错误] 找不到 git，请先安装 Git for Windows。" -ForegroundColor Red
    exit 1
}

$files = Get-ChildItem $Webroot -Recurse -File
$totalMB = [math]::Round((($files | Measure-Object Length -Sum).Sum / 1MB), 1)
Write-Host ""
Write-Host "站点目录 : $Webroot"
Write-Host "文件数量 : $($files.Count)"
Write-Host "总大小   : $totalMB MB"
Write-Host "目标仓库 : $Repo  (分支 $Branch)"
Write-Host ""

# ---- 关键：放 .nojekyll ----------------------------------------------------
# 不放的话 GitHub Pages 会跑 Jekyll 去处理这一万多个文件，几乎必然触发 10 分钟部署超时。
$nojekyll = Join-Path $Webroot '.nojekyll'
if (-not (Test-Path $nojekyll)) {
    New-Item -ItemType File -Path $nojekyll -Force | Out-Null
    Write-Host "[+] 已创建 .nojekyll（关闭 Jekyll，避免部署超时）" -ForegroundColor Green
}

# ---- 在 webroot 里建一个独立的 git 仓库 ------------------------------------
Push-Location $Webroot
try {
    if (-not (Test-Path (Join-Path $Webroot '.git'))) {
        Write-Host "[*] git init" -ForegroundColor Cyan
        & git init -b $Branch 2>$null
        if ($LASTEXITCODE -ne 0) { & git init; & git checkout -b $Branch 2>$null }
    }

    # 本地身份（不动全局配置）
    $curName = (& git config user.name) 2>$null
    if (-not $curName) {
        $n = if ($UserName) { $UserName } else { 'worldol' }
        & git config user.name $n
    }
    $curMail = (& git config user.email) 2>$null
    if (-not $curMail) {
        $m = if ($UserEmail) { $UserEmail } else { 'worldol@example.com' }
        & git config user.email $m
    }

    # 大推送必须调大 postBuffer，否则 293MB 推到一半会 RPC failed
    & git config http.postBuffer 524288000
    & git config core.autocrlf false

    $remoteExists = (& git remote) 2>$null
    if ($remoteExists -contains 'origin') {
        & git remote set-url origin $Repo
    } else {
        & git remote add origin $Repo
    }

    Write-Host "[*] git add（约 1.2 万个文件，需要一会儿）…" -ForegroundColor Cyan
    & git add -A
    if ($LASTEXITCODE -ne 0) { throw "git add 失败" }

    Write-Host "[*] git commit …" -ForegroundColor Cyan
    & git commit -m "publish worldOL standalone (H5)" 2>&1 | Out-Null

    Write-Host "[*] git push（293MB，视网速可能要几分钟）…" -ForegroundColor Cyan
    & git push -u origin $Branch

    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "[失败] 推送没成功。常见原因：" -ForegroundColor Red
        Write-Host "  1) 密码要填 Personal Access Token，不是登录密码"
        Write-Host "     （GitHub -> Settings -> Developer settings -> Personal access tokens）"
        Write-Host "  2) 网络不稳，重试一次即可：cd `"$Webroot`"; git push -u origin $Branch"
        exit 1
    }

    $siteUrl = "https://$repoName/client/standalone.html"
    Write-Host ""
    Write-Host "======================================================" -ForegroundColor Green
    Write-Host " 推送成功！" -ForegroundColor Green
    Write-Host "======================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host " 1) 到仓库 Settings -> Pages，确认 Source = Deploy from a branch,"
    Write-Host "    分支选 $Branch，目录选 / (root)，然后等 1-3 分钟构建完成。"
    Write-Host ""
    Write-Host " 2) iPhone Safari 打开：" -ForegroundColor Green
    Write-Host "      $siteUrl" -ForegroundColor Yellow
    Write-Host ""
    Write-Host " 3) Safari 分享按钮 -> 添加到主屏幕，以后点图标直接玩，电脑可以关机。" -ForegroundColor Green
    Write-Host ""
    Write-Host " 提示：首次进入要等它预载 ~190MB 数据（托管方会 gzip，实际传输少很多），" -ForegroundColor DarkGray
    Write-Host "      之后就靠浏览器缓存了。存档在浏览器里，重要进度建议用游戏内导出功能备份。" -ForegroundColor DarkGray
    Write-Host ""
}
finally {
    Pop-Location
}
