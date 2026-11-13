# Contributing to Maben Awake

Thanks for helping. This page explains how changes get from an idea to everyone's Mac.

## How the code flows

```
your fork / branch ──PR──▶ main ──release.sh + publish.sh──▶ tag vX.Y.Z + GitHub release ──▶ every Mac updates itself
```

- **`main`** is always releasable. Nobody pushes to it directly (except the maintainer for small fixes); every change
  arrives through a pull request.
- **Branches** are short-lived and named after what they do: `fix/lid-sleep-on-battery`, `feature/cursor-hooks`,
  `docs/install-steps`. One topic per branch.
- **Releases** are tags `vX.Y.Z` on `main`, created only by the maintainer with `publish.sh`. A GitHub release is
  what installed copies update to, so nothing reaches users before it's tagged and released.

## Making a change

1. Fork the repository (or, if you have write access, create a branch).
2. Build and run: `swift build && ./build.sh install` builds a development copy and installs it.
3. Run the tests: `swift test` and `./tests/integration-test.sh`. The `tests/` folder has longer end-to-end tests for the lid and
   freezing; run the ones that touch what you changed.
4. If people will notice the change, add a line under the top section of `CHANGELOG.md`. Don't change the version
   in `Info.plist`; that happens when releasing.
5. Open a pull request into `main` and fill in the template.

## What a pull request needs before it's merged

These are enforced by the repository rules on `main`:

- The **Build and test** check passes (GitHub Actions: debug and release build, unit tests, installer and hook tests, the UI
  rendered once, scripts, changelog).
- One approving review from a code owner (`.github/CODEOWNERS`).
- All review conversations resolved.
- Merged with **squash**, so `main` has one commit per pull request and a straight history. The branch is deleted
  after merging.
- No force pushes to `main`, and `main` can't be deleted.

Tags matching `v*` can only be created, moved or deleted by repository admins, so only the maintainer can release.

## Releasing (maintainer)

1. Bump `CFBundleShortVersionString` in `Info.plist` (semantic versioning: `1.4.1` for fixes, `1.5` for features)
   and make sure `CHANGELOG.md` has a section `## <version> · <date>`.
2. Merge to `main`, then on an up-to-date `main`: `./release.sh` (builds, signs, notarizes).
3. `./publish.sh`: tags `vX.Y.Z`, creates the GitHub release with `Maben-Awake.dmg` and `Maben-Awake.zip`, and
   updates awake.maben.gg.

Installed copies check GitHub at start and every 6 hours, verify the Developer ID signature and Apple's
notarization, and install while the lid is open and no agent is working.

## Style

- Swift: follow the code around you. Comments explain why, not what.
- User-facing text: short, plain sentences, sentence case, no jargon. "Frozen", not "SIGSTOPped".
- Keep the Maben look in Settings and the menu: dark, one accent colour (`MB.green`), see `MabenUI.swift`.

## Code of conduct

Be kind and assume good intent. Harassment isn't tolerated.
