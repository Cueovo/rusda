#!/usr/bin/env python3
# 纯 Python 拼 deb:ar(debian-binary + control.tar.<xz|gz> + data.tar.<xz|gz>)
#
# 为什么不直接用 dpkg-deb:macOS 上要 brew install dpkg(Apple Silicon 上还得现编),
# 而这里只做一件确定的事,产物结构和官方 frida deb 一致(装完可以用 dpkg-deb -c 验证)。
#
# 用法:
#   tools/mkdeb.py --data <数据根> --control <DEBIAN 目录> --out out.deb [--gz]
import argparse
import io
import os
import sys
import tarfile


def make_tar(root, suffix, exec_paths):
    buf = io.BytesIO()
    mode = "w:gz" if suffix == "gz" else "w:xz"

    def norm(p):
        return p.replace("\\", "/").lstrip("./")

    forced_exec = {norm(p) for p in exec_paths}
    with tarfile.open(fileobj=buf, mode=mode, format=tarfile.GNU_FORMAT) as tar:
        rels = []
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames.sort()
            rel = os.path.relpath(dirpath, root)
            if rel == ".":
                rel = ""
            if rel:
                rels.append(rel)
            for name in sorted(filenames):
                rels.append(os.path.join(rel, name) if rel else name)

        def arcname(rel):
            rel = rel.replace(os.sep, "/")
            return "./" + rel

        root_ti = tar.gettarinfo(root, arcname="./")
        root_ti.uid = root_ti.gid = 0
        root_ti.uname = root_ti.gname = "root"
        root_ti.mode = 0o755
        tar.addfile(root_ti)

        for rel in sorted(rels, key=lambda p: (p.count(os.sep), p)):
            full = os.path.join(root, rel)
            ti = tar.gettarinfo(full, arcname=arcname(rel))
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = "root"
            # 权限写死,不依赖宿主文件系统(Windows/奇怪 umask 下也一致)
            if ti.isdir() or norm(arcname(rel)) in forced_exec:
                ti.mode = 0o755
            else:
                ti.mode = 0o644
            if ti.isdir():
                tar.addfile(ti)
            else:
                with open(full, "rb") as f:
                    tar.addfile(ti, f)
    return buf.getvalue()


def ar_member(name, data):
    header = b"".join(
        [
            name.encode().ljust(16),
            b"0".ljust(12),  # mtime
            b"0".ljust(6),  # uid
            b"0".ljust(6),  # gid
            b"100644".ljust(8),  # mode
            str(len(data)).encode().ljust(10),
            b"`\n",
        ]
    )
    return header + data + (b"\n" if len(data) % 2 else b"")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True)
    ap.add_argument("--control", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--gz", action="store_true", help="用 gzip 代替 xz")
    ap.add_argument("--exec", action="append", default=[],
                    help="数据根里的可执行文件(可重复),强制 0755")
    args = ap.parse_args()

    if args.gz:
        suffix = "gz"
    else:
        try:
            import lzma  # noqa: F401

            suffix = "xz"
        except ImportError as e:
            print(f"mkdeb: 没有 xz 支持({e}),改用 gzip", file=sys.stderr)
            suffix = "gz"

    control_tar = make_tar(args.control, suffix, args.exec)
    data_tar = make_tar(args.data, suffix, args.exec)

    with open(args.out, "wb") as f:
        f.write(b"!<arch>\n")
        f.write(ar_member("debian-binary", b"2.0\n"))
        f.write(ar_member(f"control.tar.{suffix}", control_tar))
        f.write(ar_member(f"data.tar.{suffix}", data_tar))
    print(f"mkdeb: {args.out} ({os.path.getsize(args.out)} bytes, control/data .tar.{suffix})")


if __name__ == "__main__":
    main()
