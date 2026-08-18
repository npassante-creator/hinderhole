#!/usr/bin/env bash
#
# Adds a GIF picker to chat, backed by Giphy.
#
# The key stays server side behind a proxy route, results are cached for
# ten minutes, and only Giphy's own hosts can ever end up rendered in a
# message.
#
# You need a key first: developers.giphy.com, create an app, copy the key.
# Then put GIPHY_API_KEY=... in .env before running this.
#
set -euo pipefail
cd /var/www/hinderhole

if [ ! -f chat.js ]; then
  echo "Chat is not installed. Run the chat installer first."
  exit 1
fi

echo "==> checking git is clean"
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "You have uncommitted changes. Commit them first."
  git status --short
  exit 1
fi

if ! grep -q '^GIPHY_API_KEY=..' .env; then
  echo
  echo "No GIPHY_API_KEY in .env yet."
  echo "Get one at developers.giphy.com, then add the line and re-run."
  echo "Installing anyway: the button stays hidden until the key is there."
  echo
fi

cp chat.js /tmp/chat.js.before
cp public/chat.js /tmp/chatclient.js.before

echo "==> appending gif styles"
if grep -q 'gif__grid' public/app.css; then
  echo "    already there, skipping"
else
  cat gif.css >> public/app.css
  rm -f gif.css
  echo "    done"
fi

echo "==> patching the server"
python3 chat-patch.py

echo "==> patching the client"
python3 client-patch.py

echo "==> adding the button and picker to the view"
python3 - <<'PY'
import pathlib, sys
p = pathlib.Path('views/chat.ejs'); s = p.read_text()

if 'gifpicker' in s:
    print("    already there, skipping"); sys.exit(0)

anchor = """    <form class="chat__form" id="chatform">
      <textarea class="chat__box" id="chatbox" rows="2" maxlength="2000"
                placeholder="Say something" autocomplete="off"></textarea>
      <button class="button" type="submit">Send</button>
      <p class="chat__state" id="chatstate"></p>
    </form>"""

new = """    <% if (gifsOn) { %>
      <div class="gif__picker" id="gifpicker" hidden>
        <input class="gif__search" type="search" placeholder="Search GIFs"
               autocomplete="off" aria-label="Search GIFs">
        <div class="gif__grid"></div>
        <p class="gif__state"></p>
        <p class="gif__credit">Powered by GIPHY</p>
      </div>
    <% } %>

    <form class="chat__form" id="chatform">
      <textarea class="chat__box" id="chatbox" rows="2" maxlength="2000"
                placeholder="Say something" autocomplete="off"></textarea>
      <% if (gifsOn) { %>
        <button class="gif__btn" id="gifbtn" type="button"
                aria-expanded="false">GIF</button>
      <% } %>
      <button class="button" type="submit">Send</button>
      <p class="chat__state" id="chatstate"></p>
    </form>"""

if anchor not in s:
    sys.exit('Could not find the chat form in chat.ejs.')

s = s.replace(anchor, new)
p.write_text(s)
print("    done")
PY

echo "==> syntax check"
if node --check chat.js && node --check giphy.js && node --check public/chat.js; then
  echo "    ok"
  rm -f /tmp/chat.js.before /tmp/chatclient.js.before
  rm -f chat-patch.py client-patch.py
else
  echo "    FAILED, restoring"
  cp /tmp/chat.js.before chat.js
  cp /tmp/chatclient.js.before public/chat.js
  exit 1
fi

echo
echo "Run the migration, then restart:"
echo
echo '  psql "$DBURL" -v ON_ERROR_STOP=1 -f migrations/011_chat_media.sql'
echo '  pm2 restart hinderhole --update-env'
echo
echo '  git add -A && git commit -m "GIF picker in chat" && git push'
