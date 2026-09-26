#!/bin/bash
# 16.2.1 iOS 越狱 deb 打包脚本(必须在 macOS 上跑,并且已经编好 iOS 产物)
#
# 前置:
#   1) tools/apply-patches.sh --frida-root <frida> 已经打过 patch
#   2) cd <frida> && IOS_CERTID=- make build/frida-ios-arm64/usr/lib/pkgconfig/frida-core-1.0.pc
#      (要 universal 再加 build/frida-ios-arm64e/usr/lib/pkgconfig/frida-core-1.0.pc)
#
# 产物(和官方 re.frida.server 一一对应,只是换成 rusda 的名字):
#   rootless : /var/jb/usr/sbin/frida-server
#              /var/jb/usr/lib/<agent_dir>/<agent_name>      (默认 frida/frida-agent.dylib)
#              /var/jb/Library/LaunchDaemons/re.rusda.server.plist
#   rootful  : 去掉 /var/jb 前缀,Architecture 为 iphoneos-arm
#
# 之所以能 rootless:server 启动时用自身路径里 Config.FRIDA_PREFIX("/usr/")的位置反推
# sysroot(server.vala),再拼出 agent 的绝对路径,所以二进制放在 <sysroot>/usr/sbin 即可。
#
# 用法:
#   tools/package-ios.sh --frida-root ~/Code/frida --rootless
#   tools/package-ios.sh --frida-root ~/Code/frida --rootful --arch "arm64 arm64e"
#   tools/package-ios.sh --frida-root ~/Code/frida --rootless --listen 127.0.0.1:28042
#
# deb 由 tools/mkdeb.py 生成(纯 Python,不依赖 dpkg/xz/ar);想用 dpkg-deb 加 --dpkg-deb。
# 常用开关:--no-verify(跳过特征自检)、--keep(保留中间文件)、--sign <证书名>。
set -e

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRIDA_ROOT="${FRIDA_ROOT:-}"
VERSION="16.2.1"
ROOTLESS=yes
ARCHS=""
OUT="${SRC_ROOT}/dist-ios"
SIGN="-"
LISTEN=""
MAINTAINER="rusda <noreply@localhost>"
KEEP=no
VERIFY=yes
USE_DPKG=no
PY="${PYTHON:-python3}"

usage() {
    sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --frida-root) FRIDA_ROOT="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --rootless) ROOTLESS=yes; shift ;;
        --rootful) ROOTLESS=no; shift ;;
        --arch) ARCHS="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --sign) SIGN="$2"; shift 2 ;;
        --listen) LISTEN="$2"; shift 2 ;;
        --maintainer) MAINTAINER="$2"; shift 2 ;;
        --no-verify) VERIFY=no; shift ;;
        --dpkg-deb) USE_DPKG=yes; shift ;;
        --keep) KEEP=yes; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数: $1" >&2; usage; exit 2 ;;
    esac
done

if [ -z "$FRIDA_ROOT" ]; then
    if [ -f "$SRC_ROOT/../frida/frida-core/meson.build" ]; then
        FRIDA_ROOT="$SRC_ROOT/../frida"
    else
        echo "缺少 --frida-root(指向已经编好的 frida 16.2.1 源码树)" >&2
        exit 2
    fi
fi
FRIDA_ROOT="$(cd "$FRIDA_ROOT" && pwd)"

if [ "$ROOTLESS" = yes ]; then
    DEB_ARCH="iphoneos-arm64"
    SYSROOT="/var/jb"
else
    DEB_ARCH="iphoneos-arm"
    SYSROOT=""
fi
# 包内相对前缀(不带前导 /,避免 MSYS 之类把参数改写成本地路径)
if [ -n "$SYSROOT" ]; then
    REL_PREFIX="${SYSROOT#/}/"
else
    REL_PREFIX=""
fi

