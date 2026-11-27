# Contributing to Maben Awake

Thanks for helping. This page explains how changes get from an idea to everyone's Mac.

## How the code flows

```
your fork / branch ──PR──▶ main ──ship.sh──▶ tag vX.Y.Z + GitHub release ──▶ every Mac updates itself
```

- **`main`** is always releasable. Nobody pushes to it directly (except the maintainer for small fixes); every change
  arrives through a pull request.
- **Branches** are short-lived and named after what they do: `fix/lid-sleep-on-battery`, `feature/cursor-hooks`,
  `docs/install-steps`. One topic per branch.
- **Releases** are tags `vX.Y.Z` on `main`, created only by the maintainer with `ship.sh`. A GitHub release is
  what installed copies update to, so nothing reaches users before it's tagged and released.

## Making a change

1. Fork the repository (or, if you have write access, create a branch).
2. Build and run: `swift build && ./build.sh install` builds a development copy and installs it.
3. Run the tests: `swift test` and `./tests/integration-test.sh`. The `tests/` folder has longer end-to-end tests for the lid and
   freezing; run the ones that touch what you changed.
4. If people will notice the change, add a line under `## Unreleased` at the top of `CHANGELOG.md`. Don't change the version
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

One command, from an up-to-date checkout with everything that should go out in the working tree or on `main`:

```sh
./ship.sh --check        # shows the version, the notes and what will be committed; changes nothing
./ship.sh                # the next patch version; or: ./ship.sh minor | major | X.Y.Z
```

It sets the version in `Info.plist` (`1.7.2` for fixes, `1.8` for features), turns `## Unreleased` in `CHANGELOG.md` into
`## <version> · <date>`, runs the tests, opens the pull request and merges it when **Build and test** passes,
runs `./release.sh` (universal build, Developer ID, Apple's notarization) and `./publish.sh` (tag `vX.Y.Z`,
GitHub release with `Maben-Awake.dmg` and `Maben-Awake.zip`, awake.maben.gg), and at the end downloads the
published zip and checks it the way an installed copy does. After a failure, fix the cause and run it again.

It needs no passwords: Xcode's signed-in Apple account signs and notarizes, and `gh` is logged in. A published
release can't be changed (releases are immutable), so a mistake is fixed with the next version.

Installed copies check GitHub at start and every 6 hours, verify the Developer ID signature and Apple's
notarization, and install while the lid is open and no agent is working.

## Style

- Swift: follow the code around you. Comments explain why, not what.
- User-facing text: short, plain sentences, sentence case, no jargon. "Frozen", not "SIGSTOPped".
- Keep the Maben look in Settings and the menu: dark, one accent colour (`MB.green`), see `MabenUI.swift`.

## Code of conduct

Be kind and assume good intent. Harassment isn't tolerated.
