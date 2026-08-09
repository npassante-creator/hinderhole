/**
 * rounds.js
 *
 * Round detail plus the submission flow.
 *
 * Submitting is an upsert: a player has at most one song per round and can
 * replace it freely until the deadline. Past the deadline the row is stamped
 * is_late, which is what blocks that player from voting later unless an
 * admin grants a waiver.
 */

'use strict';

const express = require('express');
const { resolve, UnsupportedSourceError } = require('./resolver');
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

function router(db) {
  const r = express.Router();
  const form = express.urlencoded({ extended: false });

  /**
   * Loads the round and proves the signed in player belongs to its league.
   * A player who is not a member gets a 404 rather than a 403, so the app
   * does not confirm that a league they cannot see exists.
   */
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

  function isPastDeadline(round) {
    return Boolean(
      round.submit_deadline && Date.now() > round.submit_deadline.getTime()
    );
  }

  async function getSubmission(roundId, playerId) {
    const { rows } = await db.query(
      'select * from submissions where round_id = $1 and player_id = $2',
      [roundId, playerId]
    );
    return rows[0] || null;
  }

  async function renderRound(req, res, extra = {}) {
    const submission = await getSubmission(req.round.id, req.player.id);

    // Ten weeks of obscure music across eighteen people. Somebody will
    // resubmit something. Warn, never block: a reprise might be the joke.
    let echo = [];
    if (submission && submission.external_id) {
      const { rows } = await db.query(
        'select * from song_seen_before($1, $2, $3)',
        [req.round.league_id, submission.external_id, req.round.id]
      );
      echo = rows;
    }

    const { rows: counts } = await db.query(
      `select count(*)::int as submitted,
              (select count(*)::int from memberships where league_id = $2) as roster
         from submissions where round_id = $1`,
      [req.round.id, req.round.league_id]
    );

    res.render('round', {
      round: req.round,
      submission,
      echo,
      submitBy: formatDeadline(req.round.submit_deadline),
      voteBy: formatDeadline(req.round.vote_deadline),
      pastDeadline: isPastDeadline(req.round),
      counts: counts[0],
      error: null,
      notice: null,
      ...extra,
    });
  }

  // ---------------------------------------------------------------

  r.get('/round/:id', requireAuth, loadRound, async (req, res, next) => {
    try {
      await renderRound(req, res, { notice: req.query.saved ? 'Song saved.' : null });
    } catch (err) {
      next(err);
    }
  });

  r.post('/round/:id/submit', requireAuth, loadRound, form, async (req, res, next) => {
    try {
      if (req.round.status === 'draft') {
        return renderRound(req, res, {
          error: 'This round is not open yet.',
        });
      }
      if (req.round.status !== 'submitting') {
        return renderRound(req, res, {
          error: 'Submissions for this round are closed.',
        });
      }

      const url = String(req.body.url || '').trim();
      if (!url) {
        return renderRound(req, res, { error: 'Paste a link first.' });
      }

      let track;
      try {
        track = await resolve(url);
      } catch (err) {
        if (err instanceof UnsupportedSourceError) {
          return renderRound(req, res, { error: err.message });
        }
        // A dead link or a private video lands here.
        return renderRound(req, res, {
          error:
            'Could not read that link. Check that the video is public and ' +
            'try again.',
        });
      }

      const late = isPastDeadline(req.round);

      await db.query(
        `insert into submissions
           (round_id, player_id, source, source_url, external_id,
            title, artist, thumbnail_url, duration_s, note, is_late)
         values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
         on conflict (round_id, player_id) do update set
           source        = excluded.source,
           source_url    = excluded.source_url,
           external_id   = excluded.external_id,
           title         = excluded.title,
           artist        = excluded.artist,
           thumbnail_url = excluded.thumbnail_url,
           duration_s    = excluded.duration_s,
           submitted_at  = now(),
           is_late       = excluded.is_late`,
        [
          req.round.id,
          req.player.id,
          track.source,
          track.source_url,
          track.external_id,
          track.title,
          track.artist,
          track.thumbnail_url,
          track.duration_s,
          String(req.body.note || '').trim() || null,
          late,
        ]
      );

      res.redirect(`/round/${req.round.id}?saved=1`);
    } catch (err) {
      next(err);
    }
  });

  /** Correct the title and artist the resolver guessed. */
  r.post('/round/:id/details', requireAuth, loadRound, form, async (req, res, next) => {
    try {
      if (req.round.status !== 'submitting') {
        return renderRound(req, res, {
          error: 'Submissions for this round are closed.',
        });
      }

      const title = String(req.body.title || '').trim();
      if (!title) {
        return renderRound(req, res, { error: 'Title cannot be empty.' });
      }

      await db.query(
        `update submissions
            set title = $3, artist = $4, note = $5
          where round_id = $1 and player_id = $2`,
        [
          req.round.id,
          req.player.id,
          title,
          String(req.body.artist || '').trim() || null,
          String(req.body.note || '').trim() || null,
        ]
      );

      res.redirect(`/round/${req.round.id}?saved=1`);
    } catch (err) {
      next(err);
    }
  });

  r.post('/round/:id/withdraw', requireAuth, loadRound, form, async (req, res, next) => {
    try {
      if (req.round.status !== 'submitting') {
        return renderRound(req, res, {
          error: 'Submissions for this round are closed.',
        });
      }
      await db.query(
        'delete from submissions where round_id = $1 and player_id = $2',
        [req.round.id, req.player.id]
      );
      res.redirect(`/round/${req.round.id}`);
    } catch (err) {
      next(err);
    }
  });

  return r;
}

module.exports = { router, formatDeadline };
