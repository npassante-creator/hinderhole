#!/usr/bin/env bash
#
# Lets players set their own display name.
#
# The name is what shows next to their songs at the reveal and on the
# standings. Email stays fixed and stays private, so identity is still
# traceable by the commissioner even if someone picks something silly.
#
# No migration: players.name has always been there, it just had no form.
#
set -euo pipefail
cd /var/www/hinderhole

if [ ! -f stats.js ]; then
  echo "Not in the app directory, or the stats pages are not installed."
  exit 1
fi

echo "==> checking git is clean"
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "You have uncommitted changes. Commit them first."
  git status --short
  exit 1
fi

echo "==> adding the rename route"
python3 - <<'PY'
import pathlib, sys
p = pathlib.Path('stats.js')
s = p.read_text()

if "'/me/name'" in s:
    print("    already there, skipping")
    sys.exit(0)

if "const express = require('express');" not in s:
    sys.exit('Unexpected stats.js shape.')

route = '''
  // ---------------------------------------------------------------
  // What everyone else calls you
  // ---------------------------------------------------------------
  // The group runs on nicknames. The email stays fixed and stays private,
  // so the commissioner can always tell who is who.

  r.post('/me/name', requireAuth, express.urlencoded({ extended: false }),
    async (req, res, next) => {
      try {
        const name = String(req.body.name || '').trim().replace(/\\s+/g, ' ');

        if (name.length < 2 || name.length > 40) {
          return res.redirect('/me?err=' + encodeURIComponent(
            'Pick something between 2 and 40 characters.'));
        }

        const lg = await league(req.player.id);
        if (!lg) return res.redirect('/');

        // Two people called Sam makes the reveal unreadable.
        const { rows: clash } = await db.query(
          `select 1 from memberships m
             join players p on p.id = m.player_id
            where m.league_id = $1
              and p.id <> $2
              and lower(p.name) = lower($3)
            limit 1`,
          [lg.id, req.player.id, name]
        );
        if (clash[0]) {
          return res.redirect('/me?err=' + encodeURIComponent(
            'Somebody in the league already goes by that. Pick another.'));
        }

        await db.query('update players set name = $2 where id = $1',
          [req.player.id, name]);

        res.redirect('/me?ok=' + encodeURIComponent('That is you now.'));
      } catch (err) {
        next(err);
      }
    });

  return r;
'''

s = s.replace("\n  return r;\n}\n\nmodule.exports = { router };",
              route + "}\n\nmodule.exports = { router };")
p.write_text(s)
print("    done")
PY

echo "==> passing the banners through to the page"
python3 - <<'PY'
import pathlib
p = pathlib.Path('stats.js')
s = p.read_text()
if "error: req.query.err" not in s:
    s = s.replace(
        """      res.render('me', {
        league: lg,""",
        """      res.render('me', {
        league: lg,
        error: req.query.err || null,
        notice: req.query.ok || null,""")
    p.write_text(s)
    print("    done")
else:
    print("    already there, skipping")
PY

echo "==> adding the form to the picks page"
python3 - <<'PY'
import pathlib, sys
p = pathlib.Path('views/me.ejs')
s = p.read_text()

if 'action="/me/name"' in s:
    print("    already there, skipping")
    sys.exit(0)

anchor = '  <main class="panel">\n'
new = '''  <main class="panel">

    <% if (typeof error !== 'undefined' && error) { %>
      <p class="notice notice--bad"><%= error %></p>
    <% } %>
    <% if (typeof notice !== 'undefined' && notice) { %>
      <p class="notice notice--good"><%= notice %></p>
    <% } %>

    <details class="drawer">
      <summary class="drawer__summary">Change what people call you</summary>
      <form class="strip strip--form" method="post" action="/me/name">
        <label class="field">
          <span class="field__label">Your name in the league</span>
          <input class="field__input" type="text" name="name" maxlength="40"
                 value="<%= player.name %>" required>
        </label>
        <button class="button" type="submit">Save</button>
      </form>
      <p class="fineprint">
        This is what shows next to your songs when a round is revealed, and
        on the standings. Change it whenever. Your email never shows to
        anyone.
      </p>
    </details>

'''

if anchor not in s:
    sys.exit('Could not find the panel opening in me.ejs.')

s = s.replace(anchor, new, 1)
p.write_text(s)
print("    done")
PY

echo "==> syntax check"
node --check stats.js && echo "    ok  stats.js"

echo
echo "Restart, then commit:"
echo
echo '  pm2 restart hinderhole --update-env'
echo '  git add -A && git commit -m "Players can set their own display name" && git push'
