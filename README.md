# 世界OL（修改版67）→ 在 iPhone 上运行

## 一句话结论

**APK 无法「转换」成 IPA。** 这是两个平台完全不同的安装包格式，不存在转换工具。
但你这个包是**纯网页（H5）套壳应用**，所以有一条真实可行的路：**把里面的网页资源原样拿出来，
用一个 iOS 外壳跑**。本仓库已经把这套东西做完了。

---

## 一、为什么「转换」不可能

| | APK | IPA |
|---|---|---|
| 平台 | Android | iOS |
| 可执行代码 | `classes*.dex`（Dalvik/ART 字节码） | ARM64 Mach-O 原生二进制 |
| 运行环境 | Android Runtime + Android 框架 | iOS + UIKit/Foundation |
| 签名 | APK Signature Scheme v1/v2/v3 | Apple 代码签名 + 描述文件 |

没有编译器能把 DEX 变成 Mach-O。市面上所有号称「APK 转 IPA」的软件都是骗局或木马。

## 二、为什么你这个包有救

对 `世界OL-修改版67-军团宠物奉献修复.apk` 的实测结果：

```
包名 / 版本   com.maoyou.worldonline  /  1.9.26-standalone  (versionCode 125)
原生库 lib/   【完全不存在】——没有 libunity.so / libUE4.so / libcocos2djs.so
体积构成      assets/www.bin  119.5 MB，占整包 95%
www.bin 头    魔数 "WOLAR001"，自研加密归档
核心代码      classes3.dex 里的 WwwArchive / MainActivity$AssetServer / IntegrityGuard
```

解包后拿到 **12,651 个文件 / 307 MB**，结构是：

```
client/   140.7 MB   游戏本体（Egret H5），入口 client/standalone.html
data/     144.9 MB   全部游戏数据（地图、技能、宠物、装备…）
web/        0.5 MB   单机功能扩展层
analysis/   7.1 MB   修改者留下的分析笔记与模块
```

`client/standalone.html` 自己就写着「请通过本地静态服务器打开本页面」——
**这压根不是原生 App，是一个纯粹靠 HTTP 服务的网页游戏。**

所以移植 = 给它一个 iOS 上的 HTTP 源 + 一个 WebView。不需要碰游戏逻辑一个字节。

---

## 三、按你的设备选路线

> **Android 能"直接装 APK"是因为 Android 允许侧载任意应用；iOS 不允许，
> 这是 Apple 的限制而不是方案的问题。** 所以 iOS 上想要"桌面图标、点开就玩、离线运行"，
> 只有一条路：做出真正的 IPA 用 ESign 签名 → **路线 C**。
> A / A+ 是不用编译的替代方案，本质上仍然是"打开一个网页"。

| 路线 | 需要什么 | 体验 | 推荐给 |
|---|---|---|---|
| **C** ⭐ | GitHub 账号 + ESign | **真 App 图标，离线，和 APK 一样** | 想要"和安卓一样"的人 |
| A | 电脑 + 同一 Wi-Fi | Safari 打开，电脑要开着 | 想先试试水 |
| A+ | 一个静态托管账号 | Safari 打开，电脑可关机 | 不想编译又不介意联网 |
| B | macOS + Xcode | 同 C | 有 Mac 的人（比 C 快） |

### 路线 C：编译真 IPA（最接近"装 APK"的体验）⭐

```powershell
# 1) 在 GitHub 网页上建一个仓库（名字随便起，不像 Pages 那样有要求）
# 2) 推代码并自动触发云端编译
.\build_ipa_via_github.ps1 -Repo https://github.com/你的用户名/worldol-ios.git
# 3) 等 8-15 分钟，在仓库 Actions 页面下载 Artifacts 里的 WorldOL-unsigned-ipa
# 4) 用 ESign / 全能签 签名安装
```

装好后桌面直接有图标，**离线可玩，不需要电脑也不需要网络** —— 和安卓装 APK 体验一致。

推送到 GitHub 的只有 **12 个文件 / 119.6 MB**（`www.bin` 的两个分片 + 工程代码），
307 MB 的解包资源由云端在构建时生成，已确认不会误传 `work/`、`ios/webroot/`、`*.apk`。

> ⚠️ 已知运行时风险：`standalone.html` 会把 `standalone-files.json` 里列的
> **约 190 MB JSON 全部 `fetch` 成字符串塞进内存**（`window.__worldolFiles` 这个 Map）。
> UTF-16 下可能占到 380 MB 左右。原 Android 客户端是同样的代码，所以 iOS 上应当可比，
> 但低内存机型有被系统杀进程的可能。这是目前最大的不确定点。

### 路线 B：有 Mac 的话（比 C 快）

```bash
python3 tools/worldol_archive.py join archive /tmp/www.bin
python3 -m pip install pycryptodome
python3 tools/worldol_archive.py extract /tmp/www.bin ios/webroot
brew install xcodegen
bash ios/build_unsigned_ipa.sh          # -> ios/build/WorldOL-unsigned.ipa
```

