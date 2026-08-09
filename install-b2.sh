#!/usr/bin/env bash
#
# Adds three read-only pages: my picks, season stats, and the season
# preview. No migration, no new tables. Everything they show is already
# in the votes table.
#
set -euo pipefail
cd /var/www/hinderhole

if [ ! -f server.js ]; then
  echo "Not in the app directory. cd /var/www/hinderhole first."
  exit 1
fi

echo "==> checking git is clean"
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "You have uncommitted changes. Commit them first so this script's"
  echo "edits are easy to review on their own."
  git status --short
  exit 1
fi

echo "==> wiring the router"
python3 - <<'PY'
import pathlib, sys
p = pathlib.Path('server.js')
s = p.read_text()

if 'statsRoutes' in s:
    print("    already wired, skipping")
    sys.exit(0)

anchors = ["const categoryRoutes = require('./categories');",
           "const exportRoutes = require('./export');",
           "const resultRoutes = require('./results');"]
for a in anchors:
    if a in s:
        s = s.replace(a, a + "\nconst statsRoutes = require('./stats');")
        break
else:
    sys.exit('Could not find a router import to anchor to.')

mounts = ["app.use(categoryRoutes.router(db));",
          "app.use(exportRoutes.router(db));",
          "app.use(resultRoutes.router(db));"]
for m in mounts:
    if m in s:
        s = s.replace(m, m + "\napp.use(statsRoutes.router(db));")
        break
else:
    sys.exit('Could not find a router mount to anchor to.')

p.write_text(s)
print("    done")
PY

echo "==> adding header links"
python3 - <<'PY'
import pathlib
p = pathlib.Path('views/home.ejs')
s = p.read_text()
added = []

if 'href="/me"' not in s:
    s = s.replace('<a class="bar__back" href="/standings">Standings</a>',
                  '<a class="bar__back" href="/me">My picks</a>\n'
                  '    <a class="bar__back" href="/standings">Standings</a>', 1)
    added.append('my picks')

if 'href="/stats"' not in s:
    s = s.replace('<a class="bar__back" href="/categories">Categories</a>',
                  '<a class="bar__back" href="/categories">Categories</a>\n'
                  '    <a class="bar__back" href="/stats">Stats</a>', 1)
    added.append('stats')

p.write_text(s)
print("    " + (", ".join(added) if added else "already there, skipping"))
PY

echo "==> linking the season preview from standings"
python3 - <<'PY'
import pathlib
p = pathlib.Path('views/standings.ejs')
s = p.read_text()
if 'href="/upcoming"' not in s:
    s = s.replace('<h2 class="rack__heading">Rounds</h2>',
                  '<p class="moves">\n'
                  '      <a class="chip" href="/upcoming">See the whole season</a>\n'
                  '    </p>\n\n'
                  '    <h2 class="rack__heading">Rounds</h2>', 1)
    p.write_text(s)
    print("    done")
else:
    print("    already there, skipping")
PY

echo "==> syntax check"
for f in server.js stats.js; do
  node --check "$f" && echo "    ok  $f"
done

echo
echo "No migration this time. Just restart:"
echo
echo '  pm2 restart hinderhole --update-env'
echo
echo "Then review and commit:"
echo
echo '  git diff --stat'
echo '  git add -A && git commit -m "My picks, season stats, season preview" && git push'
