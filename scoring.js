/**
 * scoring.js
 *
 * Read-only helpers shared by the home page and the playlists page.
 *
 * roundTables() ranks every revealed round the same way the results page
 * does: votes, minus unspent-vote penalties, plus commissioner
 * adjustments, dense ranked so a tie shares a place.
 *
 * seasonTable() is the standings query, copied from results.js so the
 * home page shows the same numbers as /standings.
 */

'use strict';

async function leagueFor(db, playerId) {
  const { rows } = await db.query(
    `select l.*, m.role
       from leagues l
       join memberships m on m.league_id = l.id
      where m.player_id = $1
      order by l.created_at desc
      limit 1`,
    [playerId]
  );
  return rows[0] || null;
}

/** Map of round id (string) to that round's ranked songs. */
async function roundTables(db, leagueId) {
  const { rows: songs } = await db.query(
    `select s.id, s.round_id, s.player_id, s.title, s.artist, s.source,
            s.source_url, s.external_id, s.thumbnail_url, s.note, s.is_late,
            p.name as submitter,
            coalesce(sum(v.points), 0)::int as points,
            count(v.id)::int as backers
       from submissions s
       join rounds r on r.id = s.round_id
       join players p on p.id = s.player_id
       left join votes v on v.submission_id = s.id
      where r.league_id = $1
        and r.status = 'revealed'
      group by s.id, p.name`,
    [leagueId]
  );

  const { rows: pen } = await db.query(
    `select vp.round_id, vp.player_id, vp.unspent
       from v_vote_penalties vp
       join rounds r on r.id = vp.round_id
      where r.league_id = $1 and r.status = 'revealed'`,
    [leagueId]
  );
  const penBy = new Map(pen.map((x) =>
    [String(x.round_id) + ':' + String(x.player_id), x.unspent || 0]));

  const { rows: adj } = await db.query(
    `select round_id, player_id, sum(points)::int as points
       from adjustments
      where league_id = $1 and round_id is not null
      group by round_id, player_id`,
    [leagueId]
  );
  const adjBy = new Map(adj.map((x) =>
    [String(x.round_id) + ':' + String(x.player_id), x.points || 0]));

  const byRound = new Map();
  songs.forEach((s) => {
    const k = String(s.round_id) + ':' + String(s.player_id);
    s.raw_points = s.points;
    s.points = s.points - (penBy.get(k) || 0) + (adjBy.get(k) || 0);
    const rk = String(s.round_id);
    if (!byRound.has(rk)) byRound.set(rk, []);
    byRound.get(rk).push(s);
  });

  byRound.forEach((list) => {
    list.sort((a, b) => b.points - a.points ||
                        String(a.title).localeCompare(String(b.title)));
    let place = 0;
    let last = null;
    list.forEach((s, i) => {
      if (s.points !== last) { place = i + 1; last = s.points; }
      s.place = place;
      s.of = list.length;
    });
  });

  return byRound;
}

/** Same query and arithmetic as GET /standings in results.js. */
async function seasonTable(db, leagueId) {
  const { rows: table } = await db.query(
    `select p.id, p.name,
            coalesce(sum(v.points), 0)::int as points,
            count(distinct s.round_id)::int as rounds_played,
            coalesce((select sum(a.points) from adjustments a
                       where a.league_id = $1
                         and a.player_id = p.id), 0)::int as total_adjustment,
            count(distinct case when r.status = 'revealed'
                                and w.submission_id is not null
                           then s.round_id end)::int as wins
       from memberships m
       join players p on p.id = m.player_id
       left join submissions s on s.player_id = p.id
       left join rounds r on r.id = s.round_id
                         and r.league_id = m.league_id
                         and r.status = 'revealed'
       left join votes v on v.submission_id = s.id and r.id is not null
       left join lateral (
         select s2.id as submission_id
           from submissions s2
           left join votes v2 on v2.submission_id = s2.id
          where s2.round_id = s.round_id
          group by s2.id
          order by coalesce(sum(v2.points), 0) desc
          limit 1
       ) w on w.submission_id = s.id
      where m.league_id = $1
      group by p.id, p.name
      order by points desc, p.name`,
    [leagueId]
  );

  table.forEach((row) => {
    row.raw_points = row.points;
    row.points = row.points - (row.total_penalty || 0)
                            + (row.total_adjustment || 0);
  });
  table.sort((a, b) => b.points - a.points ||
                       String(a.name).localeCompare(String(b.name)));

  let place = 0;
  let last = null;
  return table.map((row, i) => {
    if (row.points !== last) { place = i + 1; last = row.points; }
    return { ...row, place };
  });
}

function ordinal(n) {
  const v = n % 100;
  if (v >= 11 && v <= 13) return n + 'th';
  return n + ({ 1: 'st', 2: 'nd', 3: 'rd' }[n % 10] || 'th');
}

module.exports = { leagueFor, roundTables, seasonTable, ordinal };
