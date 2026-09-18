#!/usr/bin/env bash
#
# Fix: /standings 500s.
#
# Both the penalty and adjustment subqueries referenced m.league_id,
# which is not in that query's GROUP BY. The league id is already the
# query's first parameter, so use that instead.
#
# Also: the page checks in earlier installers were worthless here. An
# unauthenticated request is redirected to the login page before the
# query ever runs, so curl saw 302 and called it healthy while the page
# was broken for anyone signed in. This one runs the SQL directly.
#
set -euo pipefail
cd /var/www/hinderhole

if [ ! -f results.js ]; then echo "Not in the app directory."; exit 1; fi

DBURL=$(grep '^DATABASE_URL=' .env | cut -d= -f2-)
cp results.js /tmp/results.js.b31

echo "==> pointing the subqueries at the parameter"
python3 - <<'PY'
import pathlib, sys
p = pathlib.Path('results.js')
s = p.read_text()

before = s.count('m.league_id')
if before == 0:
    print("    nothing to change"); sys.exit(0)

# Only inside the two scalar subqueries, both of which sit in the
# standings query where $1 is already the league id.
s = s.replace('where vp.league_id = m.league_id', 'where vp.league_id = $1')
s = s.replace('where a.league_id = m.league_id', 'where a.league_id = $1')

after = s.count('m.league_id')
p.write_text(s)
print(f"    {before - after} replaced, {after} left")
PY

echo "==> syntax"
node --check results.js || { echo "    FAILED"; cp /tmp/results.js.b31 results.js; exit 1; }
echo "    ok"

echo "==> running the standings query for real"
psql "$DBURL" -v ON_ERROR_STOP=1 -q -c "
select p.id, p.name,
       coalesce(sum(v.points), 0)::int as points,
       count(distinct s.round_id)::int as rounds_played,
       coalesce((select sum(a.points) from adjustments a
                  where a.league_id = 1 and a.player_id = p.id), 0)::int
         as total_adjustment,
       coalesce((select sum(vp.unspent) from v_vote_penalties vp
                  where vp.league_id = 1 and vp.player_id = p.id), 0)::int
         as total_penalty
  from memberships m
  join players p on p.id = m.player_id
  left join submissions s on s.player_id = p.id
  left join rounds r on r.id = s.round_id
                    and r.league_id = m.league_id
                    and r.status = 'revealed'
  left join votes v on v.submission_id = s.id and r.id is not null
 where m.league_id = 1
 group by p.id, p.name
 order by points desc
 limit 3;" > /dev/null && echo "    query runs" || {
  echo "    QUERY STILL FAILS, restoring"
  cp /tmp/results.js.b31 results.js
  exit 1
}

echo "==> restarting"
pm2 restart hinderhole --update-env >/dev/null
sleep 2
echo "    done"

rm -f /tmp/results.js.b31
echo
echo "Load /standings in the browser while signed in, then:"
echo "  git add -A && git commit -m 'Fix ungrouped league_id in standings subqueries' && git push"
