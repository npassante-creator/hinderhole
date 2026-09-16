#!/usr/bin/env python3
"""Applies the unspent-points penalty and names comment authors at reveal."""
import pathlib, sys

# ---------------------------------------------------------------
# results.js: comment authors, and the penalty on the round page
# ---------------------------------------------------------------
p = pathlib.Path('results.js')
s = p.read_text()
did = []

# Comments gain a name. This query only ever runs on a revealed round,
# so naming here is reveal-only by construction.
old_c = """      const { rows: comments } = await db.query(
        `select submission_id, body from comments
          where round_id = $1
          order by created_at`,
        [round.id]
      );"""
new_c = """      const { rows: comments } = await db.query(
        `select c.submission_id, c.body, p.name as author
           from comments c
           join players p on p.id = c.author_id
          where c.round_id = $1
          order by c.created_at`,
        [round.id]
      );"""

if 'as author' in s:
    did.append('comments already named')
elif old_c in s:
    s = s.replace(old_c, new_c, 1)
    s = s.replace(
        """      const bySong = new Map();
      comments.forEach((c) => {
        if (!bySong.has(c.submission_id)) bySong.set(c.submission_id, []);
        bySong.get(c.submission_id).push(c.body);
      });""",
        """      const bySong = new Map();
      comments.forEach((c) => {
        if (!bySong.has(c.submission_id)) bySong.set(c.submission_id, []);
        bySong.get(c.submission_id).push({ body: c.body, author: c.author });
      });"""
    )
    did.append('comment authors')
else:
    sys.exit('results.js: could not find the comments query.')

# The penalty, applied to the round results.
if 'penalties' not in s:
    anchor = """      const { rows: turnout } = await db.query("""
    if anchor not in s:
        sys.exit('results.js: could not find the turnout query.')

    s = s.replace(anchor, """      // Points left unspent come off that player's own score.
      const { rows: penaltyRows } = await db.query(
        'select player_id, unspent from v_vote_penalties where round_id = $1',
        [round.id]
      );
      const penaltyBy = new Map(
        penaltyRows.map((x) => [String(x.player_id), x.unspent])
      );

      const { rows: turnout } = await db.query(""", 1)

    # Apply it before ranking, so places reflect the final score.
    s = s.replace(
        """      // Dense ranking, so a tie shares a place and does not eat the next one.
      let place = 0;
      let lastPoints = null;
      const ranked = songs.map((s, i) => {""",
        """      // Apply penalties before ranking, so places reflect final scores.
      songs.forEach((row) => {
        row.penalty = penaltyBy.get(String(row.player_id)) || 0;
        row.raw_points = row.points;
        row.points = row.points - row.penalty;
      });
      songs.sort((a, b) => b.points - a.points ||
                           String(a.title).localeCompare(String(b.title)));

      // Dense ranking, so a tie shares a place and does not eat the next one.
      let place = 0;
      let lastPoints = null;
      const ranked = songs.map((s, i) => {""", 1)
    did.append('round penalties')

p.write_text(s)

# ---------------------------------------------------------------
# stats.js: the season table
# ---------------------------------------------------------------
p = pathlib.Path('results.js')  # standings lives in results.js
s = p.read_text()

if 'total_penalty' not in s:
    old_t = """                coalesce(sum(v.points), 0)::int as points,"""
    if old_t in s:
        s = s.replace(old_t,
            """                coalesce(sum(v.points), 0)::int as points,
                coalesce((select sum(vp.unspent) from v_vote_penalties vp
                           where vp.league_id = $1 and vp.player_id = p.id), 0)::int
                  as total_penalty,""", 1)

        s = s.replace(
            """      let place = 0;
      let last = null;
      const ranked = table.map((row, i) => {
        if (row.points !== last) { place = i + 1; last = row.points; }
        return { ...row, place };
      });""",
            """      // Unspent points come off the season total too.
      table.forEach((row) => {
        row.raw_points = row.points;
        row.points = row.points - (row.total_penalty || 0);
      });
      table.sort((a, b) => b.points - a.points ||
                           String(a.name).localeCompare(String(b.name)));

      let place = 0;
      let last = null;
      const ranked = table.map((row, i) => {
        if (row.points !== last) { place = i + 1; last = row.points; }
        return { ...row, place };
      });""", 1)
        did.append('season penalties')
        p.write_text(s)

print("    " + ", ".join(did))
