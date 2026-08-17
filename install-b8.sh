#!/usr/bin/env bash
#
# Three admin fixes:
#
#   1. "Another round is already in that phase" now names the round that is
#      in the way, so you know what to move.
#   2. Submitting can go back to draft. Without it, the only way out of the
#      situation the error describes was raw SQL.
#   3. The audit log records names instead of database ids. "Player 41
#      removed" tells you nothing a week later.
#
set -euo pipefail
cd /var/www/hinderhole

if [ ! -f admin.js ]; then
  echo "Not in the app directory."
  exit 1
fi

echo "==> checking git is clean"
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "You have uncommitted changes. Commit them first."
  git status --short
  exit 1
fi

cp admin.js /tmp/admin.js.before

echo "==> 1. naming the round that is in the way"
python3 - <<'PY'
import pathlib, sys
p = pathlib.Path('admin.js'); s = p.read_text()

if 'blocking' in s:
    print("    already there, skipping"); sys.exit(0)

old = """        } catch (e) {
          // The partial unique indexes allow only one submitting and one
          // voting round per league at a time.
          return res.redirect(
            '/admin?err=' + encodeURIComponent(
              'Another round is already in that phase. Move it along first.')
          );
        }"""

new = """        } catch (e) {
          // The partial unique indexes allow only one submitting and one
          // voting round per league at a time. Say which one is in the way,
          // because "move it along first" is useless against a list of ten.
          const { rows: blocking } = await db.query(
            `select round_number, title from rounds
              where league_id = $1 and status = $2 and id <> $3`,
            [req.league.id, to, req.round.id]
          );
          const who = blocking[0]
            ? `Round ${blocking[0].round_number}, ${blocking[0].title}, is already ${to}. Move that one along first.`
            : 'Another round is already in that phase. Move it along first.';
          return res.redirect('/admin?err=' + encodeURIComponent(who));
        }"""

if old not in s:
    print("    anchor not found, skipping"); sys.exit(0)

s = s.replace(old, new); p.write_text(s); print("    done")
PY

echo "==> 2. allowing submitting to go back to draft"
python3 - <<'PY'
import pathlib, sys
p = pathlib.Path('admin.js'); s = p.read_text()

if "submitting: ['voting', 'draft']" in s:
    print("    already there, skipping"); sys.exit(0)

if "submitting: ['voting']," not in s:
    print("    anchor not found, skipping"); sys.exit(0)

s = s.replace("submitting: ['voting'],",
              "  // Back to draft is how you unblock a round that is holding\n"
              "  // up the one you actually want open.\n"
              "  submitting: ['voting', 'draft'],")

if "draft: 'Close this round'" not in s:
    s = s.replace("const TRANSITION_LABEL = {",
                  "const TRANSITION_LABEL = {\n  draft: 'Close this round',")

p.write_text(s); print("    done")
PY

echo "==> 3. logging names instead of ids"
python3 - <<'PY'
import pathlib
p = pathlib.Path('admin.js'); s = p.read_text()
changed = []

# A small helper, added once.
if 'async function nameOf' not in s and 'async function log(' in s:
    s = s.replace(
        "  async function log(leagueId, actorId, action, detail) {",
        """  /** A name is what you want to read a week later, not a row id. */
  async function nameOf(playerId) {
    const { rows } = await db.query(
      'select name from players where id = $1', [playerId]);
    return rows[0] ? rows[0].name : `player ${playerId}`;
  }

  async function log(leagueId, actorId, action, detail) {"""
    )
    changed.append('helper')

swaps = [
    ("`Round ${req.round.round_number}, player ${playerId}`",
     "`Round ${req.round.round_number}, ${await nameOf(playerId)}`"),
    ("`Round ${req.round.round_number}, player ${playerId}: ${track.title}`",
     "`Round ${req.round.round_number}, ${await nameOf(playerId)}: ${track.title}`"),
    ("`Player ${req.params.playerId} to ${role}`",
     "`${await nameOf(req.params.playerId)} is now ${role}`"),
    ("`Player ${req.params.playerId} removed`",
     "`${await nameOf(req.params.playerId)} removed from the roster`"),
]

for old, new in swaps:
    if old in s:
        s = s.replace(old, new)
        changed.append(old.split('${')[0].strip('`, '))

p.write_text(s)
print("    " + (", ".join(changed) if changed else "nothing to change"))
PY

echo "==> syntax check"
if node --check admin.js; then
  echo "    ok  admin.js"
  rm -f /tmp/admin.js.before
else
  echo "    FAILED, restoring the original"
  cp /tmp/admin.js.before admin.js
  exit 1
fi

echo
echo "Restart, then commit:"
echo
echo '  pm2 restart hinderhole --update-env'
echo '  git add -A && git commit -m "Admin: name blocking rounds, reopen to draft, log names" && git push'
