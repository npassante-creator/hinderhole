-- Music League: saved candidates for future rounds
--
-- People hear something in week two that would be perfect for week seven.
-- Right now the only place to put it is a note on their phone.
--
-- These are private. Nobody else sees them, not even the commissioner.
-- Half the value is being able to shortlist five and change your mind.

begin;

create table if not exists shortlist (
  id            bigserial primary key,
  round_id      bigint not null references rounds(id) on delete cascade,
  player_id     bigint not null references players(id) on delete cascade,
  source        source_type not null,
  source_url    text not null,
  external_id   text,
  title         text,
  artist        text,
  thumbnail_url text,
  duration_s    integer,
  note          text,
  created_at    timestamptz not null default now()
);

-- The only query: my candidates for a round, or all of mine.
create index if not exists shortlist_owner_idx
  on shortlist (player_id, round_id, created_at);

-- The same song twice on one shortlist is a mistake, not a preference.
create unique index if not exists shortlist_no_dupes
  on shortlist (round_id, player_id, external_id)
  where external_id is not null;

commit;
