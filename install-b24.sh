#!/usr/bin/env bash
#
# Fix: the b23 template patch missed, so comments render as
# [object Object]. results.js now hands the template an object with a
# body and an author, but the template still prints the whole thing.
#
# Matching on a regex this time rather than an exact indented block.
#
set -euo pipefail
cd /var/www/hinderhole

if [ ! -f views/results.ejs ]; then
  echo "Not in the app directory."
  exit 1
fi

cp views/results.ejs /tmp/results.ejs.b24
cp views/standings.ejs /tmp/standings.ejs.b24

echo "==> naming comment authors"
python3 - <<'PY'
import pathlib, re, sys
p = pathlib.Path('views/results.ejs')
s = p.read_text()

if 'chatter__who' in s:
    print("    already there, skipping"); sys.exit(0)

# Whatever the indentation, find the line that prints the comment.
pat = re.compile(r'<li class="chatter__line"><%=\s*c\s*%></li>')
if not pat.search(s):
    sys.exit('Could not find the comment line. Paste views/results.ejs and I will look.')

s = pat.sub(
    '<li class="chatter__line">\n'
    '                  <span class="chatter__who"><%= c.author %></span>\n'
    '                  <%= c.body %>\n'
    '                </li>', s, count=1)
p.write_text(s)
print("    done")
PY

echo "==> penalty line on the results page"
python3 - <<'PY'
import pathlib, re, sys
p = pathlib.Path('views/results.ejs')
s = p.read_text()

if 'result__penalty' in s:
    print("    already there, skipping"); sys.exit(0)

pat = re.compile(r'([ \t]*)<p class="result__by">')
m = pat.search(s)
if not m:
    print("    anchor not found, skipping"); sys.exit(0)

indent = m.group(1)
block = (
    f'{indent}<% if (s.penalty) {{ %>\n'
    f'{indent}  <p class="result__penalty">\n'
    f'{indent}    <%= s.raw_points %> earned, <%= s.penalty %> deducted for\n'
    f'{indent}    <%= s.penalty %> unspent vote<%= s.penalty === 1 ? "" : "s" %>\n'
    f'{indent}  </p>\n'
    f'{indent}<% }} %>\n\n'
)
s = s[:m.start()] + block + s[m.start():]
p.write_text(s)
print("    done")
PY

echo "==> deduction on the standings"
python3 - <<'PY'
import pathlib, re, sys
p = pathlib.Path('views/standings.ejs')
s = p.read_text()

if 'league__penalty' in s:
    print("    already there, skipping"); sys.exit(0)

pat = re.compile(r'(<% if \(row\.wins\) \{ %> &middot; <%= row\.wins %> won<% \} %>)')
if not pat.search(s):
    print("    anchor not found, skipping"); sys.exit(0)

s = pat.sub(r'\1\n              <% if (row.total_penalty) { %>'
            r'<span class="league__penalty"> &middot; &minus;<%= row.total_penalty %> unspent</span><% } %>',
            s, count=1)
p.write_text(s)
print("    done")
PY

echo "==> styling"
if grep -q 'chatter__who' public/app.css; then
  echo "    already there, skipping"
else
cat >> public/app.css << 'CSSEOF'

/* Comment authors, shown only once a round is revealed. */
.chatter__who {
  font-family: var(--util);
  font-size: .64rem;
  letter-spacing: .08em;
  text-transform: uppercase;
  color: var(--amber);
  display: block;
  margin-bottom: .15rem;
}

/* Points lost for not spending your ten. */
.result__penalty {
  margin: 0 0 .4rem;
  font-family: var(--util);
  font-size: .66rem;
  letter-spacing: .06em;
  text-transform: uppercase;
  color: var(--amber);
}

.league__penalty { color: var(--amber); }
CSSEOF
  echo "    done"
fi

echo "==> tidying the patch scripts b23 left behind"
rm -f penalty-patch.py view-patch.py

echo "==> syntax check"
if node -e "
  const ejs=require('ejs'), fs=require('fs');
  ['views/results.ejs','views/standings.ejs']
    .forEach(f => ejs.compile(fs.readFileSync(f,'utf8'), { filename: f }));
  console.log('    ok');
"; then
  rm -f /tmp/results.ejs.b24 /tmp/standings.ejs.b24
else
  echo "    FAILED, restoring"
  cp /tmp/results.ejs.b24 views/results.ejs
  cp /tmp/standings.ejs.b24 views/standings.ejs
  exit 1
fi

echo
echo "  pm2 restart hinderhole --update-env"
echo "  git add -A && git commit -m 'Fix comment rendering and penalty display' && git push"
