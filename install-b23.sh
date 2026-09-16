#!/usr/bin/env bash
#
# Two rule changes:
#
#   1. Comment authors are shown at the reveal. Still hidden during
#      voting, since the results query is the only place names appear.
#   2. Points you were eligible to spend and did not are subtracted from
#      your own score for that round.
#
set -euo pipefail
cd /var/www/hinderhole

if [ ! -f results.js ]; then
  echo "Not in the app directory."
  exit 1
fi

echo "==> checking git is clean"
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "You have uncommitted changes. Commit them first."
  git status --short
  exit 1
fi

cp results.js /tmp/results.js.before
cp views/results.ejs /tmp/results.ejs.before
cp views/standings.ejs /tmp/standings.ejs.before

echo "==> patching the server"
python3 penalty-patch.py

echo "==> patching the templates"
python3 view-patch.py

echo "==> styling"
if grep -q 'chatter__who' public/app.css; then
  echo "    already there, skipping"
else
cat >> public/app.css << 'CSSEOF'

/* Comment authors, shown only once a round is revealed. */
.chatter__who {
  font-family: var(--util);
  font-size: .64rem;
  letter-spacing: .08em;
  text-transform: uppercase;
  color: var(--amber);
  display: block;
  margin-bottom: .15rem;
}

/* Points lost for not spending your ten. */
.result__penalty {
  margin: 0 0 .4rem;
  font-family: var(--util);
  font-size: .66rem;
  letter-spacing: .06em;
  text-transform: uppercase;
  color: var(--amber);
}

.league__penalty { color: var(--amber); }
CSSEOF
  echo "    done"
fi

echo "==> syntax check"
ok=1
node --check results.js || ok=0
node -e "
  const ejs=require('ejs'), fs=require('fs');
  ['views/results.ejs','views/standings.ejs']
    .forEach(f => ejs.compile(fs.readFileSync(f,'utf8'), { filename: f }));
" || ok=0

if [ "$ok" = "1" ]; then
  echo "    ok"
  rm -f /tmp/results.js.before /tmp/results.ejs.before /tmp/standings.ejs.before
  rm -f penalty-patch.py view-patch.py
else
  echo "    FAILED, restoring"
  cp /tmp/results.js.before results.js
  cp /tmp/results.ejs.before views/results.ejs
  cp /tmp/standings.ejs.before views/standings.ejs
  exit 1
fi

echo
echo "Run the migration:"
echo
echo '  psql "$DBURL" -v ON_ERROR_STOP=1 -f migrations/016_vote_penalty.sql'
echo
echo "Then switch the rule on from whichever round it starts. To apply it"
echo "from round 3 onward, leaving rounds 1 and 2 alone:"
echo
echo '  psql "$DBURL" -c "update leagues set vote_penalty_from_round = 3 where id = 1;"'
echo
echo "Nothing is deducted until you set that. Then:"
echo
echo '  pm2 restart hinderhole --update-env'
echo '  git add -A && git commit -m "Reveal comment authors, deduct unspent votes" && git push'
