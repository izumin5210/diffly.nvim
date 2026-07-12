# diffly.nvim — Releasing

Releases are automated with [tagpr](https://github.com/Songmu/tagpr). The plugin ships no
in-repo version file: **git tags are the single source of truth**, and plugin managers
(lazy.nvim et al.) pin against them. tagpr keeps the tag, the CHANGELOG, and the GitHub
Release in sync from merged PRs — you never tag by hand.

Config lives in [`.tagpr`](../.tagpr); the workflow is
[`.github/workflows/tagpr.yml`](../.github/workflows/tagpr.yml).

## How it works

Every push to `main` runs the `tagpr` workflow, which maintains a single open **release
PR** titled like `Release for vX.Y.Z`. That PR accumulates everything merged since the last
tag and previews the next CHANGELOG.

When you merge the release PR, tagpr:

1. creates the tag `vX.Y.Z` (v-prefixed),
2. cuts a matching GitHub Release, and
3. commits the updated `CHANGELOG.md`.

The default bump is **patch**. To make it a minor or major release, add a label to the
release PR before merging:

| Label   | Bump                    |
| ------- | ----------------------- |
| `minor` | `1.2.3` → `1.3.0`       |
| `major` | `1.2.3` → `2.0.0`       |
| (none)  | `1.2.3` → `1.2.4` (patch) |

## Cutting a release

1. Land your feature/fix PRs into `main` as usual.
2. Find the open `Release for …` PR that tagpr maintains.
3. (Optional) add a `minor` / `major` label to override the patch default.
4. Review the previewed CHANGELOG and merge the PR.
5. tagpr tags the release and publishes the GitHub Release automatically.

### The very first release (v1.0.0)

With no tags yet, tagpr treats the current version as `v0.0.0` and defaults the first
release PR to `v0.0.1`. To ship the intended `v1.0.0`, add the **`major`** label to that
first release PR (`0.0.0` → major bump → `1.0.0`) before merging. Every release after that
follows the table above.

## One-time repository setup

These are configured on the GitHub repository, not in this repo, and only need doing once:

- **Let Actions manage the release PR.** Settings → Actions → General → *Workflow
  permissions* → enable **"Allow GitHub Actions to create and approve pull requests."**
  Without it the workflow cannot open the release PR.
- **Create the bump labels** so they can be applied to release PRs:

  ```sh
  gh label create major -c '#B60205' -d 'tagpr: bump the major version'
  gh label create minor -c '#0E8A16' -d 'tagpr: bump the minor version'
  ```

## Notes

- The release PR is pushed by the default `GITHUB_TOKEN`, so it does **not** re-trigger the
  `CI` workflow on itself. That PR only touches `CHANGELOG.md`, so this is intentional and
  fine. If you ever want CI to run on the release PR, pass a PAT via tagpr's `github_token`
  input instead of relying on `GITHUB_TOKEN`.
