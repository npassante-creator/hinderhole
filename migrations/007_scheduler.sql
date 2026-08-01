-- Music League: scheduler support

begin;

-- Lets the commissioner stop automatic advancement without stopping the
-- process. Useful while testing, and useful if a round needs to sit.
alter table leagues
  add column if not exists auto_advance boolean not null default true;

-- One row per reminder actually sent, so a scheduler running every five
-- minutes cannot mail the same person the same nudge repeatedly.
create table if not exists reminders_sent (
  round_id   bigint not null references rounds(id) on delete cascade,
  player_id  bigint not null references players(id) on delete cascade,
  kind       text   not null,
  sent_at    timestamptz not null default now(),
  primary key (round_id, player_id, kind)
);

commit;
