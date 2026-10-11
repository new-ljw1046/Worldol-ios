# 用 GitHub Actions 的 macOS 机器编译出真正的 iOS 安装包（IPA）
#
# 这条路和"托管网页"完全不同：产出的是一个真正的 App，
# 装到 iPhone 上离线运行，有桌面图标，和安卓装 APK 的体验一致。
#
# 流程：
#   1) 本脚本把工程推到你的 GitHub 仓库
#   2) 推送会自动触发 .github/workflows/build-ios-ipa.yml
#   3) 在 macOS runner 上解包、编译，产出【未签名 IPA】
#   4) 你下载这个 IPA，用 ESign / 全能签 签名安装
#
# 注意：仓库名随便起（不像 GitHub Pages 那样必须 <用户名>.github.io），
#       因为这里的仓库只用来跑编译，不对外提供网页。
#
# 用法：
#   .\build_ipa_via_github.ps1 -Repo https://github.com/你的用户名/worldol-ios.git

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Repo,

    [string]$Branch = 'main',
    [string]$UserName,
    [string]$UserEmail
)

$ErrorActionPreference = 'Stop'

$Root = $PSScriptRoot
if (-not $Root) {
    if ($MyInvocation.MyCommand.Path) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
    else { $Root = (Get-Location).Path }
}
Set-Location $Root

Write-Host ""

# ---- 前置检查 --------------------------------------------------------------
$missing = @()
foreach ($p in @('archive', 'ios\Sources\WebViewController.swift', 'ios\project.yml', 'tools\worldol_archive.py', '.github\workflows\build-ios-ipa.yml')) {
    if (-not (Test-Path $p)) { $missing += $p }
}
if ($missing.Count) {
    Write-Host "[错误] 工程缺少必要文件：" -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "   $_" }
    exit 1
}

$parts = Get-ChildItem 'archive' -File -ErrorAction SilentlyContinue
if (-not $parts) {
    Write-Host "[错误] archive\ 里没有归档分片。" -ForegroundColor Red
    Write-Host "先执行： python tools\worldol_archive.py split work\www.bin archive --size 60"
    exit 1
}

$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) {
    Write-Host "[错误] 找不到 git，请安装 Git for Windows。" -ForegroundColor Red
    exit 1
}

$sizeMB = [math]::Round((($parts | Measure-Object Length -Sum).Sum / 1MB), 1)
Write-Host "归档分片 : $($parts.Count) 个，共 $sizeMB MB"
Write-Host "目标仓库 : $Repo  (分支 $Branch)"
Write-Host ""
Write-Host "推送后 GitHub 会自动开始编译，约 8-15 分钟。" -ForegroundColor Cyan
Write-Host ""

# ---- 建仓库并推送 ----------------------------------------------------------
if (-not (Test-Path (Join-Path $Root '.git'))) {
    Write-Host "[*] git init" -ForegroundColor Cyan
    & git init -b $Branch 2>$null
    if ($LASTEXITCODE -ne 0) { & git init; & git checkout -b $Branch 2>$null }
}

$curName = (& git config user.name) 2>$null
if (-not $curName) { & git config user.name  $(if ($UserName) { $UserName } else { 'worldol' }) }
$curMail = (& git config user.email) 2>$null
if (-not $curMail) { & git config user.email $(if ($UserEmail) { $UserEmail } else { 'worldol@example.com' }) }

& git config http.postBuffer 524288000
& git config core.autocrlf false

# GitHub 早就不接受账号密码了。Git for Windows 自带 Git Credential Manager，
# 启用后 push 会弹浏览器让你登录一次 GitHub，之后就记住了 —— 不用手动去申请 Token。
$helper = (& git config --get credential.helper) 2>$null
if (-not $helper) {
    & git config credential.helper manager
    Write-Host "[+] 已为这个仓库启用 Git Credential Manager" -ForegroundColor Green
    Write-Host "    push 时会自动弹出浏览器让你登录 GitHub，登录一次即可。" -ForegroundColor DarkGray
    Write-Host ""
}

$remotes = (& git remote) 2>$null
if ($remotes -contains 'origin') { & git remote set-url origin $Repo }
else { & git remote add origin $Repo }

Write-Host "[*] git add …" -ForegroundColor Cyan
& git add -A
if ($LASTEXITCODE -ne 0) { throw "git add 失败" }

