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
