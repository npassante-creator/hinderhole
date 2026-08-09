#!/usr/bin/env bash
#
# Installs the category board and duplicate warnings.
#
# Run from /var/www/hinderhole after unpacking the tarball. Everything it
# changes is already under git, so `git diff` will show you exactly what
# moved before you commit.
#
set -euo pipefail

cd /var/www/hinderhole

if [ ! -f server.js ]; then
  echo "Not in the app directory. cd /var/www/hinderhole first."
  exit 1
fi

echo "==> checking git is clean"
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "You have uncommitted changes. Commit or stash them first,"
  echo "so this script's edits are easy to review on their own."
  git status --short
  exit 1
fi

echo "==> appending category styles"
if ! grep -q '\.idea__title' public/app.css; then
  cat categories.css >> public/app.css
  rm -f categories.css
  echo "    done"
else
  echo "    already there, skipping"
fi

echo "==> teaching ballot.js about the category board"
python3 - <<'PY'
import pathlib
p = pathlib.Path('public/ballot.js')
s = p.read_text()

if 'data-scope' not in s:
    s = s.replace(
        "var roundId = tally.getAttribute('data-round');",
        "var roundId = tally.getAttribute('data-round');\n"
        "  var scope = tally.getAttribute('data-scope') || 'round';"
    )
    s = s.replace(
        "var card = pip.closest('.card');",
        "var card = pip.closest('.card, .idea');"
    )
    s = s.replace(
        """    post('/round/' + roundId + '/vote', {
      submission_id: Number(card.getAttribute('data-submission')),
      points: points,
    })""",
        """    var url = scope === 'category'
      ? '/categories/' + card.getAttribute('data-idea') + '/vote'
      : '/round/' + roundId + '/vote';
    var payload = scope === 'category'
      ? { points: points }
      : { submission_id: Number(card.getAttribute('data-submission')),
          points: points };

    post(url, payload)"""
    )
    p.write_text(s)
    print("    done")
else:
    print("    already there, skipping")
PY

echo "==> wiring the router into server.js"
python3 - <<'PY'
import pathlib
p = pathlib.Path('server.js')
s = p.read_text()

if 'categoryRoutes' not in s:
    # Sit next to whichever router import we can find.
    for anchor in ("const exportRoutes = require('./export');",
                   "const uploadRoutes = require('./upload');",
                   "const resultRoutes = require('./results');"):
        if anchor in s:
            s = s.replace(anchor, anchor + "\nconst categoryRoutes = require('./categories');")
            break
    else:
        raise SystemExit('Could not find a router import to anchor to.')

    for anchor in ("app.use(exportRoutes.router(db));",
                   "app.use(uploadRoutes.router(db));",
                   "app.use(resultRoutes.router(db));"):
        if anchor in s:
            s = s.replace(anchor, anchor + "\napp.use(categoryRoutes.router(db));")
            break
    else:
        raise SystemExit('Could not find a router mount to anchor to.')

    p.write_text(s)
    print("    done")
else:
    print("    already there, skipping")
PY

echo "==> adding a Categories link to the header"
python3 - <<'PY'
import pathlib
p = pathlib.Path('views/home.ejs')
s = p.read_text()
if '/categories' not in s:
    s = s.replace(
        '<a class="bar__back" href="/standings">Standings</a>',
        '<a class="bar__back" href="/standings">Standings</a>\n'
        '    <a class="bar__back" href="/categories">Categories</a>',
        1)
    p.write_text(s)
    print("    done")
else:
    print("    already there, skipping")
PY

echo "==> showing duplicate warnings on the round page"
python3 - <<'PY'
import pathlib

# rounds.js: look up whether this song has run before
p = pathlib.Path('rounds.js')
s = p.read_text()

if 'song_seen_before' not in s:
    s = s.replace(
        """  async function renderRound(req, res, extra = {}) {
    const submission = await getSubmission(req.round.id, req.player.id);""",
        """  async function renderRound(req, res, extra = {}) {
    const submission = await getSubmission(req.round.id, req.player.id);

    // Ten weeks of obscure music across eighteen people. Somebody will
    // resubmit something. Warn, never block: a reprise might be the joke.
    let echo = [];
    if (submission && submission.external_id) {
      const { rows } = await db.query(
        'select * from song_seen_before($1, $2, $3)',
        [req.round.league_id, submission.external_id, req.round.id]
      );
      echo = rows;
    }""")

    s = s.replace(
        """    res.render('round', {
      round: req.round,
      submission,""",
        """    res.render('round', {
      round: req.round,
      submission,
      echo,""")
    p.write_text(s)
    print("    rounds.js done")
else:
    print("    rounds.js already there, skipping")

# round.ejs: render the warning
p = pathlib.Path('views/round.ejs')
s = p.read_text()
if 'class="echo"' not in s:
    s = s.replace(
        '        <div class="pick">',
        """        <% if (typeof echo !== 'undefined' && echo.length) { %>
          <div class="echo">
            <span class="echo__label">Played before</span>
            <% echo.forEach(function (e) { %>
              Round <%= e.round_number %>, <%= e.round_title %>, submitted by <%= e.submitted_by %>.
            <% }) %>
            Still allowed, but people will notice.
          </div>
        <% } %>

        <div class="pick">""", 1)
    p.write_text(s)
    print("    round.ejs done")
else:
    print("    round.ejs already there, skipping")
PY

echo "==> syntax check"
for f in server.js rounds.js categories.js public/ballot.js; do
  node --check "$f" && echo "    ok  $f"
done

echo
echo "Now run the migration and restart:"
echo
echo '  psql "$DBURL" -v ON_ERROR_STOP=1 -f migrations/009_categories.sql'
echo '  pm2 restart hinderhole --update-env'
echo
echo "Then review and commit:"
echo
echo '  git diff'
echo '  git add -A && git commit -m "Category suggestion box and duplicate warnings" && git push'
