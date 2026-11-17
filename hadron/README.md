# Hadron changes

Alchemac runs on the Hadron runtime, release 0.3.0
(https://github.com/Broyojo/hadron, commit `2faae2af7dbcd0b6448bea5c86c20c33548a792c`).

`alchemac-hadron.patch` is every change Alchemac makes to that checkout:

- `scripts/standalone-run`, `standalone-common.sh`, `prefix-init.sh`: start any Windows
  program in its own Wine prefix without Steam, with per-prefix locking, private runtime
  copies and a watchdog scoped to that prefix (see `docs/standalone.md`).
- Small changes to `paths.sh`, `play`, `stop`, `watchdog`, `hadron-procs.sh` and
  `runtime-versions.sh` so those tools stay within one prefix.
- `patches/fex/0006-…`: FEX cooperative suspension on conditional backedges. It fixes
  programs that hang while another thread suspends a JIT thread in a tight loop. This
  patch is kept downstream and is not submitted to FEX.
- Wine locale data fix, applied to a built runtime by `tools/runtime/patch-locale-nls.py`:
  `nls/locale.nls` listed an empty era name for the Korean calendar, where Windows returns
  the Dangi era name. Delphi-built programs crash at startup in a Korean locale because of
  it. The script inserts the name (16 bytes) and checks the result by re-parsing the file.
- `patches/mtld3d/0004-…` to `0006-…`: three fixes to mtld3d's Direct3D 9 layer that
  WPF hardware rendering needs: reading back a render target or back buffer through
  `GetDC` when it is not lockable, keeping an additional swap chain's back buffer alive
  while the application still holds it, and renaming a contended staging resource before
  `UpdateSurface` and fill writes.
- `patches/mtld3d/0007-…`: lets the 32-bit (i686) `d3d9.dll` link against llvm-mingw's CRT
  instead of the MSVC CRT (no MSVC libraries or xwin needed), as the ARM64X one already does:
  it supplies the CRT pieces MSVC would (`__fltused`, `__tls_array`, the `type_info` vtable,
  the thread-exit TLS callback) under `--cfg mtld3d_mingw_crt`; the upstream MSVC build is
  unchanged. Only the native `d3d9.dll` files change. Build both without a Wine tree with
  `tools/runtime/build-mtld3d-d3d9.sh` and put them into a runtime with
  `tools/runtime/patch-mtld3d-d3d9.py [--i386 <i386-d3d9.dll>] <runtime> <new-runtime> d3d9.dll <patch>...`
  (`mtld3d.dll` and `mtld3d.so` are not rebuilt).
- `patches/wine/0030-…`: Wine's `win32u` now makes a window a real child of its parent when a
  `WH_CBT` hook turns an owned top-level window into a child while it is being created
  (as MFC dialogs do), like Windows. Before, the window stayed top-level with `WS_CHILD` set and
  the coordinates the program computed were wrong, so nested dialogs collapsed or were
  misplaced. Rebuild `win32u.so` from the Wine tree and put it into a runtime with
  `tools/runtime/patch-wine-unix-lib.py <runtime> <new-runtime> win32u.so <patch>...`.

Apply with `git -C hadron apply alchemac-hadron.patch`, then build the runtime as Hadron
documents. Hadron and each component keep their own licenses.
