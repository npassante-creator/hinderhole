/**
 * auth.js
 *
 * Passwordless login for a private league. The flow:
 *
 *   1. Player enters their email
 *   2. If that email is on the roster, they get a link
 *   3. Clicking it creates a 90 day session cookie
 *
 * Deliberately closed: an email that is not already a league member gets
 * no link and no account. You add people, not the internet.
 *
 * Environment:
 *   DATABASE_URL, SENDGRID_API_KEY, MAIL_FROM, APP_URL, NODE_ENV
 */

'use strict';

const crypto = require('crypto');
const express = require('express');
const sgMail = require('@sendgrid/mail');

if (process.env.SENDGRID_API_KEY) {
  sgMail.setApiKey(process.env.SENDGRID_API_KEY);
}

const LINK_TTL_MIN = 20;          // magic link lifetime
const SESSION_TTL_DAYS = 90;      // longer than a 10 week season
const MAX_LINKS_PER_HOUR = 5;     // per player
const COOKIE_NAME = 'ml_session';

const sha256 = (v) => crypto.createHash('sha256').update(v).digest('hex');
const newToken = () => crypto.randomBytes(32).toString('base64url');

// ---------------------------------------------------------------
// Issuing a link
// ---------------------------------------------------------------

/**
 * Always resolves. Never tells the caller whether the email exists,
 * so the login form cannot be used to enumerate the roster.
 */
async function requestLoginLink(db, email, { ip } = {}) {
  const clean = String(email || '').trim().toLowerCase();
  if (!clean.includes('@')) return { sent: false };

  const { rows } = await db.query(
    `select p.id, p.name, p.email
       from players p
      where p.email = $1
        and p.is_active
        and exists (select 1 from memberships m where m.player_id = p.id)`,
    [clean]
  );
  const player = rows[0];
  if (!player) return { sent: false };

  const { rows: recent } = await db.query(
    `select count(*)::int as n from login_tokens
      where player_id = $1 and created_at > now() - interval '1 hour'`,
    [player.id]
  );
  if (recent[0].n >= MAX_LINKS_PER_HOUR) {
    return { sent: false, throttled: true };
  }

  const token = newToken();
  await db.query(
    `insert into login_tokens (player_id, token_hash, expires_at, requested_ip)
     values ($1, $2, now() + ($3 || ' minutes')::interval, $4)`,
    [player.id, sha256(token), String(LINK_TTL_MIN), ip || null]
  );

  const url = `${process.env.APP_URL}/auth/callback?token=${encodeURIComponent(token)}`;
  await sendLinkEmail(player, url);

  return { sent: true };
}

async function sendLinkEmail(player, url) {
  if (!process.env.SENDGRID_API_KEY) {
    console.log(`[auth] dev login link for ${player.email}: ${url}`);
    return;
  }

  await sgMail.send({
    to: player.email,
    from: process.env.MAIL_FROM,
    subject: 'Your Music League sign in link',
    text:
      `Hi ${player.name},\n\n` +
      `Tap to sign in:\n${url}\n\n` +
      `This link works once and expires in ${LINK_TTL_MIN} minutes.\n` +
      `If you did not ask for it, ignore this email.\n`,
    html:
      `<p>Hi ${escapeHtml(player.name)},</p>` +
      `<p><a href="${url}" style="display:inline-block;padding:12px 20px;` +
      `background:#111;color:#fff;border-radius:6px;text-decoration:none;` +
      `font-family:system-ui,sans-serif">Sign in to Music League</a></p>` +
      `<p style="color:#666;font-family:system-ui,sans-serif;font-size:14px">` +
      `This link works once and expires in ${LINK_TTL_MIN} minutes. ` +
      `If you did not ask for it, ignore this email.</p>`,
  });
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[c]));
}

// ---------------------------------------------------------------
// Redeeming a link
// ---------------------------------------------------------------

/**
 * Consumes the token and opens a session, in one transaction so a
 * double-clicked link cannot produce two sessions.
 */
