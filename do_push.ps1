# 由 DSH 启动的交互式推送窗口 —— 会正常提示输入 GitHub 凭据。
#
# 这个脚本里固化了三个必须的环境前提，都是实测踩出来的坑：
#
#   1) GIT_CONFIG_NOSYSTEM=1
#      Git for Windows 在系统级配置 (C:\Program Files\Git\etc\gitconfig) 里写死了
#      [http] sslBackend = schannel 和 [credential] helper = manager。
#      credential.helper 是多值键，本地配置只能追加不能替换，所以 GCM 永远排在最前面，
#      而它的 OAuth 流程会被 GitHub 以「账号被标记」拒绝。忽略系统配置后 helper 链只剩 wincred。
#
#   2) http.sslBackend = openssl
#      这台机器上有 Watt Toolkit（Steam++）在给 HTTPS 做中间人加速，
#      Schannel 校验不了它自签证书的吊销状态，直接 CRYPT_E_NO_REVOCATION_CHECK 连不上。
#
#   3) http.sslCAInfo = work/git-ca-bundle.pem
#      git 自带的 CA 包不含 Watt Toolkit 的根证书，OpenSSL 会报
#      "unable to get local issuer certificate"。所以把它的两张根证书合并进了这个包。
#
# 以上 2) 3) 已经写进 .git/config，1) 由本脚本设置。

$ErrorActionPreference = 'Continue'
$env:GIT_CONFIG_NOSYSTEM = '1'

Set-Location 'F:\world ol'

$remote = (git remote get-url origin 2>$null)
if (-not $remote) {
    Write-Host "[错误] 没有配置 remote origin。" -ForegroundColor Red
    Read-Host "按回车关闭"
    exit 1
}

Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  正在推送 worldOL 到 GitHub" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host " 仓库 : $remote" -ForegroundColor Gray
Write-Host " 分支 : main   (16 个文件 / 119.6 MB，首次推送视网速几分钟)" -ForegroundColor Gray
Write-Host ""
Write-Host " 如果提示输入凭据，请填：" -ForegroundColor Yellow
Write-Host "   Username : 你的 GitHub 用户名" -ForegroundColor White
Write-Host "   Password : 粘贴你的 Personal Access Token（ghp_ 开头那串）" -ForegroundColor White
Write-Host "              粘贴时屏幕不会显示任何字符，这是正常的，直接回车即可" -ForegroundColor DarkGray
Write-Host ""
Write-Host "------------------------------------------------------" -ForegroundColor DarkGray
Write-Host ""

git push -u origin main
$code = $LASTEXITCODE

if ($code -ne 0) {
    Write-Host ""
    Write-Host "推送失败（退出码 $code）。" -ForegroundColor Red
    Write-Host ""
    Write-Host "如果上面错误是 non-fast-forward / rejected 之类，" -ForegroundColor Yellow
    Write-Host "说明建仓库时勾了 Add a README file，远端已经有一个提交。" -ForegroundColor Yellow
    Write-Host "这个仓库只用来跑编译，可以安全地用本地内容覆盖远端。" -ForegroundColor Yellow
    Write-Host ""
    $ans = Read-Host "强制覆盖远端并重推？(y/N)"
    if ($ans -match '^[Yy]') {
        Write-Host ""
        git push -u origin main --force
        $code = $LASTEXITCODE
    }
}

$web = $remote -replace '\.git$', ''
Write-Host ""
Write-Host "------------------------------------------------------" -ForegroundColor DarkGray
if ($code -eq 0) {
    Write-Host ""
    Write-Host " 推送成功！" -ForegroundColor Green
    Write-Host ""
    Write-Host " 接下来 GitHub 会自动开始编译，打开这个地址看进度：" -ForegroundColor Green
    Write-Host "   $web/actions" -ForegroundColor Yellow
    Write-Host ""
    Write-Host " 跑完后（约 8-15 分钟）点进那次运行，在页面最下面 Artifacts 里" -ForegroundColor Green
    Write-Host " 下载 WorldOL-unsigned-ipa，用 ESign 签名装到 iPhone。" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host " 仍未成功。" -ForegroundColor Red
    Write-Host " 把上面窗口里的完整报错复制给 DSH，我来处理。" -ForegroundColor Yellow
    Write-Host ""
    Write-Host " 常见原因：" -ForegroundColor Gray
    Write-Host "   - Token 没勾 repo 权限，或复制时漏了字符 / 已过期" -ForegroundColor Gray
    Write-Host "   - 用户名或仓库地址不对（会报 404 / Repository not found）" -ForegroundColor Gray
    Write-Host "   - 账号被 GitHub 限制，凭据被拒" -ForegroundColor Gray
}
Write-Host ""
Write-Host " 这个窗口不会自动关闭，看完结果再关。" -ForegroundColor DarkGray
Write-Host ""
