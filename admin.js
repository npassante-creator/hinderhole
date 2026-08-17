/**
 * admin.js
 *
 * Commissioner tools. Everything here is scoped to a league the signed in
 * player is an admin of, resolved once in requireAdmin rather than trusting
 * a league id from the request.
 *
 * The design goal is that Matt never has to go back to collecting songs by
 * email. That means the admin side has to cover the messy cases: someone
 * emails him a song anyway, someone misses the deadline and asks nicely,
 * someone never pays.
 */

'use strict';

const express = require('express');
const { resolve, UnsupportedSourceError } = require('./resolver');
const { requireAuth, requestLoginLink } = require('./auth');

const CT = 'America/Chicago';

function fmt(date, opts = {}) {
  if (!date) return null;
  return new Intl.DateTimeFormat('en-US', {
    timeZone: CT,
    month: 'short',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
    ...opts,
  }).format(date) + ' CT';
}

/** Legal forward moves, plus the one backward move worth allowing. */
const TRANSITIONS = {
  draft: ['submitting'],
    // Back to draft is how you unblock a round that is holding
  // up the one you actually want open.
  submitting: ['voting', 'draft'],
  voting: ['revealed', 'submitting'],
  // Revealed can be walked back. A mistap should never strand a round.
  revealed: ['voting'],
};

// Quick deadline nudges. Hours for "finish your lunch break", days for
// "somebody is travelling".
const BUMPS = {
  '1h': '1 hour',
  '2h': '2 hours',
  '4h': '4 hours',
  '8h': '8 hours',
  '1d': '1 day',
  '2d': '2 days',
  '3d': '3 days',
  '7d': '1 week',
};

const TRANSITION_LABEL = {
  draft: 'Close this round',
  submitting: 'Open for songs',
  voting: 'Open voting',
  revealed: 'Reveal results',
};

// Moves worth a second tap. Revealing cannot really be undone: once the
// group has seen who submitted what, resetting the row does not unsee it.
const CONFIRM = {
  revealed: 'Reveal this round to everyone? Names and points become visible and that cannot be taken back.',
  voting: 'Open voting? Nobody can change their song after this.',
};

