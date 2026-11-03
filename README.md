# data-backedup

> **[Clusterflick](https://clusterflick.com)** is a free, open-source site
> listing every film showing in London, from 450+ venues in one search.
>
> This repository keeps a copy of the pipeline's history somewhere other than
> GitHub. See the [Clusterflick organisation](https://github.com/clusterflick)
> for how the pieces fit together.

This repository contains the automated workflow that backs up every
[`data-transformed`](https://github.com/clusterflick/data-transformed) release
to Cloudflare R2.

## Purpose

Every release the pipeline has published lives on GitHub. That is the only
copy, so the history depends on GitHub staying up and continuing to serve
release assets for free. This keeps a second copy of the one dataset whose
history is worth keeping: each venue's transformed listings, release by
release.

Retrieved data is left out - it is large, and nothing uses its history - and so
are the matched ratings, whose history isn't tracked.

## How It Works

```bash
scripts/back-up.sh
```

Each run:

- Lists every release tag on `data-transformed` and every archive in R2
- Archives each finished week that has none yet, oldest first, at most 20 a run
- Checks each archive before and after uploading it
- Downloads one earlier archive at random and checks it still restores

A week is finished once it has been over for a whole day, from the Tuesday
after. The current week is on GitHub only until then.

The run works out what is missing rather than acting on the release that
triggered it, so a failed run is caught up by the next one, and the first runs
filled in the history from February 2025.

## Archives

One per week, Monday to Sunday in London time, named after the Monday:
`data-transformed-2026-10-26.tar.xz`. Each holds:

- `<tag>/<venue>` - every release asset, exactly as published
- `releases.json` - each release's tag, publish time, page and assets
- `SHA256SUMS` - the sha256 of every file

A week of releases is about 390MB of JSON and 2MB as an archive. Files are
ordered by venue, so each venue's versions sit side by side and xz stores each
one as a small change from the last.

Archives are written once and never replaced: the upload is refused if the
name already exists, and the bucket's lock rule stops anything deleting or
overwriting them.

### Checks

Every file is checked against the size and sha256 GitHub reports for it.
Releases from before GitHub recorded sha256s, in early 2025, are checked by
size. The archive is then unpacked and compared with GitHub's releases for that
week - every release, every asset, every checksum - before it is uploaded, and
again after downloading it back from R2.

## Restoring

The archives need nothing but standard tools:

```bash
xz --decompress --stdout data-transformed-2026-10-26.tar.xz | tar --extract
sha256sum --check SHA256SUMS
```

Each release is then a directory named after its tag, with one file per venue.
To restore a single release, extract only its directory:

```bash
xz --decompress --stdout data-transformed-2026-10-26.tar.xz | tar --extract --wildcards '20261101.*'
```

## Schedule

The workflow runs when `data-transformed` publishes a release, and daily via
[cron-job.org](https://cron-job.org). It can also be triggered manually via
workflow dispatch, with a different limit on the weeks it archives.

## Maintenance

### Configuration

Set on this repository's Actions settings:

- `R2_ACCOUNT_ID` (variable) - the Cloudflare account id
- `R2_BUCKET` (variable) - the bucket name, `clusterflick-data-transformed-backup`
- `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` (secrets) - an R2 API token
  with Object Read & Write on that bucket only

## Licence

The code in this repository is licensed under the [MIT licence](LICENSE).

The archives are a private copy of
[`data-transformed`](https://github.com/clusterflick/data-transformed)'s
releases and are not published. The releases themselves are available under the
terms in that repository.
