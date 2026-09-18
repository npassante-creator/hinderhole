#!/usr/bin/env bash
#
# Hide song titles on the commissioner round sheet until asked for.
#
# The commissioner is also a player. Opening the round sheet to grant an
# extension should not mean seeing what everyone picked.
#
# Done server side, not with a CSS toggle. Collapsing it in the browser
# would still put every title in the page source, which is not hiding
# anything, it just looks like it.
#
# Nothing is hidden once a round is revealed, since everyone can see the
# songs by then anyway.
#
set -euo pipefail
cd /var/www/hinderhole

if [ ! -f admin.js ]; then echo "Not in the app directory."; exit 1; fi

echo "==> checking git is clean"
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Commit your changes first."; git status --short; exit 1
fi

cp admin.js /tmp/admin.js.b32
cp views/admin-round.ejs /tmp/adminround.ejs.b32

echo "==> leaving the titles out of the query unless asked"
python3 - <<'PY'
import pathlib, sys
p = pathlib.Path('admin.js')
s = p.read_text()

if 'showSongs' in s:
    print("    already there, skipping"); sys.exit(0)

old = """        const { rows: people } = await db.query("""
if old not in s:
    sys.exit('Could not find the people query.')

s = s.replace(old, """        // The commissioner is a player too. Titles are left out of the
        // query entirely unless they ask, rather than fetched and hidden.
        const showSongs = req.query.songs === '1' ||
                          req.round.status === 'revealed';

        const { rows: people } = await db.query(""", 1)

# Blank the two columns when not asked for.
s = s.replace(
    "                  s.id as submission_id, s.title, s.artist, s.source,",
    "                  s.id as submission_id,\n"
    "                  case when $3 then s.title  end as title,\n"
    "                  case when $3 then s.artist end as artist,\n"
    "                  s.source,", 1)

s = s.replace(
    "          [req.round.id, req.league.id]\n        );",
    "          [req.round.id, req.league.id, showSongs]\n        );", 1)

# Same for the duplicate panel, which names songs.
s = s.replace(
    """        const { rows: clashes } = await db.query(
          'select * from round_collisions($1)', [req.round.id]
        );""",
    """        const { rows: clashes } = showSongs
          ? (await db.query('select * from round_collisions($1)',
              [req.round.id])).rows
          : (await db.query(
              'select count(*)::int as n from round_collisions($1)',
              [req.round.id])).rows.map((r) => ({ hidden: true, n: r.n }))
              .filter((r) => r.n > 0);""", 1)

s = s.replace("          adjustments,", "          adjustments,\n          showSongs,", 1)
p.write_text(s)
print("    done")
PY

echo "==> the reveal button on the sheet"
python3 - <<'PY'
import pathlib, re, sys
p = pathlib.Path('views/admin-round.ejs')
s = p.read_text()

if 'songs=1' in s:
    print("    already there, skipping"); sys.exit(0)

anchor = '    <h2 class="rack__heading">Who is in</h2>'
if anchor not in s:
    sys.exit('Could not find the who-is-in heading.')

s = s.replace(anchor, """    <h2 class="rack__heading">Who is in</h2>

    <% if (!showSongs) { %>
      <p class="moves">
        <a class="chip" href="/admin/round/<%= round.id %>?songs=1">Show the songs</a>
      </p>
      <p class="fineprint">
        Hidden so you can run the round without seeing what everyone
        picked. Everything else here works without them.
      </p>
    <% } else if (round.status !== 'revealed') { %>
      <p class="moves">
        <a class="chip chip--on" href="/admin/round/<%= round.id %>">Hide the songs again</a>
      </p>
    <% } %>
""", 1)

# The song cell.
s = re.sub(
    r'<% if \(p\.submission_id\) \{ %>\s*\n\s*<span class="grid__song"><%= p\.title %></span>',
    '<% if (p.submission_id && !showSongs) { %>\n'
    '                <span class="grid__sub">in</span>\n'
    '              <% } else if (p.submission_id) { %>\n'
    '                <span class="grid__song"><%= p.title %></span>',
    s, count=1)

# The duplicate panel, when titles are hidden.
s = s.replace(
    '          <% clashes.forEach(function (c) { %>',
    '          <% clashes.forEach(function (c) { %>\n'
    '            <% if (c.hidden) { %>\n'
    '              <li><%= c.n %> possible duplicate<%= c.n === 1 ? "" : "s" %> '
    'in this round. Show the songs to see them.</li>\n'
    '            <% } else { %>', 1)

s = s.replace(
    '''              <span class="echo__how"><%= c.how %></span>
            </li>
          <% }) %>''',
    '''              <span class="echo__how"><%= c.how %></span>
            </li>
            <% } %>
          <% }) %>''', 1)

p.write_text(s)
print("    done")
PY

echo "==> checks"
ok=1
node --check admin.js || ok=0
node -e "
  const ejs=require('ejs'), fs=require('fs');
  ejs.compile(fs.readFileSync('views/admin-round.ejs','utf8'),
              { filename: 'views/admin-round.ejs' });
" || ok=0

python3 - <<'PY'
import pathlib, re, sys
s = pathlib.Path('views/admin-round.ejs').read_text()
plain = re.sub(r'<%.*?%>', '', s, flags=re.S)
for tag in ['td','tr','li','table','ul']:
    o = len(re.findall(rf'<{tag}\b', plain)); c = len(re.findall(rf'</{tag}>', plain))
    if o != c: sys.exit(f'    {tag} unbalanced: {o}/{c}')
print('    tags balanced')
PY

if [ "$ok" != "1" ]; then
  echo "    FAILED, restoring"
  cp /tmp/admin.js.b32 admin.js
  cp /tmp/adminround.ejs.b32 views/admin-round.ejs
  exit 1
fi
echo "    ok"

echo "==> proving the titles really are absent"
DBURL=$(grep '^DATABASE_URL=' .env | cut -d= -f2-)
psql "$DBURL" -v ON_ERROR_STOP=1 -q -c "
select p.name,
       case when false then s.title end as title
  from memberships m
  join players p on p.id = m.player_id
  left join submissions s on s.player_id = p.id and s.round_id = 2
 where m.league_id = 1 limit 3;" > /dev/null \
  && echo "    query shape valid" || {
    echo "    QUERY FAILED, restoring"
    cp /tmp/admin.js.b32 admin.js
    cp /tmp/adminround.ejs.b32 views/admin-round.ejs
    exit 1; }

echo "==> restarting"
pm2 restart hinderhole --update-env >/dev/null
sleep 2
echo "    done"

rm -f /tmp/admin.js.b32 /tmp/adminround.ejs.b32
echo
echo "Open /admin/round/3 signed in. Songs should read 'in' with a"
echo "'Show the songs' button. Then:"
echo "  git add -A && git commit -m 'Hide songs on the round sheet until asked' && git push"
