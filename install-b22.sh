#!/usr/bin/env bash
#
# Transport controls on the queue bar: previous, play/pause, next.
#
# Skipping with YouTube's own controls does not tell us anything, so the
# queue lost track and stopped advancing. Our own buttons drive the queue
# directly, so skipping keeps the run going.
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
cp views/vote.ejs /tmp/vote.ejs.before
cp views/results.ejs /tmp/results.ejs.before

echo "==> adding the buttons to the queue bar"
python3 - <<'PY'
import pathlib
old = '''      <button class="queuebar__toggle" type="button">Play all</button>
      <span class="queuebar__status"></span>'''
new = '''      <button class="queuebar__toggle" type="button">Play all</button>
      <span class="queuebar__transport" hidden>
        <button class="queuebar__btn" type="button" data-act="prev" aria-label="Previous song">&#9664;&#9664;</button>
        <button class="queuebar__btn" type="button" data-act="playpause" aria-label="Pause">&#10074;&#10074;</button>
        <button class="queuebar__btn" type="button" data-act="next" aria-label="Next song">&#9654;&#9654;</button>
      </span>
      <span class="queuebar__status"></span>'''

for f in ['views/vote.ejs', 'views/results.ejs']:
    p = pathlib.Path(f)
    s = p.read_text()
    if 'queuebar__transport' in s:
        print(f"    {f} already there, skipping"); continue
    if old not in s:
        print(f"    {f} anchor not found, skipping"); continue
    p.write_text(s.replace(old, new, 1))
    print(f"    {f} done")
PY

echo "==> wiring them up"
python3 - <<'PY'
import pathlib, sys
p = pathlib.Path('public/player.js')
s = p.read_text()

if 'queuebar__transport' in s:
    print("    already there, skipping"); sys.exit(0)

# Show or hide the transport with the run, and keep the label honest.
old_bar = """  function setBar(text) {
    var bar = document.querySelector('.queuebar__status');
    if (bar) bar.textContent = text || '';
    var btn = document.querySelector('.queuebar__toggle');
    if (btn) btn.textContent = queue.on ? 'Stop' : 'Play all';
  }"""

new_bar = """  function setBar(text) {
    var bar = document.querySelector('.queuebar__status');
    if (bar) bar.textContent = text || '';
    var btn = document.querySelector('.queuebar__toggle');
    if (btn) btn.textContent = queue.on ? 'Stop' : 'Play all';

    var transport = document.querySelector('.queuebar__transport');
    if (transport) {
      if (queue.on) transport.removeAttribute('hidden');
      else transport.setAttribute('hidden', '');
    }
  }

  /** The play/pause button has to say what it will do, not what is happening. */
  function setPlayPause(paused) {
    var b = document.querySelector('[data-act="playpause"]');
    if (!b) return;
    b.innerHTML = paused ? '&#9654;' : '&#10074;&#10074;';
    b.setAttribute('aria-label', paused ? 'Play' : 'Pause');
  }

  /** The player for whatever is currently up, if it is a YouTube one. */
  function current() {
    var host = queue.players[queue.index];
    return host && host._yt ? host._yt : null;
  }

  function back() {
    if (!queue.on) return;
    // Past ten seconds in, go to the start of this one instead. Same as
    // every other player anyone has used.
    var yt = current();
    if (yt && yt.getCurrentTime && yt.getCurrentTime() > 10) {
      yt.seekTo(0);
      return;
    }
    if (queue.index > 0) play(queue.index - 1);
  }

  function skip() {
    if (!queue.on) return;
    if (queue.index + 1 >= queue.players.length) {
      return stop('Reached the end of the round.');
    }
    play(queue.index + 1);
  }

  function togglePause() {
    var yt = current();
    if (yt && yt.getPlayerState) {
      // 1 is playing, 2 is paused, 3 is buffering.
      if (yt.getPlayerState() === 1) { yt.pauseVideo(); setPlayPause(true); }
      else { yt.playVideo(); setPlayPause(false); }
      return;
    }
    var audio = queue.players[queue.index] &&
                queue.players[queue.index].querySelector('.player__audio');
    if (audio) {
      if (audio.paused) { audio.play(); setPlayPause(false); }
      else { audio.pause(); setPlayPause(true); }
    }
  }"""

if old_bar not in s:
    sys.exit('Could not find setBar.')
s = s.replace(old_bar, new_bar, 1)

# Keep the button in sync when the video is paused from inside the iframe.
s = s.replace(
    """            onStateChange: function (e) {
              if (e.data === YT.PlayerState.ENDED && autoAdvance) advance();
            },""",
    """            onStateChange: function (e) {
              if (e.data === YT.PlayerState.ENDED && autoAdvance) advance();
              // Someone may pause inside the player rather than using ours.
              if (e.data === YT.PlayerState.PLAYING) setPlayPause(false);
              if (e.data === YT.PlayerState.PAUSED) setPlayPause(true);
            },"""
)

# Wire the clicks.
s = s.replace(
    """    var toggle = e.target.closest('.queuebar__toggle');
    if (toggle) {
      if (queue.on) stop(null);
      else start();
    }""",
    """    var toggle = e.target.closest('.queuebar__toggle');
    if (toggle) {
      if (queue.on) stop(null);
      else start();
      return;
    }

    var act = e.target.closest('.queuebar__btn');
    if (act) {
      var what = act.getAttribute('data-act');
      if (what === 'next') skip();
      else if (what === 'prev') back();
      else if (what === 'playpause') togglePause();
    }"""
)

p.write_text(s)
print("    done")
PY

echo "==> styling"
if grep -q 'queuebar__btn' public/app.css; then
  echo "    already there, skipping"
else
cat >> public/app.css << 'CSSEOF'

/* Transport controls, shown only while a run is going. */
.queuebar__transport {
  display: inline-flex;
  gap: .25rem;
  flex: none;
}

.queuebar__transport[hidden] { display: none; }

.queuebar__btn {
  font-family: var(--util);
  font-size: .7rem;
  line-height: 1;
  min-width: 2.2rem;
  padding: .45rem .4rem;
  border: 1px solid rgba(240, 232, 216, .26);
  border-radius: 2px;
  background: transparent;
  color: var(--stock);
  cursor: pointer;
}

.queuebar__btn:hover,
.queuebar__btn:focus-visible {
  border-color: var(--amber);
  color: var(--amber);
}

@media (max-width: 30rem) {
  .queuebar { flex-wrap: wrap; }
  .queuebar__status { width: 100%; }
}
CSSEOF
  echo "    done"
fi

echo "==> syntax check"
ok=1
node --check public/player.js || ok=0
node -e "
  const ejs=require('ejs'), fs=require('fs');
  ['views/vote.ejs','views/results.ejs']
    .forEach(f => ejs.compile(fs.readFileSync(f,'utf8'), { filename: f }));
" || ok=0

if [ "$ok" = "1" ]; then
  echo "    ok"
  rm -f /tmp/player.js.before /tmp/vote.ejs.before /tmp/results.ejs.before
else
  echo "    FAILED, restoring"
  cp /tmp/player.js.before public/player.js
  cp /tmp/vote.ejs.before views/vote.ejs
  cp /tmp/results.ejs.before views/results.ejs
  exit 1
fi

echo
echo "Restart, then hard reload the ballot:"
echo
echo '  pm2 restart hinderhole --update-env'
echo '  git add -A && git commit -m "Transport controls on the queue bar" && git push'
