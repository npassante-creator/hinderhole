#!/usr/bin/env bash
#
# Fix: /round/N/results returns 500.
#
# The b23 patch matched a line that appears in two different queries and
# replaced the first one. The season-total penalty subquery landed in the
# round results query, where p.id is not in the GROUP BY, so Postgres
# rejects it.
#
# Take it out of the round query, put it in the standings query.
#
set -euo pipefail
cd /var/www/hinderhole

if [ ! -f results.js ]; then
  echo "Not in the app directory."
  exit 1
fi

cp results.js /tmp/results.js.b25

echo "==> removing it from the round results query"
python3 - <<'PY'
import pathlib, re, sys
p = pathlib.Path('results.js')
s = p.read_text()

# Every copy of the injected subquery, wherever it landed.
pat = re.compile(
    r'\n\s*coalesce\(\(select sum\(vp\.unspent\) from v_vote_penalties vp\s*\n'
    r'\s*where vp\.league_id = \$1 and vp\.player_id = p\.id\), 0\)::int\s*\n'
    r'\s*as total_penalty,'
)
found = len(pat.findall(s))
if not found:
    print("    none found, skipping")
else:
    s = pat.sub('', s)
    p.write_text(s)
    print(f"    removed {found}")
PY

echo "==> adding it to the standings query"
python3 - <<'PY'
import pathlib, re, sys
p = pathlib.Path('results.js')
s = p.read_text()

if 'total_penalty' in s:
    print("    already there, skipping"); sys.exit(0)

# The standings query is the one that counts rounds played. Anchor on
# that so this can never land in the round query again.
anchor = 'count(distinct s.round_id)::int as rounds_played,'
if anchor not in s:
    sys.exit('Could not find the standings query.')

s = s.replace(anchor,
    'count(distinct s.round_id)::int as rounds_played,\n'
    '                coalesce((select sum(vp.unspent)\n'
    '                            from v_vote_penalties vp\n'
    '                           where vp.league_id = m.league_id\n'
    '                             and vp.player_id = p.id), 0)::int as total_penalty,',
    1)
p.write_text(s)
print("    done")
PY

echo "==> syntax check"
if node --check results.js; then
  echo "    ok"
else
  echo "    FAILED, restoring"
  cp /tmp/results.js.b25 results.js
  exit 1
fi

echo "==> restarting"
pm2 restart hinderhole --update-env >/dev/null
sleep 2

echo "==> checking both pages actually load"
fail=0
for path in /round/1/results /standings; do
  code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:3000$path" \
    -H 'Accept: text/html')
  # Unauthenticated, so a redirect to the login page is the healthy answer.
  case "$code" in
    200|302) echo "    $path -> $code ok" ;;
    *)       echo "    $path -> $code PROBLEM"; fail=1 ;;
  esac
done

if [ "$fail" = "1" ]; then
  echo
  echo "Still broken. Restoring and stopping."
  cp /tmp/results.js.b25 results.js
  pm2 restart hinderhole --update-env >/dev/null
  exit 1
fi

rm -f /tmp/results.js.b25

echo
echo "Load /round/1/results in the browser to confirm, then:"
echo
echo "  git add -A && git commit -m 'Fix misplaced penalty subquery' && git push"
