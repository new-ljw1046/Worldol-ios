#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
worldol_archive.py —— 世界OL（com.maoyou.worldonline）www.bin 归档工具

逆向自 APK 内 classes3.dex 的 com.maoyou.worldonline.WwwArchive。
归档格式（全部整数为大端）：

    偏移  长度  说明
    ----  ----  --------------------------------------------------
    0     8     魔数 "WOLAR001"
    8     4     indexOffset       索引区在文件中的偏移
    12    4     indexLength       索引区密文长度
    16    4     indexPlainLength  索引区明文长度
    20    4     entryCount        条目数
    24    4     indexFlags        bit0 = 索引明文经过 gzip
    28    16    keyCheck          = SHA256(KEY + "WOLCHECK")[:16]
    44    16    ivSeed            每条目 IV 的种子
    60    4     保留

文件条目：
    2 字节 路径长度（UTF-8 字节数）
    N 字节 路径
    8 字节 offset     数据区偏移
    4 字节 length     密文长度
    4 字节 rawLength  明文长度
    1 字节 flags      bit0 = 明文经过 gzip

加解密：
    AES-256-CTR，无填充。KEY 硬编码在客户端里。
    索引 IV   = SHA256(KEY + ivSeed + "IDX")[:16]
    条目 IV   = SHA256(KEY + ivSeed + BE32(条目序号))[:16]
    条目序号是索引中的顺序号（0 起始），不是路径哈希。

用法：
    python worldol_archive.py info    www.bin
    python worldol_archive.py extract www.bin  webroot
    python worldol_archive.py split   www.bin  archive
    python worldol_archive.py join    archive  www.bin
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import os
import struct
import sys

# --- 客户端里硬编码的常量 -----------------------------------------------------
XK = 55  # DEX 中的 XOR 混淆键
KEY = bytes([
    0x8B, 0x78, 0x87, 0x62, 0x68, 0x56, 0xCD, 0xDC, 0x7A, 0xB2, 0x90, 0x8F, 0x59, 0x85, 0x95, 0x94,
    0xBB, 0x47, 0x73, 0xB4, 0x24, 0x41, 0xCE, 0x11, 0x06, 0x2D, 0xE7, 0x36, 0x58, 0x9F, 0x37, 0x53,
])
MAGIC = b"WOLAR001"
HEADER_SIZE = 64
FLAG_GZIP = 1

CHECK_OBF = "60787b747f72747c"                              # -> "WOLCHECK"
IDX_OBF   = "7e736f"                                        # -> "IDX"
SALT_OBF  = "4058455b53585b1a4040401a5645545f5e41521a4106"  # -> "worldol-www-archive-v1"
IV_SEED_SIZE = 16


