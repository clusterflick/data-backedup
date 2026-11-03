#!/usr/bin/env bash
# Backs up every finished week of clusterflick/data-transformed releases to
# Cloudflare R2, one write-once archive per week, then restores one earlier
# archive at random to prove it still reads back.
#
# Every run works out what is missing rather than acting on the release that
# triggered it: it lists every release tag on GitHub and every archive in R2,
# and builds each finished week that has no archive yet, oldest first. A failed run
# is caught up by the next one - the next release, or the daily trigger.
#
# Required environment:
#   GH_TOKEN               token for listing the releases
#   R2_ACCOUNT_ID          Cloudflare account id (for the S3 endpoint)
#   R2_BUCKET              bucket the archives are written to
#   AWS_ACCESS_KEY_ID      R2 API token's access key id
#   AWS_SECRET_ACCESS_KEY  R2 API token's secret access key
#
# Optional:
#   MAX_WEEKS              most weeks one run archives (default 20)
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${R2_ACCOUNT_ID:?R2_ACCOUNT_ID is required}"
: "${R2_BUCKET:?R2_BUCKET is required}"
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID is required}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY is required}"

MAX_WEEKS="${MAX_WEEKS:-20}"
SOURCE_REPO="clusterflick/data-transformed"
KEY_PREFIX="data-transformed-"
ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
WORK="$(mktemp -d "${RUNNER_TEMP:-/tmp}/back-up.XXXXXX")"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

# R2 doesn't support every checksum newer AWS CLIs send by default; Cloudflare's
# own guidance is to send them only when an operation requires one.
export AWS_DEFAULT_REGION=auto
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required

trap 'rm -rf "$WORK"' EXIT

r2() {
  aws --endpoint-url "$ENDPOINT" "$@"
}

# ------------------------------------------------------------------------------
# GitHub
# ------------------------------------------------------------------------------

# Every release tag, with its London week (the Monday it falls in) and whether
# that week is over. One `git ls-remote` rather than the releases API: the API
# returns every asset of every release, ~500 each, and paging through 1,000+
# releases that way takes minutes and draws 504s.
#
# Tags are YYYYMMDD.HHMMSS in London time, so the week is read straight off the
# tag. A week is finished once it has been over for a whole day - Tuesday
# onwards - so a release tagged late on Sunday and published after midnight is
# out before its week is archived.
list_tags() {
  local today
  git ls-remote --tags --refs "https://github.com/${SOURCE_REPO}.git" > "$WORK/ls-remote"
  today="$(TZ=Europe/London date +%F)"
  sed -n 's|^[0-9a-f]*\trefs/tags/\([0-9]\{8\}\.[0-9]\{6\}\)$|\1|p' "$WORK/ls-remote" |
    jq -R -s --arg today "$today" '
      split("\n") | map(select(length > 0)) | unique
      | map(
          (.[0:8] | strptime("%Y%m%d") | mktime) as $day
          | ($day | gmtime | .[6]) as $dow
          | ($day - ((($dow + 6) % 7) * 86400)) as $monday
          | {
              tag: .,
              week: ($monday | strftime("%Y-%m-%d")),
              weekFinished: ((($monday + 8 * 86400) | strftime("%Y-%m-%d")) <= $today)
            }
        )
    ' > "$WORK/tags.json"

  # No tags is GitHub failing, not a repository with no releases.
  if [ "$(jq length "$WORK/tags.json")" -eq 0 ]; then
    echo "::error::GitHub listed no release tags for ${SOURCE_REPO}" >&2
    return 1
  fi
}

# One release by tag, retried. Prints nothing for a tag with no published
# release - a draft left by a failed upload, or a release since deleted.
#
# Written to a file and printed only on success, because `gh api` prints an
# error response's body to stdout too.
fetch_release() {
  local tag="$1" attempt out="$WORK/release.json" err="$WORK/release.err"
  for attempt in 1 2 3 4 5; do
    if gh api "repos/${SOURCE_REPO}/releases/tags/${tag}" > "$out" 2> "$err" \
      --jq 'select(.draft == false) | {
          tag: .tag_name,
          publishedAt: .published_at,
          url: .html_url,
          assets: [.assets[] | {
            name,
            size,
            sha256: (.digest // "" | sub("^sha256:"; "")),
            download: .browser_download_url
          }]
        }'; then
      cat "$out"
      return 0
    fi
    if grep -q "HTTP 404" "$err"; then
      echo "::warning::Tag ${tag} has no published release, skipping it" >&2
      return 0
    fi
    cat "$err" >&2
    echo "::warning::Fetching release ${tag} failed (attempt ${attempt}), retrying" >&2
    sleep $((attempt * 10))
  done
  echo "::error::Could not fetch release ${tag}" >&2
  return 1
}

