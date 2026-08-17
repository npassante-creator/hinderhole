#!/usr/bin/env bash
#
# Makes the rest of the clickable things look clickable.
#
#   - drawer summaries ("Or upload an audio file", "Add players",
#     "Enter a song for someone", "Change deadlines or title")
#   - round titles in the commissioner list
#   - inline links inside prose
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

if grep -q 'drawer__summary::before' public/app.css; then
  echo "==> already styled, skipping"
else
echo "==> restyling drawers, deep links, and inline links"
cat >> public/app.css << 'CSSEOF'

/* ---------------------------------------------------------------
   Anything you can click should look like it
   --------------------------------------------------------------- */

/* Drawer summaries were grey words that happened to open something.
   Now they are buttons with a disclosure arrow. */
.drawer { border-top: 1px solid rgba(240, 232, 216, .14); }

.drawer__summary {
  display: inline-flex;
  align-items: center;
  gap: .45rem;
  font-family: var(--util);
  font-size: .68rem;
  letter-spacing: .09em;
  text-transform: uppercase;
  color: var(--stock);
  cursor: pointer;
  padding: .5rem .75rem;
  margin: .85rem 0;
  border: 1px solid rgba(240, 232, 216, .26);
  border-radius: 2px;
  list-style: none;
  transition: background .14s ease, border-color .14s ease;
}

/* Kill the native triangle so ours is the only marker. */
.drawer__summary::-webkit-details-marker { display: none; }
.drawer__summary::marker { content: ''; }

.drawer__summary::before {
  content: '';
  width: 0;
  height: 0;
  border-left: 5px solid currentColor;
  border-top: 4px solid transparent;
  border-bottom: 4px solid transparent;
  transition: transform .16s ease;
  flex: none;
}

.drawer[open] > .drawer__summary::before { transform: rotate(90deg); }

.drawer__summary:hover,
.drawer__summary:focus-visible {
  background: rgba(240, 232, 216, .08);
  border-color: var(--stock);
}

.drawer[open] > .drawer__summary {
  border-color: var(--amber);
  color: var(--amber);
}

/* The comment box on the ballot uses the same pattern. */
.say__summary {
  display: inline-flex;
  align-items: center;
  gap: .4rem;
  padding: .35rem .6rem;
  border: 1px solid rgba(240, 232, 216, .22);
  border-radius: 2px;
  list-style: none;
}

.say__summary::-webkit-details-marker { display: none; }
.say__summary::marker { content: ''; }

.say__summary::before {
  content: '';
  width: 0; height: 0;
  border-left: 5px solid currentColor;
  border-top: 4px solid transparent;
  border-bottom: 4px solid transparent;
  transition: transform .16s ease;
  flex: none;
}

.say[open] > .say__summary::before { transform: rotate(90deg); }
.say[open] > .say__summary { color: var(--amber); border-color: var(--amber); }

/* Round titles in the commissioner list open the round sheet. */
.strip__deep {
  color: inherit;
  text-decoration: underline;
  text-decoration-color: rgba(30, 24, 28, .3);
  text-underline-offset: 3px;
  text-decoration-thickness: 1px;
}

.strip__deep:hover {
  text-decoration-color: currentColor;
}

/* Links sitting inside sentences, on the dark panel. */
.panel .fineprint a,
.panel .strip--message a,
.panel .notice a,
.player__fallback a,
.card__mine a {
  color: var(--amber);
  text-decoration: underline;
  text-underline-offset: 2px;
  text-decoration-thickness: 1px;
}

.panel .fineprint a:hover,
.panel .strip--message a:hover,
.panel .notice a:hover,
.player__fallback a:hover,
.card__mine a:hover {
  color: var(--stock);
}

/* On the cream strips the same links need dark ink. */
.strip--message a { color: var(--oxblood); }
.strip--message a:hover { color: var(--ink); }
CSSEOF
  echo "    done"
fi

echo "==> syntax check"
node --check public/player.js >/dev/null && echo "    ok"

echo
echo "Restart, then commit:"
echo
echo '  pm2 restart hinderhole --update-env'
echo '  git add -A && git commit -m "Drawers and inline links read as controls" && git push'
