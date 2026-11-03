#!/usr/bin/env bash
# Mirrors the backup bucket into backup/, and optionally checks or unpacks
# every archive. Reads credentials from .env at the repository root (copy
# .env.example) - use a read-only R2 token, not the one the workflow writes
# with.
#
#   scripts/download.sh            download any archives not already in backup/
#   scripts/download.sh --verify   ...then unpack each one to a temporary
#                                  directory and check it against SHA256SUMS
#   scripts/download.sh --extract  ...then unpack each one into
#                                  restored/<archive>/ and check it there
#
# --extract keeps everything it unpacks: about 390MB per recent week, so the
# whole history is 15-20GB. --verify needs room for one week at a time.
#
# Works on Linux and macOS. Needs the AWS CLI (R2 speaks the S3 API).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-}"
case "$MODE" in
  "" | --verify | --extract) ;;
  *)
    echo "Usage: $0 [--verify | --extract]" >&2
    exit 2
    ;;
esac

if [ ! -f "$ROOT/.env" ]; then
  echo "No .env - copy .env.example to .env and fill it in" >&2
  exit 1
fi
set -a
# shellcheck source=/dev/null
. "$ROOT/.env"
set +a

: "${R2_ACCOUNT_ID:?R2_ACCOUNT_ID is not set in .env}"
: "${R2_BUCKET:?R2_BUCKET is not set in .env}"
: "${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID is not set in .env}"
: "${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY is not set in .env}"

if ! command -v aws > /dev/null; then
  echo "The AWS CLI is needed: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" >&2
  exit 1
fi

export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION=auto
# R2 doesn't support every checksum newer AWS CLIs send by default.
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required

BACKUP="$ROOT/backup"
mkdir -p "$BACKUP"

echo "Downloading s3://${R2_BUCKET} into backup/"
aws s3 sync "s3://${R2_BUCKET}" "$BACKUP" \
  --endpoint-url "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com" \
  --exclude "*" --include "*.tar.xz" --only-show-errors

count="$(find "$BACKUP" -maxdepth 1 -name '*.tar.xz' | wc -l | tr -d ' ')"
echo "${count} archives in backup/"
[ -n "$MODE" ] || exit 0

if command -v sha256sum > /dev/null; then
  sha256_check() { sha256sum --check --quiet SHA256SUMS; }
else
  sha256_check() { shasum -a 256 --check --quiet SHA256SUMS; }
fi

# Unpacks one archive into <dir> and checks that every file matches
# SHA256SUMS and that SHA256SUMS lists every file. `tar -xJ` rather than xz:
# macOS's tar reads xz itself, and doesn't ship the xz command.
check_archive() {
  local archive="$1" dir="$2" files listed
  mkdir -p "$dir"
  tar -xJf "$archive" -C "$dir"
  (cd "$dir" && sha256_check) || return 1
  files="$(cd "$dir" && find . -mindepth 2 -type f | sed 's|^\./||' | LC_ALL=C sort)"
  listed="$(cut -d' ' -f3- "$dir/SHA256SUMS" | LC_ALL=C sort)"
  if [ "$files" != "$listed" ]; then
    echo "files and SHA256SUMS differ" >&2
    return 1
  fi
}

failed=0
for archive in "$BACKUP"/*.tar.xz; do
  [ -e "$archive" ] || continue
  name="$(basename "$archive" .tar.xz)"
  if [ "$MODE" = "--extract" ]; then
    dir="$ROOT/restored/$name"
    rm -rf "${dir:?}"
  else
    dir="$(mktemp -d)"
  fi
  if check_archive "$archive" "$dir"; then
    echo "ok      $name"
  else
    echo "FAILED  $name"
    failed=$((failed + 1))
  fi
  if [ "$MODE" = "--verify" ]; then
    rm -rf "${dir:?}"
  fi
done

if [ "$failed" -gt 0 ]; then
  echo "${failed} of ${count} archives failed" >&2
  exit 1
fi
echo "All ${count} archives match their checksums"