# The week's published releases, into $WORK/releases.json.
fetch_week() {
  local week="$1" tag
  : > "$WORK/week-releases.jsonl"
  for tag in $(jq -r --arg week "$week" '.[] | select(.week == $week) | .tag' "$WORK/tags.json"); do
    fetch_release "$tag" >> "$WORK/week-releases.jsonl" || return 1
  done
  jq -s --arg week "$week" 'map(. + {week: $week}) | sort_by(.tag)' \
    "$WORK/week-releases.jsonl" > "$WORK/releases.json"

  # Tags but nothing published is something for a person to look at, not a
  # week to archive empty.
  if [ "$(jq length "$WORK/releases.json")" -eq 0 ]; then
    echo "::error::Week ${week} has release tags but no published releases" >&2
    return 1
  fi

  # Names become paths inside the archive.
  local bad
  bad="$(jq -r '.[] | .tag as $t | .assets[] | select(.name | test("^[A-Za-z0-9._-]+$") | not) | "\($t)/\(.name)"' "$WORK/releases.json")"
  if [ -n "$bad" ]; then
    echo "::error::Unexpected asset names: ${bad}" >&2
    return 1
  fi
}

# ------------------------------------------------------------------------------
# R2
# ------------------------------------------------------------------------------

list_archives() {
  r2 s3api list-objects-v2 --bucket "$R2_BUCKET" --prefix "$KEY_PREFIX" \
    --query 'Contents[].Key' --output json |
    jq -r '(. // [])[]'
}

archive_key() {
  echo "${KEY_PREFIX}$1.tar.xz"
}

# ------------------------------------------------------------------------------
# Building a week
# ------------------------------------------------------------------------------

# Downloads every asset of every release in the week into <dir>/<tag>/<name>,
# checking each against the size and sha256 GitHub reports. Releases from
# before GitHub started recording digests have only a size to check against.
download_week() {
  local week="$1" dir="$2"
  local list="$WORK/assets.tsv"
  jq -r --arg week "$week" '
    .[] | select(.week == $week) | .tag as $tag
    | .assets[] | [$tag, .name, .size, (if .sha256 == "" then "-" else .sha256 end), .download] | @tsv
  ' "$WORK/releases.json" > "$list"

  cut -f1 "$list" | sort -u | while read -r tag; do mkdir -p "$dir/$tag"; done

  # GitHub's asset servers answer the odd download with a run of 504s. No
  # --retry-delay, so curl backs off exponentially (1s, 2s, 4s...) and rides
  # out a few minutes of that rather than giving up after 25s, as fixed 5s
  # retries did. Eight at a time rather than 16 to ask less of it at once.
  cut -f1,2,5 "$list" | tr '\t' '\n' |
    xargs -d '\n' -n 3 -P 8 sh -c '
      curl --fail --silent --show-error --location \
        --retry 8 --retry-all-errors --retry-max-time 600 \
        --connect-timeout 30 --max-time 300 \
        --output "$0/$1/$2" "$3" ||
        { echo "::error::Could not download $3" >&2; exit 1; }
    ' "$dir"

  # A missing sha256 is written as "-": tab is whitespace to `read`, so an
  # empty field would be merged with its neighbour and shift the rest along.
  local tag name size sha256 url actual_size actual failures=0
  while IFS=$'\t' read -r tag name size sha256 url; do
    actual_size="$(stat -c %s "$dir/$tag/$name")"
    if [ "$actual_size" != "$size" ]; then
      echo "::error::${tag}/${name} is ${actual_size} bytes, GitHub says ${size}" >&2
      failures=$((failures + 1))
      continue
    fi
    if [ "$sha256" != "-" ]; then
      actual="$(sha256sum "$dir/$tag/$name" | cut -d' ' -f1)"
      if [ "$actual" != "$sha256" ]; then
        echo "::error::${tag}/${name} has sha256 ${actual}, GitHub says ${sha256}" >&2
        failures=$((failures + 1))
      fi
    fi
  done < "$list"
  [ "$failures" -eq 0 ]
}

