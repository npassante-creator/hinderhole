#!/usr/bin/env bash
#
# Better duplicate detection.
#
# Matching on the YouTube id only catches a literal repost. This adds a
# normalised song key plus trigram similarity, so a different upload,
# a live version, or a remaster of the same track gets flagged too.
#
# Players are only told about rounds that have already been revealed.
# Two people colliding in a live round is shown to the commissioner only,
# because telling a player would leak what is in the round.
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

cp rounds.js /tmp/rounds.js.before
cp admin.js /tmp/admin.js.before
cp views/round.ejs /tmp/round.ejs.before
cp views/admin-round.ejs /tmp/adminround.ejs.before

echo "==> richer warning on the round page"
python3 - <<'PY'
import pathlib, sys
p = pathlib.Path('views/round.ejs'); s = p.read_text()

if 'e.how' in s:
    print("    already there, skipping"); sys.exit(0)

old = """          <div class="echo">
            <span class="echo__label">Played before</span>
            <% echo.forEach(function (e) { %>
              Round <%= e.round_number %>, <%= e.round_title %>, submitted by <%= e.submitted_by %>.
            <% }) %>
            Still allowed, but people will notice.
          </div>"""

new = """          <div class="echo">
            <span class="echo__label">Played before</span>
            <ul class="echo__list">
              <% echo.forEach(function (e) { %>
                <li>
                  <strong><%= e.song_title %></strong>,
                  round <%= e.round_number %> (<%= e.round_title %>),
                  submitted by <%= e.submitted_by %>.
                  <span class="echo__how"><%= e.how %></span>
                </li>
              <% }) %>
            </ul>
            Still allowed, and the match is not always right. But people
            will notice.
          </div>"""

if old not in s:
    sys.exit('Could not find the echo block in round.ejs.')

s = s.replace(old, new)
p.write_text(s); print("    done")
PY

echo "==> collision check on the commissioner round sheet"
python3 - <<'PY'
import pathlib, sys
p = pathlib.Path('admin.js'); s = p.read_text()

if 'round_collisions' in s:
    print("    admin.js already there, skipping")
else:
    anchor = """        res.render('admin-round', {
          league: req.league,
          round: req.round,"""
    if anchor not in s:
        sys.exit('Could not find the admin-round render.')

    load = """        // Two people on the same song. Players must not be told during a
        // live round, so this is the commissioner's problem to spot.
        const { rows: clashes } = await db.query(
          'select * from round_collisions($1)', [req.round.id]
        );

        res.render('admin-round', {
          league: req.league,
          round: req.round,
          clashes,"""
    s = s.replace(anchor, load, 1)
    p.write_text(s); print("    admin.js done")

p = pathlib.Path('views/admin-round.ejs'); s = p.read_text()
if 'clashes' in s:
    print("    admin-round.ejs already there, skipping")
else:
    anchor = '    <h2 class="rack__heading">Who is in</h2>'
    new = """    <% if (typeof clashes !== 'undefined' && clashes.length) { %>
      <h2 class="rack__heading">Possible duplicates</h2>
      <div class="echo">
        <span class="echo__label">Two people, one song</span>
        <ul class="echo__list">
          <% clashes.forEach(function (c) { %>
            <li>
              <strong><%= c.a_player %></strong> (<%= c.a_title %>)
              and <strong><%= c.b_player %></strong> (<%= c.b_title %>)
              <span class="echo__how"><%= c.how %></span>
            </li>
          <% }) %>
        </ul>
        Nobody else can see this. Matching is fuzzy, so check before you
        say anything.
      </div>
    <% } %>

""" + anchor
    if anchor not in s:
        sys.exit('Could not find the who-is-in heading.')
    s = s.replace(anchor, new, 1)
    p.write_text(s); print("    admin-round.ejs done")
PY

echo "==> styling"
if grep -q 'echo__list' public/app.css; then
  echo "    already there, skipping"
else
cat >> public/app.css << 'CSSEOF'

.echo__list {
  list-style: none;
  margin: .4rem 0;
  padding: 0;
}

.echo__list li {
  padding: .25rem 0;
  line-height: 1.45;
}

.echo__how {
  font-family: var(--util);
  font-size: .6rem;
  letter-spacing: .1em;
  text-transform: uppercase;
  color: var(--amber);
  margin-left: .3rem;
}
CSSEOF
  echo "    done"
fi

echo "==> syntax check"
ok=1
node --check rounds.js || ok=0
node --check admin.js || ok=0
node -e "
  const ejs=require('ejs'), fs=require('fs');
  ['views/round.ejs','views/admin-round.ejs']
    .forEach(f => ejs.compile(fs.readFileSync(f,'utf8'), { filename: f }));
" || ok=0

if [ "$ok" = "1" ]; then
  echo "    ok"
  rm -f /tmp/rounds.js.before /tmp/admin.js.before
  rm -f /tmp/round.ejs.before /tmp/adminround.ejs.before
else
  echo "    FAILED, restoring"
  cp /tmp/rounds.js.before rounds.js
  cp /tmp/admin.js.before admin.js
  cp /tmp/round.ejs.before views/round.ejs
  cp /tmp/adminround.ejs.before views/admin-round.ejs
  exit 1
fi

echo
echo "Run the migration, then restart:"
echo
echo '  psql "$DBURL" -v ON_ERROR_STOP=1 -f migrations/013_fingerprint.sql'
echo '  pm2 restart hinderhole --update-env'
echo
echo "Then try the matcher against some real titles:"
echo
echo '  psql "$DBURL" -c "select song_key('"'"'Radiohead'"'"', '"'"'Idioteque (Official Video)'"'"');"'
echo
echo '  git add -A && git commit -m "Fuzzy duplicate detection" && git push'
