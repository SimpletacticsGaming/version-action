# Version Generator Action

Composite GitHub Action that standardises how we derive a version number in pipelines:

- Pull request events produce `0.<PR_NUMBER>.<GITHUB_RUN_ID>` so preview artifacts are easily identified.
- Protected branches (defaults to `main,master`) use the manually supplied `version` input and fail fast when the input is missing.
- Push events on branches that already have an open PR are treated as PR contexts by querying the GitHub API with the provided `GITHUB_TOKEN`.

## Inputs

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `version` | false | _none_ | Version string to use on protected branches (e.g. `1.2.3`). Required whenever you run the action outside of a PR. |
| `protected_branches` | false | `main,master` | Comma-separated list of branches that are allowed to accept the manual version input. |

## Outputs

| Name | Description |
| --- | --- |
| `version` | Either the generated PR version (`0.<PR>.<RUN_ID>`) or the supplied manual version. |

## Usage

```yaml
name: Build
on:
  pull_request:
  push:
    branches:
      - main

jobs:
  determine-version:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Compute version
        id: version
        uses: mohjohfox/version-action@main
        with:
          version: 1.2.3 # only respected on protected branches

      - name: Use version
        run: echo "Version is ${{ steps.version.outputs.version }}"
```

For release branches other than `main` set `protected_branches` accordingly.
