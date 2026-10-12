# tdlib-android

Reproducible Android build of the **official [TDLib](https://github.com/tdlib/td)** plus a small, published
source patch (`patches/`), packaged as an Android library (AAR).

| | |
|---|---|
| TDLib version | 1.8.56 |
| TDLib commit | [`dd1b761fda7e47f4e0275c4d319f80a04db1997f`](https://github.com/tdlib/td/commit/dd1b761fda7e47f4e0275c4d319f80a04db1997f) |
| Source patches | `patches/0001-parallel-file-hashes.patch` (BSL-1.0) |
| `commit_hash` reported by TDLib | `5a820775f6131520457949251510d2b932b30345` (= `TDLIB_PATCHED_COMMIT`) |
| Interface | Java (`org.drinkless.tdlib.Client`, `org.drinkless.tdlib.TdApi`) |
| ABIs | arm64-v8a, armeabi-v7a, x86_64, x86 |

## What this repository contains

Build instructions and one source patch. No TDLib source code is copied here.

- `patches/0001-parallel-file-hashes.patch` – lets TDLib keep several `upload.getFileHashes` queries of one file
  in flight when it verifies a local file against the server hashes instead of downloading it (only-check
  mode). Off by default: the integer option `x_file_hashes_inflight` (default 1 = unmodified behaviour, clamped
  to 1..32) turns it on; a process-wide counter bounds the extra queries. The code that compares local bytes
  with the server hashes is not changed.
- `scripts/check-patch-scope.sh` – content guard run by CI before every build: the comparison code in
  `FileDownloader::check_loop` and its neighbours must stay byte-identical (whitespace-normalised) to stock,
  and the patch may only touch the three files above; `--self-test` proves that counter-example patches fail.
- `tests/hash_window_test.cpp` – unit tests of the patch's pure logic, built with TDLib's language flags and
  ASan/UBSan.

- `tdlib.env` – the single place that pins the TDLib version and commit.
- `scripts/build-official.sh` – checks out `example/android` from tdlib/td at the pinned commit and runs
  the official Dockerfile there (`fetch-sdk.sh`, `build-openssl.sh`, `build-tdlib.sh`). Only `COMMIT_HASH`
  is passed; every other build argument keeps the official default (NDK 23.2.8568313, OpenSSL 1.1.1w,
  `c++_static`). With `TDLIB_PATCHES` set it inserts two steps after the official checkout: copy `patches/`,
  `git apply --index` them and commit with the fixed identity from `tdlib.env`, so `commit_hash` is reproducible.
- `scripts/verify.sh` – checks that every 64-bit `libtdjni.so` has 16 KB aligned LOAD segments and that
  each library embeds the pinned (patched) commit hash.
- `aar/` – a minimal Android library module that wraps the official output (`Client.java`, `TdApi.java`,
  `libs/<abi>/libtdjni.so`) into an AAR without changing the native libraries, plus an instrumentation
  test that loads the library on an emulator and checks the `version` and `commit_hash` options.
- `.github/workflows/build.yml` – runs all of the above on a standard GitHub-hosted `ubuntu-24.04` runner (pinned: `ubuntu-latest` moves to Ubuntu 26 from 2026-10-19)
  and, when asked, publishes a GitHub Release.

## Releases

Each release carries the AAR, the build output `tdlib.zip` / `tdlib-debug.zip` (as `tdlib-native-*.zip`), `SHA256SUMS.txt`
(release assets and every file inside them) and `build-info.txt` (tool versions, disk usage, verification
output). Consumers should pin the AAR by its SHA-256.

## Reproducing a build

Run the `Build TDLib for Android` workflow (`publish: false`) and compare its `SHA256SUMS.txt` with the
one attached to the release. The zip archives themselves carry timestamps; compare the files inside them.

## License

TDLib is distributed under the Boost Software License 1.0; the scripts in this repository are released
under the same license (see `LICENSE`). The built libraries also contain OpenSSL 1.1.1w and SQLite/SQLCipher; see
`NOTICE`.
