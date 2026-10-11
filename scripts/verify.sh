#!/usr/bin/env bash
# Checks the unpacked official output (the "tdlib" directory inside tdlib.zip):
#   1. every expected ABI has libtdjni.so;
#   2. every LOAD segment of each 64-bit .so is aligned to 16 KB (0x4000) - required by Google Play;
#      32-bit alignment is printed for the record only;
#   3. each .so embeds the pinned commit hash (the value TDLib reports as option "commit_hash");
#   4. Java bindings (Client.java, TdApi.java) are present.
# Prints a report and exits non-zero on any failure.
#
# Usage: scripts/verify.sh <unpacked-tdlib-dir>
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../tdlib.env
source "$repo_root/tdlib.env"

dir=${1:?usage: verify.sh <unpacked-tdlib-dir>}
fail=0

for f in java/org/drinkless/tdlib/Client.java java/org/drinkless/tdlib/TdApi.java; do
  if [ -s "$dir/$f" ]; then echo "OK   present $f"; else echo "FAIL missing $f"; fail=1; fi
done

for abi in arm64-v8a armeabi-v7a x86_64 x86; do
  so="$dir/libs/$abi/libtdjni.so"
  if [ ! -s "$so" ]; then
    echo "FAIL missing libs/$abi/libtdjni.so"; fail=1; continue
  fi
  echo "== libs/$abi/libtdjni.so ($(stat -c %s "$so") bytes)"
  echo "   $(readelf -hW "$so" | grep -E 'Class:|Machine:' | tr -s ' ' | tr '\n' ' ')"
  aligns=$( (readelf -lW "$so" 2>/dev/null || true) | awk '$1 == "LOAD" { print $NF }')
  echo "   LOAD align: $(echo $aligns)"
  if [ -z "$aligns" ]; then echo "FAIL no LOAD segments (not a readable ELF)"; fail=1; continue; fi
  machine=$( (readelf -hW "$so" 2>/dev/null || true) | awk -F: '/Machine:/ { gsub(/^ +/, "", $2); print $2 }')
  case "$abi" in
    arm64-v8a) want_machine="AArch64" ;;
    armeabi-v7a) want_machine="ARM" ;;
    x86_64) want_machine="Advanced Micro Devices X86-64" ;;
    x86) want_machine="Intel 80386" ;;
  esac
  if [ "$machine" = "$want_machine" ]; then echo "OK   ELF machine $machine"
  else echo "FAIL ELF machine '$machine', expected '$want_machine'"; fail=1; fi
  case "$abi" in
    arm64-v8a|x86_64)
      # 16 KB page size support: every LOAD segment aligned to a power of two >= 0x4000.
      bad=""
      for a in $aligns; do
        v=$((a))
        if [ "$v" -lt 16384 ] || [ $((v & (v - 1))) -ne 0 ]; then bad="$bad $a"; fi
      done
      if [ -n "$bad" ]; then echo "FAIL 64-bit LOAD segment not 16 KB aligned:$bad"; fail=1
      else echo "OK   16 KB aligned (every LOAD align is a power of two >= 0x4000)"; fi
      ;;
    *) echo "INFO 32-bit ABI: 16 KB alignment not required" ;;
  esac
  if strings -a "$so" | grep -q -x -F "$TDLIB_COMMIT"; then
    echo "OK   embeds commit_hash $TDLIB_COMMIT"
  else
    echo "FAIL commit hash $TDLIB_COMMIT not found in .so"; fail=1
  fi
  if strings -a "$so" | grep -q -x -F "$TDLIB_VERSION"; then
    echo "OK   embeds version string $TDLIB_VERSION"
  else
    echo "INFO version string $TDLIB_VERSION not found as a standalone string (runtime check covers it)"
  fi
done

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
