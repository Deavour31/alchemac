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
  listed in `Addon.swift` are accepted.
- `launch.englishInput`: select an English keyboard layout before starting.

## Storage

- Library: `~/Library/Application Support/Alchemac/`
- Logs: `~/Library/Logs/Alchemac/`. Logs can contain personal data; redact them
  before sharing.
- Deleting moves files to the Trash.

## Building from source

`scripts/build-alchemac-app.py [--release]` builds the app (and with `--release`
the DMG). It needs Xcode command line tools, an llvm-mingw toolchain for the
small Windows helper, and a Hadron runtime built from Hadron 0.3.0
(commit `2faae2af7dbcd0b6448bea5c86c20c33548a792c`) with the patches in
`hadron/`. See `hadron/README.md`. Place `wine-mono-11.3.0-x86.msi` (from
https://dl.winehq.org/wine/wine-mono/11.3.0/) and its `COPYING` in `work/wine-mono/`.

## License

Alchemac's own code is MIT licensed (`LICENSE`). The app bundles the Hadron
runtime (BSD-3-Clause, © 2026 David Andrews) and the components it contains,
including Wine (LGPL-2.1), FEX (MIT), DXMT, Mesa and FFmpeg, and Wine Mono, each
under its own license. All license texts are in the app under **관리 ▸ 오픈소스 라이선스**.
Changes Alchemac makes to Hadron and FEX are published in `hadron/`.

Alchemac is an independent project. It is not affiliated with or endorsed by
Hadron, the Wine project, CodeWeavers, Microsoft or Apple. Windows programs and
games are not included and keep their own licenses.
