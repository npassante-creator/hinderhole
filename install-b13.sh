#!/usr/bin/env bash
#
# Unread count on the Chat link.
#
# chat_reads already tracks where each person got to, it was just never
# displayed. Without a badge people have to remember to check the tab,
# and a room nobody remembers to check dies.
#
set -euo pipefail
cd /var/www/hinderhole

if [ ! -f chat.js ]; then
  echo "Chat is not installed."
  exit 1
fi

echo "==> checking git is clean"
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "You have uncommitted changes. Commit them first."
  git status --short
  exit 1
fi

cp chat.js /tmp/chat.js.before
cp public/player.js /tmp/player.js.before

echo "==> adding the count endpoint"
python3 - <<'PY'
import pathlib, sys
p = pathlib.Path('chat.js'); s = p.read_text()

if "'/chat/unread'" in s:
    print("    already there, skipping"); sys.exit(0)

anchor = """  // ---------------------------------------------------------------
  // Uploaded images
  // ---------------------------------------------------------------"""

new = """  // ---------------------------------------------------------------
  // How much you have missed
  // ---------------------------------------------------------------

  r.get('/chat/unread', requireAuth, loadLeague, async (req, res) => {
    try {
      const { rows } = await db.query(
        `select count(*)::int as n
           from messages m
           left join chat_reads c
                  on c.league_id = m.league_id and c.player_id = $2
          where m.league_id = $1
            and m.deleted_at is null
            and m.player_id <> $2
            and m.id > coalesce(c.last_seen, 0)`,
        [req.league.id, req.player.id]
      );
      res.json({ unread: rows[0].n });
    } catch (err) {
      res.json({ unread: 0 });
    }
  });

  // ---------------------------------------------------------------
  // Uploaded images
  // ---------------------------------------------------------------"""

if anchor not in s:
    sys.exit('Could not find the uploads section in chat.js.')

s = s.replace(anchor, new, 1)
p.write_text(s); print("    done")
PY

echo "==> showing the badge"
python3 - <<'PY'
import pathlib
p = pathlib.Path('public/player.js'); s = p.read_text()

if 'chat__badge' in s:
    print("    already there, skipping")
else:
    s += """

/* Unread count on whichever header link points at the chat. Lives here
   because player.js is on every page, so no template needs touching. */
(function () {
  'use strict';

  var link = document.querySelector('a[href="/chat"]');
  if (!link) return;

  // Pointless while you are sitting in the room reading it.
  if (location.pathname.replace(/\\/+$/, '') === '/chat') return;

  function paint(n) {
    var badge = link.querySelector('.chat__badge');
    if (!n) { if (badge) badge.remove(); return; }
    if (!badge) {
      badge = document.createElement('span');
      badge.className = 'chat__badge';
      link.appendChild(badge);
    }
    badge.textContent = n > 99 ? '99+' : String(n);
  }

  function check() {
    if (document.hidden) return;
    fetch('/chat/unread', { headers: { 'Accept': 'application/json' } })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (d) { if (d) paint(d.unread); })
      .catch(function () { /* offline, no badge, no harm */ });
  }

  check();
  setInterval(check, 60000);
  document.addEventListener('visibilitychange', function () {
    if (!document.hidden) check();
  });
}());
"""
    p.write_text(s); print("    done")
PY

echo "==> styling the badge"
if grep -q 'chat__badge' public/app.css; then
  echo "    already there, skipping"
else
cat >> public/app.css << 'CSSEOF'

/* Unread count riding on the Chat link. */
.chat__badge {
  display: inline-block;
  margin-left: .4rem;
  padding: .08rem .32rem;
  font-family: var(--util);
  font-size: .58rem;
  line-height: 1.5;
  letter-spacing: .04em;
  border-radius: 999px;
  background: var(--oxblood);
  color: var(--stock);
  vertical-align: baseline;
}

.bar__back.is-here .chat__badge {
  background: var(--field);
  color: var(--amber);
}
CSSEOF
  echo "    done"
fi

echo "==> syntax check"
if node --check chat.js && node --check public/player.js; then
  echo "    ok"
  rm -f /tmp/chat.js.before /tmp/player.js.before
else
  echo "    FAILED, restoring"
  cp /tmp/chat.js.before chat.js
  cp /tmp/player.js.before public/player.js
  exit 1
fi

echo
echo "Restart, then commit:"
echo
echo '  pm2 restart hinderhole --update-env'
echo '  git add -A && git commit -m "Unread count on the chat link" && git push'
