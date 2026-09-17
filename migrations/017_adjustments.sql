-- Music League: commissioner point adjustments
--
-- Rules never cover everything. Somebody submits something that breaks
-- the category, somebody deserves credit for a save, somebody never paid
-- their twenty dollars.
--
-- Recorded as a separate line rather than by editing votes, so the
-- arithmetic on the results page always adds up and nobody thinks the
-- site is miscounting. Every adjustment carries a reason and is shown to
-- the whole league. A silent adjustment in a league with money in it is
-- how you lose a friend.

begin;

create table if not exists adjustments (
  id         bigserial primary key,
  league_id  bigint not null references leagues(id) on delete cascade,
  -- Null means a season-wide adjustment not tied to any one round.
  round_id   bigint references rounds(id) on delete cascade,
  player_id  bigint not null references players(id) on delete cascade,
  points     integer not null check (points <> 0),
  reason     text not null check (length(btrim(reason)) between 3 and 200),
  made_by    bigint not null references players(id),
  created_at timestamptz not null default now()
);

create index if not exists adjustments_league_idx
  on adjustments (league_id, player_id);

create index if not exists adjustments_round_idx
  on adjustments (round_id);

commit;
