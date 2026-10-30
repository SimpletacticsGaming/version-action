# version-action

A composite GitHub Action that computes a **CalVer** version from a commit's
committer date in UTC.

```
yyyy.m.dhhmmss              on protected branches   →  2026.10.29143507
yyyy.m.dhhmmss-g<shortsha>  everywhere else         →  2026.10.29143507-g1a2b3c4
```

The version is a pure function of the commit, so re-running a pipeline on the
same SHA always produces the same string. That is what makes it safe to create a
release tag with exactly the computed version.

## Format

| Component | Source | Example |
| --- | --- | --- |
| `yyyy` | committer year (UTC) | `2026` |
| `m` | committer month, no leading zero | `1` … `12` |
| `dhhmmss` | committer day with no leading zero, then the time zero-padded to six digits | `5040506` (the 5th, 04:05:06) |

`2026-01-05T04:05:06Z` → `2026.1.5040506` · `2026-12-31T23:59:59Z` → `2026.12.31235959`

Only the day loses its leading zero; `hhmmss` is always exactly six digits, so
the third component is unambiguous and increases monotonically through a month.

### Why this shape

- **Valid semver.** Semver forbids leading zeros in numeric identifiers, so
  dropping them is required rather than cosmetic. npm, NuGet, Maven, Docker tags
  and anything expecting `vX.Y.Z` all keep working.
- **Fits in an Int32.** The largest possible third component is `31235959`
  (day 31, 23:59:59), well under 2147483647, which NuGet and Maven require.
- **`-g` prefix on the suffix.** A bare `-<sha>` suffix is *invalid* semver
  whenever the short sha happens to be all digits with a leading zero
  (e.g. `0123456`) — about one commit in 270. The `g` prefix follows the
  `git describe` convention and removes that failure mode entirely.
- **Prereleases sort below releases**, which is what a PR build should do.

### Sorting caveat

Version components are numeric but not fixed-width, so **plain string sorting is
wrong**:

```
2026.10.9235959    the 9th at 23:59:59
2026.10.10000000   the 10th at 00:00:00  ← newer, but sorts first lexically
```

Always compare with `sort -V`, or `git tag --sort=version:refname`. The same
applies to month 9 vs month 10.

## Usage

The action only *computes* a version — it never creates tags or releases, and it
needs no token. Your workflow stays in control of what happens next:

```yaml
- uses: actions/checkout@v4

- id: version
  uses: mohjohfox/version-action@v1

- name: Build
  run: ./build.sh --version "${{ steps.version.outputs.version }}"

- name: Release
  if: steps.version.outputs.is_prerelease == 'false' && steps.version.outputs.tag_exists == 'false'
  env:
    GH_TOKEN: ${{ github.token }}
  run: |
    gh release create "${{ steps.version.outputs.tag }}" \
      --target "${{ steps.version.outputs.commit_sha }}" \
      --title "${{ steps.version.outputs.version }}" \
      --generate-notes
```

The `tag_exists` guard makes re-running a release job a no-op instead of a
failure. Creating a release requires `permissions: contents: write` on the job.

### Protected branches

```yaml
- uses: mohjohfox/version-action@v1
  with:
    protected_branches: |
      main
      release/*
```

Patterns are globs, and may be given newline- or comma-separated. A
`pull_request` event is **always** a prerelease, even when the head branch
matches a pattern — the commit has not landed yet. A push to a branch that
matches nothing also gets the suffix.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `protected_branches` | `main,master` | Branches that receive a bare release version. Glob patterns, comma- or newline-separated. |
| `tag_prefix` | `v` | Prefix for the `tag` output. Set to `""` for bare tags. |
| `sha_length` | `7` | Characters of the short sha in the prerelease suffix (4–40). |
| `non_monotonic` | `warn` | What to do when the computed version is older than the latest existing release tag: `warn`, `fail`, or `ignore`. |
| `version` | — | Explicit override. When set, the computed value is discarded and this string is used verbatim. |
| `remote` | `origin` | Git remote used for tag lookups and for fetching a missing commit. |

## Outputs

| Output | Example | Description |
| --- | --- | --- |
| `version` | `2026.10.29143507` | The computed version. |
| `tag` | `v2026.10.29143507` | `version` with `tag_prefix` applied. |
| `is_prerelease` | `false` | `true` when the version carries a `-g<sha>` suffix. |
| `is_protected` | `true` | `true` when the branch matches `protected_branches`. |
| `tag_exists` | `false` | `true` when `tag` already exists on the remote **at this exact commit**. |
| `commit_sha` | `1a2b3c4…` | Full sha the version was derived from. |
| `short_sha` | `1a2b3c4` | Truncated sha used in the suffix. |
| `commit_date` | `2026-10-29T14:35:07Z` | Committer date of that commit, UTC. |
| `branch` | `main` | Branch the version was computed for. |

## Behaviour worth knowing

**Pull requests use the PR head commit.** On `pull_request` events `GITHUB_SHA`
points at the ephemeral `refs/pull/N/merge` commit, whose committer date is the
moment that merge ref was built — it changes on every re-run. The action reads
`.pull_request.head.sha` instead, so PR versions are reproducible. If the commit
is missing from a shallow clone, it is fetched by sha; `fetch-depth: 1` is fine.

**Tag collisions fail loudly.** On a protected branch the action checks the
remote for `tag`:

| Situation | Result |
| --- | --- |
| Tag does not exist | `tag_exists=false`, proceed |
| Tag points at this commit | `tag_exists=true`, succeed — safe pipeline re-run |
| Tag points at a different commit | **Exit 1** |

The last case means two commits share a committer second (bot or scripted
batches, or `git commit --amend` preserving the date) or history was rewritten.

**Versions can move backwards.** GitHub's merge, squash and rebase buttons set
the committer date to merge time, so merged PRs stay monotonic. Pushing commits
made locally days ago lands an older version after a newer release. The action
warns by default; set `non_monotonic: fail` to block it.

## Development

```bash
bash tests/compute-version.test.sh     # no network, no token, no framework
shellcheck --severity=style scripts/*.sh tests/*.sh
```

The logic lives in [`scripts/compute-version.sh`](scripts/compute-version.sh),
driven by `INPUT_*` environment variables and emitting `key=value` lines on
stdout, so it can be run directly:

```bash
GITHUB_REF_NAME=main GITHUB_SHA=$(git rev-parse HEAD) bash scripts/compute-version.sh
```

## Releases

The action releases itself. On a push to `main`, after shellcheck, the unit
tests and the self-test are green, the `release` job runs the action from the
repository root and uses its own output as the version it is published under:

| Tag | Moves? | Purpose |
| --- | --- | --- |
| `v2026.10.29143507` | no | Immutable release, with a GitHub release attached |
| `v1` | yes | Floating pointer consumers track with `@v1` |

Because the version is a pure function of the commit, re-running the workflow on
an already-released commit is a no-op: `tag_exists` comes back `true`, the
release step is skipped, and only the `v1` pointer is re-pushed to the same sha.
Pin `@v1` for updates, or an immutable `v2026.…` tag to freeze a version.
