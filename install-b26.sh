#!/usr/bin/env bash
#
# Fix: /round/N/results still 500s.
#
# Two separate faults from the b23 patch:
#
#   1. penaltyBy is declared after the loop that uses it, so const's
#      temporal dead zone throws a ReferenceError.
#   2. The songs query never selected player_id, so the penalty lookup
#      would have matched nothing even once the order was fixed.
#
set -euo pipefail
cd /var/www/hinderhole

if [ ! -f results.js ]; then
  echo "Not in the app directory."
  exit 1
fi

cp results.js /tmp/results.js.b26

echo "==> selecting player_id in the songs query"
python3 - <<'PY'
import pathlib, sys
p = pathlib.Path('results.js')
s = p.read_text()

anchor = """                s.external_id, s.thumbnail_url, s.note, s.is_late,
                p.name as submitter,"""
if 's.player_id,' in s:
    print("    already there, skipping")
elif anchor in s:
    s = s.replace(anchor,
        """                s.external_id, s.thumbnail_url, s.note, s.is_late,
                s.player_id,
                p.name as submitter,""", 1)
    p.write_text(s)
    print("    done")
else:
    sys.exit('Could not find the songs select list.')
PY

echo "==> moving the penalty lookup above the loop that uses it"
python3 - <<'PY'
import pathlib, re, sys
p = pathlib.Path('results.js')
s = p.read_text()

block_pat = re.compile(
    r'\n[ \t]*// Points left unspent come off that player\'s own score\.\n'
    r'[ \t]*const \{ rows: penaltyRows \} = await db\.query\(\n'
    r'.*?\n'
    r'[ \t]*\);\n'
    r'[ \t]*const penaltyBy = new Map\(\n'
    r'.*?\n'
    r'[ \t]*\);\n',
    re.S)

m = block_pat.search(s)
if not m:
    if 'penaltyBy' not in s:
        sys.exit('penaltyBy block not found at all.')
    print("    block not matched; leaving as is")
    sys.exit(0)

block = m.group(0)
s = s[:m.start()] + '\n' + s[m.end():]

# Put it directly before the loop that reads it.
target = re.search(r'\n([ \t]*)// Apply penalties before ranking', s)
if not target:
    sys.exit('Could not find the apply-penalties loop.')

s = s[:target.start()] + '\n' + block.strip('\n') + '\n' + s[target.start():]
p.write_text(s)
print("    done")
PY

echo "==> syntax check"
node --check results.js || { echo "    FAILED"; cp /tmp/results.js.b26 results.js; exit 1; }
echo "    ok"

echo "==> order check"
python3 - <<'PY'
import pathlib, sys
s = pathlib.Path('results.js').read_text()
decl = s.find('const penaltyBy')
use  = s.find('penaltyBy.get')
if decl == -1 or use == -1:
    sys.exit('    could not verify order')
if decl < use:
    print(f"    ok, declared at {decl} before use at {use}")
else:
    sys.exit(f'    STILL WRONG: used at {use} before declared at {decl}')
PY

echo "==> restarting"
pm2 restart hinderhole --update-env >/dev/null
sleep 2

echo "==> hitting the pages"
fail=0
for path in /round/1/results /standings /; do
  code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:3000$path")
  case "$code" in
    200|302) echo "    $path -> $code ok" ;;
    *)       echo "    $path -> $code PROBLEM"; fail=1 ;;
  esac
done

if [ "$fail" = "1" ]; then
  echo
  echo "Still failing. Restoring and stopping."
  cp /tmp/results.js.b26 results.js
  pm2 restart hinderhole --update-env >/dev/null
  echo "Paste this:"
  echo "  pm2 logs hinderhole --lines 30 --nostream 2>&1 | grep -A4 '\[error\]' | head"
  exit 1
fi

rm -f /tmp/results.js.b26
echo
echo "  git add -A && git commit -m 'Fix penalty lookup order and missing player_id' && git push"
