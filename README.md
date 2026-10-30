# version-action

A composite GitHub Action that computes a **semantic version** for the commit being
built. The number comes from Conventional Commit messages; the shape comes from which
channel you ask for.

```
1.4.0-g1a2b3c4    channel: dev       every push
1.4.0-rc.2        channel: rc        cut from a release/1.4 branch
1.4.0             channel: release   promotion of an existing rc
```

The action only *computes* a version — it never creates tags or releases. Your
workflow stays in control of what happens next.

## The three channels

### `dev` — what is this build?

Runs [semantic-release](https://semantic-release.gitbook.io) in dry-run to work out
what the next release *would* be, then appends the short sha. Every push to `main` or
a feature branch gets one. These versions are for images and artifacts; they are never
tagged.

| Commits since the last release | `base_version` | `version` |
| --- | --- | --- |
| a `feat:` | next minor | `1.4.0-g1a2b3c4` |
| only `fix:` | next patch | `1.3.5-g1a2b3c4` |
| a `!` or `BREAKING CHANGE:` | next major | `2.0.0-g1a2b3c4` |
| only `docs:`/`chore:`/`ci:` | last release + patch, `has_release=false` | `1.3.5-g1a2b3c4` |

That last row matters: a non-releasable commit still produces a usable version so the
build can proceed. Use `has_release` to decide whether to *tag*, never whether to
build.

### `rc` — cut a release candidate

Must run on a `release/<major>.<minor>` branch. The branch names the line, so the base
needs no commit analysis at all:

- no `v1.4.*` release yet on this branch → base `1.4.0`
- `v1.4.0` already released → base `1.4.1`

The candidate number is the highest existing `v<base>-rc.N` plus one. If the commit
already carries an rc for this base, that one is reused and `tag_exists` is `true`, so
re-running is a no-op rather than a second candidate for identical code.

### `release` — promote a candidate

Takes the rc tag in `promote_from`, strips `-rc.N`, and checks the tag exists. Pair it
with a registry-side image retag so the released image is the one that was tested:

```bash
crane tag "$IMAGE:$RC_VERSION" "$FINAL_VERSION"
```

## Why `-g<sha>` and not `-<sha>`

A bare `-<sha>` suffix is *invalid* semver whenever the short sha happens to be all
digits with a leading zero (e.g. `0123456`) — about one commit in 270. The `g` prefix
follows the `git describe` convention and removes that failure mode.

It also sorts correctly. Semver compares prerelease identifiers alphabetically, and
`g` < `r`, so dev builds rank below release candidates, and both below the release:

```
1.4.0-g1a2b3c4  <  1.4.0-rc.1  <  1.4.0
```

## Usage

```yaml
- uses: actions/checkout@v4
  with:
    # Required. semantic-release analyses history back to the last tag.
    fetch-depth: 0

- id: version
  uses: SimpletacticsGaming/version-action@v1.0.0

- name: Build
  run: ./build.sh --version "${{ steps.version.outputs.version }}"
```

Cutting a release candidate, on a `release/*` branch:

```yaml
- id: version
  uses: SimpletacticsGaming/version-action@v1.0.0
  with:
    channel: rc

- name: Tag it
  if: steps.version.outputs.tag_exists == 'false'
  run: |
    git tag "${{ steps.version.outputs.tag }}"
    git push origin "${{ steps.version.outputs.tag }}"
```

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `channel` | `dev` | `dev`, `rc` or `release`. |
| `promote_from` | — | For `release`: the `v<version>-rc.<n>` tag being promoted. |
| `tag_prefix` | `v` | Prefix for the `tag` output. Set to `""` for bare tags. |
| `sha_length` | `7` | Characters of short sha in the dev suffix (4–40). |
| `version` | — | Explicit override. The computed value is discarded. |
| `remote` | `origin` | Remote consulted for existing release branches. |

## Outputs

| Output | Example | Description |
| --- | --- | --- |
| `version` | `1.4.0-rc.2` | The computed version. |
| `base_version` | `1.4.0` | The bare `X.Y.Z` it is built from. |
| `tag` | `v1.4.0-rc.2` | `version` with `tag_prefix` applied. |
| `rc_number` | `2` | Candidate number, on the `rc` and `release` channels. |
| `is_prerelease` | `true` | `false` only on the `release` channel. |
| `has_release` | `true` | `false` when no commit since the last release was releasable. |
| `release_type` | `minor` | `major`/`minor`/`patch` on `dev`; empty otherwise. |
| `last_version` | `1.3.4` | The release this one follows, if any. |
| `tag_exists` | `false` | `true` when `tag` already exists, making the run a no-op. |
| `commit_sha` | `1a2b3c4…` | Full sha the version was derived from. |
| `short_sha` | `1a2b3c4` | Truncated sha used in the dev suffix. |
| `commit_date` | `2026-10-29T14:35:07Z` | Committer date, UTC. |
| `branch` | `main` | Branch the version was computed for. |

## Behaviour worth knowing

**`fetch-depth: 0` is required, not merely recommended.** The `dev` channel analyses
history back to the last tag. A shallow clone yields a shallow mirror, and the result
is a wrong version reported without an error.

**Do not run the `dev` channel on a detached HEAD.** semantic-release determines its
branch from the working tree, and on a detached HEAD it reports "no release" rather
than failing. The action detects this and exits with an error instead. In practice:
version the branch on a `push` build, not a tag or a `pull_request` merge ref. The
`rc` and `release` channels derive everything from refs and are safe while detached.
On a `pull_request` build, check the head branch out explicitly:

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0
    ref: ${{ github.event.pull_request.head.ref }}
    repository: ${{ github.event.pull_request.head.repo.full_name }}
```

**No credentials are needed.** semantic-release verifies push permission before it
will compute anything, and that check is *not* skipped in dry-run mode. Rather than
granting the job write access, the action clones the workspace into a throwaway bare
mirror and points semantic-release at that. A genuine auth problem can therefore never
be misreported as "nothing to release".

**Tags on other branches are ignored.** Every lookup is `git tag --merged HEAD`, so a
`v1.4.7` cut on an unrelated branch cannot raise this branch's base.

**Trunk skips past a cut release line.** Once `release/1.4` exists, `main` would
otherwise keep computing `1.4.0` until the release is tagged and merged back. The
action floors trunk's base at `1.5.0` for as long as that branch exists.

## Development

```bash
bash tests/compute-version.test.sh     # no network, no token, no Node
shellcheck --severity=style scripts/*.sh tests/*.sh
```

The logic lives in [`scripts/compute-version.sh`](scripts/compute-version.sh), driven
by `INPUT_*` environment variables and emitting `key=value` lines on stdout, so it can
be run directly:

```bash
INPUT_CHANNEL=dev GITHUB_REF_NAME=main bash scripts/compute-version.sh
```

The test suite stubs the Node call through `SEMVER_CMD`, which keeps it offline and
fast; the real semantic-release path is exercised by the `self-test` job in CI.

## Releases

The action releases itself with semantic-release. On a push to `main`, after
shellcheck, the unit tests and the self-test are green, a releasable commit produces a
`vX.Y.Z` tag and a GitHub release. A `docs:`-only push produces no release and exits
green.

Pin an exact tag — `@v1.0.0`. There is no floating `v1` pointer.
