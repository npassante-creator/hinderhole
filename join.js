/**
 * join.js
 *
 * Self signup by invite link. Two routes, no auth required.
 *
 * The security model: the code is unguessable and rotatable, and joining
 * only creates a roster row. Actual access still comes from clicking a
 * magic link sent to the address they typed, so someone cannot join as
 * somebody else's email and get in.
 */

'use strict';

const express = require('express');
const { requestLoginLink } = require('./auth');

function router(db) {
  const r = express.Router();
  const form = express.urlencoded({ extended: false });

  async function loadLeague(code) {
    const { rows } = await db.query(
      `select id, name, invite_code, invites_open
         from leagues where invite_code = $1`,
      [String(code || '').toLowerCase().trim()]
    );
    return rows[0] || null;
  }

  r.get('/join/:code', async (req, res, next) => {
    try {
      const league = await loadLeague(req.params.code);
      if (!league || !league.invites_open) {
        return res.status(404).render('error', {
          code: '404',
          headline: 'No such record',
          detail: 'That invite link is closed or was never a link at all.',
        });
      }
      res.render('join', { league, error: null, values: {} });
    } catch (err) {
      next(err);
    }
  });

  r.post('/join/:code', form, async (req, res, next) => {
    try {
      const league = await loadLeague(req.params.code);
      if (!league || !league.invites_open) {
        return res.status(404).render('error', {
          code: '404',
          headline: 'No such record',
          detail: 'That invite link is closed.',
        });
      }

      const name = String(req.body.name || '').trim();
      const email = String(req.body.email || '').trim().toLowerCase();
      const values = { name, email };

      if (name.length < 2) {
        return res.render('join', {
          league, values, error: 'Put in the name you want the group to see.',
        });
      }
      if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
        return res.render('join', {
          league, values, error: 'That does not look like an email address.',
        });
      }

      // Existing player keeps their name unless they are new.
      const { rows } = await db.query(
        `insert into players (name, email) values ($1, $2)
         on conflict (email) do update set name = players.name
         returning id`,
        [name, email]
      );
      const playerId = rows[0].id;

      await db.query(
        `insert into memberships (league_id, player_id, role, joined_via)
         values ($1, $2, 'player', 'invite')
         on conflict (league_id, player_id) do nothing`,
        [league.id, playerId]
      );

      await db.query(
        `insert into admin_actions (league_id, actor_id, action, detail)
         values ($1, $2, 'self_join', $3)`,
        [league.id, playerId, `${name} joined by invite link`]
      );

      // Send them straight in. requestLoginLink re-checks membership, so
      // this only works because the row above now exists.
      await requestLoginLink(db, email, { ip: req.ip });

      res.render('check-email', { email });
    } catch (err) {
      next(err);
    }
  });

  return r;
}

module.exports = { router };
