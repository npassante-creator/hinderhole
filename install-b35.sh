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
VIEWS="views/admin-round.ejs views/admin.ejs views/categories.ejs views/chat.ejs
       views/home.ejs views/me.ejs views/results.ejs views/round.ejs
       views/standings.ejs views/stats.ejs views/upcoming.ejs views/vote.ejs"
cp public/app.css /tmp/app.css.b35.bak
for f in $VIEWS; do
  cp "$f" /tmp/$(basename "$f").b35.bak
done
echo "    done"

# ── step 1: rename nav link text ──────────────────────────────────────────────
echo "==> renaming Categories → Suggest rounds in nav"
python3 - <<'PY'
import glob
old = 'href="/categories">Categories</a>'
new = 'href="/categories">Suggest rounds</a>'
for path in sorted(glob.glob('views/*.ejs')):
    txt = open(path).read()
    if old in txt:
        open(path, 'w').write(txt.replace(old, new))
        print(f'    patched {path}')
PY
echo "    done"

# ── step 2: update categories page <title> ────────────────────────────────────
echo "==> updating categories page title"
python3 - <<'PY'
path = 'views/categories.ejs'
txt = open(path).read()
if "title: 'Categories - Holy Hinder Hole Sound Society'" not in txt:
    print('    WARNING: title anchor not found, skipping')
else:
    txt = txt.replace(
        "title: 'Categories - Holy Hinder Hole Sound Society'",
        "title: 'Suggest Rounds - Holy Hinder Hole Sound Society'"
    )
    open(path, 'w').write(txt)
    print('    done')
PY

# ── step 3: wrap right-side nav in bar__right ─────────────────────────────────
echo "==> fixing nav layout (bar__right wrapper)"
python3 - <<'PY'
import glob

OLD = (
    '    <span class="bar__name"><%= player.name %></span>\n'
    '    <% if (typeof isAdmin !== "undefined" && isAdmin) { %>'
    '<a class="bar__admin" href="/admin">Commissioner</a><% } %>\n'
    '    <form method="post" action="/auth/logout">\n'
    '      <button class="bar__out" type="submit">Sign out</button>\n'
    '    </form>\n'
    '  </header>'
)

NEW = (
    '    <div class="bar__right">\n'
    '      <span class="bar__name"><%= player.name %></span>\n'
    '      <% if (typeof isAdmin !== "undefined" && isAdmin) { %>'
    '<a class="bar__admin" href="/admin">Commissioner</a><% } %>\n'
    '      <form method="post" action="/auth/logout">\n'
    '        <button class="bar__out" type="submit">Sign out</button>\n'
    '      </form>\n'
    '    </div>\n'
    '  </header>'
)

patched = 0
for path in sorted(glob.glob('views/*.ejs')):
    txt = open(path).read()
    if OLD in txt:
        open(path, 'w').write(txt.replace(OLD, NEW))
        print(f'    patched {path}')
        patched += 1
    elif 'bar__name' in txt:
        print(f'    WARNING: bar__name found in {path} but pattern did not match — check manually')

print(f'    {patched} files patched')
PY
echo "    done"

# ── step 4: CSS — bar__name loses margin-left:auto; add bar__right ────────────
echo "==> patching app.css"
python3 - <<'PY'
path = 'public/app.css'
txt = open(path).read()

OLD_NAME = (
    '.bar__name {\n'
    '  font-family: var(--util);\n'
    '  font-size: .66rem;\n'
    '  letter-spacing: .09em;\n'
    '  text-transform: uppercase;\n'
    '  color: var(--steel);\n'
    '  margin-left: auto;\n'
    '  padding-left: .5rem;\n'
    '  white-space: nowrap;\n'
    '}'
)
NEW_NAME = (
    '.bar__name {\n'
    '  font-family: var(--util);\n'
    '  font-size: .66rem;\n'
    '  letter-spacing: .09em;\n'
    '  text-transform: uppercase;\n'
    '  color: var(--steel);\n'
    '  padding-left: .5rem;\n'
    '  white-space: nowrap;\n'
    '}\n'
    '\n'
    '.bar__right {\n'
    '  margin-left: auto;\n'
    '  display: flex;\n'
    '  align-items: center;\n'
    '  gap: .4rem;\n'
    '  flex-shrink: 0;\n'
    '}'
)

if OLD_NAME not in txt:
    print('ERROR: bar__name CSS anchor not found'); exit(1)
txt = txt.replace(OLD_NAME, NEW_NAME)

# mobile breakpoint: bar__name width rule moves to bar__right
OLD_MOB = '  .bar__name { width: 100%; margin-left: 0; padding: .2rem 0 0; }'
NEW_MOB = '  .bar__right { width: 100%; margin-left: 0; }\n  .bar__name { padding: .2rem 0 0; }'
if OLD_MOB in txt:
    txt = txt.replace(OLD_MOB, NEW_MOB)
else:
    print('    WARNING: mobile bar__name rule not found, skipping')

open(path, 'w').write(txt)
print('    done')
PY

# ── step 5: syntax check ──────────────────────────────────────────────────────
echo "==> syntax check"
FAIL=0
node --check server.js 2>&1 || FAIL=1
node --check results.js 2>&1 || FAIL=1
if [ $FAIL -ne 0 ]; then
  echo "    FAIL — restoring backups"
  cp /tmp/app.css.b35.bak public/app.css
  for f in $VIEWS; do
    cp /tmp/$(basename "$f").b35.bak "$f"
  done
  exit 1
fi
echo "    ok"

# ── step 6: restart ───────────────────────────────────────────────────────────
echo "==> restarting"
pm2 restart hinderhole --update-env
echo "    done"

echo ""
echo "==> git add -A && git commit -m 'Rename Categories to Suggest Rounds; fix Commissioner nav wrapping' && git push"
