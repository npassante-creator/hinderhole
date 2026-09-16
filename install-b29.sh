#!/usr/bin/env bash
#
# Show vote progress on the commissioner round sheet.
#
# The sheet already says who has submitted. It says nothing about who has
# voted, which is the thing worth chasing once a round is live, and now
# doubly so with unspent points costing people.
#
set -euo pipefail
cd /var/www/hinderhole

if [ ! -f admin.js ]; then
  echo "Not in the app directory."
  exit 1
fi

cp admin.js /tmp/admin.js.b29
cp views/admin-round.ejs /tmp/adminround.ejs.b29

echo "==> adding spend and eligibility to the query"
python3 - <<'PY'
import pathlib, re, sys
p = pathlib.Path('admin.js')
s = p.read_text()

if 'as spent' in s:
    print("    already there, skipping"); sys.exit(0)

anchor = "                  (w.player_id is not null) as has_waiver"
if anchor not in s:
    sys.exit('Could not find the people query.')

s = s.replace(anchor,
    """                  (w.player_id is not null) as has_waiver,
                  can_vote($1, p.id) as eligible,
                  coalesce((select sum(v.points) from votes v
                             where v.round_id = $1 and v.voter_id = p.id), 0)::int
                    as spent""", 1)
p.write_text(s)
print("    done")
PY

echo "==> passing the budget and a tally to the view"
python3 - <<'PY'
import pathlib, sys
p = pathlib.Path('admin.js')
s = p.read_text()

if 'notVoted' in s:
    print("    already there, skipping"); sys.exit(0)

anchor = """          missing: people.filter((p) => !p.submission_id).length,"""
if anchor not in s:
    sys.exit('Could not find the missing count.')

s = s.replace(anchor,
    """          missing: people.filter((p) => !p.submission_id).length,
          budget: req.league.points_per_voter,
          // Eligible voters who have not spent everything. The ones worth
          // a nudge before the deadline.
          notVoted: people.filter((x) => x.eligible && x.spent === 0).length,
          partial: people.filter(
            (x) => x.eligible && x.spent > 0 &&
                   x.spent < req.league.points_per_voter).length,""", 1)
p.write_text(s)
print("    done")
PY

echo "==> showing it on the sheet"
python3 - <<'PY'
import pathlib, re, sys
p = pathlib.Path('views/admin-round.ejs')
s = p.read_text()

if 'grid__spent' in s:
    print("    already there, skipping"); sys.exit(0)

# A line in the facts plate.
facts = re.search(r'([ \t]*)<div class="facts__row"><dt>Still missing</dt>.*?</div>', s, re.S)
if facts:
    indent = facts.group(1)
    s = s[:facts.end()] + (
        f'\n{indent}<div class="facts__row">'
        f'<dt>Not voted</dt>'
        f'<dd><%= notVoted %> none, <%= partial %> partway</dd></div>'
    ) + s[facts.end():]

# A column in the table.
s = s.replace(
    '<tr><th>Player</th><th>Song</th><th>Extension</th></tr>',
    '<tr><th>Player</th><th>Song</th><th>Voted</th><th>Extension</th></tr>', 1)

old_cell = re.search(
    r'([ \t]*)<td>\s*\n\s*<form method="post" action="/admin/round/<%= round\.id %>/waiver">',
    s)
if not old_cell:
    sys.exit('Could not find the waiver cell.')

indent = old_cell.group(1)
vote_cell = (
    f'{indent}<td class="grid__spent">\n'
    f'{indent}  <% if (!p.eligible) {{ %>\n'
    f'{indent}    <span class="grid__sub">not eligible</span>\n'
    f'{indent}  <% }} else if (p.spent >= budget) {{ %>\n'
    f'{indent}    <span class="grid__done"><%= p.spent %>/<%= budget %></span>\n'
    f'{indent}  <% }} else {{ %>\n'
    f'{indent}    <span class="grid__owed"><%= p.spent %>/<%= budget %></span>\n'
    f'{indent}  <% }} %>\n'
    f'{indent}</td>\n'
)

s = s[:old_cell.start()] + vote_cell + s[old_cell.start():]
p.write_text(s)
print("    done")
PY

echo "==> styling"
if grep -q 'grid__owed' public/app.css; then
  echo "    already there, skipping"
else
cat >> public/app.css << 'CSSEOF'

/* Vote progress on the commissioner round sheet. */
.grid__spent { white-space: nowrap; }

.grid__done {
  font-family: var(--util);
  font-size: .8rem;
  color: #4f9c6c;
}

.grid__owed {
  font-family: var(--util);
  font-size: .8rem;
  color: var(--amber);
}
CSSEOF
  echo "    done"
fi

echo "==> checks"
node --check admin.js || { echo "    FAILED"; cp /tmp/admin.js.b29 admin.js; exit 1; }
node -e "
  const ejs=require('ejs'), fs=require('fs');
  ejs.compile(fs.readFileSync('views/admin-round.ejs','utf8'),
              { filename: 'views/admin-round.ejs' });
" || { echo "    FAILED"; cp /tmp/adminround.ejs.b29 views/admin-round.ejs; exit 1; }

python3 - <<'PY'
import pathlib, re, sys
s = pathlib.Path('views/admin-round.ejs').read_text()
plain = re.sub(r'<%.*?%>', '', s, flags=re.S)
for tag in ['td', 'tr', 'table']:
    o = len(re.findall(rf'<{tag}\b', plain)); c = len(re.findall(rf'</{tag}>', plain))
    if o != c: sys.exit(f'    {tag} unbalanced: {o} open {c} close')
print('    table tags balanced')
PY

echo "==> restarting"
pm2 restart hinderhole --update-env >/dev/null
sleep 2
code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:3000/admin/round/2")
case "$code" in
  200|302) echo "    /admin/round/2 -> $code ok" ;;
  *) echo "    -> $code PROBLEM, restoring"
     cp /tmp/admin.js.b29 admin.js
     cp /tmp/adminround.ejs.b29 views/admin-round.ejs
     pm2 restart hinderhole --update-env >/dev/null
     exit 1 ;;
esac

rm -f /tmp/admin.js.b29 /tmp/adminround.ejs.b29
echo
echo "  git add -A && git commit -m 'Show vote progress on the round sheet' && git push"
