#!/usr/bin/env bash
#
# Fix: media vanished on reload.
#
# The chat client draws media for messages it receives by polling, but the
# initial page is rendered server side by EJS and that template only ever
# drew the text. Send a GIF and it appears; reload and it is gone.
#
set -euo pipefail
cd /var/www/hinderhole

if [ ! -f views/chat.ejs ]; then
  echo "Not in the app directory."
  exit 1
fi

echo "==> checking git is clean"
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "You have uncommitted changes. Commit them first."
  git status --short
  exit 1
fi

cp views/chat.ejs /tmp/chat.ejs.before

echo "==> drawing media in the server-rendered log"
python3 - <<'PY'
import pathlib, sys
p = pathlib.Path('views/chat.ejs'); s = p.read_text()

if 'msg__gif' in s:
    print("    already there, skipping"); sys.exit(0)

old = """              <p class="msg__body"><%= m.body %></p>"""

new = """              <% if (m.body) { %>
                <p class="msg__body"><%= m.body %></p>
              <% } %>
              <% if (m.media && m.media.url) { %>
                <img class="msg__gif" src="<%= m.media.url %>"
                     alt="<%= m.media.alt || 'Image' %>" loading="lazy"
                     <% if (m.media.w) { %>width="<%= m.media.w %>"<% } %>
                     <% if (m.media.h) { %>height="<%= m.media.h %>"<% } %>>
              <% } %>"""

if old not in s:
    sys.exit('Could not find the message body line in chat.ejs.')

s = s.replace(old, new)
p.write_text(s)
print("    done")
PY

echo "==> checking the template parses"
if node -e "
  const ejs = require('ejs');
  const fs = require('fs');
  ejs.compile(fs.readFileSync('views/chat.ejs', 'utf8'), { filename: 'views/chat.ejs' });
  console.log('    ok  views/chat.ejs');
"; then
  rm -f /tmp/chat.ejs.before
else
  echo "    FAILED, restoring"
  cp /tmp/chat.ejs.before views/chat.ejs
  exit 1
fi

echo
echo "Restart, then commit:"
echo
echo '  pm2 restart hinderhole --update-env'
echo '  git add -A && git commit -m "Draw chat media on first load, not just on poll" && git push'
