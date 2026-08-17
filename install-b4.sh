#!/usr/bin/env bash
#
# Adds a "welcome everyone" button to the admin roster.
#
# Sends each player a real sign-in link, so nobody has to be told to go to
# the site and type their address unprompted. Skips anyone who has already
# signed in, so pressing it twice does not spam the people who are in.
#
set -euo pipefail
cd /var/www/hinderhole

if [ ! -f admin.js ]; then
  echo "Not in the app directory."
  exit 1
fi

echo "==> checking git is clean"
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "You have uncommitted changes. Commit them first."
  git status --short
  exit 1
fi

echo "==> adding the welcome mailer"
python3 - <<'PY'
import pathlib, sys
p = pathlib.Path('admin.js')
s = p.read_text()

if 'welcome-all' in s:
    print("    already there, skipping")
    sys.exit(0)

# The mailer needs sendgrid and the token machinery auth.js already has.
if "require('./auth')" in s and 'requestLoginLink' not in s:
    s = s.replace("const { requireAuth } = require('./auth');",
                  "const { requireAuth, requestLoginLink } = require('./auth');")

route = '''
  // ---------------------------------------------------------------
  // Welcoming the roster
  // ---------------------------------------------------------------
  // Twenty one people are not going to independently decide to visit a
  // website and type their address. Send them a way in.

  r.post('/admin/roster/welcome-all', requireAuth, requireAdmin, form,
    async (req, res, next) => {
      try {
        const everyone = req.body.everyone === '1';

        const { rows: people } = await db.query(
          `select p.id, p.name, p.email
             from memberships m
             join players p on p.id = m.player_id
            where m.league_id = $1
              and p.is_active
              and p.email not like '%@demo.invalid'
              ${everyone ? '' : 'and p.last_login_at is null'}
            order by p.name`,
          [req.league.id]
        );

        let sent = 0;
        let failed = 0;
        for (const person of people) {
          try {
            await requestLoginLink(db, person.email, { ip: req.ip });
            sent++;
          } catch (err) {
            console.error('[admin] welcome failed for', person.email, err.message);
            failed++;
          }
        }

        await log(req.league.id, req.player.id, 'welcome_sent',
          `${sent} sign in links sent${failed ? `, ${failed} failed` : ''}`);

        res.redirect('/admin?ok=' + encodeURIComponent(
          `${sent} sign in link${sent === 1 ? '' : 's'} sent.` +
          (failed ? ` ${failed} failed, check the logs.` : '')));
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

echo "==> adding the buttons to the roster"
python3 - <<'PY'
import pathlib, sys
p = pathlib.Path('views/admin.ejs')
s = p.read_text()

if 'welcome-all' in s:
    print("    already there, skipping")
    sys.exit(0)

anchor = '''    <details class="drawer">
      <summary class="drawer__summary">Add players</summary>'''

new = '''    <p class="moves">
      <form method="post" action="/admin/roster/welcome-all"
            onsubmit="return confirm('Email a sign in link to everyone who has not signed in yet?')">
        <button class="chip" type="submit">email everyone who has not signed in</button>
      </form>
      <form method="post" action="/admin/roster/welcome-all"
            onsubmit="return confirm('Email a fresh sign in link to the WHOLE roster, including people already signed in?')">
        <input type="hidden" name="everyone" value="1">
        <button class="chip chip--danger" type="submit">email the whole roster</button>
      </form>
    </p>
    <p class="fineprint">
      Sends each person a link that signs them straight in. Links work once
      and expire in 20 minutes, so send these when people are around.
    </p>

''' + anchor

if anchor not in s:
    sys.exit('Could not find the Add players drawer.')

s = s.replace(anchor, new, 1)
p.write_text(s)
print("    done")
PY

echo "==> syntax check"
node --check admin.js && echo "    ok  admin.js"

echo
echo "Restart, then commit:"
echo
echo '  pm2 restart hinderhole --update-env'
echo '  git add -A && git commit -m "Bulk welcome emails and season reset" && git push'
