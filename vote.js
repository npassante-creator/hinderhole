/**
 * vote.js
 *
 * The voting page. Twenty songs, ten points, a five day window, and nobody
 * doing it in one sitting. Three things follow from that:
 *
 *   1. Allocations save as you go, one fetch per change, no submit button
 *      to forget. Close the tab and your points are already banked.
 *   2. Songs are shuffled per voter, deterministically, so everyone does
 *      not hear them in the same order but any one person sees a stable
 *      order across visits.
 *   3. Your own song is shown but cannot be voted on, since hiding it
 *      would make it obvious which one was yours.
 *
 * Anonymity is enforced by never selecting submitter identity before the
 * round is revealed, not by hiding it in the template.
 */

'use strict';

const express = require('express');
const crypto = require('crypto');
const { requireAuth } = require('./auth');

const CT = 'America/Chicago';

function formatDeadline(date) {
  if (!date) return null;
  return new Intl.DateTimeFormat('en-US', {
    timeZone: CT,
    weekday: 'short',
    month: 'short',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
  }).format(date) + ' CT';
}

/**
 * Stable per-voter shuffle. Same voter always sees the same order for a
 * given round; different voters see different orders.
 */
function shuffleFor(rows, seed) {
  return rows
    .map((row) => ({
      row,
      key: crypto.createHash('sha256')
        .update(`${seed}:${row.id}`).digest('hex'),
    }))
    .sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0))
    .map((x) => x.row);
}

function router(db) {
  const r = express.Router();
  const json = express.json();

  async function loadRound(req, res, next) {
    try {
      const { rows } = await db.query(
        `select r.*, l.name as league_name, l.points_per_voter, l.max_per_song
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

  async function canVote(roundId, playerId) {
    const { rows } = await db.query(
      'select can_vote($1, $2) as ok', [roundId, playerId]
    );
    return rows[0].ok;
  }

  // ---------------------------------------------------------------
  // The page
  // ---------------------------------------------------------------

  r.get('/round/:id/vote', requireAuth, loadRound, async (req, res, next) => {
    try {
      const round = req.round;

      if (round.status !== 'voting') {
        return res.redirect(`/round/${round.id}`);
      }

      const eligible = await canVote(round.id, req.player.id);

      // Submitter identity is deliberately absent from this query.
      const { rows: songs } = await db.query(
        `select s.id, s.title, s.artist, s.source, s.source_url,
                s.external_id, s.thumbnail_url, s.duration_s,
                (s.player_id = $2) as is_mine,
                coalesce(v.points, 0) as my_points,
                c.body as my_comment
           from submissions s
           left join votes v
                  on v.submission_id = s.id and v.voter_id = $2
           left join comments c
                  on c.submission_id = s.id and c.author_id = $2
          where s.round_id = $1`,
        [round.id, req.player.id]
      );

      const ordered = shuffleFor(songs, `${req.player.id}:${round.id}`);
      const spent = songs.reduce((n, s) => n + Number(s.my_points), 0);

      res.render('vote', {
        round,
        songs: ordered,
        budget: round.points_per_voter,
        maxPerSong: round.max_per_song,
        spent,
        eligible,
        voteBy: formatDeadline(round.vote_deadline),
        votableCount: songs.filter((s) => !s.is_mine).length,
      });
    } catch (err) {
      next(err);
    }
  });

  // ---------------------------------------------------------------
  // Allocation, saved as it changes
  // ---------------------------------------------------------------

  r.post('/round/:id/vote', requireAuth, loadRound, json, async (req, res, next) => {
    const client = await db.connect();
    try {
      const round = req.round;
      if (round.status !== 'voting') {
        return res.status(409).json({ error: 'Voting is closed for this round.' });
      }
      if (!(await canVote(round.id, req.player.id))) {
        return res.status(403).json({
          error: 'You are not eligible to vote in this round.',
        });
      }

      const submissionId = Number(req.body.submission_id);
      const points = Number(req.body.points);

      if (!Number.isInteger(submissionId) || !Number.isInteger(points) ||
          points < 0 || points > round.max_per_song) {
        return res.status(400).json({ error: 'That is not a valid allocation.' });
      }

      await client.query('begin');

      // Lock this voter's rows so two tabs cannot both pass the budget check.
      const { rows: current } = await client.query(
        `select v.submission_id, v.points
           from votes v
          where v.round_id = $1 and v.voter_id = $2
          for update`,
        [round.id, req.player.id]
      );

      const others = current
        .filter((v) => v.submission_id !== submissionId)
        .reduce((n, v) => n + v.points, 0);

      if (others + points > round.points_per_voter) {
        await client.query('rollback');
        return res.status(409).json({
          error: `That would put you over ${round.points_per_voter} points.`,
          spent: others,
        });
      }

      if (points === 0) {
        await client.query(
          'delete from votes where round_id = $1 and voter_id = $2 and submission_id = $3',
          [round.id, req.player.id, submissionId]
        );
      } else {
        await client.query(
          `insert into votes (round_id, voter_id, submission_id, points)
           values ($1,$2,$3,$4)
           on conflict (round_id, voter_id, submission_id)
           do update set points = excluded.points`,
          [round.id, req.player.id, submissionId, points]
        );
      }

      await client.query('commit');
      res.json({ ok: true, spent: others + points, points });
    } catch (err) {
      await client.query('rollback').catch(() => {});
      // The database triggers carry the real rules. Surface their message.
      if (err.code === 'P0001') {
        return res.status(409).json({ error: err.message });
      }
      next(err);
    } finally {
      client.release();
    }
  });

  // ---------------------------------------------------------------
  // Comments, independent of points
  // ---------------------------------------------------------------

  r.post('/round/:id/comment', requireAuth, loadRound, json, async (req, res, next) => {
    try {
      const round = req.round;
      if (!['voting', 'revealed'].includes(round.status)) {
        return res.status(409).json({ error: 'Comments are closed.' });
      }

      const submissionId = Number(req.body.submission_id);
      const body = String(req.body.body || '').trim();

      if (!Number.isInteger(submissionId)) {
        return res.status(400).json({ error: 'Unknown song.' });
      }

      if (!body) {
        await db.query(
          'delete from comments where submission_id = $1 and author_id = $2',
          [submissionId, req.player.id]
        );
        return res.json({ ok: true, body: '' });
      }

      await db.query(
        `insert into comments (round_id, submission_id, author_id, body)
         values ($1,$2,$3,$4)
         on conflict (submission_id, author_id)
         do update set body = excluded.body, updated_at = now()`,
        [round.id, submissionId, req.player.id, body.slice(0, 2000)]
      );

      res.json({ ok: true, body });
    } catch (err) {
      if (err.code === 'P0001') {
        return res.status(409).json({ error: err.message });
      }
      next(err);
    }
  });

  return r;
}

module.exports = { router };
