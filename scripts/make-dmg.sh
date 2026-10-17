#!/bin/bash
# Builds the release DMG: Xkeys.app beside a link to /Applications, in a Finder window whose background shows the drag.
# The layout needs Finder scripting. If Finder cannot be scripted (no GUI session or no Automation permission),
# the DMG keeps Finder's default layout with the same two items, so a release never fails because of the layout.
# Usage: scripts/make-dmg.sh <Xkeys.app> <output.dmg> <volume name>
set -euo pipefail

app="$1"
dmg="$2"
volname="$3"
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
device=""
cleanup() {
  if [ -n "$device" ]; then hdiutil detach "$device" -force >/dev/null 2>&1 || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

staging="$work/staging"
mkdir -p "$staging/.background"
ditto "$app" "$staging/Xkeys.app"
ln -s /Applications "$staging/Applications"
# One TIFF with both resolutions keeps the background sharp on Retina displays; fall back to the 1x PNG.
if tiffutil -cathidpicheck "$here/dmg/background.png" "$here/dmg/background@2x.png" -out "$staging/.background/background.tiff" >/dev/null 2>&1; then
  background="background.tiff"
else
  cp "$here/dmg/background.png" "$staging/.background/background.png"
  background="background.png"
fi

# hdiutil occasionally reports "Resource busy" on hosted runners; retry instead of rerunning the whole job.
rw="$work/rw.dmg"
for attempt in 1 2 3; do
  hdiutil create -volname "$volname" -srcfolder "$staging" -fs HFS+ -format UDRW -ov "$rw" >/dev/null && break
  [ "$attempt" = 3 ] && exit 1
  sleep 5
done

device="$(hdiutil attach -readwrite -noverify -noautoopen "$rw" | awk '/^\/dev\// { dev = $1 } END { print dev }')"
device="$(printf '%s' "$device" | sed -E 's/s[0-9]+$//')"
[ -d "/Volumes/$volname" ] || { echo "::error::Could not mount $rw at /Volumes/$volname"; exit 1; }

# Icon positions are the icon centers; they match the arrow drawn in dmg/background.png (660×400).
osascript > "$work/layout.log" 2>&1 <<APPLESCRIPT &
tell application "Finder"
  tell disk "$volname"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 548}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 112
    set text size of viewOptions to 13
    set background picture of viewOptions to file ".background:$background"
    set position of item "Xkeys.app" of container window to {170, 210}
    set position of item "Applications" of container window to {490, 210}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT
layout=$!
# A Finder that waits for an Automation prompt would hang the job, so give up after a minute.
( sleep 60; kill "$layout" 2>/dev/null ) &
watchdog=$!
if wait "$layout"; then
  echo "Applied the Finder layout to the DMG window"
else
  echo "::warning::Finder could not lay out the DMG window; it keeps the default layout. $(tr '\n' ' ' < "$work/layout.log")"
fi
kill "$watchdog" 2>/dev/null || true

sync
for attempt in 1 2 3; do
  hdiutil detach "$device" >/dev/null && break
  [ "$attempt" = 3 ] && hdiutil detach "$device" -force >/dev/null
  sleep 3
done
device=""
hdiutil convert "$rw" -format UDZO -imagekey zlib-level=9 -ov -o "$dmg" >/dev/null
