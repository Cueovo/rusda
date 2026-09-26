#!/bin/bash
# 16.2.1 patch 应用脚本(Android / iOS 共用)
#
# 把本版本目录里的 patch 打到 frida 16.2.1 源码树上:
#   <版本目录>/frida-core/*.patch -> <frida>/frida-core/   (git apply -p1)
#   <版本目录>/frida-gum/*.patch  -> <frida>/frida-gum/
#   <版本目录>/frida-core/src/topatch.py -> <frida>/frida-core/src/
#     (embed-agent.sh.patch 里的内嵌 agent 加固依赖这个路径)
#
# 用法:
#   tools/apply-patches.sh --frida-root ~/Code/frida
#   tools/apply-patches.sh --frida-root ~/Code/frida --entrypoint rusda_agent_main
#
# 关于入口符号:agent 的入口默认叫 rusda_agent_main —— lib/agent/agent.vala 里加一格
# Darwin 限定的 [CCode (cname = "rusda_agent_main")],lib/agent/meson.build 里 Darwin
# 分支改成导出 _rusda_agent_main。这一步必须在链接期做:Mach-O 的符号查找走 export trie
# (frida 用 gum_darwin_module_resolve_export),事后改符号表字符串没有任何作用。
# 别用 main 这个名字:clang 15+ 对 main 的参数类型是硬校验(error,不是 warning),
#   error: first parameter of 'main' (argument count) must be of type 'int'
# 会被直接拒;--entrypoint 可以换成别的普通名字,脚本会同步改掉相关引用点。
#
# 可重复执行:已经打过的 patch 会显示 [skip]。
set -e

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRIDA_ROOT="${FRIDA_ROOT:-}"
ENTRYPOINT="rusda_agent_main"
PY="${PYTHON:-python3}"

usage() {
    sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --frida-root) FRIDA_ROOT="$2"; shift 2 ;;
        --entrypoint) ENTRYPOINT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数: $1" >&2; usage; exit 2 ;;
    esac
done

if [ -z "$FRIDA_ROOT" ]; then
    if [ -f "$SRC_ROOT/../frida/frida-core/meson.build" ]; then
        FRIDA_ROOT="$SRC_ROOT/../frida"
    else
        echo "缺少 --frida-root(指向 frida 16.2.1 源码树)" >&2
        usage
        exit 2
    fi
fi
FRIDA_ROOT="$(cd "$FRIDA_ROOT" && pwd)"

if [ ! -f "$FRIDA_ROOT/frida-core/meson.build" ] || [ ! -f "$FRIDA_ROOT/frida-gum/meson.build" ]; then
    echo "  [ERR] $FRIDA_ROOT 看起来不是 frida 源码树(缺 frida-core/frida-gum 子模块)" >&2
    echo "        请确认 clone 时带了 --recurse-submodules" >&2
    exit 1
fi

echo "=== 应用 patch"
echo "  frida 源码: $FRIDA_ROOT"
echo "  版本目录:   $SRC_ROOT"
echo "  入口符号:   $ENTRYPOINT"

apply_group() {
    repo="$1"
    dir="$2"
    for p in "$dir"/*.patch; do
        [ -e "$p" ] || continue
        if git -C "$repo" apply --check "$p" >/dev/null 2>&1; then
            git -C "$repo" apply "$p"
            echo "  [ok]   $(basename "$p")"
        elif git -C "$repo" apply --check --reverse "$p" >/dev/null 2>&1; then
            echo "  [skip] $(basename "$p")(已打过)"
        else
            echo "  [ERR]  $(basename "$p") 打不上,确认 frida 版本是 16.2.1" >&2
            exit 1
        fi
    done
}

apply_group "$FRIDA_ROOT/frida-core" "$SRC_ROOT/frida-core"
apply_group "$FRIDA_ROOT/frida-gum" "$SRC_ROOT/frida-gum"

topatch_src="$SRC_ROOT/frida-core/src/topatch.py"
topatch_dst="$FRIDA_ROOT/frida-core/src/topatch.py"
if [ "$topatch_src" != "$topatch_dst" ]; then
    cp -f "$topatch_src" "$topatch_dst"
    echo "  [ok]   src/topatch.py"
fi

# 纯文本替换(不用 sed,免得转义/分隔符踩坑)
rewrite() {
    file="$1"
    from="$2"
    to="$3"
    tmp="$file.tmp.$$"
    if [ ! -f "$file" ]; then
        echo "  [ERR] 找不到 $file" >&2
        exit 1
    fi
    if [ "$from" = "$to" ]; then
        return 0
    fi
    if ! grep -qF -- "$from" "$file"; then
        if grep -qF -- "$to" "$file"; then
            echo "  [skip] ${file#$FRIDA_ROOT/}: 已经是 $to"
            return 0
        fi
        echo "  [ERR] $file 里既找不到 '$from' 也找不到 '$to'" >&2
        exit 1
    fi
    "$PY" - "$file" "$tmp" "$from" "$to" <<'PY' || exit 1
import sys
path, out, old, new = sys.argv[1:5]
old_b, new_b = old.encode(), new.encode()
data = open(path, "rb").read()
if data.count(old_b) == 0:
    sys.exit(1)
open(out, "wb").write(data.replace(old_b, new_b))
PY
    mv "$tmp" "$file"
    echo "  [ok]   ${file#$FRIDA_ROOT/}: $from -> $to"
}

# patch 文件里 Darwin 入口符号默认就是 rusda_agent_main;--entrypoint 只在这条链路上改
# (agent.vala 的 cname、meson 的导出符号、darwin-host-session 的查找名)。
# 注意两点:
#   1) 不要用 main:clang 15+ 对 main 的参数类型是硬校验(error,不是 warning),
#      error: first parameter of 'main' (argument count) must be of type 'int'
#   2) --entrypoint 请在干净的源码树上用一次;换名会改掉 patch 的上下文,同一棵树上
#      再跑会报「打不上」,重新 clone 或 git checkout 那几个文件即可。
# Darwin 限定的 [CCode (cname = ...)] 是链接期改名的唯一办法(Mach-O 的符号查找走
# export trie),已验证 valac 会按 cname 生成符号。
if [ "$ENTRYPOINT" = "main" ]; then
    echo "  [warn] 入口符号 main 会被 clang 15+ 拒绝(参数类型硬校验),建议用 rusda_agent_main" >&2
fi
echo "=== 入口符号: $ENTRYPOINT"
rewrite "$FRIDA_ROOT/frida-core/lib/agent/agent.vala" '[CCode (cname = "rusda_agent_main")]' "[CCode (cname = \"$ENTRYPOINT\")]"
rewrite "$FRIDA_ROOT/frida-core/lib/agent/meson.build" '-Wl,-exported_symbol,_rusda_agent_main' "-Wl,-exported_symbol,_$ENTRYPOINT"
rewrite "$FRIDA_ROOT/frida-core/src/darwin/darwin-host-session.vala" 'entrypoint = "rusda_agent_main"' "entrypoint = \"$ENTRYPOINT\""

echo "=== 完成"
echo "  Android: cd $FRIDA_ROOT && make core-android-arm64 && $SRC_ROOT/tools/package-android.sh"
echo "  iOS:     cd $FRIDA_ROOT && IOS_CERTID=- make build/frida-ios-arm64/usr/lib/pkgconfig/frida-core-1.0.pc \\"
echo "                 && $SRC_ROOT/tools/package-ios.sh --frida-root $FRIDA_ROOT --rootless"