### 路线 A：零门槛，今天就能玩（不需要 Mac / 不需要 IPA / 不需要签名）

游戏本来就是网页，iPhone 的 Safari 直接打开就行。

```powershell
# 在这台电脑上（和 iPhone 连同一个 Wi-Fi）
.\play_on_iphone.ps1
```

脚本会打印出局域网地址，在 iPhone Safari 里打开：

```
http://<电脑的局域网IP>:8099/client/standalone.html
```

进游戏后：**Safari 分享按钮 → 添加到主屏幕**。桌面会多一个图标，点开就是全屏游戏，
和装了个 App 几乎没区别（存档存在 Safari 的 localStorage 里，不清网站数据就不会丢）。

> **已实测验证**：在 127.0.0.1:8099 上用真实 Chrome 加载 `client/standalone.html`，
> Egret 引擎成功初始化并批量拉取了数百个 `client/assets/*/*.png|json` 图集资源，
> 全部 `web/` 扩展模块与 1.09 MB 的 `worldol-standalone.js` 核心均 200 加载，
> 修改版的「游玩前承诺」弹窗正常渲染。除 `/favicon.ico` 与首次运行必然缺失的
> `/saves/world.json` 外无任何 404。

### 路线 A+：电脑不想常开 → 部署到公网静态托管（iPhone 完全独立）

**先接受一个物理事实**：293 MB 数据必须先从电脑传出去一次。传完之后 iPhone 就完全独立了。

#### 首选：GitHub Pages 用户站（一条命令）

```powershell
# 先在 GitHub 网页上建仓库，仓库名必须是 <你的用户名>.github.io
.\publish_github_pages.ps1 -Repo https://github.com/你的用户名/你的用户名.github.io.git
```

脚本会自动处理两个关键点：

- **放 `.nojekyll`** —— 不放的话 GitHub Pages 会用 Jekyll 处理这一万多个文件，
  几乎必然撞上它 10 分钟的部署超时（见[官方限制](https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits)）。
- **`git config http.postBuffer 524288000`** —— 不调大的话 293 MB 推到一半会 `RPC failed`。

#### 备选：Netlify Drop（不碰 git）

```powershell
.\publish_web.ps1 -Method Zip    # 生成 work\worldol-web.zip (~120 MB)
```

然后把这个 zip 拖到 <https://app.netlify.com/drop>，拿到 `https://xxx.netlify.app`。

> ⚠️ 打包**不能**用 `ZipFile.CreateFromDirectory`：它在 Windows 上会把条目名写成
> `client\assets\x.png`（反斜杠），而 zip 标准要求正斜杠。这种包上传解压后会把
> 整串当成一个文件名，站点直接废掉。脚本里已改成手动建条目并强制 `/`。

> ⚠️ **必须部署在域名根目录**，这是最容易踩的坑。游戏里写着
> `const url = new URL(rel, location.origin).href;`（`rel = "/data/xxx.json"`），
> 也就是它假定自己在域名根上。所以：
>
> - ✅ `https://用户名.github.io/client/standalone.html`（**用户站**，根目录）
> - ✅ `https://你的名字.netlify.app/client/standalone.html`（根目录）
> - ❌ `https://用户名.github.io/仓库名/client/standalone.html`（**项目站**，子目录 → 全部 404）
>
> 子目录的问题已实测确认：页面 HTML 能加载，但所有 `/data/*.json`、`/analysis/modules/*.js`
> 都会解析到域名根并返回 404，游戏起不来。
>
> surge.sh 虽然也是根目录，但它有大量 `Application too large` / 文件数报错的历史 issue，
> 一万两千个文件风险偏高，不推荐。

#### 完全离线：手机自己当服务器（a-Shell）

不想联网、也不想注册托管账号的话，可以让 iPhone 自己跑一个本地服务：

1. App Store 装 **a-Shell**（免费，自带 Python）
2. 把 `work\worldol-web.zip` 传到手机（iTunes/Finder 文件共享，或网盘再下载）
3. 在 a-Shell 里执行：

   ```
   python -m zipfile -e worldol-web.zip webroot
   python -m http.server 8000 --directory webroot
   ```

4. Safari 打开 `http://localhost:8000/client/standalone.html`

好处是彻底不依赖电脑也不依赖网络。代价是每次玩都要先去 a-Shell 里把服务起起来
（a-Shell 目前不支持开机自启脚本）。**这条路我没法在这里实测 iOS 应用的行为，
属未验证方案。**

> 私仓跑 Actions 的额度：免费 2000 分钟/月，但 macOS runner 按 10 倍计费
> （≈200 有效分钟），一次构建约 8–15 分钟。

---

## 四、iOS 外壳是怎么做的

对应 Android 端的做法：

