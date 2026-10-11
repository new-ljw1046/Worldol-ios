# 把世界OL单机版发布到公网静态托管 —— 之后 iPhone 在任何地方都能玩，电脑不用常开。
#
# ⚠️ 关键约束（踩坑点）：
#   游戏内部用的是【根绝对路径】。standalone.html 里写着：
#       const url = new URL(rel, location.origin).href;   // rel = "/data/xxx.json"
#   也就是说它假定自己被部署在【域名根目录】。
#   所以下面这种地址会全部 404：
#       https://用户名.github.io/仓库名/client/standalone.html   ← 项目站，子目录，不行
#   必须部署在根目录：
#       https://用户名.github.io/client/standalone.html          ← 用户站，可以
#       https://xxx.surge.sh/client/standalone.html              ← 可以
#       https://xxx.netlify.app/client/standalone.html           ← 可以
#
# 用法：
#   .\publish_web.ps1 -Method Surge -SiteName worldol-你的名字
#   .\publish_web.ps1 -Method Zip
#   .\publish_web.ps1 -Method Print

[CmdletBinding()]
param(
    [ValidateSet('Surge', 'Zip', 'Print')]
    [string]$Method = 'Print',
    [string]$SiteName,
    [string]$Webroot
)

$ErrorActionPreference = 'Stop'

$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) {
    if ($MyInvocation.MyCommand.Path) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    else { $ScriptDir = (Get-Location).Path }
}
if (-not $Webroot) { $Webroot = Join-Path $ScriptDir 'work\webroot' }
$Webroot = [System.IO.Path]::GetFullPath($Webroot)

$entry = Join-Path $Webroot 'client\standalone.html'
if (-not (Test-Path $entry)) {
    Write-Host "[错误] 找不到 $entry，请先解包。" -ForegroundColor Red
    Write-Host "  python tools\worldol_archive.py join archive work\www.bin"
    Write-Host "  python -m pip install pycryptodome"
    Write-Host "  python tools\worldol_archive.py extract work\www.bin work\webroot"
    exit 1
}

$files = Get-ChildItem $Webroot -Recurse -File
$totalMB = [math]::Round((($files | Measure-Object Length -Sum).Sum / 1MB), 1)
Write-Host ""
Write-Host "站点目录 : $Webroot"
Write-Host "文件数量 : $($files.Count)"
Write-Host "总大小   : $totalMB MB"
Write-Host ""

function Show-Instructions {
    Write-Host "======================================================" -ForegroundColor Cyan
    Write-Host " 三种公网托管方式（都部署在域名根目录，满足游戏要求）" -ForegroundColor Cyan
    Write-Host "======================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "① GitHub Pages 用户站 —— 推荐（一条命令）" -ForegroundColor Green
    Write-Host "   先在 GitHub 网页上建仓库，仓库名必须是   <你的用户名>.github.io" -ForegroundColor Yellow
    Write-Host "   然后运行：" -ForegroundColor Green
    Write-Host "     .\publish_github_pages.ps1 -Repo https://github.com/你的用户名/你的用户名.github.io.git" -ForegroundColor Yellow
    Write-Host "   网址： https://<你的用户名>.github.io/client/standalone.html" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "② Netlify Drop —— 不用命令行、不碰 git" -ForegroundColor Green
    Write-Host "   先打包：  .\publish_web.ps1 -Method Zip" -ForegroundColor Yellow
    Write-Host "   浏览器打开 https://app.netlify.com/drop ，把 work\worldol-web.zip 拖进去"
    Write-Host "   拿到 https://xxx.netlify.app 后，iPhone Safari 打开：" -ForegroundColor Green
    Write-Host "     https://xxx.netlify.app/client/standalone.html" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "③ surge.sh —— 可用但不推荐" -ForegroundColor DarkYellow
    Write-Host "   .\publish_web.ps1 -Method Surge -SiteName worldol-你的名字" -ForegroundColor Yellow
    Write-Host "   surge 有大量 Application too large / 文件数报错的历史 issue，"
    Write-Host "   一万两千个文件风险偏高。"
    Write-Host ""
    Write-Host "⚠️ 三种方式都必须是【域名根目录】。项目站（子目录）会全部 404：" -ForegroundColor Yellow
    Write-Host "   ❌ https://用户名.github.io/仓库名/client/standalone.html" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "提示：部署完成后，在 iPhone Safari 里打开上述地址，" -ForegroundColor DarkGray
    Write-Host "      再用「分享 -> 添加到主屏幕」即可像 App 一样使用，电脑可以关机。" -ForegroundColor DarkGray
    Write-Host ""
}

switch ($Method) {
    'Print' { Show-Instructions }

    'Zip' {
        $zipPath = Join-Path $ScriptDir 'work\worldol-web.zip'
        if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
        Write-Host "正在打包（$($files.Count) 个文件，$totalMB MB）…" -ForegroundColor Cyan
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem

        # ⚠️ 不能用 ZipFile.CreateFromDirectory：
        #    它在 Windows 上会把条目名写成 "client\assets\x.png"（反斜杠），
        #    而 zip 标准要求正斜杠。这种包上传后被解压会把整串当成一个文件名，站点直接废掉。
        #    所以这里手动建条目，强制把分隔符换成 '/'。
        if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
        $baseLen = $Webroot.TrimEnd('\').Length + 1
        $zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
        $count = 0
        try {
            foreach ($f in (Get-ChildItem $Webroot -Recurse -File)) {
                $rel = $f.FullName.Substring($baseLen).Replace('\', '/')
                $entry = $zip.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
                $es = $entry.Open()
                try {
                    $fs = [System.IO.File]::OpenRead($f.FullName)
                    try { $fs.CopyTo($es) } finally { $fs.Dispose() }
                } finally { $es.Dispose() }
                $count++
                if ($count % 2000 -eq 0) { Write-Host "    ... $count / $($files.Count)" -ForegroundColor DarkGray }
            }
        } finally {
            $zip.Dispose()
        }

        $zipMB = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
        Write-Host "完成：$zipPath  ($zipMB MB, $count 条)" -ForegroundColor Green
        Write-Host ""
        Write-Host "把这个 zip 拖到 https://app.netlify.com/drop 即可。" -ForegroundColor Green
        Show-Instructions
    }

    'Surge' {
        if (-not $SiteName) {
            Write-Host "[错误] -Method Surge 需要 -SiteName，例如 worldol-abc123" -ForegroundColor Red
            exit 1
        }
        $domain = if ($SiteName -like '*.surge.sh') { $SiteName } else { "$SiteName.surge.sh" }
        $npx = Get-Command npx -ErrorAction SilentlyContinue
        if (-not $npx) {
            Write-Host "[错误] 找不到 npx，请先安装 Node.js。" -ForegroundColor Red
            exit 1
        }
        Write-Host "部署到 https://$domain …" -ForegroundColor Cyan
        Write-Host "（首次运行会要求输入邮箱和密码来注册 surge 账号）" -ForegroundColor DarkGray
        Write-Host ""
        & $npx.Source --yes surge "$Webroot" "$domain"
        if ($LASTEXITCODE -eq 0) {
            Write-Host ""
            Write-Host "部署成功！iPhone Safari 打开：" -ForegroundColor Green
            Write-Host "  https://$domain/client/standalone.html" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "如需下线：npx surge teardown $domain" -ForegroundColor DarkGray
        }
    }
}
