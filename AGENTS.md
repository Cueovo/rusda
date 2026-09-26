# rusda(frida 魔改 / 反检测)仓库说明

每个版本目录(如 `16.2.1/`)= 一份「frida 官方源码 + 我们的 patch」。仓库里不放 frida 源码,
运行时把 patch 打到对应版本的 frida 源码树上再编译。

## 目录结构(以 16.2.1 为例)

```
16.2.1/
  frida-core/*.patch            打到 frida-core 的补丁(路径相对 frida-core 根目录)
  frida-core/src/topatch.py     ELF 产物加固(Android/Linux,依赖 lief);embed-agent.sh 会调它
  frida-gum/*.patch             打到 frida-gum 的补丁
  tools/apply-patches.sh        一键打补丁(可重复执行)
  tools/patch-macho.py          Mach-O 产物加固(iOS/tvOS/macOS,纯 Python,等长替换 + --check 自检)
  tools/package-ios.sh          iOS deb 打包(patch → lipo → codesign → deb)
  tools/mkdeb.py                纯 Python 生成 deb(不依赖 dpkg/xz/ar)
  tools/package-android.sh      Android 产物打包(xz)
```

## 常用命令

```bash
# 1) 准备 frida 源码(版本必须和 patch 目录一致)
git clone -b 16.2.1 --recurse-submodules https://github.com/frida/frida.git
export IOS_CERTID="-"          # ad-hoc 签名;iOS/macOS 编译必须要这个变量

# 2) 打补丁(务必先跑,别直接编)
16.2.1/tools/apply-patches.sh --frida-root ./frida

# 3) Android
cd frida && make core-android-arm64 && ../16.2.1/tools/package-android.sh

# 4) iOS(必须在 macOS + Xcode 上;产物是 Mach-O)
cd frida && make build/frida-ios-arm64/usr/lib/pkgconfig/frida-core-1.0.pc
../16.2.1/tools/package-ios.sh --frida-root . --rootless          # Dopamine/palera1n rootless
../16.2.1/tools/package-ios.sh --frida-root . --rootful           # unc0ver/checkra1n

# 5) 自检(残留特征)
python3 16.2.1/tools/patch-macho.py --check <frida-server> <frida-agent.dylib>
```

CI:`.github/workflows/build-ios-deb.yml`(workflow_dispatch)在 GitHub 的 macOS runner 上完成
3~5 步,产物 deb + 两个二进制作为 artifact 上传。

## 关键事实(踩过的坑,改代码前先看)

- **iOS 是 installed assets**:`Makefile.macos.mk` 里 ios/tvos 用 `-Dassets=installed`,agent 是
  独立的 `frida-agent.dylib`,server 运行时按 `Config.FRIDA_AGENT_PATH`(prefix=/usr)去 dlopen。
  所以 Android 那套「编内嵌 agent 时跑 topatch」(`embed-agent.sh`)在 iOS 完全不生效,
  必须在打包阶段用 `patch-macho.py` 对 Mach-O 再打一遍。
- **入口符号只能在链接期改,而且不能叫 main**:Darwin 的符号解析走 export trie
  (`gum_darwin_module_resolve_export` 只查 trie),事后改符号表/sed 替换字符串没用。
  现在由 `frida-core/agent.vala.patch`(`#if DARWIN` + `[CCode (cname = "rusda_agent_main")]`)
  和 `frida-core/agent-meson.build.patch`(`-Wl,-exported_symbol,_rusda_agent_main`)在编译期完成,
  与 `darwin-host-session.vala.patch`(查找同名)配套。
  踩过的坑:一开始把名字设成 `main`,clang 15+ 直接报
  `error: first parameter of 'main' (argument count) must be of type 'int'`
  (main 的参数类型是硬校验,不只是返回值 warning),所以必须用普通名字;
  `--entrypoint <name>` 可以改(agent.vala / meson.build / darwin-host-session.vala 三处,
  要在干净源码树上跑一次;gum 的 mapper 测试里也已经是这个名字)。
- **新 clang 要放行一批默认 error**:frida 16.2.1 是 Xcode 11/12 时代编的,而 GitHub 现在
  只有 macOS 14/15/26(Xcode 15/16/26,clang 15+;macOS 13 已下线)。clang 15+ 把
  `implicit-function-declaration` / `int-conversion` / `incompatible-pointer-types` 这一家族
  从 warning 提升为 error,老版 Vala 生成的 C 会直接编译失败(例如
  `lib/base/session.vala: ... 1 error generated`)。`frida-core/clang16-compat.meson.build.patch`
  给 frida-core 的 `add_project_arguments` 加了对应的 `-Wno-error=...`,把这些降回 warning。
  注意 `-Wno-error=return-mismatch` 在 clang 15 上不存在(会报 unknown warning option),别加。
- **改完二进制必须重签名**:iOS 构建期由 `server/post-process.sh` 用 `IOS_CERTID` +
  `server/frida-server.xcent` 签名;`package-ios.sh` 在 patch/lipo 之后重做一遍
  (`codesign -f -s - --entitlements ...`),否则设备上会被 amfid 干掉。
- **rootless 靠路径自举**:`server.vala` 用自身路径里 `FRIDA_PREFIX`("/usr/")的位置反推 sysroot,
  所以二进制放在 `<sysroot>/usr/sbin/frida-server`(rootless = `/var/jb/usr/sbin/...`)就能找到
  `<sysroot>/usr/lib/<dir>/<agent>`。deb 布局:rootless 加 `/var/jb` 前缀、`Architecture: iphoneos-arm64`;
  plist 用 `re.rusda.server`(与 `server.vala` 的 `DEFAULT_DIRECTORY` 改名保持一致)。
- **不能乱改线上协议字符串**:`re.frida.HostSession` 之类的 D-Bus 名字、`frida:rpc` 字面量必须和
  官方 frida-tools/frida-python 一致(所以 rpc.vala 只是 base64 化,不改协议)。
- 编译依赖:frida 官方预编译 deps(`build.frida.re/deps/20240123/{toolchain,sdk-ios}-*.tar.bz2`)仍可下载;
  Xcode 用 14/15 都可以,`arm64eoabi` 才需要 Xcode 11.7(`XCODE11=/Applications/Xcode-11.7.app`)。
- `patch-macho.py --check` 里 `[FAIL]` 表示「源码 patch 打全了就该消失」的特征,`[hint]`
  表示无法在本脚本消除的(JS 侧 `frida:rpc`、模块路径 `/usr/lib/frida/`)。

## 本地验证脚本的办法(不需要 Mac)

- `bash -n tools/*.sh` 语法检查。
- `apply-patches.sh` 可以直接对 GitHub 拉下来的 frida-core/frida-gum 源码树跑(`git apply` 不要求是 git 仓库)。
- `patch-macho.py` 可以拿官方 `frida_<ver>_iphoneos-arm64.deb` 里的 `frida-server` /
  `frida-agent.dylib` 试(deb 是 ar 包,用 Python 解 ar + tarfile 即可),再用 `lief` 校验
  打完后文件大小/load commands/sections/exports 不变。
- `package-ios.sh` 在没有 macOS 工具时可以用 stub 的 `lipo`/`install_name_tool`/`codesign`
  走通打包逻辑(把 stub 放进 PATH 最前面)。
