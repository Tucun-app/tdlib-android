#!/usr/bin/env bash
# Builds TDLib for Android with the official build in tdlib/td example/android
# (Dockerfile -> fetch-sdk.sh, build-openssl.sh, build-tdlib.sh) at the commit pinned in tdlib.env.
# Only COMMIT_HASH is passed; every other build argument keeps the official default.
# When tdlib.env lists TDLIB_PATCHES, the official Dockerfile is copied and two lines are inserted right after its
# clone/checkout and merge-base steps: COPY the patches, then `git apply --index` + `git commit` them with the fixed
# identity from tdlib.env and check that the resulting commit equals TDLIB_PATCHED_COMMIT. Nothing else is changed.
#
# Usage: scripts/build-official.sh <output-dir>
# Output: <output-dir>/tdlib.zip, <output-dir>/tdlib-debug.zip (official output), <output-dir>/build-official.txt
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../tdlib.env
source "$repo_root/tdlib.env"

out=${1:?usage: build-official.sh <output-dir>}
mkdir -p "$out"
out=$(cd "$out" && pwd)
info="$out/build-official.txt"

src=$(mktemp -d)
echo "Fetching tdlib/td@$TDLIB_COMMIT (example/android only)..."
git -C "$src" init -q td
git -C "$src/td" remote add origin https://github.com/tdlib/td.git
git -C "$src/td" sparse-checkout set example/android
git -C "$src/td" fetch -q --depth 1 origin "$TDLIB_COMMIT"
git -C "$src/td" checkout -q FETCH_HEAD
head=$(git -C "$src/td" rev-parse HEAD)
if [ "$head" != "$TDLIB_COMMIT" ]; then
  echo "error: checked out $head, expected $TDLIB_COMMIT" >&2
  exit 1
fi

android_dir="$src/td/example/android"
dockerfile="$android_dir/Dockerfile"
context="$android_dir"
if [ -n "${TDLIB_PATCHES:-}" ]; then
  context=$(mktemp -d)
  cp -R "$android_dir/." "$context/"
  mkdir -p "$context/patches"
  for p in $TDLIB_PATCHES; do cp "$repo_root/$p" "$context/patches/"; done
  dockerfile="$context/Dockerfile.patched"
  clone_line='RUN git clone https://github.com/tdlib/td.git && cd td && git checkout "$COMMIT_HASH"'
  merge_base_prefix='RUN cd td && git merge-base --is-ancestor '
  if [ "$(grep -c -x -F "$clone_line" "$android_dir/Dockerfile")" != 1 ] \
      || [ "$(grep -c "^$merge_base_prefix" "$android_dir/Dockerfile")" != 1 ]; then
    echo "error: official Dockerfile: clone/checkout or merge-base line not found exactly once" >&2
    exit 1
  fi
  awk -v mb="$merge_base_prefix" -v name="$TDLIB_PATCH_NAME" -v email="$TDLIB_PATCH_EMAIL" \
      -v date="$TDLIB_PATCH_DATE" -v msg="$TDLIB_PATCH_MESSAGE" -v want="$TDLIB_PATCHED_COMMIT" '
    { print }
    index($0, mb) == 1 {
      print "COPY patches /home/patches"
      print "RUN cd td && git apply --index /home/patches/*.patch && GIT_AUTHOR_NAME=" name " GIT_AUTHOR_EMAIL=" email \
            " GIT_AUTHOR_DATE=" date " GIT_COMMITTER_NAME=" name " GIT_COMMITTER_EMAIL=" email " GIT_COMMITTER_DATE=" date \
            " git -c commit.gpgsign=false commit -q -m " msg " && git log -1 --format=patched_commit=%H" \
            " && test \"$(git rev-parse HEAD)\" = " want
    }' "$android_dir/Dockerfile" > "$dockerfile"
  if [ "$(grep -c '^COPY patches /home/patches$' "$dockerfile")" != 1 ]; then
    echo "error: generated Dockerfile.patched does not contain the patch step exactly once" >&2
    exit 1
  fi
  diff -u "$android_dir/Dockerfile" "$dockerfile" > "$out/Dockerfile.patched.diff" || true
  cp "$dockerfile" "$out/Dockerfile.patched"
