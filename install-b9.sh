#!/usr/bin/env bash
#
# Adds league chat.
#
# One room, polling rather than a persistent connection, because mobile
# browsers suspend background tabs and would leave an event stream
# silently stale.
#
set -euo pipefail
cd /var/www/hinderhole

if [ ! -f server.js ]; then
  echo "Not in the app directory."
  exit 1
fi

echo "==> checking git is clean"
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "You have uncommitted changes. Commit them first."
  git status --short
  exit 1
fi

cp server.js /tmp/server.js.before

echo "==> appending chat styles"
if grep -q 'chat__log' public/app.css; then
  echo "    already there, skipping"
else
  cat chat.css >> public/app.css
  rm -f chat.css
  echo "    done"
fi

echo "==> wiring the router"
python3 - <<'PY'
import pathlib, sys
p = pathlib.Path('server.js'); s = p.read_text()

if 'chatRoutes' in s:
    print("    already there, skipping"); sys.exit(0)

anchors = ["const statsRoutes = require('./stats');",
           "const categoryRoutes = require('./categories');",
           "const exportRoutes = require('./export');"]
for a in anchors:
    if a in s:
        s = s.replace(a, a + "\nconst chatRoutes = require('./chat');")
        break
else:
    sys.exit('Could not find a router import to anchor to.')

mounts = ["app.use(statsRoutes.router(db));",
          "app.use(categoryRoutes.router(db));",
          "app.use(exportRoutes.router(db));"]
for m in mounts:
    if m in s:
        s = s.replace(m, m + "\napp.use(chatRoutes.router(db));")
        break
else:
    sys.exit('Could not find a router mount to anchor to.')

p.write_text(s); print("    done")
PY

echo "==> adding the header link"
python3 - <<'PY'
import pathlib
p = pathlib.Path('views/home.ejs'); s = p.read_text()
if 'href="/chat"' in s:
    print("    already there, skipping")
else:
    s = s.replace('<a class="bar__back" href="/me">My picks</a>',
                  '<a class="bar__back" href="/chat">Chat</a>\n'
                  '    <a class="bar__back" href="/me">My picks</a>', 1)
    p.write_text(s); print("    done")
PY

echo "==> syntax check"
if node --check server.js && node --check chat.js && node --check public/chat.js; then
  echo "    ok"
  rm -f /tmp/server.js.before
else
  echo "    FAILED, restoring server.js"
  cp /tmp/server.js.before server.js
  exit 1
fi

echo
echo "Run the migration, then restart:"
echo
echo '  psql "$DBURL" -v ON_ERROR_STOP=1 -f migrations/010_chat.sql'
echo '  pm2 restart hinderhole --update-env'
echo
echo '  git add -A && git commit -m "League chat" && git push'
