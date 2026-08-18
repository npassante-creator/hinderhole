#!/usr/bin/env bash
#
# Adds image upload to chat.
#
# Photos are shrunk in the browser before sending, so there is no image
# library on the server and no waiting on a phone signal. Animated GIFs go
# up untouched, since drawing one to a canvas flattens it to one frame.
#
set -euo pipefail
cd /var/www/hinderhole

if [ ! -f chat.js ]; then
  echo "Chat is not installed."
  exit 1
fi

echo "==> checking git is clean"
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "You have uncommitted changes. Commit them first."
  git status --short
  exit 1
fi

cp chat.js /tmp/chat.js.before
cp public/chat.js /tmp/chatclient.js.before

echo "==> making the chat media directory"
MEDIA_DIR=$(grep '^MEDIA_DIR=' .env | cut -d= -f2- || echo /var/lib/hinderhole/media)
mkdir -p "$MEDIA_DIR/chat"
echo "    $MEDIA_DIR/chat"

echo "==> appending styles"
if grep -q 'img__btn' public/app.css; then
  echo "    already there, skipping"
else
  cat img.css >> public/app.css
  rm -f img.css
  echo "    done"
fi

echo "==> patching the server"
python3 chatmedia-patch.py

echo "==> patching the client"
python3 clientmedia-patch.py

echo "==> adding the button to the view"
python3 - <<'PY'
import pathlib, sys
p = pathlib.Path('views/chat.ejs'); s = p.read_text()

if 'imgbtn' in s:
    print("    already there, skipping"); sys.exit(0)

anchor = '      <button class="button" type="submit">Send</button>'
new = """      <button class="img__btn" id="imgbtn" type="button">Pic</button>
      <input id="imginput" type="file" accept="image/*" hidden>
      <button class="button" type="submit">Send</button>"""

if anchor not in s:
    sys.exit('Could not find the send button in chat.ejs.')

s = s.replace(anchor, new, 1)
p.write_text(s); print("    done")
PY

echo "==> syntax check"
if node --check chat.js && node --check public/chat.js; then
  echo "    ok"
  rm -f /tmp/chat.js.before /tmp/chatclient.js.before
  rm -f chatmedia-patch.py clientmedia-patch.py
else
  echo "    FAILED, restoring"
  cp /tmp/chat.js.before chat.js
  cp /tmp/chatclient.js.before public/chat.js
  exit 1
fi

echo
echo "No migration, the media columns are already there. Just restart:"
echo
echo '  pm2 restart hinderhole --update-env'
echo '  git add -A && git commit -m "Image upload in chat" && git push'
