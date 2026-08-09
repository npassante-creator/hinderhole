#!/usr/bin/env bash
#
# Makes the round description editable.
#
# The column has existed since 001_init.sql and the player-facing round
# page already renders it. It has just never had a form behind it, so it
# has always been null. No migration needed.
#
set -euo pipefail
cd /var/www/hinderhole

if [ ! -f admin.js ]; then
  echo "Not in the app directory. cd /var/www/hinderhole first."
  exit 1
fi

echo "==> checking git is clean"
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "You have uncommitted changes. Commit them first."
  git status --short
  exit 1
fi

echo "==> adding description to the round edit query"
python3 - <<'PY'
import pathlib, sys
p = pathlib.Path('admin.js')
s = p.read_text()

if 'nullif($5' in s:
    print("    already there, skipping")
    sys.exit(0)

old = """        await db.query(
          `update rounds
              set submit_deadline = case when $2 = '' then submit_deadline
                     else ($2 || ':00')::timestamp at time zone 'America/Chicago' end,
                  vote_deadline = case when $3 = '' then vote_deadline
                     else ($3 || ':00')::timestamp at time zone 'America/Chicago' end,
                  title = coalesce(nullif($4, ''), title)
            where id = $1`,
          [
            req.round.id,
            String(req.body.submit_deadline || ''),
            String(req.body.vote_deadline || ''),
            String(req.body.title || ''),
          ]
        );"""

new = """        await db.query(
          `update rounds
              set submit_deadline = case when $2 = '' then submit_deadline
                     else ($2 || ':00')::timestamp at time zone 'America/Chicago' end,
                  vote_deadline = case when $3 = '' then vote_deadline
                     else ($3 || ':00')::timestamp at time zone 'America/Chicago' end,
                  title = coalesce(nullif($4, ''), title),
                  -- Empty clears it, which is how you take a caption back off.
                  description = nullif($5, '')
            where id = $1`,
          [
            req.round.id,
            String(req.body.submit_deadline || ''),
            String(req.body.vote_deadline || ''),
            String(req.body.title || ''),
            String(req.body.description || '').trim(),
          ]
        );"""

if old not in s:
    sys.exit('Could not find the round update query. Has admin.js changed?')

s = s.replace(old, new)
p.write_text(s)
print("    done")
PY

echo "==> adding the field to the admin form"
python3 - <<'PY'
import pathlib, sys
p = pathlib.Path('views/admin-round.ejs')
s = p.read_text()

if 'name="description"' in s:
    print("    already there, skipping")
    sys.exit(0)

old = """        <label class="field">
          <span class="field__label">Title</span>
          <input class="field__input" type="text" name="title" value="<%= round.title %>">
        </label>"""

new = """        <label class="field">
          <span class="field__label">Title</span>
          <input class="field__input" type="text" name="title" value="<%= round.title %>">
        </label>
        <label class="field">
          <span class="field__label">What counts (shown to everyone under the title)</span>
          <textarea class="field__input field__input--area" name="description" rows="3"
                    placeholder="Instrumentals count. Live versions do not. Argue with me."><%= round.description || '' %></textarea>
        </label>"""

if old not in s:
    sys.exit('Could not find the title field. Has admin-round.ejs changed?')

s = s.replace(old, new)

# The hint under the form only mentions dates; say the caption clears on empty.
s = s.replace(
    '<p class="fineprint">Leave a date blank to keep it as it is.</p>',
    '<p class="fineprint">\n'
    '        Leave a date blank to keep it as it is. Clearing the caption and\n'
    '        saving removes it.\n'
    '      </p>')

p.write_text(s)
print("    done")
PY

echo "==> showing the caption on the ballot and results too"
python3 - <<'PY'
import pathlib

# The round page already shows it. The ballot and results pages do not,
# and that is where people are actually deciding what fits.
for path, anchor in [
    ('views/vote.ejs',
     '''    <h1 class="marquee__title"><span><%= round.title %></span></h1>
  </header>'''),
    ('views/results.ejs',
     '''    <h1 class="marquee__title"><span><%= round.title %></span></h1>
  </header>'''),
]:
    p = pathlib.Path(path)
    s = p.read_text()
    if 'round.description' in s:
        print(f"    {path} already there, skipping")
        continue
    if anchor not in s:
        print(f"    {path} anchor not found, skipping")
        continue
    s = s.replace(anchor,
        '''    <h1 class="marquee__title"><span><%= round.title %></span></h1>
    <% if (round.description) { %>
      <p class="marquee__sub"><%= round.description %></p>
    <% } %>
  </header>''', 1)
    p.write_text(s)
    print(f"    {path} done")
PY

echo "==> syntax check"
node --check admin.js && echo "    ok  admin.js"

echo
echo "Restart:"
echo
echo '  pm2 restart hinderhole --update-env'
echo
echo "Then:"
echo
echo '  git diff --stat'
echo '  git add -A && git commit -m "Editable round descriptions" && git push'
