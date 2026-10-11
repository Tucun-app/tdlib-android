# tdlib-android

Reproducible Android build of the **official, unmodified [TDLib](https://github.com/tdlib/td)**,
packaged as an Android library (AAR).

| | |
|---|---|
| TDLib version | 1.8.56 |
| TDLib commit | [`dd1b761fda7e47f4e0275c4d319f80a04db1997f`](https://github.com/tdlib/td/commit/dd1b761fda7e47f4e0275c4d319f80a04db1997f) |
| Interface | Java (`org.drinkless.tdlib.Client`, `org.drinkless.tdlib.TdApi`) |
| ABIs | arm64-v8a, armeabi-v7a, x86_64, x86 |

## What this repository contains

Only build instructions. No TDLib source code is copied here and no source patch is applied.

- `tdlib.env` – the single place that pins the TDLib version and commit.
- `scripts/build-official.sh` – checks out `example/android` from tdlib/td at the pinned commit and runs
  the official Dockerfile there (`fetch-sdk.sh`, `build-openssl.sh`, `build-tdlib.sh`). Only `COMMIT_HASH`
  is passed; every other build argument keeps the official default (NDK 23.2.8568313, OpenSSL 1.1.1w,
  `c++_static`).
- `scripts/verify.sh` – checks that every 64-bit `libtdjni.so` has 16 KB aligned LOAD segments and that
  each library embeds the pinned commit hash.
- `aar/` – a minimal Android library module that wraps the official output (`Client.java`, `TdApi.java`,
  `libs/<abi>/libtdjni.so`) into an AAR without changing the native libraries, plus an instrumentation
  test that loads the library on an emulator and checks the `version` and `commit_hash` options.
- `.github/workflows/build.yml` – runs all of the above on a standard GitHub-hosted `ubuntu-latest` runner
  and, when asked, publishes a GitHub Release.

## Releases

Each release carries the AAR, the untouched official `tdlib.zip` / `tdlib-debug.zip`, `SHA256SUMS.txt`
(release assets and every file inside them) and `build-info.txt` (tool versions, disk usage, verification
output). Consumers should pin the AAR by its SHA-256.

## Reproducing a build

Run the `Build TDLib for Android` workflow (`publish: false`) and compare its `SHA256SUMS.txt` with the
one attached to the release. The zip archives themselves carry timestamps; compare the files inside them.

## License

TDLib is distributed under the Boost Software License 1.0; the scripts in this repository are released
under the same license (see `LICENSE`). The built libraries also contain OpenSSL 1.1.1w and SQLite/SQLCipher; see
`NOTICE`.
