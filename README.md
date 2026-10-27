# Reusable components and profiles

Actions, components, and descriptions for the `bcit-tlu` organization.

## Renovate preset

[`.github/renovate/default.json`](.github/renovate/default.json) is a shared [Renovate](https://docs.renovatebot.com) preset.

Consumer repos opt in with a root `renovate.json`:

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["github>bcit-tlu/.github//.github/renovate/default"]
}
```

The shared reusable workflow `.github/workflows/renovate.yaml` runs Renovate
self-hosted via GitHub Actions (`GITHUB_TOKEN`, no third-party app).

## PR preview images

`oci-build.yaml` can publish images for same-repository pull requests
(`push_pr_images: true`): tags `sha-<head sha>` and `pr-<number>`, built from
the PR head, never rc-tagged or signed. flux-fleet-v2 PR previews pin
`sha-<head>`.

`pr-image-cleanup.yaml` removes those versions when the PR closes. Callers add:

```yaml
# .github/workflows/pr-image-cleanup.yaml
name: PR image cleanup
on:
  pull_request:
    types: [closed]
jobs:
  cleanup:
    uses: bcit-tlu/.github/.github/workflows/pr-image-cleanup.yaml@main
    permissions:
      contents: read
      packages: write
      pull-requests: read
    with:
      image_names: |
        <image-name>
```

Only versions tagged exclusively with `pr-*`/`sha-*` for that PR are deleted;
main-branch builds (which always carry an rc tag) and releases are never
touched.
