#!/usr/bin/env bash
# Builds TDLib for Android with the official, unmodified build in tdlib/td example/android
# (Dockerfile -> fetch-sdk.sh, build-openssl.sh, build-tdlib.sh) at the commit pinned in tdlib.env.
# Only COMMIT_HASH is passed; every other build argument keeps the official default.
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
{
  echo "tdlib_version=$TDLIB_VERSION"
  echo "tdlib_commit=$TDLIB_COMMIT"
  echo "official_build_dir=tdlib/td@$TDLIB_COMMIT:example/android"
  echo "docker_build_args=COMMIT_HASH=$TDLIB_COMMIT (all other args: official defaults)"
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
docker build --progress=plain \
  --build-arg "COMMIT_HASH=$TDLIB_COMMIT" \
  --output "type=local,dest=$out" \
  "$android_dir"
end=$(date +%s)
echo "docker_build_seconds=$((end - start))" >> "$info"

ls -l "$out"
for f in tdlib.zip tdlib-debug.zip; do
  if [ ! -s "$out/$f" ]; then
    echo "error: official build did not produce $f" >&2
    exit 1
  fi
done
rm -rf "$src"