# Packs a downloaded week into <archive>:
#   releases.json   each release's tag, publish time, page and assets
#   SHA256SUMS      every file's sha256, for `sha256sum -c`
#   <tag>/<name>    the release assets as published
#
# Files are ordered by venue, then tag, so each venue's versions sit side by
# side and xz stores each as a small change from the one before: a week of
# ~390MB packs into ~2MB this way. Single-threaded, because xz's threads
# compress separate blocks and lose the matches between them.
pack_week() {
  local week="$1" dir="$2" archive="$3"

  (cd "$dir" && find . -mindepth 2 -type f -printf '%P\n' | LC_ALL=C sort |
    xargs -d '\n' sha256sum) > "$dir/SHA256SUMS"

  jq --arg week "$week" --rawfile sums "$dir/SHA256SUMS" '
    ($sums | split("\n") | map(select(length > 0) | split("  ") | {key: .[1], value: .[0]}) | from_entries) as $sha
    | [.[] | select(.week == $week) | .tag as $tag | {
        tag, publishedAt, url,
        assets: [.assets[] | {name, size, sha256: $sha["\($tag)/\(.name)"]}]
      }]
    | sort_by(.tag)
  ' "$WORK/releases.json" > "$dir/releases.json"

  # Files carry their release's publish time, so a restore keeps it.
  jq -r '.[] | [.tag, .publishedAt] | @tsv' "$dir/releases.json" |
    while IFS=$'\t' read -r tag published; do
      find "$dir/$tag" -type f -exec touch -d "$published" {} +
    done
  touch -d "$(jq -r 'map(.publishedAt) | max' "$dir/releases.json")" "$dir/releases.json" "$dir/SHA256SUMS"

  {
    echo releases.json
    echo SHA256SUMS
    (cd "$dir" && find . -mindepth 2 -type f -printf '%f\t%P\n') | LC_ALL=C sort | cut -f2
  } > "$WORK/order"

  tar --create --format=gnu --no-recursion --verbatim-files-from \
    --owner=0 --group=0 --numeric-owner \
    --directory "$dir" --files-from "$WORK/order" |
    xz -9 --threads=1 > "$archive"
}

# ------------------------------------------------------------------------------
# Verifying an archive
# ------------------------------------------------------------------------------

# Unpacks an archive and checks it against itself and, while GitHub still has
# them, against the releases it was made from:
#   - every file is listed in SHA256SUMS and matches it
#   - its releases are exactly GitHub's releases for that week
#   - each release holds exactly GitHub's assets, matching every sha256 and
#     size GitHub reports
verify_archive() {
  local archive="$1" week="$2" dir
  dir="$(mktemp -d "$WORK/verify.XXXXXX")"

  xz --test "$archive"
  xz --decompress --stdout "$archive" | tar --extract --directory "$dir"

  (cd "$dir" && sha256sum --check --quiet --strict SHA256SUMS)
  local files listed
  files="$(cd "$dir" && find . -mindepth 2 -type f -printf '%P\n' | LC_ALL=C sort)"
  listed="$(cut -d' ' -f3- "$dir/SHA256SUMS" | LC_ALL=C sort)"
  if [ "$files" != "$listed" ]; then
    echo "::error::$(basename "$archive") holds files SHA256SUMS does not list, or the reverse" >&2
    return 1
  fi

  # Errors are differences in what the archive holds; a release GitHub no
  # longer has is only a warning, since outliving GitHub is the point.
  local findings
  findings="$(jq -n -r --arg week "$week" \
    --slurpfile archived "$dir/releases.json" \
    --slurpfile github "$WORK/releases.json" '
      ($archived[0] | map({key: .tag, value: .}) | from_entries) as $a
      | ($github[0] | map(select(.week == $week)) | map({key: .tag, value: .}) | from_entries) as $g
      | (($g | keys) - ($a | keys) | .[] | "error\trelease \(.) is on GitHub but not in the archive"),
        (($a | keys) - ($g | keys) | .[] | "warning\trelease \(.) is in the archive but no longer on GitHub"),
        (($a | keys) - (($a | keys) - ($g | keys)) | .[] as $tag
          | ($a[$tag].assets | map({key: .name, value: .}) | from_entries) as $aa
          | ($g[$tag].assets | map({key: .name, value: .}) | from_entries) as $ga
          | (($ga | keys) - ($aa | keys) | .[] | "error\t\($tag)/\(.) is on GitHub but not in the archive"),
            (($aa | keys) - ($ga | keys) | .[] | "error\t\($tag)/\(.) is in the archive but not on GitHub"),
            ($aa | keys[] | select($ga[.] != null) as $name
              | if $ga[$name].size != $aa[$name].size then "error\t\($tag)/\($name) size differs from GitHub"
                elif $ga[$name].sha256 != "" and $ga[$name].sha256 != $aa[$name].sha256 then "error\t\($tag)/\($name) sha256 differs from GitHub"
                else empty end))
    ')"
  local level message errors=0
  while IFS=$'\t' read -r level message; do
    [ -n "$level" ] || continue
    echo "::${level}::$(basename "$archive"): ${message}" >&2
    if [ "$level" = "error" ]; then errors=$((errors + 1)); fi
  done <<< "$findings"
  if [ "$errors" -gt 0 ]; then
    return 1
  fi

  rm -rf "$dir"
}

