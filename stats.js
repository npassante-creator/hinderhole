/**
 * stats.js
 *
 * Three read-only pages that need no schema of their own, because the
 * interesting things are already sitting in the votes table.
 *
 *   /me         every song you have submitted, and how it did
 *   /stats      the season's social data, the stuff people argue about
 *   /upcoming   what is coming, so people can plan
 *
 * Everything here counts revealed rounds only. A live round leaking into
 * a stats page would undo what the ballot is careful about.
 */

'use strict';

const express = require('express');
const { requireAuth } = require('./auth');

const CT = 'America/Chicago';

function fmtDate(d) {
  if (!d) return null;
  return new Intl.DateTimeFormat('en-US', {
    timeZone: CT, weekday: 'short', month: 'short', day: 'numeric',
  }).format(d);
}

function router(db) {
  const r = express.Router();

  async function league(playerId) {
    const { rows } = await db.query(
      `select l.* from leagues l
         join memberships m on m.league_id = l.id
        where m.player_id = $1
        order by l.created_at desc limit 1`,
      [playerId]
    );
    return rows[0] || null;
  }

  // ---------------------------------------------------------------
  // Your own picks
  // ---------------------------------------------------------------

  r.get('/me', requireAuth, async (req, res, next) => {
    try {
      const lg = await league(req.player.id);
      if (!lg) return res.redirect('/');

      const { rows: picks } = await db.query(
        `select r.id as round_id, r.round_number, r.title as category,
                r.status,
                s.id, s.title, s.artist, s.source, s.source_url,
                s.external_id, s.thumbnail_url, s.note, s.is_late,
                case when r.status = 'revealed'
                     then coalesce(sum(v.points), 0)::int end as points,
                case when r.status = 'revealed'
                     then count(v.id)::int end as backers
           from rounds r
           left join submissions s
                  on s.round_id = r.id and s.player_id = $2
           left join votes v on v.submission_id = s.id
          where r.league_id = $1 and r.status <> 'draft'
          group by r.id, s.id
          order by r.round_number`,
        [lg.id, req.player.id]
      );

      // Where each of your songs placed, among revealed rounds only.
      const { rows: places } = await db.query(
        `select s.id,
                rank() over (partition by s.round_id
                             order by coalesce(v.total, 0) desc) as place,
                (select count(*) from submissions s2
                  where s2.round_id = s.round_id) as field
           from submissions s
           join rounds r on r.id = s.round_id and r.status = 'revealed'
           left join lateral (
             select sum(points) as total from votes
              where submission_id = s.id
           ) v on true
          where r.league_id = $1`,
        [lg.id]
      );
      const placeById = new Map(places.map((p) => [String(p.id), p]));

      const scored = picks.filter((p) => p.points !== null);
      const total = scored.reduce((n, p) => n + p.points, 0);
      const wins = scored.filter((p) => {
        const pl = placeById.get(String(p.id));
        return pl && Number(pl.place) === 1;
      }).length;

      res.render('me', {
        league: lg,
        picks: picks.map((p) => ({
          ...p,
          place: placeById.get(String(p.id)) || null,
        })),
        total,
        wins,
        played: scored.length,
        missed: picks.filter((p) => !p.id && p.status !== 'submitting').length,
        best: scored.slice().sort((a, b) => b.points - a.points)[0] || null,
      });
    } catch (err) {
      next(err);
    }
  });

  // ---------------------------------------------------------------
  // Season stats
  // ---------------------------------------------------------------

  r.get('/stats', requireAuth, async (req, res, next) => {
    try {
      const lg = await league(req.player.id);
      if (!lg) return res.redirect('/');

      const { rows: revealed } = await db.query(
        `select count(*)::int as n from rounds
          where league_id = $1 and status = 'revealed'`,
        [lg.id]
      );
      const rounds = revealed[0].n;

      if (!rounds) {
        return res.render('stats', {
          league: lg, rounds: 0, biggest: null, generous: [],
          divisive: [], pairs: [], maxed: [], shutouts: [],
        });
      }

      // Biggest single round score.
      const { rows: biggest } = await db.query(
        `select s.title, s.artist, p.name, r.round_number, r.title as category,
                sum(v.points)::int as points
           from votes v
           join submissions s on s.id = v.submission_id
           join rounds r on r.id = s.round_id and r.status = 'revealed'
           join players p on p.id = s.player_id
          where r.league_id = $1
          group by s.id, s.title, s.artist, p.name, r.round_number, r.title
          order by sum(v.points) desc limit 1`,
        [lg.id]
      );

      // Who spreads their points thin, and who goes all in.
      const { rows: generous } = await db.query(
        `select p.name,
                count(distinct v.round_id)::int as rounds_voted,
                count(v.id)::int as allocations,
                round(count(v.id)::numeric
                      / nullif(count(distinct v.round_id), 0), 1) as per_round,
                max(v.points)::int as biggest_single
           from votes v
           join players p on p.id = v.voter_id
           join rounds r on r.id = v.round_id and r.status = 'revealed'
          where r.league_id = $1
          group by p.id, p.name
          order by per_round desc`,
        [lg.id]
      );

      // Songs that split the room: high total, few backers, or the reverse.
      const { rows: divisive } = await db.query(
        `select s.title, p.name, r.round_number,
                sum(v.points)::int as points,
                count(v.id)::int as backers,
                round(sum(v.points)::numeric / count(v.id), 1) as intensity
           from votes v
           join submissions s on s.id = v.submission_id
           join rounds r on r.id = s.round_id and r.status = 'revealed'
           join players p on p.id = s.player_id
          where r.league_id = $1
          group by s.id, s.title, p.name, r.round_number
         having count(v.id) >= 2
          order by intensity desc limit 5`,
        [lg.id]
      );

      // Who keeps voting for whom. The stat that starts arguments.
      const { rows: pairs } = await db.query(
        `select voter.name as voter, writer.name as submitter,
                sum(v.points)::int as points,
                count(*)::int as times
           from votes v
           join players voter on voter.id = v.voter_id
           join submissions s on s.id = v.submission_id
           join players writer on writer.id = s.player_id
           join rounds r on r.id = s.round_id and r.status = 'revealed'
          where r.league_id = $1
          group by voter.id, voter.name, writer.id, writer.name
         having count(*) >= 2
          order by sum(v.points) desc limit 8`,
        [lg.id]
      );

      // Every time someone put their whole budget on one song.
      const { rows: maxed } = await db.query(
        `select voter.name as voter, s.title, writer.name as submitter,
                r.round_number, v.points
           from votes v
           join players voter on voter.id = v.voter_id
           join submissions s on s.id = v.submission_id
           join players writer on writer.id = s.player_id
           join rounds r on r.id = s.round_id and r.status = 'revealed'
          where r.league_id = $1 and v.points >= $2
          order by r.round_number`,
        [lg.id, lg.points_per_voter]
      );

      // Songs nobody voted for. Somebody has to be told.
      const { rows: shutouts } = await db.query(
        `select s.title, s.artist, p.name, r.round_number, r.title as category
           from submissions s
           join rounds r on r.id = s.round_id and r.status = 'revealed'
           join players p on p.id = s.player_id
           left join votes v on v.submission_id = s.id
          where r.league_id = $1
          group by s.id, s.title, s.artist, p.name, r.round_number, r.title
         having count(v.id) = 0
          order by r.round_number`,
        [lg.id]
      );

      res.render('stats', {
        league: lg, rounds,
        biggest: biggest[0] || null,
        generous, divisive, pairs, maxed, shutouts,
      });
    } catch (err) {
      next(err);
    }
  });

  // ---------------------------------------------------------------
  // What is coming
  // ---------------------------------------------------------------

  r.get('/upcoming', requireAuth, async (req, res, next) => {
    try {
      const lg = await league(req.player.id);
      if (!lg) return res.redirect('/');

      const { rows } = await db.query(
        `select id, round_number, title, description, status,
                submit_deadline, vote_deadline
           from rounds
          where league_id = $1
          order by round_number`,
        [lg.id]
      );

      res.render('upcoming', {
        league: lg,
        rounds: rows.map((x) => ({
          ...x,
          songsDue: fmtDate(x.submit_deadline),
          votesDue: fmtDate(x.vote_deadline),
        })),
      });
    } catch (err) {
      next(err);
    }
  });

  return r;
}

module.exports = { router };
