#!/usr/bin/env bash
set -euo pipefail
APP=/var/www/hinderhole
cd "$APP"

# ── guard ─────────────────────────────────────────────────────────────────────
echo "==> checking git is clean"
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "    ABORT: uncommitted changes"; exit 1
fi

# ── backups ───────────────────────────────────────────────────────────────────
echo "==> backing up files"
cp views/admin-round.ejs /tmp/admin-round.ejs.b37.bak
cp public/app.css        /tmp/app.css.b37.bak
echo "    done"

# ── step 1: admin-round.ejs — hide player names when songs are shown ──────────
echo "==> admin-round.ejs: hide player names when showSongs"
python3 - <<'PY'
path = 'views/admin-round.ejs'
txt = open(path).read()

old = (
    '            <td>\n'
    '              <span class="grid__name"><%= p.name %></span>\n'
    '              <% if (p.is_late) { %><span class="tag tag--late">late</span><% } %>\n'
    '            </td>'
)
new = (
    '            <td>\n'
    '              <% if (showSongs) { %>\n'
    '                <details class="grid__who">\n'
    '                  <summary class="grid__who-sum">reveal</summary>\n'
    '                  <span class="grid__name"><%= p.name %></span>\n'
    '                  <% if (p.is_late) { %><span class="tag tag--late">late</span><% } %>\n'
    '                </details>\n'
    '              <% } else { %>\n'
    '                <span class="grid__name"><%= p.name %></span>\n'
    '                <% if (p.is_late) { %><span class="tag tag--late">late</span><% } %>\n'
    '              <% } %>\n'
    '            </td>'
)

if old not in txt:
    print('ERROR: player name td anchor not found'); exit(1)
open(path, 'w').write(txt.replace(old, new))
print('    done')
PY

# ── step 2: app.css — styles for reveal toggle ────────────────────────────────
echo "==> app.css: grid__who reveal styles"
python3 - <<'PY'
path = 'public/app.css'
txt = open(path).read()

addition = '''
/* ---------------------------------------------------------------
   Player name reveal (admin song view)
   --------------------------------------------------------------- */

.grid__who {
  display: inline;
}

.grid__who-sum {
  font-family: var(--util);
  font-size: .6rem;
  letter-spacing: .08em;
  text-transform: uppercase;
  color: var(--amber);
  cursor: pointer;
  list-style: none;
  border-bottom: 1px solid currentColor;
}

.grid__who-sum::-webkit-details-marker { display: none; }
.grid__who-sum::marker              { display: none; }

/* once opened, hide the summary so only the name shows */
.grid__who[open] > .grid__who-sum {
  display: none;
}
'''

open(path, 'a').write(addition)
print('    done')
PY

# ── step 3: restart ───────────────────────────────────────────────────────────
echo "==> restarting"
pm2 restart hinderhole --update-env
echo "    done"

echo ""
echo "==> verify: /admin/round/<id>?songs=1"
echo "    - player column should show 'reveal' links instead of names"
echo "    - clicking a 'reveal' link shows the player name"
echo ""
echo "==> git add -A && git commit -m 'Hide player names from admin song view until revealed' && git push"
