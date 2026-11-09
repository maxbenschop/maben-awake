#!/bin/zsh
# Publishes the release that ./release.sh just built:
#   1. checks that main is clean, pushed, and has a CHANGELOG.md section for this version
#   2. tags the commit vX.Y.Z and pushes the tag
#   3. creates the GitHub release with Maben-Awake.dmg and Maben-Awake.zip, notes from CHANGELOG.md
#      -> every installed copy sees it within 6 hours and updates itself
#   4. rebuilds and deploys awake.maben.gg (version, checksums, changelog). Its download buttons point at
#      releases/latest, so they already serve the new version as soon as step 3 is done.
# Needs: gh (logged in as a maintainer), and ../maben with the website for step 4 (skipped if missing).
set -e
cd "$(dirname "$0")"
VERSION=$(plutil -extract CFBundleShortVersionString raw Info.plist)
TAG="v$VERSION"
DMG=dist/Maben-Awake.dmg
ZIP=dist/Maben-Awake.zip
BUILT="build/archive/notarized/Maben Awake.app"

[[ -f $DMG && -f $ZIP && -d $BUILT ]] || { echo "Run ./release.sh first."; exit 1; }
[[ $(plutil -extract CFBundleShortVersionString raw "$BUILT/Contents/Info.plist") == "$VERSION" ]] \
  || { echo "dist/ holds another version than Info.plist ($VERSION). Run ./release.sh again."; exit 1; }
xcrun stapler validate "$BUILT" >/dev/null || { echo "The build isn't notarized."; exit 1; }

[[ $(git branch --show-current) == main ]] || { echo "Publish from main."; exit 1; }
[[ -z $(git status --porcelain) ]] || { echo "Commit or stash your changes first."; exit 1; }
git fetch -q origin main
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || { echo "main isn't the same as origin/main. Push or pull first."; exit 1; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "$TAG already exists."; exit 1; }

NOTES=$(mktemp)
awk -v v="## $VERSION " 'index($0, v) == 1 {on=1; next} /^## / && on {exit} on' CHANGELOG.md | sed '/./,$!d' > "$NOTES"
[[ -s $NOTES ]] || { echo "CHANGELOG.md has no section '## $VERSION · <date>'."; exit 1; }

echo "Publishing Maben Awake $VERSION…"
git tag -a "$TAG" -m "Maben Awake $VERSION"
git push -q origin "$TAG"
gh release create "$TAG" "$DMG" "$ZIP" --title "Maben Awake $VERSION" --notes-file "$NOTES" --verify-tag --latest
rm -f "$NOTES"
echo "GitHub release $TAG is live. Installed copies update within 6 hours."

SITE=../maben
if [[ -f $SITE/awake-site-src/build.py ]]; then
  python3 - "$SITE/awake-site-src/release.json" "$VERSION" <<'PY'
import json, sys, datetime
p, version = sys.argv[1], sys.argv[2]
r = json.load(open(p))
d = datetime.date.today()
nl = ["januari","februari","maart","april","mei","juni","juli","augustus","september","oktober","november","december"]
r.update(version=version, date=d.isoformat(), date_text=f"{d.day} {d.strftime('%B')} {d.year}", date_text_nl=f"{d.day} {nl[d.month-1]} {d.year}")
json.dump(r, open(p, "w"), indent=2)
PY
  python3 "$SITE/awake-site-src/build.py" --from-dist dist
  HOST=eq14
  ssh -o BatchMode=yes -o ConnectTimeout=5 eq14 true 2>/dev/null || HOST_OPT=(-o HostName=eq14.local)
  rsync -a --delete --exclude .DS_Store -e "ssh ${HOST_OPT[*]}" "$SITE/awake-site/" "$HOST:/opt/stacks/maben-site/awake-site/"
  echo "awake.maben.gg updated to $VERSION."
fi