fi
{
  echo "tdlib_version=$TDLIB_VERSION"
  echo "tdlib_commit=$TDLIB_COMMIT"
  echo "official_build_dir=tdlib/td@$TDLIB_COMMIT:example/android"
  echo "docker_build_args=COMMIT_HASH=$TDLIB_COMMIT (all other args: official defaults)"
  if [ -n "${TDLIB_PATCHES:-}" ]; then
    echo "tdlib_patched_commit=$TDLIB_PATCHED_COMMIT"
    echo "## sha256 of the source patches and of the generated Dockerfile"
    (cd "$repo_root" && sha256sum $TDLIB_PATCHES)
    echo "$(sha256sum < "$dockerfile" | cut -d' ' -f1)  Dockerfile.patched"
    echo "## Dockerfile.patched vs official Dockerfile"
    cat "$out/Dockerfile.patched.diff"
  fi
  echo "## sha256 of the official build files used"
  (cd "$android_dir" && sha256sum Dockerfile fetch-sdk.sh build-openssl.sh build-tdlib.sh check-environment.sh CMakeLists.txt AddIntDef.php)
  echo "## defaults declared in the official Dockerfile"
  grep -E '^(FROM|ARG) ' "$android_dir/Dockerfile"
  echo "## host"
  echo "runner_image=${ImageOS:-unknown} ${ImageVersion:-unknown}"
  docker version --format 'docker_server={{.Server.Version}} docker_client={{.Client.Version}}'
  docker buildx version
} > "$info"
cat "$info"

start=$(date +%s)
# Sample disk usage of / every 30 s to record the peak (the official per-ABI build dirs are removed only
# at the end of the build).
( while true; do df -B1 --output=used / | tail -1 >> "$out/df-samples.txt"; sleep 30; done ) &
sampler=$!
trap 'kill "$sampler" 2>/dev/null || true' EXIT
# The official Dockerfile fetches https://api.github.com/repos/tdlib/td/git/refs/heads/master without
# authentication (only to invalidate its cache); on shared runner IPs that can hit the API rate limit
# (HTTP 403) within the first seconds. Retry only that failure; any other failure stops immediately.
for attempt in 1 2 3 4; do
  if docker build --progress=plain \
      --build-arg "COMMIT_HASH=$TDLIB_COMMIT" \
      --output "type=local,dest=$out" \
      -f "$dockerfile" \
      "$context" 2>&1 | tee "$out/docker-build.log"; then
    break
  fi
  if [ "$attempt" -lt 4 ] && grep -q 'api.github.com/repos/tdlib/td/git/refs/heads/master' "$out/docker-build.log" \
      && grep -q 'invalid response status 403' "$out/docker-build.log"; then
    echo "official Dockerfile: GitHub API rate limit on the cache-busting ADD (attempt $attempt); retrying in 10 minutes"
    echo "docker_build_retry_after_api_403=attempt $attempt" >> "$info"
    sleep 600
    continue
  fi
  exit 1
done
end=$(date +%s)
kill "$sampler" 2>/dev/null || true
echo "docker_build_seconds=$((end - start))" >> "$info"
peak=$(sort -n "$out/df-samples.txt" | tail -1)
echo "disk_used_peak_on_root=$((peak / 1024 / 1024)) MiB" >> "$info"
echo "## base image resolved by the official Dockerfile" >> "$info"
grep -o -m 1 -E 'docker\.io/library/ubuntu:24\.04@sha256:[0-9a-f]{64}' "$out/docker-build.log" >> "$info" \
  || echo "UNKNOWN (digest not found in build log)" >> "$info"

ls -l "$out"
for f in tdlib.zip tdlib-debug.zip; do
  if [ ! -s "$out/$f" ]; then
    echo "error: official build did not produce $f" >&2
    exit 1
  fi
done
if [ -n "${TDLIB_PATCHES:-}" ]; then
  grep -o -m 1 "patched_commit=[0-9a-f]*" "$out/docker-build.log" >> "$info" \
    || { echo "error: patched commit not found in the build log" >&2; exit 1; }
  rm -rf "$context"
fi
rm -rf "$src"
