# Alchemac

Alchemac runs unmodified Windows applications on Apple Silicon Macs without
Rosetta 2. It is a front end for the Hadron runtime: Wine for the Windows API,
FEX for x86/x64 code and DXMT for Direct3D 11 on Metal. Opening Alchemac never
starts Wine; programs run only when you choose them.

Status: pre-release (0.5). Every program behaves differently under Wine;
nothing here guarantees that a given program works.

## Requirements

- A Mac with Apple silicon (M1 or later)
- macOS 27 or later
- About 1.2 GB of disk space for the app, plus your programs

## Install

1. Open `Alchemac-<version>.dmg` and drag Alchemac into Applications.
2. Alchemac is not notarized by Apple, so the first launch is blocked.
   Open it once, then go to **System Settings ▸ Privacy & Security** and click
   **Open Anyway** next to the Alchemac message. Later launches open normally.

## Use

- **설치 파일 실행 (Run installer)**: runs a Windows setup EXE. Programs it
  installs are offered for registration when it finishes.
- **프로그램 등록 (Register program)**: registers an EXE that needs no installer.
  The folder is copied into the library; the original is never modified.
- **Wine 환경 (Wine environment)**: programs share one environment unless you
  give a program its own. Different environments can run at the same time.
- **선명한 화면 (Retina)**: per environment. Programs draw at native resolution;
  "크기 보정" scales a single program that draws too small.
- **애드온 (Add-ons)**: `.alchemacaddon` folders that describe settings a specific
  program needs. Install one from the 애드온 menu, then register the program; the
  add-on is applied automatically. Add-ons contain no code (see below).

The interface is in Korean for now.

## Add-on format

An add-on is a folder named `<Name>.alchemacaddon` with an `addon.json` and an
optional `README.md` and `LICENSE`. Nothing else in the folder is installed.

```json
{
  "schema": 1,
  "id": "example",
  "name": "Example Game",
  "version": "1.0.0",
  "summary": "Optional one-line description.",
  "detect": { "executable": "Launcher.exe", "siblings": ["Game_Data"] },
  "import": { "exclude": ["account.txt", "logs", "*.log", ".*"] },
  "environment": { "mode": "private" },
  "launch": { "env": { "WINEDLLOVERRIDES": "d3dcompiler_47=n" }, "englishInput": true }
}
```

- `detect`: the EXE the user selects, and files or folders that must sit next to it.
- `import.exclude`: names left out when the program folder is copied (`name`,
  `*.ext`, or `.*` for hidden files).
- `environment.mode`: `private` gives the program its own Wine environment;
  `shared` uses the default one.
- `launch.env`: only `WINEDLLOVERRIDES`, `DOTNET_BUNDLE_EXTRACT_BASE_DIR`,
  `DXMT_CONFIG`, `MTLD3D_CONFIG`, `MTL_HUD_ENABLED` and the `HADRON_*` options
  listed in `Addon.swift` are accepted, and each value must have the shape
  `Addon.allowedValue` expects for its key (for example `HADRON_MEM_LIMIT_GB`
  is a plain number, `*_CONFIG` has no `log.`/`debug.` keys or paths).
- `launch.englishInput`: select an English keyboard layout before starting.

## Storage

- Library: `~/Library/Application Support/Alchemac/`
- Logs: `~/Library/Logs/Alchemac/`. Logs can contain personal data; redact them
  before sharing.
- Deleting moves files to the Trash.
- Each Wine environment runs from a private copy of the bundled runtime. Before a
  new session starts, the copy is checked against the signed app (entry list, sizes,
  change times, host scripts byte for byte); a changed copy is deleted and recreated.

## Building from source

