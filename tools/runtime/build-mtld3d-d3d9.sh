#!/usr/bin/env bash
# Build only the native d3d9.dll files of mtld3d (D3D9 on Metal): the ARM64X one and
# the 32-bit (i686, syswow64) one.
#
# Why this exists: the d3d9 crate of mtld3d is the only part that changed in the
# Hadron mtld3d patches 0004-0006, so only the native d3d9.dll has to be rebuilt.
# Doing that normally needs a full Wine build tree and an MSVC CRT. This script needs
# neither: rustup (stable), Homebrew lld and the llvm-mingw toolchain are enough.
#   - The d3d9 staticlib is built twice (aarch64 and arm64ec, windows-msvc targets).
#     The C++ of snmalloc is compiled by llvm-mingw clang in mingw mode with small
#     shims (stdlib/CRT pre-include, ARM64_SYSREG macro, no exceptions/RTTI, thread
#     cleanup hook); for ARM64EC an extra pre-include header hides the x86-64 macros
#     so snmalloc takes its ARM path. The header is generated into the output dir.
#   - lld-link joins both libraries into one ARM64X image, against the llvm-mingw
#     import libraries; compiler-rt builtins provide __chkstk.
#
#   - The i686 DLL is built the same way: the staticlib is compiled for
#     i686-pc-windows-msvc with `--cfg mtld3d_mingw_crt` (patch 0007) and linked by
#     lld-link against llvm-mingw's i686 CRT instead of upstream's MSVC CRT (so no xwin
#     and no Microsoft licence). The pieces the MSVC CRT would give (__fltused,
#     __tls_array, type_info vtable, thread-exit TLS callback) come from the crate;
#     __aulldiv, __aullrem and __chkstk are imported from ntdll.dll (Wine's i386 ntdll
#     exports them with the MSVC calling conventions) through an import library made
#     here with llvm-dlltool from a generated .def.
#
# Limits: mtld3d.dll / mtld3d.so are NOT rebuilt; they stay as shipped in the base
# runtime. The i686 DLL uses the mingw CRT, not upstream's MSVC CRT.
#
# Usage: build-mtld3d-d3d9.sh [mtld3d-src] [llvm-mingw-dir] [out-dir]
#   or env MTLD3D_SRC, LLVM_MINGW, OUT_DIR (arguments win). PROFILE (default
#   production), LLD_LINK, RUSTUP_BIN (default /opt/homebrew/opt/rustup/bin) also work.
#   mtld3d-src: mtld3d checkout with the Hadron patches (0001-0007) already applied.
#   BUILD_I686=0 skips the i686 DLL (default 1).
# Result: <out-dir>/windows/arm64x/<profile>/d3d9.dll
#         <out-dir>/windows/i686/<profile>/d3d9.dll
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC=${1:-${MTLD3D_SRC:-$ROOT/work/hadron-prototype/mtld3d}}
MINGW=${2:-${LLVM_MINGW:-$ROOT/work/hadron-prototype/toolchains/llvm-mingw-20260922-ucrt-macos-universal}}
OUT=${3:-${OUT_DIR:-$ROOT/work/hadron-prototype/mtld3d-d3d9-out}}
PROFILE=${PROFILE:-production}
LLD_LINK=${LLD_LINK:-/opt/homebrew/opt/lld/bin/lld-link}
RUSTUP_BIN=${RUSTUP_BIN:-/opt/homebrew/opt/rustup/bin}
[[ -d $SRC/windows/d3d9 ]] || { echo "not an mtld3d source dir: $SRC" >&2; exit 2; }
[[ -x $MINGW/bin/clang++ ]] || { echo "not an llvm-mingw dir: $MINGW" >&2; exit 2; }
[[ -x $LLD_LINK ]] || { echo "lld-link not found: $LLD_LINK (brew install lld)" >&2; exit 2; }
SRC=$(cd "$SRC" && pwd); MINGW=$(cd "$MINGW" && pwd)
mkdir -p "$OUT/binshim" "$OUT/ecshim"; OUT=$(cd "$OUT" && pwd)
ln -sf "$MINGW/bin/llvm-ar" "$OUT/binshim/llvm-lib"
export PATH="$RUSTUP_BIN:$MINGW/bin:$OUT/binshim:$PATH"
cat > "$OUT/ecshim/ec-pre.h" <<'HDR'
/* ARM64EC C++ built in mingw mode: pull in the CRT first, then hide the x86-64
   macros so snmalloc takes its ARM path (MSVC mode never sees its GNU asm). */
#include <stdlib.h>
#include <math.h>
#include <string.h>
#include <windows.h>
#include <intrin.h>
#undef __x86_64__
#undef __amd64__
#undef _M_X64
#undef _M_AMD64
HDR
export CARGO_TARGET_DIR="$OUT/windows" CFLAGS="-DNDEBUG" CXXFLAGS="-DNDEBUG"
arm64_cxx='-fno-exceptions -fno-rtti -fno-threadsafe-statics -DSNMALLOC_USE_THREAD_CLEANUP -DARM64_SYSREG(op0,op1,crn,crm,op2)=((((op0)&1)<<14)|(((op1)&7)<<11)|(((crn)&15)<<7)|(((crm)&15)<<3)|((op2)&7))'
cd "$SRC/windows"
for target in aarch64-pc-windows-msvc arm64ec-pc-windows-msvc; do
  mt=${target%%-*}-w64-mingw32; inc="--target=$mt"; cxxinc="--target=$mt -include stdlib.h"
  [[ $target == arm64ec* ]] && cxxinc="$cxxinc -include $OUT/ecshim/ec-pre.h"
  env RUSTFLAGS="-C target-feature=-crt-static" "CFLAGS_$target=$inc" "CXXFLAGS_$target=$arm64_cxx $cxxinc" \
      "AR_$target=llvm-lib" "CC_$target=$MINGW/bin/clang" "CXX_$target=$MINGW/bin/clang++" \
      "ARFLAGS_arm64ec-pc-windows-msvc=-machine:arm64ec" \
      cargo +stable rustc --profile "$PROFILE" --target "$target" -p d3d9 --crate-type staticlib
