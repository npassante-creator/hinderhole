#!/usr/bin/env bash
#
# Makes the header links read as buttons instead of a row of grey words,
# and marks the page you are on.
#
set -euo pipefail
cd /var/www/hinderhole

if [ ! -f public/app.css ]; then
  echo "Not in the app directory."
  exit 1
fi

echo "==> checking git is clean"
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "You have uncommitted changes. Commit them first."
  git status --short
  exit 1
fi

echo "==> restyling the header"
if grep -q 'bar__back.is-here' public/app.css; then
  echo "    already there, skipping"
else
cat >> public/app.css << 'CSSEOF'

/* ---------------------------------------------------------------
   Header navigation
   ---------------------------------------------------------------
   Five links in a row of identical grey words is a wall. These read as
   buttons, wrap on a phone, and the current page is filled in so you can
   see where you are without reading the URL. */

.bar {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: .4rem;
  padding: .75rem 0;
  margin-bottom: .5rem;
  border-bottom: 1px solid rgba(240, 232, 216, .12);
}

.bar__back {
  font-family: var(--util);
  font-size: .66rem;
  letter-spacing: .09em;
  text-transform: uppercase;
  text-decoration: none;
  color: var(--steel);
  padding: .38rem .62rem;
  border: 1px solid rgba(240, 232, 216, .2);
  border-radius: 2px;
  background: transparent;
  white-space: nowrap;
  transition: color .14s ease, border-color .14s ease, background .14s ease;
}

.bar__back:hover,
.bar__back:focus-visible {
  color: var(--stock);
  border-color: var(--stock);
  background: rgba(240, 232, 216, .06);
}

/* The page you are on. */
.bar__back.is-here {
  color: var(--field);
  background: var(--amber);
  border-color: var(--amber);
}

.bar__back.is-here:hover { color: var(--field); }

/* Commissioner is a different kind of place, so it looks like one. */
.bar__admin {
  font-family: var(--util);
  font-size: .66rem;
  letter-spacing: .09em;
  text-transform: uppercase;
  text-decoration: none;
  color: #d98a92;
  padding: .38rem .62rem;
  border: 1px solid rgba(107, 32, 41, .85);
  border-radius: 2px;
  white-space: nowrap;
  margin-left: 0;
  transition: color .14s ease, background .14s ease;
}

.bar__admin:hover,
.bar__admin:focus-visible {
  background: var(--oxblood);
  color: var(--stock);
  border-color: var(--oxblood);
}

.bar__admin.is-here {
  background: var(--oxblood);
  color: var(--stock);
  border-color: var(--oxblood);
}

/* Your own name is a label, not a control. Pushed to the far end. */
.bar__name {
  font-family: var(--util);
  font-size: .66rem;
  letter-spacing: .09em;
  text-transform: uppercase;
  color: var(--steel);
  margin-left: auto;
  padding-left: .5rem;
  white-space: nowrap;
}

@media (max-width: 30rem) {
  .bar { gap: .3rem; }
  .bar__back,
  .bar__admin { font-size: .6rem; padding: .34rem .5rem; }
  .bar__name { width: 100%; margin-left: 0; padding: .2rem 0 0; }
}
CSSEOF
  echo "    done"
fi

echo "==> marking the current page"
python3 - <<'PY'
import pathlib
p = pathlib.Path('public/player.js')
s = p.read_text()

if 'is-here' in s:
    print("    already there, skipping")
else:
    s += """

/* Fill in whichever header link points at the page you are on. Done here
   rather than server side so every view gets it without being touched. */
(function () {
  'use strict';
  var here = location.pathname.replace(/\\/+$/, '') || '/';
  document.querySelectorAll('.bar__back, .bar__admin').forEach(function (a) {
    var href = (a.getAttribute('href') || '').replace(/\\/+$/, '') || '/';
    if (href === here) a.classList.add('is-here');
  });
}());
"""
    p.write_text(s)
    print("    done")
PY

echo "==> syntax check"
node --check public/player.js && echo "    ok  public/player.js"

echo
echo "Restart, then commit:"
echo
echo '  pm2 restart hinderhole --update-env'
echo '  git add -A && git commit -m "Header links read as buttons" && git push'