function router(db) {
  const r = express.Router();
  const form = express.urlencoded({ extended: false });

  async function requireAdmin(req, res, next) {
    try {
      const { rows } = await db.query(
        `select l.* from leagues l
           join memberships m on m.league_id = l.id
          where m.player_id = $1 and m.role = 'admin'
          order by l.created_at desc limit 1`,
        [req.player.id]
      );
      if (!rows[0]) {
        return res.status(404).render('error', {
          code: '404',
          headline: 'No such record',
          detail: 'That page is not in the rack.',
        });
      }
      req.league = rows[0];
      next();
    } catch (err) {
      next(err);
    }
  }

  /** A name is what you want to read a week later, not a row id. */
  async function nameOf(playerId) {
    const { rows } = await db.query(
      'select name from players where id = $1', [playerId]);
    return rows[0] ? rows[0].name : `player ${playerId}`;
  }

  async function log(leagueId, actorId, action, detail) {
    await db.query(
      `insert into admin_actions (league_id, actor_id, action, detail)
       values ($1,$2,$3,$4)`,
      [leagueId, actorId, action, detail || null]
    );
  }

  async function loadRound(req, res, next) {
    try {
      const { rows } = await db.query(
        'select * from rounds where id = $1 and league_id = $2',
        [req.params.id, req.league.id]
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
  // Dashboard
  // ---------------------------------------------------------------

  r.get('/admin', requireAuth, requireAdmin, async (req, res, next) => {
    try {
      const { rows: rounds } = await db.query(
        `select r.*,
                (select count(*)::int from submissions s where s.round_id = r.id) as submitted
           from rounds r
          where r.league_id = $1
          order by r.round_number`,
        [req.league.id]
      );

      const { rows: roster } = await db.query(
        `select * from v_roster where league_id = $1 order by role, name`,
        [req.league.id]
      );

      const { rows: recent } = await db.query(
        `select a.action, a.detail, a.created_at, p.name as actor
           from admin_actions a join players p on p.id = a.actor_id
          where a.league_id = $1
          order by a.created_at desc limit 8`,
        [req.league.id]
      );

      res.render('admin', {
        league: req.league,
        rounds: rounds.map((x) => ({
          ...x,
          submitBy: fmt(x.submit_deadline),
          voteBy: fmt(x.vote_deadline),
          moves: (TRANSITIONS[x.status] || []).map((s) => ({
            to: s,
            label: x.status === 'revealed' && s === 'voting'
              ? 'Reopen voting' : (TRANSITION_LABEL[s] || s),
            confirm: CONFIRM[s] || null,
          })),
        })),
        roster,
        recent: recent.map((x) => ({ ...x, when: fmt(x.created_at) })),
        paidCount: roster.filter((p) => p.dues_paid_at).length,
        error: req.query.err || null,
        notice: req.query.ok || null,
      });
    } catch (err) {
      next(err);
    }
  });

  // ---------------------------------------------------------------
  // Round control
  // ---------------------------------------------------------------

  r.post('/admin/round/:id/status', requireAuth, requireAdmin, loadRound, form,
    async (req, res, next) => {
      try {
        const to = String(req.body.status || '');
        const allowed = TRANSITIONS[req.round.status] || [];
        if (!allowed.includes(to)) {
          return res.redirect(
            '/admin?err=' + encodeURIComponent(
              `Cannot move round ${req.round.round_number} from ${req.round.status} to ${to}.`)
          );
        }

        try {
          await db.query('update rounds set status = $2 where id = $1',
            [req.round.id, to]);
        } catch (e) {
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
        }

        await log(req.league.id, req.player.id, 'round_status',
          `Round ${req.round.round_number} ${req.round.status} to ${to}`);
        res.redirect('/admin?ok=' + encodeURIComponent(
          `Round ${req.round.round_number} is now ${to}.`));
      } catch (err) {
        next(err);
      }
    });

  r.post('/admin/round/:id/deadlines', requireAuth, requireAdmin, loadRound, form,
    async (req, res, next) => {
      try {
        // datetime-local sends wall clock time with no zone attached.
        // Postgres interprets it as Central, which is what the league runs on.
        await db.query(
          `update rounds
              set submit_deadline = case when $2 = '' then submit_deadline
                     else ($2 || ':00')::timestamp at time zone 'America/Chicago' end,
                  vote_deadline = case when $3 = '' then vote_deadline
                     else ($3 || ':00')::timestamp at time zone 'America/Chicago' end,
                  title = coalesce(nullif($4, ''), title),
                  -- Empty clears it, which is how you take a caption back off.
                  description = nullif($5, '')
            where id = $1`,
          [
            req.round.id,
            String(req.body.submit_deadline || ''),
            String(req.body.vote_deadline || ''),
            String(req.body.title || ''),
            String(req.body.description || '').trim(),
          ]
        );
        await log(req.league.id, req.player.id, 'round_edit',
          `Round ${req.round.round_number} deadlines or title changed`);
        res.redirect(`/admin/round/${req.round.id}?ok=` +
          encodeURIComponent('Round updated.'));
      } catch (err) {
        next(err);
      }
    });

  // ---------------------------------------------------------------
  // Round detail: who is in, who is missing, extensions
  // ---------------------------------------------------------------

  r.get('/admin/round/:id', requireAuth, requireAdmin, loadRound,
    async (req, res, next) => {
      try {
        const { rows: people } = await db.query(
          `select p.id, p.name, p.email,
                  s.id as submission_id, s.title, s.artist, s.source,
                  s.is_late, s.submitted_at,
                  (w.player_id is not null) as has_waiver
             from memberships m
             join players p on p.id = m.player_id
             left join submissions s
                    on s.player_id = p.id and s.round_id = $1
             left join vote_waivers w
                    on w.player_id = p.id and w.round_id = $1
            where m.league_id = $2
            order by (s.id is null), p.name`,
          [req.round.id, req.league.id]
        );

        res.render('admin-round', {
          league: req.league,
          round: req.round,
          bumps: Object.entries(BUMPS).map(([key, label]) => ({ key, label })),
          people: people.map((x) => ({
            ...x,
            submittedAt: fmt(x.submitted_at),
          })),
          submitBy: fmt(req.round.submit_deadline, { weekday: 'short' }),
          voteBy: fmt(req.round.vote_deadline, { weekday: 'short' }),
          missing: people.filter((p) => !p.submission_id).length,
          error: req.query.err || null,
          notice: req.query.ok || null,
        });
      } catch (err) {
        next(err);
      }
    });

  /** Grant or revoke the "ask for a reasonable extension" allowance. */
  r.post('/admin/round/:id/waiver', requireAuth, requireAdmin, loadRound, form,
    async (req, res, next) => {
      try {
        const playerId = Number(req.body.player_id);
        if (req.body.revoke) {
          await db.query(
            'delete from vote_waivers where round_id = $1 and player_id = $2',
            [req.round.id, playerId]
          );
          await log(req.league.id, req.player.id, 'waiver_revoked',
            `Round ${req.round.round_number}, ${await nameOf(playerId)}`);
        } else {
          await db.query(
            `insert into vote_waivers (round_id, player_id, granted_by, reason)
             values ($1,$2,$3,$4)
             on conflict (round_id, player_id) do nothing`,
            [req.round.id, playerId, req.player.id,
             String(req.body.reason || '').trim() || null]
          );
          await log(req.league.id, req.player.id, 'waiver_granted',
            `Round ${req.round.round_number}, ${await nameOf(playerId)}`);
        }
        res.redirect(`/admin/round/${req.round.id}?ok=` +
          encodeURIComponent('Extension updated.'));
      } catch (err) {
        next(err);
      }
    });

  /** Someone emailed their song in anyway. Enter it for them. */
  r.post('/admin/round/:id/submit-for', requireAuth, requireAdmin, loadRound, form,
    async (req, res, next) => {
      try {
        const playerId = Number(req.body.player_id);
        const url = String(req.body.url || '').trim();
        if (!playerId || !url) {
          return res.redirect(`/admin/round/${req.round.id}?err=` +
            encodeURIComponent('Pick a player and paste a link.'));
        }

        let track;
        try {
          track = await resolve(url);
        } catch (err) {
          const msg = err instanceof UnsupportedSourceError
            ? err.message
            : 'Could not read that link.';
          return res.redirect(`/admin/round/${req.round.id}?err=` +
            encodeURIComponent(msg));
        }

        await db.query(
          `insert into submissions
             (round_id, player_id, source, source_url, external_id,
              title, artist, thumbnail_url, duration_s, is_late)
           values ($1,$2,$3,$4,$5,$6,$7,$8,$9,false)
           on conflict (round_id, player_id) do update set
             source = excluded.source, source_url = excluded.source_url,
             external_id = excluded.external_id, title = excluded.title,
             artist = excluded.artist, thumbnail_url = excluded.thumbnail_url,
             duration_s = excluded.duration_s, submitted_at = now(),
             is_late = false`,
          [req.round.id, playerId, track.source, track.source_url,
           track.external_id, track.title, track.artist,
           track.thumbnail_url, track.duration_s]
        );

        await log(req.league.id, req.player.id, 'submitted_for',
          `Round ${req.round.round_number}, ${await nameOf(playerId)}: ${track.title}`);
        res.redirect(`/admin/round/${req.round.id}?ok=` +
          encodeURIComponent('Song entered.'));
      } catch (err) {
        next(err);
      }
    });

  // ---------------------------------------------------------------
  // Roster
  // ---------------------------------------------------------------

  r.post('/admin/roster/add', requireAuth, requireAdmin, form,
    async (req, res, next) => {
      try {
        // One per line: Name, email@example.com
        const lines = String(req.body.bulk || '')
          .split('\n')
          .map((l) => l.trim())
          .filter(Boolean);

        let added = 0;
        for (const line of lines) {
          const idx = line.lastIndexOf(',');
          if (idx === -1) continue;
          const name = line.slice(0, idx).trim();
          const email = line.slice(idx + 1).trim().toLowerCase();
          if (!name || !email.includes('@')) continue;

          const { rows } = await db.query(
            `insert into players (name, email) values ($1,$2)
             on conflict (email) do update set name = excluded.name
             returning id`,
            [name, email]
          );
          await db.query(
            `insert into memberships (league_id, player_id, role)
             values ($1,$2,'player') on conflict do nothing`,
            [req.league.id, rows[0].id]
          );
          added++;
        }

        await log(req.league.id, req.player.id, 'roster_add', `${added} added`);
        res.redirect('/admin?ok=' + encodeURIComponent(`${added} added to the roster.`));
      } catch (err) {
        next(err);
      }
    });

  r.post('/admin/roster/:playerId/role', requireAuth, requireAdmin, form,
    async (req, res, next) => {
      try {
        const role = req.body.role === 'admin' ? 'admin' : 'player';
        // Never leave the league without an admin.
        if (role === 'player') {
          const { rows } = await db.query(
            `select count(*)::int as n from memberships
              where league_id = $1 and role = 'admin'`,
            [req.league.id]
          );
          if (rows[0].n <= 1) {
            return res.redirect('/admin?err=' +
              encodeURIComponent('The league needs at least one admin.'));
          }
        }
        await db.query(
          `update memberships set role = $3
            where league_id = $1 and player_id = $2`,
          [req.league.id, req.params.playerId, role]
        );
        await log(req.league.id, req.player.id, 'role_change',
          `${await nameOf(req.params.playerId)} is now ${role}`);
        res.redirect('/admin?ok=' + encodeURIComponent('Role updated.'));
      } catch (err) {
        next(err);
      }
    });

  r.post('/admin/roster/:playerId/dues', requireAuth, requireAdmin, form,
    async (req, res, next) => {
      try {
        await db.query(
          `update memberships
              set dues_paid_at = case when dues_paid_at is null then now() else null end
            where league_id = $1 and player_id = $2`,
          [req.league.id, req.params.playerId]
        );
        res.redirect('/admin?ok=' + encodeURIComponent('Dues updated.'));
      } catch (err) {
        next(err);
      }
    });

  // ---------------------------------------------------------------
  // Invite link
  // ---------------------------------------------------------------

  r.post('/admin/invite/rotate', requireAuth, requireAdmin, form,
    async (req, res, next) => {
      try {
        await db.query(
          'update leagues set invite_code = new_invite_code() where id = $1',
          [req.league.id]
        );
        await log(req.league.id, req.player.id, 'invite_rotated',
          'Old invite links stopped working');
        res.redirect('/admin?ok=' + encodeURIComponent(
          'New invite link created. The old one no longer works.'));
      } catch (err) {
        next(err);
      }
    });

  r.post('/admin/invite/toggle', requireAuth, requireAdmin, form,
    async (req, res, next) => {
      try {
        const { rows } = await db.query(
          `update leagues set invites_open = not invites_open
            where id = $1 returning invites_open`,
          [req.league.id]
        );
        await log(req.league.id, req.player.id, 'invite_toggle',
          rows[0].invites_open ? 'Signups opened' : 'Signups closed');
        res.redirect('/admin?ok=' + encodeURIComponent(
          rows[0].invites_open ? 'Signups are open.' : 'Signups are closed.'));
      } catch (err) {
        next(err);
      }
    });

  /** Stop or start automatic round advancement. */
  r.post('/admin/auto/toggle', requireAuth, requireAdmin, form,
    async (req, res, next) => {
      try {
        const { rows } = await db.query(
          `update leagues set auto_advance = not auto_advance
            where id = $1 returning auto_advance`,
          [req.league.id]
        );
        await log(req.league.id, req.player.id, 'auto_toggle',
          rows[0].auto_advance ? 'Auto advance on' : 'Auto advance off');
        res.redirect('/admin?ok=' + encodeURIComponent(
          rows[0].auto_advance
            ? 'Rounds will advance on their deadlines.'
            : 'Automatic advancement paused. You are driving.'));
      } catch (err) {
        next(err);
      }
    });

  /** Remove someone from the roster. Their submissions go with them. */
  r.post('/admin/roster/:playerId/remove', requireAuth, requireAdmin, form,
    async (req, res, next) => {
      try {
        if (Number(req.params.playerId) === req.player.id) {
          return res.redirect('/admin?err=' +
            encodeURIComponent('You cannot remove yourself.'));
        }
        await db.query(
          'delete from memberships where league_id = $1 and player_id = $2',
          [req.league.id, req.params.playerId]
        );
        await log(req.league.id, req.player.id, 'roster_remove',
          `${await nameOf(req.params.playerId)} removed from the roster`);
        res.redirect('/admin?ok=' + encodeURIComponent('Removed from the roster.'));
      } catch (err) {
        next(err);
      }
    });

  // ---------------------------------------------------------------
  // Deadline nudges
  // ---------------------------------------------------------------
  // "Give everyone another day" is the common case, and it is not worth
  // making anyone type a date on a phone to do it.

  r.post('/admin/round/:id/extend', requireAuth, requireAdmin, loadRound, form,
    async (req, res, next) => {
      try {
        const by = String(req.body.by || '');
        const which = req.body.which === 'vote' ? 'vote' : 'submit';
        const shift = req.body.shift === '1';

        if (!BUMPS[by]) {
          return res.redirect(`/admin/round/${req.round.id}?err=` +
            encodeURIComponent('Unknown extension.'));
        }

        const n = parseInt(by, 10);
        const interval = by.endsWith('h') ? `${n} hours` : `${n} days`;

        if (which === 'submit') {
          // Moving the song deadline without moving the vote deadline just
          // eats the listening window, so shift both unless told otherwise.
          await db.query(
            `update rounds
                set submit_deadline = submit_deadline + $2::interval,
                    vote_deadline = case when $3 then vote_deadline + $2::interval
                                         else vote_deadline end
              where id = $1`,
            [req.round.id, interval, shift]
          );
        } else {
          await db.query(
            `update rounds set vote_deadline = vote_deadline + $2::interval
              where id = $1`,
            [req.round.id, interval]
          );
        }

        await log(req.league.id, req.player.id, 'deadline_extended',
          `Round ${req.round.round_number} ${which} deadline +${BUMPS[by]}`);
        res.redirect(`/admin/round/${req.round.id}?ok=` +
          encodeURIComponent(`${which === 'submit' ? 'Songs' : 'Votes'} due ${BUMPS[by]} later.`));
      } catch (err) {
        next(err);
      }
    });

  /** Pin one round in place without stopping the whole season. */
  r.post('/admin/round/:id/hold', requireAuth, requireAdmin, loadRound, form,
    async (req, res, next) => {
      try {
        const { rows } = await db.query(
          'update rounds set on_hold = not on_hold where id = $1 returning on_hold',
          [req.round.id]
        );
        await log(req.league.id, req.player.id, 'round_hold',
          `Round ${req.round.round_number} ${rows[0].on_hold ? 'held' : 'released'}`);
        res.redirect(`/admin/round/${req.round.id}?ok=` +
          encodeURIComponent(rows[0].on_hold
            ? 'Round held. It will not advance until you release it.'
            : 'Hold released. It will advance on its deadline.'));
      } catch (err) {
        next(err);
      }
    });

  // ---------------------------------------------------------------
  // Welcoming the roster
  // ---------------------------------------------------------------
  // Twenty one people are not going to independently decide to visit a
  // website and type their address. Send them a way in.

  r.post('/admin/roster/welcome-all', requireAuth, requireAdmin, form,
    async (req, res, next) => {
      try {
        const everyone = req.body.everyone === '1';

        const { rows: people } = await db.query(
          `select p.id, p.name, p.email
             from memberships m
             join players p on p.id = m.player_id
            where m.league_id = $1
              and p.is_active
              and p.email not like '%@demo.invalid'
              ${everyone ? '' : 'and p.last_login_at is null'}
            order by p.name`,
          [req.league.id]
        );

        let sent = 0;
        let failed = 0;
        for (const person of people) {
          try {
            await requestLoginLink(db, person.email, { ip: req.ip });
            sent++;
          } catch (err) {
            console.error('[admin] welcome failed for', person.email, err.message);
            failed++;
          }
        }

        await log(req.league.id, req.player.id, 'welcome_sent',
          `${sent} sign in links sent${failed ? `, ${failed} failed` : ''}`);

        res.redirect('/admin?ok=' + encodeURIComponent(
          `${sent} sign in link${sent === 1 ? '' : 's'} sent.` +
          (failed ? ` ${failed} failed, check the logs.` : '')));
      } catch (err) {
        next(err);
      }
    });

  return r;
}

module.exports = { router };
