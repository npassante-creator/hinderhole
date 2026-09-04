#!/usr/bin/env bash
#
# Blocks a second person from submitting a song already picked this round.
#
# Exact matches only, and only on the player-facing paths. The
# commissioner can still enter a song on someone's behalf, which is the
# escape hatch if the block ever gets it wrong.
#
set -euo pipefail
cd /var/www/hinderhole

if [ ! -f rounds.js ]; then
  echo "Not in the app directory."
  exit 1
fi

echo "==> checking git is clean"
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "You have uncommitted changes. Commit them first."
  git status --short
  exit 1
fi

for f in rounds.js shortlist.js upload.js; do
  cp "$f" "/tmp/$f.before"
done

echo "==> wiring the check into the submit paths"
python3 block-patch.py

echo "==> syntax check"
ok=1
for f in rounds.js shortlist.js upload.js dupecheck.js; do
  node --check "$f" || ok=0
done

if [ "$ok" = "1" ]; then
  echo "    ok"
  rm -f /tmp/rounds.js.before /tmp/shortlist.js.before /tmp/upload.js.before
  rm -f block-patch.py
else
  echo "    FAILED, restoring"
  for f in rounds.js shortlist.js upload.js; do cp "/tmp/$f.before" "$f"; done
  exit 1
fi

echo
echo "No migration. Restart:"
echo
echo '  pm2 restart hinderhole --update-env'
echo
echo "Then try submitting a song someone else already has. You should be"
echo "turned away without being told who has it."
echo
echo '  git add -A && git commit -m "Block duplicate songs within a round" && git push'
