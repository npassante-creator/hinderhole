#!/usr/bin/env bash
# b38: new top bar with dropdowns, wider home, compact results,
# season playlists, commissioner tabs, round sheet extend dropdown.
#
# Replaces whole files, but only if each one is exactly the version this
# was built against. If anything was changed on the server since, it stops
# before touching anything.

set -euo pipefail
APP=${HH_APP:-/var/www/hinderhole}
cd "$APP"

PAY="$APP/b38"
BK="/tmp/hinderhole-b38-backup-$(date +%Y%m%d-%H%M%S)"

say() { printf '==> %s\n' "$1"; }
die() { printf '\nSTOPPED: %s\n' "$1" >&2; exit 1; }

[ -d "$PAY/files" ] || die "payload folder b38/ is missing. Run tar -xzf ~/hinderhole-redesign.tar.gz first."

say "checking git is clean"
dirty=$(git status --porcelain | grep -v -E '^\?\? (install-b38\.sh|b38/)$' || true)
[ -z "$dirty" ] || die "uncommitted changes:
$dirty
Commit or stash them first."

say "checking these files are the versions this was built against"
bad=0
while read -r sum file; do
  if [ ! -f "$file" ]; then echo "    missing  $file"; bad=1; continue; fi
  now=$(sha256sum "$file" | awk '{print $1}')
  if [ "$now" != "$sum" ]; then echo "    changed  $file"; bad=1; fi
done < "$PAY/base.sha256"
while read -r file; do
  [ -z "$file" ] && continue
  if [ -e "$file" ]; then echo "    exists   $file"; bad=1; fi
done < "$PAY/new.txt"
[ "$bad" = 0 ] || die "the server copy differs from what this was built on. Nothing was changed. Send Claude the output above."
echo "    all match"

say "backing up to $BK"
mkdir -p "$BK"
while read -r sum file; do
  mkdir -p "$BK/$(dirname "$file")"
  cp -p "$file" "$BK/$file"
done < "$PAY/base.sha256"

restore() {
  echo
  say "restoring the previous files"
  while read -r sum file; do cp -p "$BK/$file" "$file"; done < "$PAY/base.sha256"
  while read -r file; do [ -n "$file" ] && rm -f "$file"; done < "$PAY/new.txt"
  pm2 restart hinderhole --update-env >/dev/null 2>&1 || true
  echo "    restored and restarted. The site is back to how it was."
  echo "    Last log lines:"
  pm2 logs hinderhole --lines 25 --nostream 2>/dev/null | tail -25 || true
  exit 1
}

say "copying new files"
(cd "$PAY/files" && find . -type f | sed 's|^\./||') | while read -r f; do
  mkdir -p "$(dirname "$f")"
  cp "$PAY/files/$f" "$f"
  echo "    $f"
done

say "syntax check"
for f in server.js admin.js scoring.js playlists.js; do
  node --check "$f" || { echo "    $f failed"; restore; }
done
node -e '
  const ejs = require("ejs"), fs = require("fs"), path = require("path");
  const dirs = ["views", "views/partials"];
  let n = 0;
  for (const d of dirs) for (const f of fs.readdirSync(d)) {
    if (!f.endsWith(".ejs")) continue;
    ejs.compile(fs.readFileSync(path.join(d, f), "utf8"), { filename: path.join(d, f) });
    n++;
  }
  console.log("    " + n + " templates compile");
' || restore

say "running the new queries against the database"
node b38/verify.js db || restore

say "restarting"
pm2 restart hinderhole --update-env >/dev/null
port=$(grep -E '^PORT=' .env | cut -d= -f2- || true); port=${port:-3000}
up=0
for i in $(seq 1 20); do
  if curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null 2>&1; then up=1; break; fi
  sleep 1
done
[ "$up" = 1 ] || { echo "    did not come back up"; restore; }
echo "    up"

say "loading every page signed in (temporary session, deleted after)"
node b38/verify.js smoke || restore

rm -rf "$PAY"

cat <<'MSG'

Done. Hard reload the site (Cmd+Shift+R). Then commit:

  git add -A && git commit -m "Top bar with dropdowns, new home, compact results, playlists, commissioner tabs" && git push

Backups of the old files are in /tmp/hinderhole-b38-backup-* if you ever need them.
MSG