# ---- 1. 确定要打包的架构 ----
if [ -z "$ARCHS" ]; then
    for a in arm64 arm64e arm64eoabi; do
        if [ -d "$FRIDA_ROOT/build/frida-ios-$a" ]; then
            ARCHS="$ARCHS $a"
        fi
    done
    ARCHS="${ARCHS# }"
fi
if [ -z "$ARCHS" ]; then
    echo "  [ERR] 找不到 build/frida-ios-<arch>,先编译:" >&2
    echo "        cd $FRIDA_ROOT && IOS_CERTID=- make build/frida-ios-arm64/usr/lib/pkgconfig/frida-core-1.0.pc" >&2
    exit 1
fi

WORK="${OUT}/.work"
rm -rf "$WORK"
mkdir -p "$WORK" "$OUT"

PATCHER="${SRC_ROOT}/tools/patch-macho.py"
MKDEP="${SRC_ROOT}/tools/mkdeb.py"
XCENT="$FRIDA_ROOT/frida-core/server/frida-server.xcent"
[ -f "$XCENT" ] || { echo "  [ERR] 缺少 $XCENT(确认 patch 打在了正确源码树上)" >&2; exit 1; }

echo "=== 收集产物(架构: $ARCHS)"
servers=()
agents=()
AGENT_DIR=""
AGENT_NAME=""
for arch in $ARCHS; do
    bdir="$FRIDA_ROOT/build/frida-ios-$arch"
    server="$bdir/usr/bin/frida-server"
    agent=$(ls "$bdir"/usr/lib/*/*-agent.dylib 2>/dev/null | head -n 1 || true)

    [ -f "$server" ] || { echo "  [ERR] 缺少 $server" >&2; exit 1; }
    [ -n "$agent" ] || { echo "  [ERR] $arch 下找不到 usr/lib/*/*-agent.dylib" >&2; exit 1; }

    this_dir=$(basename "$(dirname "$agent")")
    this_name=$(basename "$agent")
    if [ -z "$AGENT_DIR" ]; then
        AGENT_DIR="$this_dir"
        AGENT_NAME="$this_name"
    elif [ "$AGENT_DIR/$AGENT_NAME" != "$this_dir/$this_name" ]; then
        echo "  [ERR] 各架构 agent 文件名不一致: $AGENT_DIR/$AGENT_NAME vs $this_dir/$this_name" >&2
        exit 1
    fi

    cp "$server" "$WORK/frida-server.$arch"
    cp "$agent" "$WORK/agent.$arch"
    servers+=("$WORK/frida-server.$arch")
    agents+=("$WORK/agent.$arch")
    echo "  $arch: frida-server + usr/lib/$AGENT_DIR/$AGENT_NAME"
done

echo "=== 加固 Mach-O(等长字符串替换)"
"$PY" "$PATCHER" "${servers[@]}" "${agents[@]}"

echo "=== lipo"
if [ ${#servers[@]} -gt 1 ]; then
    lipo -create "${servers[@]}" -output "$WORK/frida-server"
    lipo -create "${agents[@]}" -output "$WORK/$AGENT_NAME"
else
    cp "${servers[0]}" "$WORK/frida-server"
    cp "${agents[0]}" "$WORK/$AGENT_NAME"
fi
echo "  frida-server archs: $(lipo -archs "$WORK/frida-server")"
echo "  $AGENT_NAME archs:  $(lipo -archs "$WORK/$AGENT_NAME")"

# agent 的 LC_ID_DYLIB 改成 FridaAgent(官方也这么做,加载后模块名不带文件名)
install_name_tool -id FridaAgent "$WORK/$AGENT_NAME"

echo "=== 重新签名(--sign 默认 - 即 ad-hoc)"
codesign -f -s "$SIGN" --entitlements "$XCENT" "$WORK/frida-server"
codesign -f -s "$SIGN" "$WORK/$AGENT_NAME"
codesign -dv "$WORK/frida-server" 2>&1 | sed -n '1,5p' | sed 's/^/  /'

if [ "$VERIFY" = yes ]; then
    echo "=== 自检(残留特征会直接失败)"
    if ! "$PY" "$PATCHER" --check "$WORK/frida-server" "$WORK/$AGENT_NAME"; then
        echo "  [ERR] 特征残留,见上面的 [FAIL];确认 apply-patches.sh 打全了、编的是 16.2.1" >&2
        echo "        确实要跳过可以加 --no-verify" >&2
        exit 1
    fi
fi

echo "=== 组织 deb(Architecture: $DEB_ARCH,prefix: ${SYSROOT:-/})"
PKG="$WORK/pkg"
CTRL="$WORK/control"
mkdir -p "$PKG$SYSROOT/usr/sbin" "$PKG$SYSROOT/usr/lib/$AGENT_DIR" \
         "$PKG$SYSROOT/Library/LaunchDaemons" "$CTRL"

cp "$WORK/frida-server" "$PKG$SYSROOT/usr/sbin/frida-server"
cp "$WORK/$AGENT_NAME" "$PKG$SYSROOT/usr/lib/$AGENT_DIR/$AGENT_NAME"
chmod 755 "$PKG$SYSROOT/usr/sbin/frida-server" "$PKG$SYSROOT/usr/lib/$AGENT_DIR/$AGENT_NAME"

PLIST="$PKG$SYSROOT/Library/LaunchDaemons/re.rusda.server.plist"
{
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0">'
    echo '<dict>'
    echo '	<key>Label</key>'
    echo '	<string>re.rusda.server</string>'
    echo '	<key>Program</key>'
    echo "	<string>$SYSROOT/usr/sbin/frida-server</string>"
    echo '	<key>ProgramArguments</key>'
    echo '	<array>'
    echo "		<string>$SYSROOT/usr/sbin/frida-server</string>"
    if [ -n "$LISTEN" ]; then
        echo '		<string>-l</string>'
        echo "		<string>$LISTEN</string>"
    fi
    echo '	</array>'
    if [ "$ROOTLESS" = no ]; then
        echo '	<key>EnvironmentVariables</key>'
        echo '	<dict>'
        echo '		<key>_MSSafeMode</key>'
        echo '		<string>1</string>'
        echo '	</dict>'
    fi
    echo '	<key>UserName</key>'
    echo '	<string>root</string>'
    echo '	<key>POSIXSpawnType</key>'
    echo '	<string>Interactive</string>'
    echo '	<key>RunAtLoad</key>'
    echo '	<true/>'
    if [ "$ROOTLESS" = no ]; then
        echo '	<key>LimitLoadToSessionType</key>'
        echo '	<string>System</string>'
    fi
    echo '	<key>KeepAlive</key>'
    echo '	<true/>'
    echo '	<key>ThrottleInterval</key>'
    echo '	<integer>5</integer>'
    echo '	<key>ExecuteAllowed</key>'
    echo '	<true/>'
    echo '</dict>'
    echo '</plist>'
} > "$PLIST"
chmod 644 "$PLIST"

INSTALLED_SIZE=$(du -sk "$PKG" | cut -f1)
write_control() {
    cat >"$CTRL/control" <<EOF
Package: re.rusda.server
Name: Frida (rusda)
Version: $VERSION
Priority: optional
Size: $1
Installed-Size: $INSTALLED_SIZE
Architecture: $DEB_ARCH
Description: Observe and reprogram running programs.
Homepage: https://frida.re/
Maintainer: $MAINTAINER
Author: $MAINTAINER
Section: Development
Conflicts: re.frida.server, re.frida.server64
Replaces: re.frida.server, re.frida.server64
EOF
}
write_control 1337
chmod 644 "$CTRL/control"

cat >"$CTRL/extrainst_" <<EOF
#!/bin/bash

launchcfg=$SYSROOT/Library/LaunchDaemons/re.rusda.server.plist
launchlog=\$(mktemp)

function dispose {
  rm -f "\$launchlog"
}
trap dispose EXIT

if [ "\$1" = upgrade ]; then
  launchctl unload "\$launchcfg" &> /dev/null
fi

if [ "\$1" = install ] || [ "\$1" = upgrade ]; then
  launchctl load "\$launchcfg" &> "\$launchlog"
  res=\$?

  if grep -q "Service cannot load in requested session" "\$launchlog"; then
    sed -ie "/LimitLoadToSessionType/,+1d" "\$launchcfg"
    launchctl load "\$launchcfg" &> "\$launchlog"
    res=\$?
  fi

  if [ \$res -ne 0 ]; then
    cat "\$launchlog" > /dev/stderr
    exit \$res
  fi
fi

exit 0
EOF
chmod 755 "$CTRL/extrainst_"

cat >"$CTRL/prerm" <<EOF
#!/bin/bash

if [ "\$1" = remove ] || [ "\$1" = purge ]; then
  launchctl unload $SYSROOT/Library/LaunchDaemons/re.rusda.server.plist &> /dev/null
fi

exit 0
EOF
chmod 755 "$CTRL/prerm"

echo "2.0" > "$WORK/debian-binary"

build_deb() {
    out="$1"
    rm -f "$out"
    if [ "$USE_DPKG" = yes ] && command -v dpkg-deb >/dev/null 2>&1; then
        rm -rf "$WORK/dpkg"
        mkdir -p "$WORK/dpkg/DEBIAN"
        cp -a "$PKG/." "$WORK/dpkg/"
        cp -a "$CTRL/." "$WORK/dpkg/DEBIAN/"
        dpkg-deb -Zxz --root-owner-group --build "$WORK/dpkg" "$out" >/dev/null
    else
        # 默认走纯 Python 的 mkdeb.py:不依赖 dpkg/xz/ar,产物结构与官方 deb 一致
        "$PY" "$MKDEP" --data "$PKG" --control "$CTRL" --out "$out" \
            --exec "${REL_PREFIX}usr/sbin/frida-server" \
            --exec "${REL_PREFIX}usr/lib/$AGENT_DIR/$AGENT_NAME" \
            --exec "extrainst_" --exec "prerm" >/dev/null
    fi
}

DEB="${OUT}/rusda_${VERSION}_${DEB_ARCH}.deb"
build_deb "$DEB"
PACKAGE_SIZE=$(wc -c < "$DEB" | tr -d ' ')
write_control "$PACKAGE_SIZE"
build_deb "$DEB"

cp "$WORK/frida-server" "$OUT/frida-server-${DEB_ARCH}"
cp "$WORK/$AGENT_NAME" "$OUT/${AGENT_NAME%.dylib}-${DEB_ARCH}.dylib"

echo "=== 完成"
ls -lh "$DEB" | awk '{printf "  %s  %s\n", $5, $9}'
echo "--- control"
sed 's/^/  /' "$CTRL/control"
echo "--- deb 内容"
if command -v dpkg-deb >/dev/null 2>&1; then
    dpkg-deb -c "$DEB" | awk '{printf "  %s %s %s\n", $1, $3, $NF}'
else
    "$PY" - "$DEB" <<'PY' | sed 's/^/  /'
import io, sys, tarfile
data = open(sys.argv[1], "rb").read()[8:]
pos = 0
while pos < len(data):
    h = data[pos:pos + 60]
    name = h[0:16].decode().strip()
    size = int(h[48:58].decode().strip())
    body = data[pos + 60:pos + 60 + size]
    if name.startswith("data.tar"):
        with tarfile.open(fileobj=io.BytesIO(body)) as tf:
            for m in tf.getmembers():
                if m.isreg():
                    print(f"{m.mode:04o} root/root {m.size:>10} {m.name}")
    else:
        print(f"{name} ({size} bytes)")
    pos += 60 + size + (size % 2)
PY
fi

[ "$KEEP" = yes ] || rm -rf "$WORK"
