#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
patch_webroot.py —— 给解包出来的 webroot 打「单机自用」补丁

目前只做一件事：去掉每次启动都要输入的「游玩前承诺」。

为什么需要这个补丁
------------------
原版 client/entry-pledge-standalone.js 里写得很明确：

    // Nothing is persisted: reopening the page always requires confirmation.

也就是说「每次都要重新承诺」是修改者**有意加的门槛**，不是 bug。
它是硬门槛 —— 在用户输入正确之前，游戏核心 gd.js 根本不会被加载。
个人单机使用完全没有必要，所以这里改成直接加载。

为什么要在构建时打
------------------
webroot 是从 APK 里的 assets/www.bin 解包出来的，每次构建都会重新生成，
所以不能直接改解包结果，必须让构建流程在解包之后调用本脚本。

用法
----
    python tools/patch_webroot.py <webroot 目录>
    python tools/patch_webroot.py <webroot 目录> --restore   # 还原成原版
"""

from __future__ import annotations

import argparse
import os
import shutil
import sys

TARGET_REL = os.path.join("client", "entry-pledge-standalone.js")
BACKUP_SUFFIX = ".orig-pledge"

PATCHED = """// [单机自用补丁 · 由 tools/patch_webroot.py 生成]
//
// 跳过「游玩前承诺」，直接加载游戏核心 gd.js。
//
// 原版每次启动都强制要求输入承诺（原文注释：
//   "Nothing is persisted: reopening the page always requires confirmation."），
// 并且只有验证通过才会注入 gd.js。单机自用没有必要。
(() => {
  'use strict';

  // 把弹窗从 DOM 里直接拿掉。它默认不 open，本来就不会显示，
  // 移除是为了避免任何样式或脚本再把它调出来。
  const dialog = document.getElementById('entry-pledge-dialog');
  if (dialog) {
    try { dialog.close(); } catch (e) {}
    dialog.remove();
  }

  // 已经在加载了就不要再插一次。
  if (document.getElementById('worldol-client-boot')) {
    return;
  }

  const boot = document.createElement('script');
  boot.id = 'worldol-client-boot';
  boot.src = 'gd.js';                 // 相对于 /client/ 目录
  boot.onload = () => {
    const loader = document.getElementById('standalone-loading');
    if (loader) loader.remove();
  };
  boot.onerror = () => {
    boot.remove();
    const loader = document.getElementById('standalone-loading');
    if (loader) {
      loader.textContent = '核心脚本 gd.js 加载失败，资源可能不完整。';
    }
  };
  document.body.appendChild(boot);
})();
"""


def patch(webroot: str) -> int:
    target = os.path.join(webroot, TARGET_REL)
    if not os.path.isfile(target):
        print(f"[错误] 找不到 {target}", file=sys.stderr)
        return 1

    backup = target + BACKUP_SUFFIX
    if not os.path.exists(backup):
        shutil.copy2(target, backup)
        print(f"  已备份原版 -> {os.path.basename(backup)}")

    with open(target, "w", encoding="utf-8", newline="\n") as f:
        f.write(PATCHED)
    print(f"  已打补丁：去掉「游玩前承诺」  ({TARGET_REL})")
    return 0


def restore(webroot: str) -> int:
    target = os.path.join(webroot, TARGET_REL)
    backup = target + BACKUP_SUFFIX
    if not os.path.exists(backup):
        print(f"[错误] 没有备份文件 {backup}", file=sys.stderr)
        return 1
    shutil.copy2(backup, target)
    os.remove(backup)
    print(f"  已还原：{TARGET_REL}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="给 worldOL webroot 打单机自用补丁")
    ap.add_argument("webroot", help="解包出来的 webroot 目录")
    ap.add_argument("--restore", action="store_true", help="还原成原版")
    args = ap.parse_args()

    webroot = os.path.abspath(args.webroot)
    if not os.path.isdir(os.path.join(webroot, "client")):
        print(f"[错误] {webroot} 看起来不是 webroot（缺少 client/ 目录）", file=sys.stderr)
        return 1

    print(f"webroot: {webroot}")
    return restore(webroot) if args.restore else patch(webroot)


if __name__ == "__main__":
    sys.exit(main())