# 确认没把 307MB 的 webroot 或 APK 一起提交进去
$staged = & git diff --cached --name-only
$bad = $staged | Where-Object { $_ -like 'work/*' -or $_ -like '*.apk' -or $_ -like 'ios/webroot/*' }
if ($bad) {
    Write-Host "[警告] 暂存区里有不该提交的文件（应被 .gitignore 排除）：" -ForegroundColor Yellow
    $bad | Select-Object -First 5 | ForEach-Object { Write-Host "   $_" }
    $ans = Read-Host "继续吗？(y/N)"
    if ($ans -notmatch '^[Yy]') { exit 1 }
}

& git commit -m "worldOL iOS standalone shell" 2>&1 | Out-Null
$stagedCount = (& git diff --cached --name-only) 2>$null
if ($stagedCount) {
    Write-Host "[*] 提交变更 …" -ForegroundColor Cyan
    & git commit -m "update" 2>&1 | Out-Null
}

Write-Host "[*] git push（$sizeMB MB，视网速可能要几分钟）…" -ForegroundColor Cyan
$pushOut = & git push -u origin $Branch 2>&1
$pushCode = $LASTEXITCODE
$pushOut | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

if ($pushCode -ne 0) {
    $pushText = ($pushOut | Out-String)

    # 建仓库时如果勾了 "Add a README file"，远端会有一个提交，普通 push 会被拒。
    # 这个仓库只用来跑编译，直接覆盖远端即可。
    if ($pushText -match 'non-fast-forward|rejected|fetch first|unrelated histories|tip of your current branch') {
        Write-Host ""
        Write-Host "[!] 远端仓库已有提交（多半是建仓库时勾了 Add a README file）。" -ForegroundColor Yellow
        Write-Host "    这个仓库只用于跑编译，可以安全地用本地内容覆盖远端。" -ForegroundColor Yellow
        $ans = Read-Host "    强制推送覆盖远端？(y/N)"
        if ($ans -match '^[Yy]') {
            & git push -u origin $Branch --force
            $pushCode = $LASTEXITCODE
            if ($pushCode -eq 0) { $pushOut = @('forced update ok') }
        }
    }
}

if ($pushCode -ne 0) {
    Write-Host ""
    Write-Host "[失败] 推送没成功。常见原因：" -ForegroundColor Red
    Write-Host "  1) 认证没过 —— 弹出的浏览器窗口里登录 GitHub 即可；"
    Write-Host "     如果没有弹窗，说明 Git Credential Manager 没生效，改用 Token："
    Write-Host "     GitHub -> Settings -> Developer settings -> Personal access tokens -> Tokens(classic)"
    Write-Host "     生成时勾上 repo 权限，然后 push 时用户名填 GitHub 用户名、密码粘贴这个 Token。"
    Write-Host "  2) 仓库地址写错了，或仓库还没在网页上创建"
    Write-Host "  3) 网络不稳，重试一次： git push -u origin $Branch"
    exit 1
}

$repoWeb = $Repo -replace '\.git$', '' -replace '^https://github\.com/', 'https://github.com/'
Write-Host ""
Write-Host "======================================================" -ForegroundColor Green
Write-Host " 推送成功！接下来：" -ForegroundColor Green
Write-Host "======================================================" -ForegroundColor Green
Write-Host ""
Write-Host " 1) 打开  $repoWeb/actions" -ForegroundColor Yellow
Write-Host "    （推送已自动触发，看到 'Build unsigned iOS IPA' 在跑就对了）"
Write-Host ""
Write-Host " 2) 等 8-15 分钟，跑完后点进那次运行，在最下面 Artifacts 里下载"
Write-Host "      WorldOL-unsigned-ipa  （约 120 MB 的 zip，解开是 .ipa）" -ForegroundColor Yellow
Write-Host ""
Write-Host " 3) 把 .ipa 传到 iPhone，用 ESign / 全能签 签名安装" -ForegroundColor Yellow
Write-Host "    装好后桌面就有图标，离线可玩，和安卓装 APK 一样。" -ForegroundColor Green
Write-Host ""
Write-Host " 注意：产物是【未签名】IPA，这正是 ESign 需要的。" -ForegroundColor DarkGray
Write-Host "      如果 Actions 报错，把构建日志贴给我，我来改。" -ForegroundColor DarkGray
Write-Host ""
