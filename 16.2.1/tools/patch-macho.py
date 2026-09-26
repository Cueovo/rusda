#!/usr/bin/env python3
# 16.2.1 Mach-O(iOS/tvOS/macOS)产物字符串加固
#
# 和 frida-core/src/topatch.py 的区别:
#   * topatch.py 走 lief + `.rodata` + `sed -b`,是给 ELF(Android/Linux)用的;
#     Mach-O 的段名不是 .rodata,而且 macOS 自带的 sed 没有 -b。
#   * 这里只做「等长原地字节替换」,不解析、不重排文件结构,所以对 __TEXT/__cstring、
#     __const、__DATA_CONST 以及 fat(universal)文件同样有效;替换后文件大小、偏移、
#     签名槽位置都不变(改完仍需重新 codesign,见 package-ios.sh)。
#
# 不在这个脚本里的两件事(都是编译期的事,见 apply-patches.sh):
#   * 入口符号 frida_agent_main -> main:Mach-O 的符号查找走 export trie,链接期就得定好;
#   * 运行时临时目录 re.frida.server -> re.rusda.server、frida:rpc 字面量的 base64 化。
#
# 用法:
#   tools/patch-macho.py frida-server frida-agent.dylib          # 原地加固(生成 .orig 备份)
#   tools/patch-macho.py --check frida-server frida-agent.dylib  # 只自检,有残留则退出码 1
#
# 自检里 [FAIL] 的是「patch 打全了就该消失」的特征;[hint] 的是无法/不能在本脚本消除的
# (例如 frida:rpc 必须与官方 frida-tools 保持一致,只能靠 rpc.vala 那种 base64 手法)。
import sys

REVERSED = [b"FridaScriptEngine", b"GLib-GIO", b"GDBusProxy", b"GumScript"]
REPLACEMENTS = []
for _s in REVERSED:
    REPLACEMENTS.append((_s, _s[::-1]))
REPLACEMENTS += [
    (b"gum-js-loop", b"russellloop"),
    (b"gmain", b"rmain"),
    (b"gdbus", b"rubus"),
]

# 打完源码 patch + 本脚本后,这些特征必须消失
WATCH_FAIL = [
    b"FridaScriptEngine",
    b"GumScript",
    b"gum-js-loop",
    b"gmain",
    b"gdbus",
    b"frida_agent_main",
    b"re.frida.server",
]
# 只能提示
WATCH_HINT = {
    b"frida:rpc": "JS 侧 rpc 字面量,必须和官方 frida-tools 一致(rpc.vala 只是 base64 化了 Vala 侧)",
    b"/usr/lib/frida/": "加载后的模块路径;要消掉得编译期改 meson 的 asset_dir/agent_name",
}

MACHO_MAGICS = (
    b"\xcf\xfa\xed\xfe",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xfe\xed\xfa\xce",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf",
)

for _old, _new in REPLACEMENTS:
    assert len(_old) == len(_new), f"{_old!r} 与 {_new!r} 长度不一致,无法原地替换"


def patch_file(path, check_only):
    with open(path, "rb") as f:
        blob = f.read()
    if len(blob) < 4 or blob[:4] not in MACHO_MAGICS:
        print(f"  [ERR] {path} 不是 Mach-O(前 4 字节 {blob[:4]!r})")
        return 1

    out = blob
    for old, new in REPLACEMENTS:
        hits = out.count(old)
        if hits:
            verb = "would patch" if check_only else "patch"
            print(f"  {path}: {verb} {old.decode()} -> {new.decode()} x{hits}")
            if not check_only:
                out = out.replace(old, new)

    if not check_only and out != blob:
        with open(path + ".orig", "wb") as f:
            f.write(blob)
        with open(path, "wb") as f:
            f.write(out)

    fails = [p for p in WATCH_FAIL if p in out]
    for p in fails:
        print(f"  [FAIL] {path}: 残留 {p.decode()}")
    for p, why in WATCH_HINT.items():
        if p in out:
            print(f"  [hint] {path}: 含 {p.decode()} — {why}")

    return len(fails) if check_only else 0


def main(argv):
    check_only = False
    files = []
    for arg in argv:
        if arg == "--check":
            check_only = True
        elif arg in ("-h", "--help"):
            print("用法: patch-macho.py [--check] FILE...\n"
                  "  --check  只检查特征残留(退出码 1 表示未加固干净),不修改文件\n"
                  "  默认     等长原地替换,并生成 FILE.orig 备份")
            return 0
        else:
            files.append(arg)

    if not files:
        print("用法: patch-macho.py [--check] FILE...", file=sys.stderr)
        return 2

    failures = 0
    for path in files:
        try:
            failures += patch_file(path, check_only)
        except OSError as e:
            print(f"  [ERR] {path}: {e}")
            failures += 1

    if check_only:
        if failures:
            print(f"  [FAIL] {failures} 处特征残留")
            return 1
        print("  [ok] 无残留特征")
    else:
        print("  [ok] 加固完成(上面若有 [FAIL],说明源码 patch 没打全或版本不对)")
    return 1 if failures and check_only else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
