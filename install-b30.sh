#!/usr/bin/env bash
#
# Commissioner point adjustments.
#
# Recorded as their own line rather than by editing votes, so the results
# page can show its working. Every adjustment needs a reason and is shown
# to the whole league.
#
set -euo pipefail
cd /var/www/hinderhole

if [ ! -f admin.js ]; then echo "Not in the app directory."; exit 1; fi

echo "==> checking git is clean"
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Commit your changes first."; git status --short; exit 1
fi

for f in admin.js results.js views/admin-round.ejs views/results.ejs; do
  cp "$f" "/tmp/$(basename $f).b30"
done

echo "==> migration"
DBURL=$(grep '^DATABASE_URL=' .env | cut -d= -f2-)
psql "$DBURL" -v ON_ERROR_STOP=1 -q -f migrations/017_adjustments.sql
echo "    done"

echo "==> server"
python3 adj-patch.py

echo "==> views"
python3 adj-views.py

echo "==> styling"
if grep -q 'result__adjust' public/app.css; then
  echo "    already there, skipping"
else
cat >> public/app.css << 'CSSEOF'

/* Commissioner adjustments, shown with their reason. */
.result__adjust {
  margin: 0 0 .4rem;
  font-family: var(--util);
  font-size: .66rem;
  letter-spacing: .06em;
  text-transform: uppercase;
  color: var(--oxblood);
}
CSSEOF
  echo "    done"
fi

echo "==> checks"
ok=1
node --check admin.js || ok=0
node --check results.js || ok=0
node -e "
  const ejs=require('ejs'), fs=require('fs');
  ['views/admin-round.ejs','views/results.ejs']
    .forEach(f => ejs.compile(fs.readFileSync(f,'utf8'), { filename: f }));
" || ok=0

if [ "$ok" != "1" ]; then
  echo "    FAILED, restoring"
  for f in admin.js results.js; do cp "/tmp/$f.b30" "$f"; done
  cp /tmp/admin-round.ejs.b30 views/admin-round.ejs
  cp /tmp/results.ejs.b30 views/results.ejs
  exit 1
fi
echo "    ok"

echo "==> restarting"
pm2 restart hinderhole --update-env >/dev/null
sleep 2
fail=0
for path in /admin/round/2 /round/1/results /standings; do
  code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:3000$path")
  case "$code" in
    200|302) echo "    $path -> $code ok" ;;
    *) echo "    $path -> $code PROBLEM"; fail=1 ;;
  esac
done

if [ "$fail" = "1" ]; then
  echo "Restoring."
  for f in admin.js results.js; do cp "/tmp/$f.b30" "$f"; done
  cp /tmp/admin-round.ejs.b30 views/admin-round.ejs
  cp /tmp/results.ejs.b30 views/results.ejs
  pm2 restart hinderhole --update-env >/dev/null
  exit 1
fi

rm -f /tmp/*.b30 adj-patch.py adj-views.py
echo
echo "  git add -A && git commit -m 'Commissioner point adjustments' && git push"
