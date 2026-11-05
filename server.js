/**
 * server.js
 * Holy Hinder Hole Sound Society
 */

'use strict';

require('dotenv').config();

const path = require('path');
const express = require('express');
const cookieParser = require('cookie-parser');

const db = require('./db');
const auth = require('./auth');
const roundRoutes = require('./rounds');
const adminRoutes = require('./admin');
const joinRoutes = require('./join');
const voteRoutes = require('./vote');
const resultRoutes = require('./results');
const uploadRoutes = require('./upload');
const exportRoutes = require('./export');
const categoryRoutes = require('./categories');
const statsRoutes = require('./stats');
const shortlistRoutes = require('./shortlist');
const chatRoutes = require('./chat');
const playlistRoutes = require('./playlists');
const scoring = require('./scoring');

const app = express();
const PORT = process.env.PORT || 3000;

// Behind Nginx. Without this req.ip is always 127.0.0.1 and the login
// rate limiter treats every player as the same client.
app.set('trust proxy', 1);

// Stamped onto static asset URLs so a deploy busts the browser cache
// without giving up caching between deploys.
app.locals.assetVersion = Date.now().toString(36);
app.locals.appUrl = process.env.APP_URL || '';

app.set('view engine', 'ejs');
app.set('views', path.join(__dirname, 'views'));

app.use((req, res, next) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('Referrer-Policy', 'strict-origin-when-cross-origin');
  next();
});

app.use(express.static(path.join(__dirname, 'public'), { maxAge: '1h' }));
app.use(cookieParser());
app.use(auth.attachPlayer(db));
app.use(auth.router(db));

// Every view gets these.
app.use((req, res, next) => {
  res.locals.player = req.player;
  res.locals.isAdmin = false;
  res.locals.error = null;
  res.locals.navPath = req.path;
  res.locals.navAdmin = false;
  next();
});

// The top bar needs to know whether to show the Commissioner link on
// every page, not only the ones whose route happens to look it up.
app.use(async (req, res, next) => {
  if (!req.player) return next();
  try {
    const { rows } = await db.query(
      `select m.role from memberships m
         join leagues l on l.id = m.league_id
        where m.player_id = $1
        order by l.created_at desc limit 1`,
      [req.player.id]
    );
    res.locals.navAdmin = !!(rows[0] && rows[0].role === 'admin');
  } catch (err) {
    console.error('[nav] role lookup failed', err);
  }
  next();
});

app.use(voteRoutes.router(db));
app.use(resultRoutes.router(db));
app.use(uploadRoutes.router(db));
app.use(exportRoutes.router(db));
app.use(categoryRoutes.router(db));
app.use(statsRoutes.router(db));
app.use(shortlistRoutes.router(db));
app.use(chatRoutes.router(db));
app.use(playlistRoutes.router(db));
app.use(roundRoutes.router(db));
app.use(adminRoutes.router(db));
app.use(joinRoutes.router(db));

// ---------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------

const CT = 'America/Chicago';

function formatDeadline(date) {
  if (!date) return null;
  return new Intl.DateTimeFormat('en-US', {
    timeZone: CT,
    month: 'short',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
  }).format(date) + ' CT';
}

function daysUntil(date) {
  if (!date) return null;
  const ms = date.getTime() - Date.now();
  if (ms <= 0) return null;
  return Math.ceil(ms / 86400000);
}

const STATE_LABEL = {
  draft: 'Not open',
  submitting: 'Songs open',
  voting: 'Voting open',
  revealed: 'Done',
};

// ---------------------------------------------------------------
// Routes
// ---------------------------------------------------------------

app.get('/login', (req, res) => {
  if (req.player) return res.redirect('/');
  res.render('login', { error: null });
});