| Android（原 APK） | iOS（本工程） |
|---|---|
| `assets/www.bin` + `WwwArchive` 解密 | 构建期用 `tools/worldol_archive.py` 全量解包进 bundle |
| `MainActivity$AssetServer` 虚拟主机 `appassets.worldol.local` | `Sources/LocalHTTPServer.swift`：127.0.0.1 上真实的 HTTP 服务 |
| `WebViewClient.shouldInterceptRequest` | `Sources/WebViewController.swift`：WKWebView 加载 `http://127.0.0.1:<port>/client/standalone.html` |
| WebView + localStorage 存档 | WKWebView + `.default()` 持久化数据存储 |

**为什么不用 `file://` 直接打开**：`file://` 的 origin 是 `null`，
游戏里的 `fetch('/data/xxx.json')` 和 XHR 会被同源策略全部挡死，必然白屏。
必须给它一个真正的 HTTP 源——这也是 Android 端要用 `AssetServer` 的原因。

**为什么不用 `WKURLSchemeHandler`**：自定义 scheme 在 Web Workers / 部分存储 API 上
有兼容性坑，而 localhost HTTP 源的行为和 Android 端完全一致，风险最低。

---

## 五、关于微信里那个「军团宠物奉献修复」

那是修改者对这个单机版做的功能修复，**不涉及 Android 平台代码**，
所以解包出来的 H5 内容原样搬到 iOS 上，这部分修改是完整保留的。

---

## 六、仓库结构

```
archive/                      www.bin 的 2 个分片（60 MB + 59.5 MB）
tools/worldol_archive.py      归档格式实现：info / extract / split / join
ios/Sources/                  iOS 外壳（Swift，无第三方依赖）
  AppDelegate.swift
  WebViewController.swift     WKWebView 容器
  LocalHTTPServer.swift       仅回环的静态 HTTP 服务
  Info.plist
ios/project.yml               XcodeGen 工程描述
ios/build_unsigned_ipa.sh     一键出未签名 IPA（macOS）
.github/workflows/            GitHub Actions 构建
play_on_iphone.ps1            路线 A：起局域网服务
```

`.gitignore` 已排除 `ios/webroot/`（307 MB，由脚本生成）和 `work/`。

---

## 七、实机反馈后的两处修复（v2）

App 装到 iPhone 上跑起来后，实测反馈了两个问题，都已修复：

### 1. 存档不持久：每次启动都要重新建角色 ❌ → ✅

**这是我的 bug，不是游戏的问题。**

`WebViewController` 里原来写的是 `server.start()`，端口参数默认 0，也就是让系统
**随机分配临时端口**。而浏览器存储（localStorage）是**按 origin 隔离的，端口算在
origin 里**。端口每次都变 → 每次都是一块全新的存储空间 → 游戏存档
（localStorage 键 `worldol-standalone-world`）自然读不到。

修复：`LocalHTTPServer.stablePort = 47653`，改成固定端口。
端口被占用时（上次进程没退干净）会退化为随机端口，游戏仍能启动，但那次读不到旧档。

> 注：之前用随机端口那几次的存档本来就没落盘，找不回来了。修好之后新建的角色会一直保留。

### 2. 每次启动都要输入「游玩前承诺」→ 已去掉

**这个是修改者的有意设计，不是 bug。** `client/entry-pledge-standalone.js` 里原作者写着：

```js
// Nothing is persisted: reopening the page always requires confirmation.
```

而且它是**硬门槛**：在你输入正确之前，游戏核心 `gd.js` 根本不会被加载。

修复：`tools/patch_webroot.py`，在构建时把这个脚本替换成直接加载 `gd.js` 的版本，
并把弹窗元素从 DOM 移除。因为 webroot 每次都从 `www.bin` 重新解包，所以补丁必须在
构建流程里打，工作流中已加对应步骤：

```bash
python3 tools/patch_webroot.py ios/webroot        # 打补丁
python3 tools/patch_webroot.py ios/webroot --restore   # 还原原版
```

已实测验证（真实 Chrome 加载）：`entry-pledge-dialog === null` 为 `true`，
`window.egret` 为 `object`，游戏直接进主界面。

---

## 八、已知风险 / 注意点

1. **`IntegrityGuard` 在原 APK 里校验 APK 签名证书**，用来做授权绑定。
   本工程不实现它——单机版本身不需要联网激活，这条路绕开了整套授权校验。
2. **307 MB 的 App 体积**：IPA 打 zip 后约 120–150 MB，ESign 签名会比较慢，属正常。
3. **免费 Apple ID 签名 7 天过期**；企业证书签名有被吊销风险，这是签名工具本身的限制。
4. **首次启动会预载约 190 MB 数据**，低内存机型有被系统杀进程的可能。
5. 若游戏侧以后新增功能依赖 Android 原生能力，需要在 `WebViewController` 里补对应的桥。
   当前版本**完全没有原生桥接**（已全量扫描确认）。
6. **不要改 `LocalHTTPServer.stablePort`**，改了会让已有存档全部失效（origin 变了）。
7. `WorldOL-unsigned.ipa` 已加入 `.gitignore`——它 121.7 MB，超过 GitHub
   单文件 100 MB 限制，推不上去。