`scripts/build-alchemac-app.py [--release]` builds the app (and with `--release`
the DMG). It needs Xcode command line tools, an llvm-mingw toolchain for the
small Windows helper, and a Hadron runtime built from Hadron 0.3.0
(commit `2faae2af7dbcd0b6448bea5c86c20c33548a792c`) with the patches in
`hadron/`, then patched with `tools/runtime/patch-locale-nls.py <runtime> <new-runtime>`
(Korean calendar era name in Wine's locale data). mtld3d's native `d3d9.dll` files (ARM64X and 32-bit) are rebuilt with the
patches `hadron/patches/mtld3d/0004-…`–`0006-…` (fixes needed by WPF hardware rendering) and `0007-…` (links the 32-bit one against llvm-mingw's CRT instead of the MSVC CRT) using
`tools/runtime/build-mtld3d-d3d9.sh` (no Wine tree needed) and installed with
`tools/runtime/patch-mtld3d-d3d9.py [--i386 <i386-d3d9.dll>] <runtime> <new-runtime> d3d9.dll <patch>...`. Wine's `win32u.so`
is rebuilt with `hadron/patches/wine/0030-…` (a window that a `WH_CBT` hook turns into a child is reparented
like on Windows) and installed with `tools/runtime/patch-wine-unix-lib.py <runtime> <new-runtime> win32u.so <patch>...`. See `hadron/README.md`. Place `wine-mono-11.3.0-x86.msi` (from
https://dl.winehq.org/wine/wine-mono/11.3.0/) and its `COPYING` in `work/wine-mono/`.

Before every launch the Windows helper (`prefix-profile.c`) prepares the environment's prefix:
Korean font fallbacks (GDI substitutes/links and DirectWrite replacements, only where
the font is absent and no entry exists). WPF hardware rendering is on by default again: 0.5.7 set
`Avalon.Graphics\DisableHWAcceleration=1`, and the helper removes that value once per environment
(marker `HKCU\Software\Alchemac\WpfHardwareRestored`) if it is still 1; a value set later is kept.

If the environment has no `Internet Settings\Connections\DefaultConnectionSettings` value, the helper writes a direct-connection one (proxy auto-detect off). Wine derives the WPAD host from the Mac's `<name>.local` host name, and on some networks `wpad.local` accepts the connection but never answers, which stalls the first .NET/WinHTTP request for 60 s; Windows does not search WPAD under `.local`. An existing value, such as a proxy the user configured, is left alone.

A Wine environment receives mtld3d's `d3d9.dll` only when it is created. On every run except `--check` the
helper (`refresh_d3d9` in `prefix-profile.c`, after the runtime's own migration and before the target starts)
replaces that file in `C:\windows\system32` (aarch64) and `C:\windows\syswow64` (i386) with the one in
`..\SharedSupport\runtime\dist\lib\hadron\d3d9` of the app, when it differs. Only a file that already contains
the "mtld3d" marker is replaced (copy to a temporary file, then `MoveFileEx`); Wine's builtin, a file a user put
there, or an absent file is never touched. Failures print `prefix-profile: d3d9 refresh failed (...)` and do not
stop the launch. The helper is an x86_64 PE, but x64 code on ARM64 Wine is not a WOW64 process, so
`system32` is not redirected for it.

The app also looks after leftovers: at launch it offers to stop Wine sessions an earlier run left behind (the
supervisor holds the environment's session lock; see `OrphanSessions` in `Maintenance.swift`), cleans stale
staging folders and old private runtime copies in the background (`StartupCleanup`), and "Wine 환경 > 환경 백업 정리…"
keeps only the newest migration snapshot of each environment (`Backups`).

## License

Alchemac's own code is MIT licensed (`LICENSE`). The app bundles the Hadron
runtime (BSD-3-Clause, © 2026 David Andrews) and the components it contains,
including Wine (LGPL-2.1), FEX (MIT), DXMT, Mesa and FFmpeg, and Wine Mono, each
under its own license. All license texts are in the app under **관리 ▸ 오픈소스 라이선스**.
Changes Alchemac makes to Hadron and FEX are published in `hadron/`.

Alchemac is an independent project. It is not affiliated with or endorsed by
Hadron, the Wine project, CodeWeavers, Microsoft or Apple. Windows programs and
games are not included and keep their own licenses.
