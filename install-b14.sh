#!/usr/bin/env bash
#
# Shortlists: save songs for rounds that have not opened yet.
#
# Private per player. Promoting one copies it into your submission and
# leaves it on the list, so changing your mind back is easy.
#
set -euo pipefail
cd /var/www/hinderhole

if [ ! -f stats.js ]; then
  echo "Not in the app directory, or the stats pages are missing."
  exit 1
fi

echo "==> checking git is clean"
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "You have uncommitted changes. Commit them first."
  git status --short
  exit 1
fi

for f in stats.js rounds.js views/upcoming.ejs views/round.ejs server.js; do
  cp "$f" "/tmp/$(basename $f).before"
done

echo "==> appending styles"
if grep -q 'cand__title' public/app.css; then
  echo "    already there, skipping"
else
  cat shortlist.css >> public/app.css
  rm -f shortlist.css
  echo "    done"
fi

echo "==> wiring the router"
python3 - <<'PY'
import pathlib, sys
p = pathlib.Path('server.js'); s = p.read_text()

if 'shortlistRoutes' in s:
    print("    already there, skipping"); sys.exit(0)

a = "const statsRoutes = require('./stats');"
m = "app.use(statsRoutes.router(db));"
if a not in s or m not in s:
    sys.exit('Could not find the stats router to anchor to.')

s = s.replace(a, a + "\nconst shortlistRoutes = require('./shortlist');")
s = s.replace(m, m + "\napp.use(shortlistRoutes.router(db));")
p.write_text(s); print("    done")
PY

echo "==> patching the season page"
python3 upcoming-patch.py

echo "==> patching the round page"
python3 round-patch.py

echo "==> syntax check"
ok=1
node --check server.js || ok=0
node --check stats.js || ok=0
node --check rounds.js || ok=0
node --check shortlist.js || ok=0
node -e "
  const ejs=require('ejs'), fs=require('fs');
  for (const f of ['views/upcoming.ejs','views/round.ejs']) {
    ejs.compile(fs.readFileSync(f,'utf8'), { filename: f });
  }
" || ok=0

if [ "$ok" = "1" ]; then
  echo "    ok"
  rm -f /tmp/*.before upcoming-patch.py round-patch.py
else
  echo "    FAILED, restoring"
  for f in stats.js rounds.js server.js; do cp "/tmp/$f.before" "$f"; done
  cp /tmp/upcoming.ejs.before views/upcoming.ejs
  cp /tmp/round.ejs.before views/round.ejs
  exit 1
fi

echo
echo "Run the migration, then restart:"
echo
echo '  psql "$DBURL" -v ON_ERROR_STOP=1 -f migrations/012_shortlist.sql'
echo '  pm2 restart hinderhole --update-env'
echo
echo '  git add -A && git commit -m "Shortlist songs for future rounds" && git push'
