# data-backedup

Part of the Clusterflick project. Backs up every finished week of
`clusterflick/data-transformed` releases to Cloudflare R2, as one write-once
tar.xz per week. See README.md for the archive format and how to restore.

## Repo structure

- `scripts/back-up.sh` - the whole job: list, build, verify, upload, check.
- `.github/workflows/back-up.yml` - runs it, on each `data-transformed`
  release (`repository_dispatch`) and daily from cron-job.org
  (`workflow_dispatch`). Not a GitHub schedule: their timing is too poor.

No dependency on `clusterflick/scripts`, unlike the other `data-*` repos. The
backup needs none of the pipeline's code, and pulling the latest pipeline
would let a bad commit there break the backup.

## Rules

- **Archives are write-once.** The upload uses `--if-none-match '*'` and the
  bucket has an indefinite lock rule. Never add code that overwrites, deletes
  or rewrites an archive, and never keep a mutable index file in the bucket:
  the archive names are the index, and each archive describes itself
  (`releases.json`, `SHA256SUMS`).
- **Work out what is missing; don't react to the trigger.** Every run lists
  every tag (`git ls-remote`, not the releases API, which returns ~500 assets
  per release and takes minutes to page) and every archive, and builds the
  finished weeks with no archive. That is what makes a failed run self-healing.
- **Fail loudly.** An empty tag listing, a size or sha256 mismatch, a release
  on GitHub but not in the archive - each fails the job. The one warning is a
  release that is in an archive but no longer on GitHub: outliving GitHub is
  the point.
- **A week is finished from the Tuesday after**, so a release tagged late on
  Sunday and published after midnight is out before its week is archived.
- **Keep files ordered by venue, then tag, and xz single-threaded.** That is
  what makes a week ~2MB rather than ~40MB: each venue's versions sit side by
  side in one compression stream.

## Testing

There are no automated tests. To try a change locally without R2, put a stub
`aws` on `PATH` that maps `s3api list-objects-v2`, `put-object` (honouring
`--if-none-match`) and `get-object` onto a directory, then source the script
and call `list_tags` and `back_up_week <monday>` directly. Run it as a script
(`bash -c` or a wrapper), not sourced into an interactive shell, or `set -e`
is not in force and a failed check carries on. A week takes a few minutes to
download, so test with one week, and say so before starting.

## Commit style

Short imperative messages describing the change.