done
A=$OUT/windows/aarch64-pc-windows-msvc/$PROFILE E=$OUT/windows/arm64ec-pc-windows-msvc/$PROFILE X=$OUT/windows/arm64x/$PROFILE
for lib in "$A/d3d9.lib" "$E/d3d9.lib"; do
  syms=$(llvm-nm "$lib" 2>/dev/null)
  grep -qE ' T #?_malloc_thread_cleanup$' <<<"$syms" || { echo "no _malloc_thread_cleanup in $lib" >&2; exit 1; }
  ! grep -qE ' #?__tlregdtor$' <<<"$syms" || { echo "__tlregdtor in $lib" >&2; exit 1; }
done
mkdir -p "$X"; libs=()
for l in mingw32 mingwex ucrt kernel32 mincore user32 advapi32 gdi32 ws2_32 userenv bcrypt dbghelp ntdll; do
  libs+=("$MINGW/aarch64-w64-mingw32/lib/lib$l.a")
done
"$LLD_LINK" -lldmingw /dll /machine:arm64x /nodefaultlib /opt:ref,icf /entry:DllMainCRTStartup \
  /def:"$SRC/windows/d3d9/d3d9.def" /defarm64native:"$SRC/windows/d3d9/d3d9.def" /debug /pdb:"$X/d3d9.pdb" /out:"$X/d3d9.dll" \
  "$MINGW/aarch64-w64-mingw32/lib/dllcrt2.o" "$A/d3d9.lib" "$E/d3d9.lib" "${libs[@]}" \
  "$MINGW"/lib/clang/*/lib/windows/libclang_rt.builtins-aarch64.a
ls -l "$X/d3d9.dll"; shasum -a 256 "$X/d3d9.dll"

[[ ${BUILD_I686:-1} == 0 ]] && exit 0
# ---- i686 (32-bit) DLL, mingw CRT ----
t=i686-pc-windows-msvc; mt=i686-w64-mingw32
I=$OUT/windows/$t/$PROFILE X86=$OUT/windows/i686/$PROFILE
env RUSTFLAGS="-C target-cpu=pentium4 -C target-feature=-crt-static --cfg mtld3d_mingw_crt" \
    "CFLAGS_$t=--target=$mt -march=pentium4 -fno-omit-frame-pointer" \
    "CXXFLAGS_$t=--target=$mt -march=pentium4 -fno-omit-frame-pointer -include stdlib.h -fno-exceptions -fno-rtti -fno-threadsafe-statics -DSNMALLOC_USE_THREAD_CLEANUP" \
    "AR_$t=llvm-lib" "CC_$t=$MINGW/bin/clang" "CXX_$t=$MINGW/bin/clang++" \
    cargo +stable rustc --profile "$PROFILE" --target "$t" -p d3d9 --crate-type staticlib
syms=$(llvm-nm "$I/d3d9.lib" 2>/dev/null)
grep -qE ' T __malloc_thread_cleanup$' <<<"$syms" || { echo "no _malloc_thread_cleanup in $I/d3d9.lib" >&2; exit 1; }
! grep -qE ' __tlregdtor$' <<<"$syms" || { echo "__tlregdtor in $I/d3d9.lib" >&2; exit 1; }
mkdir -p "$X86"
# Import library for the MSVC runtime helpers Wine's i386 ntdll.dll exports.
printf 'LIBRARY ntdll.dll\nEXPORTS\n_aulldiv\n_aullrem\n_chkstk\n' > "$OUT/ntdll-msvc-helpers.def"
llvm-dlltool -m i386 -d "$OUT/ntdll-msvc-helpers.def" -l "$OUT/ntdll-msvc-helpers.lib"
libs=()
for l in mingw32 mingwex ucrt kernel32 mincore user32 advapi32 gdi32 ws2_32 userenv bcrypt dbghelp ntdll; do
  libs+=("$MINGW/$mt/lib/lib$l.a")
done
"$LLD_LINK" -lldmingw /dll /machine:x86 /nodefaultlib /opt:ref,icf /entry:DllMainCRTStartup@12 \
  /def:"$SRC/windows/d3d9/d3d9.def" /debug /pdb:"$X86/d3d9.pdb" /out:"$X86/d3d9.dll" \
  "$MINGW/$mt/lib/dllcrt2.o" "$I/d3d9.lib" "$OUT/ntdll-msvc-helpers.lib" "${libs[@]}" \
  "$MINGW"/lib/clang/*/lib/windows/libclang_rt.builtins-i386.a
ls -l "$X86/d3d9.dll"; shasum -a 256 "$X86/d3d9.dll"
