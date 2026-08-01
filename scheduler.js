#!/usr/bin/env node
/**
 * scheduler.js
 *
 * Advances rounds on their deadlines and sends the nudges that would
 * otherwise be someone chasing a group thread.
 *
 * Runs every five minutes under PM2. Everything it does is idempotent, so
 * a missed tick or a double run changes nothing.
 *
 *   node scheduler.js --once           run one pass and exit
 *   node scheduler.js --once --dry     say what it would do, change nothing
 *   node scheduler.js --once --no-mail transitions only, no email
 *
 * Deadlines were authored in Central and stored as UTC. All comparisons
 * happen in Postgres against now(), never with date maths in Node.
 */

'use strict';

require('dotenv').config();

const { Pool } = require('pg');
const sgMail = require('@sendgrid/mail');

const args = process.argv.slice(2);
const ONCE = args.includes('--once');
const DRY = args.includes('--dry');
const NO_MAIL = args.includes('--no-mail') || DRY;
const EVERY_MS = 5 * 60 * 1000;

if (process.env.SENDGRID_API_KEY) {
  sgMail.setApiKey(process.env.SENDGRID_API_KEY);
}

const db = new Pool({ connectionString: process.env.DATABASE_URL, max: 2 });

const log = (...a) => console.log(new Date().toISOString(), ...a);
const would = (...a) => log(DRY ? '[dry]' : '[run]', ...a);

// ---------------------------------------------------------------
// Email
// ---------------------------------------------------------------

// Demo players live at @demo.invalid, a reserved TLD that cannot receive
// mail. Never attempt a send there.
const sendable = (email) => email && !email.endsWith('@demo.invalid');

async function mail(to, subject, text, html) {
  if (NO_MAIL) return would('would email', to, '|', subject);
  if (!sendable(to)) return;
  if (!process.env.SENDGRID_API_KEY) {
    return log('[dev] email to', to, '|', subject);
  }
  await sgMail.send({ to, from: process.env.MAIL_FROM, subject, text, html });
}

function wrap(body) {
  return `<div style="font-family:system-ui,-apple-system,sans-serif;` +
         `font-size:15px;line-height:1.55;color:#222">${body}</div>`;
}

// ---------------------------------------------------------------
// Transitions
// ---------------------------------------------------------------

/**
 * Songs are in. Close submissions and open the ballot.
 * The same tick opens the next round for songs, which is what keeps the
 * Friday to Wednesday overlap running without anyone touching a button.
 */
async function openVoting() {
  const { rows } = await db.query(
    `select r.id, r.round_number, r.title, r.league_id
       from rounds r
       join leagues l on l.id = r.league_id
      where r.status = 'submitting'
        and l.auto_advance
        and not r.on_hold
        and r.submit_deadline is not null
        and now() >= r.submit_deadline`
  );

  for (const round of rows) {
    would(`round ${round.round_number} to voting`);
    if (DRY) continue;

    // Anyone who never submitted is left ineligible. That is the rule,
    // and the commissioner can grant an extension by hand.
    await db.query('update rounds set status = $2 where id = $1',
      [round.id, 'voting']);
    await db.query(
      `insert into admin_actions (league_id, actor_id, action, detail)
       select $1, l.created_by, 'auto_voting', $2 from leagues l where l.id = $1`,
      [round.league_id, `Round ${round.round_number} opened for voting`]
    );

    await openNextRound(round.league_id, round.round_number);
    await announce(round, 'voting');
  }
  return rows.length;
}

async function openNextRound(leagueId, afterNumber) {
  const { rows } = await db.query(
    `update rounds set status = 'submitting'
      where id = (
        select id from rounds
         where league_id = $1 and round_number > $2 and status = 'draft'
         order by round_number limit 1
      )
      returning id, round_number, title`,
    [leagueId, afterNumber]
  );
  if (rows[0]) log(`round ${rows[0].round_number} now open for songs`);
  return rows[0] || null;
}

/** Votes are in. Reveal. */
async function reveal() {
  const { rows } = await db.query(
    `select r.id, r.round_number, r.title, r.league_id
       from rounds r
       join leagues l on l.id = r.league_id
      where r.status = 'voting'
        and l.auto_advance
        and not r.on_hold
        and r.vote_deadline is not null
        and now() >= r.vote_deadline`
  );

  for (const round of rows) {
    would(`round ${round.round_number} to revealed`);
    if (DRY) continue;

    await db.query('update rounds set status = $2 where id = $1',
      [round.id, 'revealed']);
    await db.query(
      `insert into admin_actions (league_id, actor_id, action, detail)
       select $1, l.created_by, 'auto_revealed', $2 from leagues l where l.id = $1`,
      [round.league_id, `Round ${round.round_number} revealed`]
    );

    await announce(round, 'revealed');
  }
  return rows.length;
}

// ---------------------------------------------------------------
// Announcements and nudges
// ---------------------------------------------------------------

async function roster(leagueId) {
  const { rows } = await db.query(
    `select p.id, p.name, p.email
       from memberships m join players p on p.id = m.player_id
      where m.league_id = $1`,
    [leagueId]
  );
  return rows;
}

