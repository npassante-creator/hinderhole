/**
 * categories.js
 *
 * The suggestion box and the vote that turns it into next season.
 *
 * This is the same shape as song voting on purpose: everyone gets ten
 * points and spreads them however they like. The league already runs this
 * by hand, the Autumn document has the tallies written beside each
 * candidate. All this does is count.
 *
 * Anyone can suggest at any time. Voting only opens when the commissioner
 * says so, which keeps the board from becoming a live scoreboard while
 * people are still thinking.
 */

'use strict';

const express = require('express');
const { requireAuth } = require('./auth');

function router(db) {
  const r = express.Router();
  const form = express.urlencoded({ extended: false });
  const json = express.json();

  async function loadLeague(req, res, next) {
    try {
      const { rows } = await db.query(
        `select l.*, m.role
           from leagues l
           join memberships m on m.league_id = l.id
          where m.player_id = $1
          order by l.created_at desc limit 1`,
        [req.player.id]
      );
      if (!rows[0]) return res.redirect('/');
      req.league = rows[0];
      req.isAdmin = rows[0].role === 'admin';
      next();
    } catch (err) {
      next(err);
    }
  }

  // ---------------------------------------------------------------
  // The board
  // ---------------------------------------------------------------

  r.get('/categories', requireAuth, loadLeague, async (req, res, next) => {
    try {
      const league = req.league;
      const voting = league.nomination_status === 'nominating';
      const settled = league.nomination_status === 'settled';
      const showPoints = voting || settled;

      // While people are still suggesting, the board is deliberately
      // unranked. A running tally turns a suggestion box into a popularity
      // contest before anyone has thought about it.
      const { rows: ideas } = await db.query(
        `select i.id, i.title, i.description, i.created_at,
                p.name as proposed_by,
                (i.proposed_by = $2) as is_mine,
                ${showPoints
                  ? 'coalesce(sum(v.points), 0)::int as points, count(v.player_id)::int as backers,'
                  : '0 as points, 0 as backers,'}
                coalesce(max(case when v.player_id = $2 then v.points end), 0)::int as my_points
           from category_ideas i
           left join players p on p.id = i.proposed_by
           left join category_votes v on v.idea_id = i.id
          where i.league_id = $1
          group by i.id, p.name
          order by ${showPoints
            ? 'coalesce(sum(v.points), 0) desc, i.created_at'
            : 'i.created_at desc'}`,
        [league.id, req.player.id]
      );

      const spent = ideas.reduce((n, i) => n + Number(i.my_points), 0);

      let place = 0;
      let last = null;
      const ranked = ideas.map((idea, i) => {
        if (!showPoints) return { ...idea, place: null };
        if (idea.points !== last) { place = i + 1; last = idea.points; }
        return { ...idea, place };
      });

      res.render('categories', {
        league,
        ideas: ranked,
        voting,
        settled,
        showPoints,
        budget: league.nomination_points,
        spent,
        isAdmin: req.isAdmin,
        error: req.query.err || null,
        notice: req.query.ok || null,
      });
    } catch (err) {
      next(err);
    }
  });

  // ---------------------------------------------------------------
  // Suggesting
  // ---------------------------------------------------------------

  r.post('/categories', requireAuth, loadLeague, form, async (req, res, next) => {
    try {
      if (req.league.nomination_status === 'settled') {
        return res.redirect('/categories?err=' +
          encodeURIComponent('The list is closed for this season.'));
      }

      const title = String(req.body.title || '').trim();
      if (title.length < 2 || title.length > 120) {
        return res.redirect('/categories?err=' +
          encodeURIComponent('Give it a name between 2 and 120 characters.'));
      }

      try {
        await db.query(
          `insert into category_ideas (league_id, title, description, proposed_by)
           values ($1, $2, $3, $4)`,
          [req.league.id, title,
           String(req.body.description || '').trim() || null,
           req.player.id]
        );
      } catch (err) {
        if (err.code === '23505') {
          return res.redirect('/categories?err=' +
            encodeURIComponent('Somebody already suggested that one.'));
        }
        throw err;
      }

      res.redirect('/categories?ok=' + encodeURIComponent('Added to the list.'));
    } catch (err) {
      next(err);
    }
  });

  /** Withdraw your own suggestion, while it is still just a suggestion. */
  r.post('/categories/:id/remove', requireAuth, loadLeague, form,
    async (req, res, next) => {
      try {
        const { rows } = await db.query(
          `delete from category_ideas
            where id = $1 and league_id = $2
              and (proposed_by = $3 or $4)
          returning id`,
          [req.params.id, req.league.id, req.player.id, req.isAdmin]
        );
        res.redirect('/categories?ok=' + encodeURIComponent(
          rows[0] ? 'Removed.' : 'Nothing to remove.'));
      } catch (err) {
        next(err);
      }
    });

  // ---------------------------------------------------------------
  // Voting, saved as it changes
  // ---------------------------------------------------------------

  r.post('/categories/:id/vote', requireAuth, loadLeague, json,
    async (req, res, next) => {
      const client = await db.connect();
      try {
        if (req.league.nomination_status !== 'nominating') {
          return res.status(409).json({ error: 'Category voting is closed.' });
        }

        const points = Number(req.body.points);
        if (!Number.isInteger(points) || points < 0 ||
            points > req.league.nomination_points) {
          return res.status(400).json({ error: 'Not a valid allocation.' });
        }

        await client.query('begin');

        const { rows: current } = await client.query(
          `select v.idea_id, v.points
             from category_votes v
             join category_ideas i on i.id = v.idea_id
            where i.league_id = $1 and v.player_id = $2
            for update`,
          [req.league.id, req.player.id]
        );

        const others = current
          .filter((v) => String(v.idea_id) !== String(req.params.id))
          .reduce((n, v) => n + v.points, 0);

        if (others + points > req.league.nomination_points) {
          await client.query('rollback');
          return res.status(409).json({
            error: `That would put you over ${req.league.nomination_points} points.`,
            spent: others,
          });
        }

        if (points === 0) {
          await client.query(
            'delete from category_votes where idea_id = $1 and player_id = $2',
            [req.params.id, req.player.id]
          );
        } else {
          await client.query(
            `insert into category_votes (idea_id, player_id, points)
             values ($1, $2, $3)
             on conflict (idea_id, player_id)
             do update set points = excluded.points`,
            [req.params.id, req.player.id, points]
          );
        }

        await client.query('commit');
        res.json({ ok: true, spent: others + points });
      } catch (err) {
        await client.query('rollback').catch(() => {});
        if (err.code === 'P0001') {
          return res.status(409).json({ error: err.message });
        }
        next(err);
      } finally {
        client.release();
      }
    });

  // ---------------------------------------------------------------
  // Commissioner controls
  // ---------------------------------------------------------------

  r.post('/categories/phase', requireAuth, loadLeague, form,
    async (req, res, next) => {
      try {
        if (!req.isAdmin) return res.status(403).redirect('/categories');

        const to = String(req.body.status || '');
        if (!['open', 'nominating', 'settled'].includes(to)) {
          return res.redirect('/categories?err=' +
            encodeURIComponent('Unknown phase.'));
        }

        await db.query(
          'update leagues set nomination_status = $2 where id = $1',
          [req.league.id, to]
        );
        await db.query(
          `insert into admin_actions (league_id, actor_id, action, detail)
           values ($1, $2, 'nomination_phase', $3)`,
          [req.league.id, req.player.id, `Category board set to ${to}`]
        );

        const said = {
          open: 'Suggestions are open. Voting is off.',
          nominating: 'Voting is open. Everyone has their points.',
          settled: 'Voting closed. The list is final.',
        };
        res.redirect('/categories?ok=' + encodeURIComponent(said[to]));
      } catch (err) {
        next(err);
      }
    });

  return r;
}

module.exports = { router };