async function consumeLoginLink(db, token, { ip, userAgent } = {}) {
  if (!token) return null;

  const client = await db.connect();
  try {
    await client.query('begin');

    const { rows } = await client.query(
      `update login_tokens
          set consumed_at = now()
        where token_hash = $1
          and consumed_at is null
          and expires_at > now()
        returning player_id`,
      [sha256(token)]
    );
    if (!rows[0]) {
      await client.query('rollback');
      return null;
    }
    const playerId = rows[0].player_id;

    const sessionToken = newToken();
    await client.query(
      `insert into sessions
         (player_id, token_hash, user_agent, ip, expires_at)
       values ($1, $2, $3, $4, now() + ($5 || ' days')::interval)`,
      [playerId, sha256(sessionToken), userAgent || null, ip || null,
       String(SESSION_TTL_DAYS)]
    );

    await client.query(
      'update players set last_login_at = now() where id = $1',
      [playerId]
    );

    await client.query('commit');
    return { playerId, sessionToken };
  } catch (err) {
    await client.query('rollback');
    throw err;
  } finally {
    client.release();
  }
}

// ---------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------

function cookieOptions() {
  return {
    httpOnly: true,
    secure: process.env.NODE_ENV === 'production',
    sameSite: 'lax',
    maxAge: SESSION_TTL_DAYS * 24 * 60 * 60 * 1000,
    path: '/',
  };
}

/**
 * Populates req.player when a valid session cookie is present.
 * Never rejects: use requireAuth for that.
 */
function attachPlayer(db) {
  return async function (req, res, next) {
    req.player = null;
    const token = req.cookies && req.cookies[COOKIE_NAME];
    if (!token) return next();

    try {
      const { rows } = await db.query(
        `update sessions s
            set last_seen_at = now()
           from players p
          where s.token_hash = $1
            and s.player_id = p.id
            and s.revoked_at is null
            and s.expires_at > now()
            and p.is_active
        returning p.id, p.name, p.email, s.id as session_id`,
        [sha256(token)]
      );
      if (rows[0]) {
        req.player = {
          id: rows[0].id,
          name: rows[0].name,
          email: rows[0].email,
        };
        req.sessionId = rows[0].session_id;
      }
    } catch (err) {
      console.error('[auth] session lookup failed', err);
    }
    next();
  };
}

function requireAuth(req, res, next) {
  if (!req.player) {
    if (req.accepts('json') && !req.accepts('html')) {
      return res.status(401).json({ error: 'Sign in required' });
    }
    return res.redirect(`/login?next=${encodeURIComponent(req.originalUrl)}`);
  }
  next();
}

/** Gate admin-only routes for a specific league. */
function requireLeagueAdmin(db) {
  return async function (req, res, next) {
    const leagueId = req.params.leagueId || req.body.league_id;
    const { rows } = await db.query(
      `select 1 from memberships
        where league_id = $1 and player_id = $2 and role = 'admin'`,
      [leagueId, req.player.id]
    );
    if (!rows[0]) return res.status(403).json({ error: 'Admins only' });
    next();
  };
}

// ---------------------------------------------------------------
// Routes
// ---------------------------------------------------------------

function router(db) {
  const r = express.Router();

  r.post('/auth/request', express.urlencoded({ extended: false }), async (req, res) => {
    try {
      await requestLoginLink(db, req.body.email, { ip: req.ip });
    } catch (err) {
      console.error('[auth] link request failed', err);
    }
    // Same response either way.
    res.render('check-email', { email: req.body.email });
  });

  r.get('/auth/callback', async (req, res) => {
    const result = await consumeLoginLink(db, req.query.token, {
      ip: req.ip,
      userAgent: req.get('user-agent'),
    });
    if (!result) {
      return res.status(400).render('login', {
        error: 'That link expired or was already used. Request a new one.',
      });
    }
    res.cookie(COOKIE_NAME, result.sessionToken, cookieOptions());
    res.redirect(req.query.next || '/');
  });

  r.post('/auth/logout', async (req, res) => {
    if (req.sessionId) {
      await db.query(
        'update sessions set revoked_at = now() where id = $1',
        [req.sessionId]
      );
    }
    res.clearCookie(COOKIE_NAME, { path: '/' });
    res.redirect('/login');
  });

  return r;
}

module.exports = {
  router,
  attachPlayer,
  requireAuth,
  requireLeagueAdmin,
  requestLoginLink,
  consumeLoginLink,
  COOKIE_NAME,
};
