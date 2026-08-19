#!/usr/bin/env bash
#
# Makes shortlists findable.
#
#   1. "Coming up" goes in the header, on every player-facing page.
#   2. My picks grows a "Saved for later" section, since that page is
#      already where you go to look at your own stuff.
#
set -euo pipefail
cd /var/www/hinderhole

if [ ! -f views/home.ejs ] || [ ! -f shortlist.js ]; then
  echo "Not in the app directory, or shortlists are not installed."
  exit 1
fi

echo "==> checking git is clean"
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "You have uncommitted changes. Commit them first."
  git status --short
  exit 1
fi

cp stats.js /tmp/stats.js.before
cp views/me.ejs /tmp/me.ejs.before

echo "==> adding the header link"
python3 - <<'PY'
import pathlib

targets = ['views/home.ejs', 'views/upcoming.ejs', 'views/standings.ejs',
           'views/me.ejs', 'views/stats.ejs', 'views/categories.ejs',
           'views/chat.ejs']
link = '<a class="bar__back" href="/upcoming">Coming up</a>'
done, skipped = [], []

for path in targets:
    p = pathlib.Path(path)
    if not p.exists():
        continue
    s = p.read_text()
    if 'href="/upcoming"' in s:
        skipped.append(path); continue

    if '<a class="bar__back" href="/me">My picks</a>' in s:
        s = s.replace('<a class="bar__back" href="/me">My picks</a>',
                      '<a class="bar__back" href="/me">My picks</a>\n    ' + link, 1)
    elif '<a class="bar__back" href="/">All rounds</a>' in s:
        s = s.replace('<a class="bar__back" href="/">All rounds</a>',
                      '<a class="bar__back" href="/">All rounds</a>\n    ' + link, 1)
    else:
        skipped.append(path + ' (no bar)'); continue

    p.write_text(s); done.append(path)

print("    added: " + (", ".join(done) if done else "none"))
if skipped:
    print("    skipped: " + ", ".join(skipped))
PY

echo "==> loading shortlists on My picks"
python3 - <<'PY'
import pathlib, sys
p = pathlib.Path('stats.js'); s = p.read_text()

if 'savedByRound' in s:
    print("    already there, skipping"); sys.exit(0)

anchor = "      res.render('me', {"
if anchor not in s:
    sys.exit('Could not find the me render call.')

load = """      // Saved candidates for rounds that have not finished. Owner only.
      const { rows: savedRows } = await db.query(
        `select s.*, r.round_number, r.title as category, r.status
           from shortlist s
           join rounds r on r.id = s.round_id
          where s.player_id = $1
            and r.league_id = $2
            and r.status <> 'revealed'
          order by r.round_number, s.created_at`,
        [req.player.id, lg.id]
      );

      const savedByRound = [];
      savedRows.forEach((row) => {
        let group = savedByRound.find((g) => g.round_id === row.round_id);
        if (!group) {
          group = {
            round_id: row.round_id,
            round_number: row.round_number,
            category: row.category,
            status: row.status,
            items: [],
          };
          savedByRound.push(group);
        }
        group.items.push(row);
      });

      res.render('me', {
        savedByRound,"""

s = s.replace(anchor, load, 1)
p.write_text(s); print("    done")
PY

echo "==> showing them on the page"
python3 - <<'PY'
import pathlib, sys
p = pathlib.Path('views/me.ejs'); s = p.read_text()

if 'savedByRound' in s:
    print("    already there, skipping"); sys.exit(0)

anchor = '    <ol class="results">'

new = """    <% if (typeof savedByRound !== 'undefined' && savedByRound.length) { %>
      <h2 class="rack__heading">Saved for later</h2>
      <% savedByRound.forEach(function (g) { %>
        <p class="saved__round">
          Round <%= String(g.round_number).padStart(2, '0') %> &middot;
          <%= g.category %>
          <% if (g.status === 'submitting') { %>
            <span class="tag tag--gave">open now</span>
          <% } %>
        </p>
        <ul class="shortlist__items">
          <% g.items.forEach(function (c) { %>
            <li class="cand">
              <% if (c.thumbnail_url) { %>
                <img class="cand__art" src="<%= c.thumbnail_url %>" alt="" loading="lazy">
              <% } %>
              <div class="cand__body">
                <p class="cand__title"><%= c.title || 'Untitled' %></p>
                <p class="cand__artist"><%= c.artist || 'Unknown artist' %></p>
                <% if (c.note) { %><p class="cand__note"><%= c.note %></p><% } %>
              </div>
              <div class="cand__acts">
                <% if (g.status === 'submitting') { %>
                  <form method="post" action="/shortlist/item/<%= c.id %>/use">
                    <button class="chip chip--on" type="submit">use this</button>
                  </form>
                <% } %>
                <form method="post" action="/shortlist/item/<%= c.id %>/remove">
                  <button class="chip chip--danger" type="submit">drop</button>
                </form>
              </div>
            </li>
          <% }) %>
        </ul>
      <% }) %>
      <p class="fineprint">
        Only you can see these. Add more from
        <a href="/upcoming">Coming up</a>.
      </p>
    <% } else { %>
      <p class="fineprint">
        Heard something that would suit a later round? Save it from
        <a href="/upcoming">Coming up</a> and it will be waiting when that
        week arrives.
      </p>
    <% } %>

    <h2 class="rack__heading">Every round</h2>

    <ol class="results">"""

if anchor not in s:
    sys.exit('Could not find the results list in me.ejs.')

s = s.replace(anchor, new, 1)
p.write_text(s); print("    done")
PY

echo "==> styling"
if grep -q 'saved__round' public/app.css; then
  echo "    already there, skipping"
else
cat >> public/app.css << 'CSSEOF'

/* Shortlist groups on My picks. */
.saved__round {
  font-family: var(--util);
  font-size: .68rem;
  letter-spacing: .08em;
  text-transform: uppercase;
  color: var(--steel);
  margin: 1.1rem 0 .2rem;
}
CSSEOF
  echo "    done"
fi

echo "==> also make the season page eyebrow say what it is for"
python3 - <<'PY'
import pathlib
p = pathlib.Path('views/upcoming.ejs'); s = p.read_text()
old = '<p class="marquee__eyebrow">Plan ahead</p>'
new = '<p class="marquee__eyebrow">Plan ahead &middot; save songs for later</p>'
if old in s:
    s = s.replace(old, new, 1); p.write_text(s); print("    done")
else:
    print("    already there, skipping")
PY

echo "==> syntax check"
ok=1
node --check stats.js || ok=0
node -e "
  const ejs=require('ejs'), fs=require('fs');
  ['home','upcoming','standings','me','stats','categories','chat']
    .map(n => 'views/' + n + '.ejs')
    .filter(f => fs.existsSync(f))
    .forEach(f => ejs.compile(fs.readFileSync(f,'utf8'), { filename: f }));
" || ok=0

if [ "$ok" = "1" ]; then
  echo "    ok"
  rm -f /tmp/stats.js.before /tmp/me.ejs.before
else
  echo "    FAILED, restoring"
  cp /tmp/stats.js.before stats.js
  cp /tmp/me.ejs.before views/me.ejs
  exit 1
fi

echo
echo "Restart, then commit:"
echo
echo '  pm2 restart hinderhole --update-env'
echo '  git add -A && git commit -m "Shortlists findable: header link and My picks section" && git push'
