#!/usr/bin/env bash
set -euo pipefail
APP=/var/www/hinderhole
cd "$APP"

# ── guard ─────────────────────────────────────────────────────────────────────
echo "==> checking git is clean"
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "    ABORT: uncommitted changes"; exit 1
fi

# ── backups ───────────────────────────────────────────────────────────────────
echo "==> backing up files"
cp admin.js           /tmp/admin.js.b36.bak
cp views/admin-round.ejs /tmp/admin-round.ejs.b36.bak
echo "    done"

# ── step 1: update round_collisions to return submitted_at ───────────────────
echo "==> updating round_collisions function"
DB_URL=$(grep DATABASE_URL .env | cut -d= -f2-)
psql "$DB_URL" <<'SQL'
create or replace function round_collisions(p_round_id bigint)
returns table(
  a_id          bigint,
  a_player      text,
  a_title       text,
  a_submitted_at timestamptz,
  b_id          bigint,
  b_player      text,
  b_title       text,
  b_submitted_at timestamptz,
  how           text
)
language sql stable as $$
  select a.id, pa.name, a.title, a.submitted_at,
         b.id, pb.name, b.title, b.submitted_at,
         case
           when a.external_id = b.external_id then 'the same link'
           when a.song_key = b.song_key       then 'the same song'
           else 'something very close'
         end
    from submissions a
    join submissions b
      on b.round_id = a.round_id and b.id > a.id
    join players pa on pa.id = a.player_id
    join players pb on pb.id = b.player_id
   where a.round_id = p_round_id
     and (
       a.external_id = b.external_id
       or (a.song_key is not null and a.song_key = b.song_key)
       or (a.song_key is not null and b.song_key is not null
           and similarity(a.song_key, b.song_key) > 0.62)
     );
$$;
SQL
echo "    done"

# ── step 2: admin.js — add showDupes flag ────────────────────────────────────
echo "==> admin.js: showDupes flag"
python3 - <<'PY'
path = 'admin.js'
txt = open(path).read()

old = (
    "        const showSongs = req.query.songs === '1' ||\n"
    "                          req.round.status === 'revealed';"
)
new = (
    "        const showSongs = req.query.songs === '1' ||\n"
    "                          req.round.status === 'revealed';\n"
    "        const showDupes = showSongs || req.query.dupes === '1';"
)

if old not in txt:
    print('ERROR: showSongs anchor not found'); exit(1)
open(path, 'w').write(txt.replace(old, new))
print('    done')
PY

# ── step 3: admin.js — fix clashes query (also fixes latent undefined bug) ───
echo "==> admin.js: clashes query"
python3 - <<'PY'
path = 'admin.js'
txt = open(path).read()

old = (
    "        // Two people on the same song. Players must not be told during a\n"
    "        // live round, so this is the commissioner's problem to spot.\n"
    "        const { rows: clashes } = showSongs\n"
    "          ? (await db.query('select * from round_collisions($1)',\n"
    "              [req.round.id])).rows\n"
    "          : (await db.query(\n"
    "              'select count(*)::int as n from round_collisions($1)',\n"
    "              [req.round.id])).rows.map((r) => ({ hidden: true, n: r.n }))\n"
    "              .filter((r) => r.n > 0);"
)
new = (
    "        // Two people on the same song. Players must not be told during a\n"
    "        // live round, so this is the commissioner's problem to spot.\n"
    "        let clashes;\n"
    "        if (showDupes) {\n"
    "          const { rows } = await db.query(\n"
    "            'select * from round_collisions($1)', [req.round.id]);\n"
    "          clashes = rows.map((c) => ({\n"
    "            ...c,\n"
    "            a_submitted_at_fmt: fmt(c.a_submitted_at),\n"
    "            b_submitted_at_fmt: fmt(c.b_submitted_at),\n"
    "            a_first: !c.b_submitted_at ||\n"
    "              (c.a_submitted_at && c.a_submitted_at <= c.b_submitted_at),\n"
    "          }));\n"
    "        } else {\n"
    "          const { rows } = await db.query(\n"
    "            'select count(*)::int as n from round_collisions($1)', [req.round.id]);\n"
    "          clashes = rows\n"
    "            .map((r) => ({ hidden: true, n: r.n }))\n"
    "            .filter((r) => r.n > 0);\n"
    "        }"
)

if old not in txt:
    print('ERROR: clashes anchor not found'); exit(1)
open(path, 'w').write(txt.replace(old, new))
print('    done')
PY

# ── step 4: admin.js — pass showDupes to render ───────────────────────────────
echo "==> admin.js: render showDupes"
python3 - <<'PY'
path = 'admin.js'
txt = open(path).read()

old = '          showSongs,\n          round: req.round,'
new = '          showSongs,\n          showDupes,\n          round: req.round,'

if old not in txt:
    print('ERROR: render anchor not found'); exit(1)
open(path, 'w').write(txt.replace(old, new))
print('    done')
PY

# ── step 5: admin-round.ejs — update clashes block ───────────────────────────
echo "==> admin-round.ejs: clashes block"
python3 - <<'PY'
path = 'views/admin-round.ejs'
txt = open(path).read()