async function announce(round, phase) {
  const people = await roster(round.league_id);
  const url = process.env.APP_URL || '';

  for (const person of people) {
    if (!sendable(person.email)) continue;

    if (phase === 'voting') {
      await mail(
        person.email,
        `Voting is open: ${round.title}`,
        `The songs are in for round ${round.round_number}, ${round.title}.\n\n` +
        `Listen and spread your ten points:\n${url}/round/${round.id}/vote\n`,
        wrap(`<p>The songs are in for round ${round.round_number}, ` +
             `<strong>${round.title}</strong>.</p>` +
             `<p><a href="${url}/round/${round.id}/vote">Listen and vote</a></p>`)
      );
    } else {
      await mail(
        person.email,
        `Results: ${round.title}`,
        `Round ${round.round_number} is revealed.\n\n${url}/round/${round.id}/results\n`,
        wrap(`<p>Round ${round.round_number}, <strong>${round.title}</strong>, ` +
             `is revealed.</p><p><a href="${url}/round/${round.id}/results">` +
             `See who took it</a></p>`)
      );
    }
  }
}

/**
 * Nudge people who have not acted yet, once each, in the last day before
 * a deadline. reminders_sent is what makes "once" true across ticks.
 */
async function nudge() {
  let sent = 0;

  // Missing a song, deadline within 24 hours.
  const { rows: needSong } = await db.query(
    `select r.id as round_id, r.round_number, r.title, r.submit_deadline,
            p.id as player_id, p.name, p.email
       from rounds r
       join leagues l on l.id = r.league_id
       join memberships m on m.league_id = r.league_id
       join players p on p.id = m.player_id
      where r.status = 'submitting'
        and r.submit_deadline between now() and now() + interval '24 hours'
        and not exists (select 1 from submissions s
                         where s.round_id = r.id and s.player_id = p.id)
        and not exists (select 1 from reminders_sent x
                         where x.round_id = r.id and x.player_id = p.id
                           and x.kind = 'submit')`
  );

  for (const row of needSong) {
    would('nudge submit', row.email, `round ${row.round_number}`);
    if (DRY) continue;
    await mail(
      row.email,
      `Song due tomorrow: ${row.title}`,
      `You have not picked a song for round ${row.round_number}, ${row.title}.\n\n` +
      `${process.env.APP_URL}/round/${row.round_id}\n\n` +
      `Miss the deadline and you cannot vote this round.\n`,
      wrap(`<p>No song from you yet for round ${row.round_number}, ` +
           `<strong>${row.title}</strong>.</p>` +
           `<p><a href="${process.env.APP_URL}/round/${row.round_id}">Pick one</a></p>` +
           `<p style="color:#666">Miss the deadline and you cannot vote ` +
           `this round.</p>`)
    );
    await db.query(
      `insert into reminders_sent (round_id, player_id, kind)
       values ($1,$2,'submit') on conflict do nothing`,
      [row.round_id, row.player_id]
    );
    sent++;
  }

  // Eligible, has not spent all their points, deadline within 24 hours.
  const { rows: needVote } = await db.query(
    `select r.id as round_id, r.round_number, r.title,
            p.id as player_id, p.name, p.email,
            l.points_per_voter,
            coalesce((select sum(v.points) from votes v
                       where v.round_id = r.id and v.voter_id = p.id), 0) as spent
       from rounds r
       join leagues l on l.id = r.league_id
       join memberships m on m.league_id = r.league_id
       join players p on p.id = m.player_id
      where r.status = 'voting'
        and r.vote_deadline between now() and now() + interval '24 hours'
        and can_vote(r.id, p.id)
        and coalesce((select sum(v.points) from votes v
                       where v.round_id = r.id and v.voter_id = p.id), 0)
            < l.points_per_voter
        and not exists (select 1 from reminders_sent x
                         where x.round_id = r.id and x.player_id = p.id
                           and x.kind = 'vote')`
  );

  for (const row of needVote) {
    const left = row.points_per_voter - Number(row.spent);
    would('nudge vote', row.email, `round ${row.round_number}, ${left} left`);
    if (DRY) continue;
    await mail(
      row.email,
      `Votes due tomorrow: ${row.title}`,
      `You have ${left} of ${row.points_per_voter} points left in round ` +
      `${row.round_number}, ${row.title}.\n\n` +
      `${process.env.APP_URL}/round/${row.round_id}/vote\n`,
      wrap(`<p>You have <strong>${left}</strong> of ${row.points_per_voter} ` +
           `points left in round ${row.round_number}, ` +
           `<strong>${row.title}</strong>.</p>` +
           `<p><a href="${process.env.APP_URL}/round/${row.round_id}/vote">` +
           `Finish voting</a></p>`)
    );
    await db.query(
      `insert into reminders_sent (round_id, player_id, kind)
       values ($1,$2,'vote') on conflict do nothing`,
      [row.round_id, row.player_id]
    );
    sent++;
  }

  return sent;
}

// ---------------------------------------------------------------
// The tick
// ---------------------------------------------------------------

async function tick() {
  try {
    const opened = await openVoting();
    const revealed = await reveal();
    const nudged = await nudge();

    if (!DRY) await db.query('select purge_expired_auth()');

    if (opened || revealed || nudged) {
      log(`opened ${opened}, revealed ${revealed}, nudged ${nudged}`);
    }
  } catch (err) {
    console.error(new Date().toISOString(), '[scheduler] tick failed', err);
  }
}

async function main() {
  log(`scheduler starting${DRY ? ' (dry run)' : ''}${NO_MAIL && !DRY ? ' (no mail)' : ''}`);
  await tick();
  if (ONCE) {
    await db.end();
    process.exit(0);
  }
  setInterval(tick, EVERY_MS);
}

process.on('SIGTERM', () => db.end().then(() => process.exit(0)));
process.on('SIGINT', () => db.end().then(() => process.exit(0)));

main();
