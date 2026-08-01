-- Music League: admin support
-- Dues tracking and an audit trail for commissioner actions.

begin;

-- $20 buy-in. Track who has settled up so nobody has to chase a group thread.
alter table memberships
  add column if not exists dues_paid_at timestamptz,
  add column if not exists dues_note text;

-- Payout structure lives on the league so it shows up in the app rather
-- than only in the rules document.
alter table leagues
  add column if not exists buy_in_cents integer not null default 2000,
  add column if not exists payouts_cents integer[] not null
      default '{20000,15000,5000}';


-- ---------------------------------------------------------------
-- Audit trail
-- ---------------------------------------------------------------
-- Extensions and status changes are the kind of thing people argue about
-- later. Record who did what.

create table if not exists admin_actions (
  id         bigserial primary key,
  league_id  bigint not null references leagues(id) on delete cascade,
  actor_id   bigint not null references players(id),
  action     text not null,
  detail     text,
  created_at timestamptz not null default now()
);

create index if not exists admin_actions_league_idx
  on admin_actions (league_id, created_at desc);


-- ---------------------------------------------------------------
-- Roster view
-- ---------------------------------------------------------------
-- One row per player with the things a commissioner actually needs:
-- are they paid, and have they turned in the current round.

create or replace view v_roster as
select
  m.league_id,
  p.id            as player_id,
  p.name,
  p.email,
  m.role,
  m.dues_paid_at,
  p.last_login_at,
  (select count(*)::int from submissions s
     join rounds r on r.id = s.round_id
    where s.player_id = p.id and r.league_id = m.league_id) as songs_in
from memberships m
join players p on p.id = m.player_id;

commit;
