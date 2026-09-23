#!/usr/bin/env bash
#
# Fix: changing a vote from one non-zero value to another is rejected.
#
# The budget check sums the points on every OTHER song by filtering the
# current one out of the list. Postgres returns bigint ids as strings,
# the code compared against a number, so the filter never matched and the
# song's own points were counted as someone else's.
#
# Change a song from 3 to 5 and the server thinks you are asking for 15.
# Setting it to 0 first works because the delete path has no budget
# check, which is the workaround people found on their own.
#
set -euo pipefail
cd /var/www/hinderhole

if [ ! -f vote.js ]; then echo "Not in the app directory."; exit 1; fi

cp vote.js /tmp/vote.js.b33

echo "==> comparing ids as strings"
python3 - <<'PY'
import pathlib, sys
p = pathlib.Path('vote.js')
s = p.read_text()

old = ".filter((v) => v.submission_id !== submissionId)"
new = ".filter((v) => String(v.submission_id) !== String(submissionId))"

if new in s:
    print("    already fixed, skipping"); sys.exit(0)
if old not in s:
    sys.exit('Could not find the filter. Paste vote.js and I will look.')

s = s.replace(old, new, 1)
p.write_text(s)
print("    done")
PY

echo "==> checking nothing else compares ids loosely"
grep -n "submission_id !==\|submission_id ===" vote.js || echo "    none left"

echo "==> syntax"
node --check vote.js || { echo "    FAILED"; cp /tmp/vote.js.b33 vote.js; exit 1; }
echo "    ok"

echo "==> proving the comparison was the problem"
node -e "
  // What pg actually hands back for a bigint column.
  const fromDb = [{ submission_id: '41', points: 7 },
                  { submission_id: '42', points: 3 }];
  const changing = 42;
  const broken = fromDb.filter(v => v.submission_id !== changing)
                       .reduce((n, v) => n + v.points, 0);
  const fixed  = fromDb.filter(v => String(v.submission_id) !== String(changing))
                       .reduce((n, v) => n + v.points, 0);
  console.log('    others, before fix:', broken, '(wrong, includes its own 3)');
  console.log('    others, after fix: ', fixed, '(correct)');
  if (broken === 10 && fixed === 7) console.log('    confirmed');
  else { console.log('    unexpected'); process.exit(1); }
"

echo "==> restarting"
pm2 restart hinderhole --update-env >/dev/null
sleep 2
echo "    done"

echo
echo "==> who is short in the live round"
DBURL=$(grep '^DATABASE_URL=' .env | cut -d= -f2-)
psql "$DBURL" -c "
select r.round_number, p.name,
       coalesce(sum(v.points), 0)::int as spent
  from rounds r
  join memberships m on m.league_id = r.league_id
  join players p on p.id = m.player_id
  left join votes v on v.round_id = r.id and v.voter_id = p.id
 where r.status = 'voting'
   and can_vote(r.id, p.id)
 group by r.round_number, p.id, p.name
having coalesce(sum(v.points), 0) < 10
 order by spent desc, p.name;"

rm -f /tmp/vote.js.b33
echo
echo "  git add -A && git commit -m 'Fix vote change rejected by bad id comparison' && git push"
