#!/usr/bin/env bash
#
# Emails the commissioners when two people land on the same song.
#
# Detection already existed but only appeared on the round sheet, so it
# depended on somebody thinking to look. This pushes it out within five
# minutes of the second submission, while there is still time to act.
#
set -euo pipefail
cd /var/www/hinderhole

if [ ! -f scheduler.js ]; then
  echo "Not in the app directory."
  exit 1
fi

echo "==> checking git is clean"
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "You have uncommitted changes. Commit them first."
  git status --short
  exit 1
fi

cp scheduler.js /tmp/scheduler.js.before
cp views/admin-round.ejs /tmp/adminround.ejs.before

echo "==> patching the scheduler"
python3 collision-patch.py

echo "==> the round sheet now gets ids back too"
python3 - <<'PY'
import pathlib
# round_collisions gained a_id and b_id. The template reads by name, so
# nothing breaks, but flag it if the shape ever changes again.
p = pathlib.Path('views/admin-round.ejs')
s = p.read_text()
if 'c.a_player' in s:
    print("    template already reads by name, no change needed")
else:
    print("    template does not show clashes, skipping")
PY

echo "==> syntax check"
if node --check scheduler.js; then
  echo "    ok  scheduler.js"
  rm -f /tmp/scheduler.js.before /tmp/adminround.ejs.before collision-patch.py
else
  echo "    FAILED, restoring"
  cp /tmp/scheduler.js.before scheduler.js
  exit 1
fi

echo
echo "Run the migration, then restart BOTH processes:"
echo
echo '  psql "$DBURL" -v ON_ERROR_STOP=1 -f migrations/015_collision_alerts.sql'
echo '  pm2 restart hinderhole --update-env'
echo '  pm2 restart hinderhole-cron --update-env'
echo
echo "See what it would send, without sending anything:"
echo
echo '  node scheduler.js --once --dry'
echo
echo '  git add -A && git commit -m "Email admins about duplicate songs" && git push'