# Downloads an archive from R2 and verifies it.
verify_stored() {
  local week="$1" expected_sha256="${2:-}" key copy
  key="$(archive_key "$week")"
  copy="$WORK/stored-$week.tar.xz"
  r2 s3api get-object --bucket "$R2_BUCKET" --key "$key" "$copy" > /dev/null
  if [ -n "$expected_sha256" ]; then
    local actual
    actual="$(sha256sum "$copy" | cut -d' ' -f1)"
    if [ "$actual" != "$expected_sha256" ]; then
      echo "::error::${key} in R2 has sha256 ${actual}, uploaded ${expected_sha256}" >&2
      return 1
    fi
  fi
  verify_archive "$copy" "$week"
  rm -f "$copy"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

back_up_week() {
  local week="$1" dir archive key sha256 size
  dir="$WORK/week-$week"
  archive="$WORK/$(archive_key "$week")"
  key="$(archive_key "$week")"
  mkdir -p "$dir"

  echo "::group::${week}"
  fetch_week "$week"
  download_week "$week" "$dir"
  pack_week "$week" "$dir" "$archive"
  rm -rf "$dir"
  verify_archive "$archive" "$week"

  sha256="$(sha256sum "$archive" | cut -d' ' -f1)"
  size="$(stat -c %s "$archive")"
  # Write-once: R2 refuses the upload if the key already exists, so nothing
  # this job does can replace an archive.
  r2 s3api put-object --bucket "$R2_BUCKET" --key "$key" --body "$archive" \
    --if-none-match '*' --content-type application/x-xz \
    --metadata "sha256=${sha256}" > /dev/null
  verify_stored "$week" "$sha256"
  rm -f "$archive"

  local releases
  releases="$(jq --arg week "$week" '[.[] | select(.week == $week)] | length' "$WORK/releases.json")"
  echo "Archived ${key}: ${releases} releases, ${size} bytes"
  echo "| \`${key}\` | ${releases} | ${size} |" >> "$SUMMARY"
  echo "::endgroup::"
}

main() {
  list_tags
  list_archives > "$WORK/archived"

  jq -r '[.[] | select(.weekFinished) | .week] | unique[]' "$WORK/tags.json" > "$WORK/finished"
  local missing
  missing="$(LC_ALL=C comm -23 "$WORK/finished" <(sed -n "s/^${KEY_PREFIX}\(.*\)\.tar\.xz$/\1/p" "$WORK/archived" | LC_ALL=C sort))"

  echo "${SOURCE_REPO}: $(jq length "$WORK/tags.json") release tags, $(wc -l < "$WORK/finished") finished weeks, $(wc -l < "$WORK/archived") archived"

  if [ -n "$missing" ]; then
    local total batch
    total="$(wc -l <<< "$missing")"
    # Oldest first, and a run builds at most MAX_WEEKS, so a backfill is split
    # across runs: each archive is uploaded as it's built, and the next run
    # carries on from the oldest week still missing.
    batch="$(head -n "$MAX_WEEKS" <<< "$missing")"
    {
      echo "### Archived"
      echo
      echo "| Archive | Releases | Bytes |"
      echo "| --- | --- | --- |"
    } >> "$SUMMARY"
    local week
    for week in $batch; do
      back_up_week "$week"
    done
    if [ "$total" -gt "$MAX_WEEKS" ]; then
      echo "::notice::Archived ${MAX_WEEKS} of ${total} missing weeks; the next run carries on"
      printf '\n%s more weeks to archive on later runs.\n' "$((total - MAX_WEEKS))" >> "$SUMMARY"
    fi
  else
    echo "Every finished week is archived"
    echo "Every finished week is archived." >> "$SUMMARY"
  fi

  # One archive from an earlier run, read back from R2, so a backup that has
  # quietly stopped restoring is found while GitHub still has the originals.
  local earlier
  earlier="$(sed -n "s/^${KEY_PREFIX}\(.*\)\.tar\.xz$/\1/p" "$WORK/archived" | shuf -n 1)"
  if [ -n "$earlier" ]; then
    echo "::group::Restore check: ${earlier}"
    fetch_week "$earlier"
    verify_stored "$earlier"
    echo "::endgroup::"
    echo "Restored $(archive_key "$earlier") and it matched." | tee -a "$SUMMARY"
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
