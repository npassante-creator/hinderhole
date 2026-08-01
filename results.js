/**
 * results.js
 *
 * The reveal, and the season table.
 *
 * Everything hidden during voting comes out at once: who submitted what,
 * how the points landed, and what people said. Comments stay anonymous
 * even here, because "who dunked on my song" sours a league faster than
 * anything else. The submitter is named; the critic is not.
 */

'use strict';

const express = require('express');
const { requireAuth } = require('./auth');

function router(db) {
  const r = express.Router();

  async function loadRound(req, res, next) {
    try {
      const { rows } = await db.query(
        `select r.*, l.name as league_name, l.points_per_voter
           from rounds r
           join leagues l on l.id = r.league_id
           join memberships m on m.league_id = l.id and m.player_id = $2
          where r.id = $1`,
        [req.params.id, req.player.id]
      );
      if (!rows[0]) {
        return res.status(404).render('error', {
          code: '404',
          headline: 'No such record',
          detail: 'That round is not in the rack.',
        });
      }
      req.round = rows[0];
      next();
    } catch (err) {
      next(err);
    }
  }

  // ---------------------------------------------------------------
  // Round results
  // ---------------------------------------------------------------

  r.get('/round/:id/results', requireAuth, loadRound, async (req, res, next) => {
    try {
      const round = req.round;

      if (round.status !== 'revealed') {
        return res.redirect(
          round.status === 'voting'
            ? `/round/${round.id}/vote`
            : `/round/${round.id}`
        );
      }

      const { rows: songs } = await db.query(
        `select s.id, s.title, s.artist, s.source, s.source_url,
                s.external_id, s.thumbnail_url, s.note, s.is_late,
                p.name as submitter,
                (s.player_id = $2) as is_mine,
                coalesce(sum(v.points), 0)::int as points,
                count(v.id)::int as backers,
                coalesce(max(case when v.voter_id = $2 then v.points end), 0)::int as my_points
           from submissions s
           join players p on p.id = s.player_id
           left join votes v on v.submission_id = s.id
          where s.round_id = $1
          group by s.id, p.name
          order by coalesce(sum(v.points), 0) desc, s.title`,
        [round.id, req.player.id]
      );

      // Comments are attributed to nobody, on purpose.
      const { rows: comments } = await db.query(
        `select submission_id, body from comments
          where round_id = $1
          order by created_at`,
        [round.id]
      );

      const bySong = new Map();
      comments.forEach((c) => {
        if (!bySong.has(c.submission_id)) bySong.set(c.submission_id, []);
        bySong.get(c.submission_id).push(c.body);
      });

      // Dense ranking, so a tie shares a place and does not eat the next one.
      let place = 0;
      let lastPoints = null;
      const ranked = songs.map((s, i) => {
        if (s.points !== lastPoints) {
          place = i + 1;
          lastPoints = s.points;
        }
        return { ...s, place, comments: bySong.get(s.id) || [] };
      });

      const { rows: turnout } = await db.query(
        `select count(distinct v.voter_id)::int as voted,
                (select count(*)::int from memberships where league_id = $2) as roster,
                coalesce(sum(v.points), 0)::int as cast
           from votes v where v.round_id = $1`,
        [round.id, round.league_id]
      );

      res.render('results', {
        round,
        songs: ranked,
        turnout: turnout[0],
        winner: ranked[0] || null,
      });
    } catch (err) {
      next(err);
    }
  });

  // ---------------------------------------------------------------
  // Season standings
  // ---------------------------------------------------------------

  r.get('/standings', requireAuth, async (req, res, next) => {
    try {
      const { rows: leagues } = await db.query(
        `select l.* from leagues l
           join memberships m on m.league_id = l.id
          where m.player_id = $1
          order by l.created_at desc limit 1`,
        [req.player.id]
      );
      if (!leagues[0]) return res.redirect('/');
      const league = leagues[0];

      // Only revealed rounds count, so the table never leaks a live round.
      const { rows: table } = await db.query(
        `select p.id, p.name,
                coalesce(sum(v.points), 0)::int as points,
                count(distinct s.round_id)::int as rounds_played,
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
        [league.id]
      );

      let place = 0;
      let last = null;
      const ranked = table.map((row, i) => {
        if (row.points !== last) { place = i + 1; last = row.points; }
        return { ...row, place };
      });

      const { rows: rounds } = await db.query(
        `select id, round_number, title, status from rounds
          where league_id = $1 order by round_number`,
        [league.id]
      );

      const payouts = (league.payouts_cents || []).map((c) => c / 100);

      res.render('standings', {
        league,
        table: ranked,
        rounds,
        payouts,
        revealedCount: rounds.filter((x) => x.status === 'revealed').length,
      });
    } catch (err) {
      next(err);
    }
  });

  return r;
}

module.exports = { router };
