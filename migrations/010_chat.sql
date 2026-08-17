-- Music League: league chat
--
-- One room for the whole league. Not per round, because a room that
-- empties out between rounds reads as abandoned.

begin;

create table if not exists messages (
  id         bigserial primary key,
  league_id  bigint not null references leagues(id) on delete cascade,
  player_id  bigint not null references players(id) on delete cascade,
  body       text not null check (length(btrim(body)) between 1 and 2000),
  created_at timestamptz not null default now(),
  edited_at  timestamptz,
  deleted_at timestamptz,
  deleted_by bigint references players(id)
);

-- The only query that matters: recent messages for a league, newest last.
create index if not exists messages_league_idx
  on messages (league_id, id desc);

-- Where each person had read up to, so the header can show a count.
create table if not exists chat_reads (
  league_id  bigint not null references leagues(id) on delete cascade,
  player_id  bigint not null references players(id) on delete cascade,
  last_seen  bigint not null default 0,
  updated_at timestamptz not null default now(),
  primary key (league_id, player_id)
);

commit;