old = (
    '    <% if (typeof clashes !== \'undefined\' && clashes.length) { %>\n'
    '      <h2 class="rack__heading">Possible duplicates</h2>\n'
    '      <div class="echo">\n'
    '        <span class="echo__label">Two people, one song</span>\n'
    '        <ul class="echo__list">\n'
    '          <% clashes.forEach(function (c) { %>\n'
    '            <% if (c.hidden) { %>\n'
    '              <li><%= c.n %> possible duplicate<%= c.n === 1 ? "" : "s" %> in this round. Show the songs to see them.</li>\n'
    '            <% } else { %>\n'
    '            <li>\n'
    '              <strong><%= c.a_player %></strong> (<%= c.a_title %>)\n'
    '              and <strong><%= c.b_player %></strong> (<%= c.b_title %>)\n'
    '              <span class="echo__how"><%= c.how %></span>\n'
    '            </li>\n'
    '            <% } %>\n'
    '          <% }) %>\n'
    '        </ul>\n'
    '        Nobody else can see this. Matching is fuzzy, so check before you\n'
    '        say anything.\n'
    '      </div>\n'
    '    <% } %>'
)
new = (
    '    <% if (typeof clashes !== \'undefined\' && clashes.length) { %>\n'
    '      <h2 class="rack__heading">Possible duplicates</h2>\n'
    '      <div class="echo">\n'
    '        <span class="echo__label">Two people, one song</span>\n'
    '        <ul class="echo__list">\n'
    '          <% clashes.forEach(function (c) { %>\n'
    '            <% if (c.hidden) { %>\n'
    '              <li>\n'
    '                <%= c.n %> possible duplicate<%= c.n === 1 ? "" : "s" %> in this round.\n'
    '                <a class="echo__reveal" href="/admin/round/<%= round.id %>?dupes=1">Show who</a>\n'
    '              </li>\n'
    '            <% } else { %>\n'
    '            <li class="echo__clash">\n'
    '              <span class="echo__how"><%= c.how %></span>\n'
    '              <span class="echo__pair">\n'
    '                <span class="echo__side <% if (c.a_first) { %>echo__side--first<% } else { %>echo__side--second<% } %>">\n'
    '                  <strong><%= c.a_player %></strong>\n'
    '                  <span class="echo__song"><%= c.a_title %></span>\n'
    '                  <span class="echo__ts"><%= c.a_submitted_at_fmt %> &middot; <%= c.a_first ? "submitted first" : "needs to change" %></span>\n'
    '                </span>\n'
    '                <span class="echo__side <% if (!c.a_first) { %>echo__side--first<% } else { %>echo__side--second<% } %>">\n'
    '                  <strong><%= c.b_player %></strong>\n'
    '                  <span class="echo__song"><%= c.b_title %></span>\n'
    '                  <span class="echo__ts"><%= c.b_submitted_at_fmt %> &middot; <% if (!c.a_first) { %>submitted first<% } else { %>needs to change<% } %></span>\n'
    '                </span>\n'
    '              </span>\n'
    '            </li>\n'
    '            <% } %>\n'
    '          <% }) %>\n'
    '        </ul>\n'
    '        Nobody else can see this. Matching is fuzzy, so check before you say anything.\n'
    '      </div>\n'
    '    <% } %>'
)

if old not in txt:
    print('ERROR: clashes block anchor not found'); exit(1)
open(path, 'w').write(txt.replace(old, new))
print('    done')
PY

# ── step 6: CSS for new elements ─────────────────────────────────────────────
echo "==> app.css: clash reveal styles"
python3 - <<'PY'
path = 'public/app.css'
txt = open(path).read()

addition = '''
/* ---------------------------------------------------------------
   Duplicate clash reveal
   --------------------------------------------------------------- */

.echo__reveal {
  color: var(--amber);
  font-family: var(--util);
  font-size: .65rem;
  letter-spacing: .08em;
  text-transform: uppercase;
  text-decoration: none;
  border-bottom: 1px solid currentColor;
}

.echo__reveal:hover { opacity: .75; }

.echo__clash {
  display: flex;
  flex-direction: column;
  gap: .5rem;
  padding: .5rem 0;
}

.echo__pair {
  display: flex;
  flex-direction: column;
  gap: .35rem;
}

.echo__side {
  display: flex;
  flex-direction: column;
  gap: .1rem;
  padding: .45rem .65rem;
  border-left: 3px solid transparent;
  border-radius: 2px;
  background: rgba(240, 232, 216, .04);
}

.echo__side--first {
  border-left-color: #5a8a5a;
}

.echo__side--second {
  border-left-color: var(--oxblood);
}

.echo__song {
  font-size: .8rem;
  color: var(--stock);
}

.echo__ts {
  font-family: var(--util);
  font-size: .6rem;
  letter-spacing: .07em;
  text-transform: uppercase;
  color: var(--steel);
}
'''

open(path, 'a').write(addition)
print('    done')
PY

# ── step 7: syntax check ──────────────────────────────────────────────────────
echo "==> syntax check"
FAIL=0
node --check admin.js 2>&1 || FAIL=1
if [ $FAIL -ne 0 ]; then
  echo "    FAIL — restoring backups"
  cp /tmp/admin.js.b36.bak admin.js
  cp /tmp/admin-round.ejs.b36.bak views/admin-round.ejs
  exit 1
fi
echo "    ok"

# ── step 8: restart ───────────────────────────────────────────────────────────
echo "==> restarting"
pm2 restart hinderhole --update-env
echo "    done"

echo ""
echo "==> verify: open /admin/round/<id> for a round with submissions"
echo "    - no songs shown: should say 'X possible duplicate(s)' with 'Show who' link"
echo "    - click Show who: should reveal player names, songs, timestamps, first/second labels"
echo ""
echo "==> git add -A && git commit -m 'Show duplicate submitters on demand with timestamps' && git push"