def unobf(hexstr: str) -> bytes:
    """还原 DEX 里 XOR(XK) 混淆过的字符串常量。"""
    return bytes(((int(hexstr[i * 2:i * 2 + 2], 16) ^ XK) & 0xFF) for i in range(len(hexstr) // 2))


def sha256(*parts: bytes) -> bytes:
    h = hashlib.sha256()
    for p in parts:
        h.update(p)
    return h.digest()


def _aes_ctr(key: bytes, iv: bytes, data: bytes) -> bytes:
    """Java Cipher("AES/CTR/NoPadding")：整个 128 位计数器按大端自增。"""
    try:
        from Crypto.Cipher import AES
    except ImportError:  # pragma: no cover
        try:
            from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
            dec = Cipher(algorithms.AES(key), modes.CTR(iv)).decryptor()
            return dec.update(data) + dec.finalize()
        except ImportError:
            raise SystemExit("需要 pycryptodome 或 cryptography：pip install pycryptodome")
    return AES.new(key, AES.MODE_CTR, nonce=b"", initial_value=int.from_bytes(iv, "big")).decrypt(data)


class Entry:
    __slots__ = ("index", "path", "offset", "length", "raw_length", "flags")

    def __init__(self, index, path, offset, length, raw_length, flags):
        self.index = index
        self.path = path
        self.offset = offset
        self.length = length
        self.raw_length = raw_length
        self.flags = flags

    @property
    def gzipped(self) -> bool:
        return bool(self.flags & FLAG_GZIP)


class Archive:
    def __init__(self, path: str):
        self.path = path
        self.fh = open(path, "rb")
        self.fh.seek(0, os.SEEK_END)
        self.size = self.fh.tell()
        self.fh.seek(0)
        header = self.fh.read(HEADER_SIZE)
        if len(header) < HEADER_SIZE:
            raise ValueError("文件太小，不是有效的 www.bin")
        if header[:8] != MAGIC:
            raise ValueError(f"魔数不匹配：{header[:8]!r} != {MAGIC!r}")

        self.index_offset = struct.unpack_from(">I", header, 8)[0]
        self.index_length = struct.unpack_from(">I", header, 12)[0]
        self.index_plain_length = struct.unpack_from(">I", header, 16)[0]
        self.entry_count = struct.unpack_from(">I", header, 20)[0]
        self.index_flags = struct.unpack_from(">I", header, 24)[0]
        self.key_check = header[28:44]
        self.iv_seed = header[44:60]

        expect = sha256(KEY, unobf(CHECK_OBF))[:16]
        if self.key_check != expect:
            raise ValueError("密钥校验失败：这个归档使用的不是内置的硬编码密钥")

        self.entries: list[Entry] = []
        self._load_index()

    def _load_index(self) -> None:
        self.fh.seek(self.index_offset)
        cipher = self.fh.read(self.index_length)
        iv = sha256(KEY, self.iv_seed, unobf(IDX_OBF))[:16]
        plain = _aes_ctr(KEY, iv, cipher)
        if self.index_flags & FLAG_GZIP:
            plain = gzip.decompress(plain)
        if len(plain) != self.index_plain_length:
            raise ValueError(f"索引明文长度不符：{len(plain)} != {self.index_plain_length}")

        count = struct.unpack_from(">I", plain, 0)[0]
        if count != self.entry_count:
            raise ValueError(f"索引条目数不符：{count} != {self.entry_count}")

        pos = 4
        for i in range(count):
            name_len = struct.unpack_from(">H", plain, pos)[0]
            pos += 2
            raw_name = plain[pos:pos + name_len]
            pos += name_len
            try:
                name = raw_name.decode("utf-8")
            except UnicodeDecodeError:
                name = raw_name.decode("gbk", errors="replace")
            offset = struct.unpack_from(">q", plain, pos)[0]
            pos += 8
            length = struct.unpack_from(">I", plain, pos)[0]
            pos += 4
            raw_length = struct.unpack_from(">I", plain, pos)[0]
            pos += 4
            flags = plain[pos]
            pos += 1
            self.entries.append(
                Entry(i, name.replace("\\", "/").lstrip("/"), offset, length, raw_length, flags)
            )

    def read(self, entry: Entry) -> bytes:
        self.fh.seek(entry.offset)
        cipher = self.fh.read(entry.length)
        iv = sha256(KEY, self.iv_seed, struct.pack(">I", entry.index))[:16]
        plain = _aes_ctr(KEY, iv, cipher)
        if entry.gzipped:
            plain = gzip.decompress(plain)
        if len(plain) != entry.raw_length:
            raise ValueError(f"{entry.path}: 明文长度不符 {len(plain)} != {entry.raw_length}")
        return plain

    def close(self) -> None:
        self.fh.close()


# --- 子命令 -------------------------------------------------------------------

def cmd_info(args) -> int:
    ar = Archive(args.src)
    try:
        print(f"文件            : {args.src}")
        print(f"归档大小        : {ar.size:,} 字节")
        print(f"条目数          : {ar.entry_count:,}")
        print(f"索引偏移        : {ar.index_offset:,}")
        print(f"索引密文长度    : {ar.index_length:,}")
        print(f"索引明文长度    : {ar.index_plain_length:,}")
        print(f"索引 gzip       : {bool(ar.index_flags & FLAG_GZIP)}")
        print(f"ivSeed          : {ar.iv_seed.hex()}")
        print(f"keyCheck        : {ar.key_check.hex()}  (校验通过)")
        total = sum(e.raw_length for e in ar.entries)
        print(f"明文总大小      : {total:,} 字节 ({total / 1048576:.1f} MB)")
        print()
        print("前 10 条：")
        for e in ar.entries[:10]:
            print(f"  #{e.index:<6} {e.raw_length:>10,} 字节  {e.path}")
    finally:
        ar.close()
    return 0


def cmd_extract(args) -> int:
    ar = Archive(args.src)
    out = os.path.abspath(args.dest)
    os.makedirs(out, exist_ok=True)
    ok = failed = 0
    errors = []
    try:
        for e in ar.entries:
            parts = [p for p in e.path.split("/") if p not in ("", ".")]
            if not parts or any(p == ".." for p in parts):
                failed += 1
                continue
            dest = os.path.join(out, *parts)
            if not os.path.realpath(dest).startswith(os.path.realpath(out) + os.sep):
                failed += 1
                continue
            try:
                data = ar.read(e)
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                with open(dest, "wb") as f:
                    f.write(data)
                ok += 1
            except Exception as exc:  # noqa: BLE001
                failed += 1
                if len(errors) < 10:
                    errors.append((e.path, repr(exc)))
            if (ok + failed) % 2000 == 0:
                print(f"  ... {ok + failed:,}/{ar.entry_count:,}", file=sys.stderr)
    finally:
        ar.close()

    print(f"解包完成：成功 {ok:,}，失败 {failed:,}")
    print(f"输出目录：{out}")
    if errors:
        print("部分错误：")
        for p, m in errors:
            print("  ", p, m)
    return 1 if failed else 0


def cmd_split(args) -> int:
    part_size = args.size * 1024 * 1024
    os.makedirs(args.dest, exist_ok=True)
    base = os.path.join(args.dest, os.path.basename(args.src))
    n = 0
    with open(args.src, "rb") as src:
        while True:
            chunk = src.read(part_size)
            if not chunk:
                break
            name = f"{base}.part{n:03d}"
            with open(name, "wb") as f:
                f.write(chunk)
            print(f"  {name}  {len(chunk):,} 字节")
            n += 1
    print(f"已切分为 {n} 个分片，目录：{os.path.abspath(args.dest)}")
    return 0


def cmd_join(args) -> int:
    d = args.src
    parts = sorted(f for f in os.listdir(d) if ".part" in f)
    if not parts:
        raise SystemExit(f"{d} 下没有找到分片文件")
    with open(args.dest, "wb") as out:
        for name in parts:
            p = os.path.join(d, name)
            with open(p, "rb") as f:
                while True:
                    chunk = f.read(8 * 1024 * 1024)
                    if not chunk:
                        break
                    out.write(chunk)
            print(f"  + {name}")
    print(f"合并完成：{args.dest}  {os.path.getsize(args.dest):,} 字节")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="世界OL www.bin 归档工具")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("info", help="查看归档信息")
    p.add_argument("src")
    p.set_defaults(func=cmd_info)

    p = sub.add_parser("extract", help="解包到目录")
    p.add_argument("src")
    p.add_argument("dest")
    p.set_defaults(func=cmd_extract)

    p = sub.add_parser("split", help="切成可提交的分片")
    p.add_argument("src")
    p.add_argument("dest")
    p.add_argument("--size", type=int, default=60, help="每个分片的 MB 数（默认 60）")
    p.set_defaults(func=cmd_split)

    p = sub.add_parser("join", help="把分片合并回 www.bin")
    p.add_argument("src")
    p.add_argument("dest")
    p.set_defaults(func=cmd_join)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
