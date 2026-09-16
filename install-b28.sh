#!/usr/bin/env bash
#
# Playback changes:
#
#   1. Clicking any song starts a run from there and keeps going.
#      Play all is now just a shortcut for starting at the top.
#   2. Controls appear whenever something is playing, not only after
#      Play all.
#   3. Controls move to a bar fixed at the bottom of the screen, away
#      from the points buttons, because reaching for next and hitting a
#      7 by mistake costs someone real points.
#
# player.js is replaced wholesale rather than patched. It had been
# string-patched four times and was getting brittle.
#
set -euo pipefail
cd /var/www/hinderhole

if [ ! -f public/player.js ]; then
  echo "Not in the app directory."
  exit 1
fi

cp public/player.js /tmp/player.js.b28
cp public/app.css /tmp/app.css.b28

echo "==> replacing player.js"
cp player.js public/player.js
node --check public/player.js || {
  echo "    FAILED"; cp /tmp/player.js.b28 public/player.js; exit 1; }
echo "    ok"

echo "==> checking the chat badge survived the rewrite"
grep -q 'chat__badge' public/player.js && echo "    ok" || {
  echo "    MISSING, restoring"; cp /tmp/player.js.b28 public/player.js; exit 1; }

echo "==> styles"
if grep -q 'nowbar__inner' public/app.css; then
  echo "    already there, skipping"
else
  cat nowbar.css >> public/app.css
  echo "    done"
fi

rm -f player.js nowbar.css

echo "==> restarting"
pm2 restart hinderhole --update-env >/dev/null
sleep 2

fail=0
for path in /round/2/vote /round/1/results /; do
  code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:3000$path")
  case "$code" in
    200|302) echo "    $path -> $code ok" ;;
    *) echo "    $path -> $code PROBLEM"; fail=1 ;;
  esac
done

if [ "$fail" = "1" ]; then
  echo "Restoring."
  cp /tmp/player.js.b28 public/player.js
  cp /tmp/app.css.b28 public/app.css
  pm2 restart hinderhole --update-env >/dev/null
  exit 1
fi

rm -f /tmp/player.js.b28 /tmp/app.css.b28
echo
echo "Hard reload the ballot, then:"
echo "  git add -A && git commit -m 'Play from any song, controls fixed to the bottom' && git push"
