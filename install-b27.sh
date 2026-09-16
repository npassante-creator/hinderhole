#!/usr/bin/env bash
#
# Pin the points tally properly.
#
# The tally and the play bar were both position:sticky at top:0. Two
# sticky siblings pinned to the same edge do not stack, the later one
# rides up over the first, so the tally disappeared under the play bar
# as soon as you scrolled.
#
# One sticky wrapper around both fixes it and keeps the controls up
# there too.
#
set -euo pipefail
cd /var/www/hinderhole

if [ ! -f views/vote.ejs ]; then
  echo "Not in the app directory."
  exit 1
fi

cp views/vote.ejs /tmp/vote.ejs.b27
cp public/app.css /tmp/app.css.b27

echo "==> wrapping the tally and the play bar"
python3 - <<'PY'
import pathlib, re, sys
p = pathlib.Path('views/vote.ejs')
s = p.read_text()

if 'pinned' in s:
    print("    already there, skipping"); sys.exit(0)

# From the opening of the tally through the close of the queuebar.
start = s.find('<div class="tally"')
if start == -1:
    sys.exit('Could not find the tally block.')

end_marker = '</div>'
qb = s.find('<div class="queuebar">', start)
if qb == -1:
    sys.exit('Could not find the queuebar.')
qb_end = s.find('</div>', s.find('queuebar__status', qb))
if qb_end == -1:
    sys.exit('Could not find the end of the queuebar.')
qb_end += len(end_marker)

block = s[start:qb_end]
wrapped = ('<div class="pinned">\n      '
           + block.replace('\n', '\n  ')
           + '\n    </div>')

s = s[:start] + wrapped + s[qb_end:]
p.write_text(s)
print("    done")
PY

echo "==> moving the stickiness onto the wrapper"
python3 - <<'PY'
import pathlib
p = pathlib.Path('public/app.css')
s = p.read_text()

if '.pinned {' in s:
    print("    already there, skipping")
else:
    s += """

/* ---------------------------------------------------------------
   The pinned bar on the ballot
   ---------------------------------------------------------------
   The tally and the play controls were separately sticky at top:0.
   Sticky siblings pinned to the same edge do not stack, so the play bar
   rode up over the tally the moment you scrolled. One wrapper, one
   sticky context, both stay visible. */

.pinned {
  position: sticky;
  top: 0;
  z-index: 10;
  background: var(--field);
  padding-bottom: .5rem;
  margin-bottom: .75rem;
  border-bottom: 1px solid rgba(240, 232, 216, .16);
  /* A shadow so cards passing underneath read as underneath. */
  box-shadow: 0 6px 12px -8px rgba(0, 0, 0, .7);
}

/* The children no longer position themselves. */
.pinned .tally,
.pinned .queuebar {
  position: static;
  z-index: auto;
  border-bottom: 0;
  margin-bottom: 0;
}

.pinned .queuebar { padding-top: .4rem; padding-bottom: 0; }
.pinned .tally { padding-bottom: .3rem; }

/* On a phone this bar is competing with eleven songs for screen, so
   tighten it up. */
@media (max-width: 30rem) {
  .pinned { padding-bottom: .35rem; }
  .pinned .tally__due { display: none; }
  .pinned .tally__line { font-size: .72rem; }
}
"""
    p.write_text(s)
    print("    done")
PY

echo "==> template check"
node -e "
  const ejs=require('ejs'), fs=require('fs');
  ejs.compile(fs.readFileSync('views/vote.ejs','utf8'), { filename: 'views/vote.ejs' });
  console.log('    ok');
" || { echo "    FAILED, restoring"; cp /tmp/vote.ejs.b27 views/vote.ejs; cp /tmp/app.css.b27 public/app.css; exit 1; }

echo "==> tag balance check"
python3 - <<'PY'
import pathlib, re, sys
s = pathlib.Path('views/vote.ejs').read_text()
# Strip EJS so only real markup is counted.
plain = re.sub(r'<%.*?%>', '', s, flags=re.S)
opens = len(re.findall(r'<div\b', plain))
closes = len(re.findall(r'</div>', plain))
if opens == closes:
    print(f"    ok, {opens} divs balanced")
else:
    sys.exit(f"    UNBALANCED: {opens} open, {closes} close")
PY

echo "==> restarting"
pm2 restart hinderhole --update-env >/dev/null
sleep 2

code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:3000/round/2/vote")
case "$code" in
  200|302) echo "    /round/2/vote -> $code ok" ;;
  *) echo "    -> $code PROBLEM, restoring"
     cp /tmp/vote.ejs.b27 views/vote.ejs
     cp /tmp/app.css.b27 public/app.css
     pm2 restart hinderhole --update-env >/dev/null
     exit 1 ;;
esac

rm -f /tmp/vote.ejs.b27 /tmp/app.css.b27
echo
echo "Hard reload the ballot, then:"
echo "  git add -A && git commit -m 'Pin the tally and play controls together' && git push"
