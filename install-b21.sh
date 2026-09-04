#!/usr/bin/env bash
#
# Fix: Play all did nothing.
#
# The YouTube IFrame API was fetched on the first click. By the time the
# script arrived and the player was built, the browser no longer traced
# it back to a user gesture, so autoplay was refused and nothing happened
# with no error to show for it.
#
# Three changes:
#   1. Load the API when the page loads, so the player can be created
#      immediately on click while the gesture still counts.
#   2. Call playVideo() explicitly when the player is ready, rather than
#      trusting the autoplay flag.
#   3. Say something when it fails instead of failing silently.
#
set -euo pipefail
cd /var/www/hinderhole

if [ ! -f public/player.js ]; then
  echo "Not in the app directory."
  exit 1
fi

echo "==> checking git is clean"
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "You have uncommitted changes. Commit them first."
  git status --short
  exit 1
fi

cp public/player.js /tmp/player.js.before

echo "==> patching the player"
python3 - <<'PY'
import pathlib, sys
p = pathlib.Path('public/player.js')
s = p.read_text()
changed = []

# 1. Play as soon as the player is ready. The autoplay flag alone is not
#    reliable once a promise has broken the gesture chain.
if 'onReady' not in s:
    old = """          events: {
            onStateChange: function (e) {
              if (e.data === YT.PlayerState.ENDED && autoAdvance) advance();
            },
            onError: function () {
              if (autoAdvance) advance();
            }
          }"""
    new = """          events: {
            onReady: function (e) {
              // Belt and braces: playerVars.autoplay is ignored in some
              // browsers when the player was built after an await.
              try { e.target.playVideo(); } catch (err) { /* nothing to do */ }
            },
            onStateChange: function (e) {
              if (e.data === YT.PlayerState.ENDED && autoAdvance) advance();
            },
            onError: function () {
              if (autoAdvance) advance();
              else setBar('That video will not play here. Open it on YouTube.');
            }
          }"""
    if old not in s:
        sys.exit('Could not find the player events block.')
    s = s.replace(old, new, 1)
    changed.append('onReady')

# 2. Surface a failure instead of swallowing it.
if 'Could not start the player' not in s:
    old = """    setBar('Playing ' + (i + 1) + ' of ' + queue.players.length);
    mount(host, true);"""
    new = """    setBar('Playing ' + (i + 1) + ' of ' + queue.players.length);
    mount(host, true).catch(function () {
      setBar('Could not start the player. Try tapping the song itself.');
    });"""
    if old in s:
        s = s.replace(old, new, 1)
        changed.append('error surfacing')

# 3. Fetch the API up front, so the click has a player to talk to.
if 'preload' not in s:
    old = "  document.addEventListener('click', function (e) {\n    if (!e.target.closest) return;"
    new = """  // Fetch the YouTube API now rather than on the first click. Loading it
  // inside the click handler meant the player was built a second later,
  // by which point the browser had stopped treating it as user initiated
  // and quietly refused to play anything.
  function preload() {
    if (document.querySelector('.player[data-video]')) loadYT();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', preload);
  } else {
    preload();
  }

  document.addEventListener('click', function (e) {
    if (!e.target.closest) return;"""
    if old not in s:
        sys.exit('Could not find the click handler.')
    s = s.replace(old, new, 1)
    changed.append('preload')

p.write_text(s)
print("    " + (", ".join(changed) if changed else "all already patched"))
PY

echo "==> syntax check"
if node --check public/player.js; then
  echo "    ok"
  rm -f /tmp/player.js.before
else
  echo "    FAILED, restoring"
  cp /tmp/player.js.before public/player.js
  exit 1
fi

echo
echo "Restart, then hard reload the ballot page:"
echo
echo '  pm2 restart hinderhole --update-env'
echo
echo '  git add -A && git commit -m "Fix Play all: preload the YouTube API" && git push'