app.get('/', auth.requireAuth, async (req, res, next) => {
  try {
    const { rows: leagues } = await db.query(
      `select l.id, l.name, l.points_per_voter, m.role
         from leagues l
         join memberships m on m.league_id = l.id
        where m.player_id = $1
        order by l.created_at desc
        limit 1`,
      [req.player.id]
    );

    if (!leagues[0]) {
      return res.render('home', { league: null, rounds: [], current: null, isAdmin: false, wide: true });
    }

    const { rows: rounds } = await db.query(
      `select id, round_number, title, status,
              submit_deadline, vote_deadline
         from rounds
        where league_id = $1
        order by round_number`,
      [leagues[0].id]
    );

    const decorated = rounds.map((r) => ({
      ...r,
      stateLabel: STATE_LABEL[r.status],
      submitBy: formatDeadline(r.submit_deadline),
      voteBy: formatDeadline(r.vote_deadline),
      daysLeft:
        r.status === 'submitting'
          ? daysUntil(r.submit_deadline)
          : r.status === 'voting'
            ? daysUntil(r.vote_deadline)
            : null,
    }));

    const submitting = decorated.find((r) => r.status === 'submitting') || null;
    const voting = decorated.find((r) => r.status === 'voting') || null;
    const current = submitting || voting || null;

    const league = leagues[0];
    const me = req.player.id;

    // Your own pick for the round taking songs. Only ever your own.
    let myPick = null;
    let inCount = 0;
    if (submitting) {
      const { rows: mine } = await db.query(
        `select title, artist, source from submissions
          where round_id = $1 and player_id = $2`,
        [submitting.id, me]
      );
      myPick = mine[0] || null;
      const { rows: c } = await db.query(
        'select count(*)::int as n from submissions where round_id = $1',
        [submitting.id]
      );
      inCount = c[0].n;
    }

    // Where you are with the round open for voting.
    let myVote = null;
    if (voting) {
      const { rows: v } = await db.query(
        `select coalesce(sum(points), 0)::int as spent,
                (select count(distinct voter_id)::int from votes
                  where round_id = $1) as voters,
                (select count(*)::int from submissions
                  where round_id = $1) as songs
           from votes where round_id = $1 and voter_id = $2`,
        [voting.id, me]
      );
      myVote = { ...v[0], budget: league.points_per_voter };
    }

    const tables = await scoring.roundTables(db, league.id);
    decorated.forEach((r) => {
      const t = tables.get(String(r.id));
      const mine = t && t.find((s) => String(s.player_id) === String(me));
      r.mine = mine
        ? { place: scoring.ordinal(mine.place), points: mine.points, of: mine.of }
        : null;
      r.href = r.status === 'draft' ? null
        : '/round/' + r.id + (r.status === 'voting' ? '/vote'
          : (r.status === 'revealed' ? '/results' : ''));
    });

    const revealed = decorated.filter((r) => r.status === 'revealed');
    const lastRound = revealed.length ? revealed[revealed.length - 1] : null;
    let last = null;
    if (lastRound) {
      const t = tables.get(String(lastRound.id)) || [];
      last = { round: lastRound, winner: t[0] || null, mine: lastRound.mine };
    }

    const table = await scoring.seasonTable(db, league.id);
    const top = table.slice(0, 5);
    const meRow = table.find((x) => String(x.id) === String(me));
    const meShown = top.some((x) => String(x.id) === String(me));

    res.render('home', {
      league,
      rounds: decorated,
      current,
      submitting,
      voting,
      myPick,
      inCount,
      myVote,
      last,
      top,
      meRow: meShown ? null : meRow || null,
      rosterSize: table.length,
      revealedCount: revealed.length,
      isAdmin: league.role === 'admin',
      wide: true,
    });
  } catch (err) {
    next(err);
  }
});

app.get('/healthz', async (req, res) => {
  try {
    await db.query('select 1');
    res.json({ ok: true });
  } catch {
    res.status(503).json({ ok: false });
  }
});

// ---------------------------------------------------------------
// Errors
// ---------------------------------------------------------------

app.use((req, res) => {
  res.status(404).render('error', {
    code: '404',
    headline: 'No such record',
    detail: 'That page is not in the rack.',
  });
});

app.use((err, req, res, next) => {
  console.error('[error]', err);
  res.status(500).render('error', {
    code: '500',
    headline: 'The needle skipped',
    detail: 'Something broke on our end. Try again in a moment.',
  });
});

const server = app.listen(PORT, '127.0.0.1', () => {
  console.log(`[server] listening on 127.0.0.1:${PORT}`);
});

for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, () => {
    server.close(() => db.end().then(() => process.exit(0)));
  });
}
