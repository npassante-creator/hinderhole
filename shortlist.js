/**
 * shortlist.js
 *
 * Saved candidates for rounds that have not opened yet.
 *
 * Private, always. Every query here filters on the owner, and nothing
 * joins shortlist into anything anyone else can see. A leaked shortlist
 * would give away someone's pick weeks early, which is worse than not
 * having the feature.
 *
 * Promoting a candidate copies it into submissions rather than moving it,
 * so a song you used still sits in your list if you change your mind
 * before the deadline.
 */

'use strict';

const express = require('express');
const { resolve, UnsupportedSourceError } = require('./resolver');
const { requireAuth } = require('./auth');

const MAX_PER_ROUND = 12;

function router(db) {
  const r = express.Router();
  const form = express.urlencoded({ extended: false });

  /** The round must exist and belong to a league the player is in. */
  async function loadRound(req, res, next) {
    try {
      const { rows } = await db.query(
        `select r.*, l.id as league_id
           from rounds r
           join leagues l on l.id = r.league_id
           join memberships m on m.league_id = l.id and m.player_id = $2
          where r.id = $1`,
        [req.params.roundId, req.player.id]
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

  function back(req, roundId, params) {
    // Come back to wherever they were: the season page or the round page.
    const from = String(req.body.from || '');
    const base = from === 'round' ? `/round/${roundId}` : '/upcoming';
    return base + (params ? (base.includes('?') ? '&' : '?') + params : '');
  }

  // ---------------------------------------------------------------
  // Saving one
  // ---------------------------------------------------------------

  r.post('/shortlist/:roundId', requireAuth, loadRound, form,
    async (req, res, next) => {
      try {
        if (req.round.status === 'revealed') {
          return res.redirect(back(req, req.round.id,
            'err=' + encodeURIComponent('That round is over.')));
        }

        const url = String(req.body.url || '').trim();
        if (!url) {
          return res.redirect(back(req, req.round.id,
            'err=' + encodeURIComponent('Paste a link first.')));
        }

        const { rows: count } = await db.query(
          `select count(*)::int as n from shortlist
            where round_id = $1 and player_id = $2`,
          [req.round.id, req.player.id]
        );
        if (count[0].n >= MAX_PER_ROUND) {
          return res.redirect(back(req, req.round.id,
            'err=' + encodeURIComponent(
              `That is ${MAX_PER_ROUND} already. Clear one out first.`)));
        }

        let track;
        try {
          track = await resolve(url);
        } catch (err) {
          const msg = err instanceof UnsupportedSourceError
            ? err.message
            : 'Could not read that link.';
          return res.redirect(back(req, req.round.id,
            'err=' + encodeURIComponent(msg)));
        }

        try {
          await db.query(
            `insert into shortlist
               (round_id, player_id, source, source_url, external_id,
                title, artist, thumbnail_url, duration_s, note)
             values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`,
            [req.round.id, req.player.id, track.source, track.source_url,
             track.external_id, track.title, track.artist,
             track.thumbnail_url, track.duration_s,
             String(req.body.note || '').trim() || null]
          );
        } catch (err) {
          if (err.code === '23505') {
            return res.redirect(back(req, req.round.id,
              'err=' + encodeURIComponent('That one is already on your list.')));
          }
          throw err;
        }

        res.redirect(back(req, req.round.id,
          'ok=' + encodeURIComponent('Saved for later.')));
      } catch (err) {
        next(err);
      }
    });

  // ---------------------------------------------------------------
  // Removing one
  // ---------------------------------------------------------------

  r.post('/shortlist/item/:id/remove', requireAuth, form,
    async (req, res, next) => {
      try {
        const { rows } = await db.query(
          `delete from shortlist
            where id = $1 and player_id = $2
          returning round_id`,
          [req.params.id, req.player.id]
        );
        const roundId = rows[0] ? rows[0].round_id : 0;
        res.redirect(back(req, roundId, 'ok=' + encodeURIComponent('Removed.')));
      } catch (err) {
        next(err);
      }
    });

  // ---------------------------------------------------------------
  // Promoting one to the actual submission
  // ---------------------------------------------------------------

  r.post('/shortlist/item/:id/use', requireAuth, form,
    async (req, res, next) => {
      try {
        const { rows } = await db.query(
          `select s.*, r.status, r.submit_deadline
             from shortlist s
             join rounds r on r.id = s.round_id
            where s.id = $1 and s.player_id = $2`,
          [req.params.id, req.player.id]
        );
        const pick = rows[0];
        if (!pick) return res.redirect('/upcoming');

        if (pick.status !== 'submitting') {
          return res.redirect(back(req, pick.round_id, 'err=' +
            encodeURIComponent(pick.status === 'draft'
              ? 'That round has not opened yet.'
              : 'Submissions for that round are closed.')));
        }

        const late = Boolean(pick.submit_deadline &&
          Date.now() > pick.submit_deadline.getTime());

        await db.query(
          `insert into submissions
             (round_id, player_id, source, source_url, external_id,
              title, artist, thumbnail_url, duration_s, note, is_late)
           values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
           on conflict (round_id, player_id) do update set
             source = excluded.source, source_url = excluded.source_url,
             external_id = excluded.external_id, title = excluded.title,
             artist = excluded.artist, thumbnail_url = excluded.thumbnail_url,
             duration_s = excluded.duration_s, note = excluded.note,
             submitted_at = now(), is_late = excluded.is_late`,
          [pick.round_id, req.player.id, pick.source, pick.source_url,
           pick.external_id, pick.title, pick.artist, pick.thumbnail_url,
           pick.duration_s, pick.note, late]
        );

        // Deliberately left on the shortlist. Changing your mind back is
        // the whole point of having kept a list.
        res.redirect(`/round/${pick.round_id}?saved=1`);
      } catch (err) {
        next(err);
      }
    });

  return r;
}

/** Used by the season page and the round page. Owner only, always. */
async function forPlayer(db, playerId, roundIds) {
  if (!roundIds || !roundIds.length) return new Map();
  const { rows } = await db.query(
    `select * from shortlist
      where player_id = $1 and round_id = any($2::bigint[])
      order by created_at`,
    [playerId, roundIds]
  );
  const byRound = new Map();
  rows.forEach((x) => {
    if (!byRound.has(String(x.round_id))) byRound.set(String(x.round_id), []);
    byRound.get(String(x.round_id)).push(x);
  });
  return byRound;
}

module.exports = { router, forPlayer, MAX_PER_ROUND };
