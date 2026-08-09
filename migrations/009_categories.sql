-- Music League: category suggestions, nomination voting, duplicate warnings
--
-- The league already does this by hand. The Autumn doc carries a list of
-- winter candidates with vote counts beside them. Same thing, counted for
-- you.
--
-- Three phases, held on the league row:
--   open        anyone can suggest an idea
--   nominating  everyone spreads points across the ideas
--   settled     voting closed, the top ones become the next season

begin;

do $$ begin
  create type nomination_status as enum ('open', 'nominating', 'settled');
exception when duplicate_object then null;
end $$;

create table if not exists category_ideas (
  id           bigserial primary key,
  league_id    bigint not null references leagues(id) on delete cascade,
  title        text not null check (length(btrim(title)) between 2 and 120),
  description  text,
  proposed_by  bigint references players(id) on delete set null,
  created_at   timestamptz not null default now()
);

create index if not exists category_ideas_league_idx
  on category_ideas (league_id);

-- The same category twice is noise, not enthusiasm.
create unique index if not exists category_ideas_unique_title
  on category_ideas (league_id, lower(btrim(title)));

-- Points spread across ideas, exactly like song voting.
create table if not exists category_votes (
  idea_id    bigint not null references category_ideas(id) on delete cascade,
  player_id  bigint not null references players(id) on delete cascade,
  points     smallint not null check (points > 0),
  created_at timestamptz not null default now(),
  primary key (idea_id, player_id)
);

create index if not exists category_votes_idea_idx on category_votes (idea_id);

alter table leagues
  add column if not exists nomination_status nomination_status
    not null default 'open',
  add column if not exists nomination_points smallint not null default 10;


-- ---------------------------------------------------------------
-- Budget enforcement, same pattern as song votes
-- ---------------------------------------------------------------

create or replace function enforce_category_vote() returns trigger as $$
declare
  v_league    bigint;
  v_budget    smallint;
  v_status    nomination_status;
  v_allocated int;
begin
  select i.league_id into v_league
    from category_ideas i where i.id = new.idea_id;

  select l.nomination_points, l.nomination_status
    into v_budget, v_status
    from leagues l where l.id = v_league;

  if v_status <> 'nominating' then
    raise exception 'Category voting is not open right now';
  end if;

  if not exists (select 1 from memberships m
                  where m.league_id = v_league
                    and m.player_id = new.player_id) then
    raise exception 'Not a member of this league';
  end if;

  select coalesce(sum(v.points), 0) into v_allocated
    from category_votes v
    join category_ideas i on i.id = v.idea_id
   where i.league_id = v_league
     and v.player_id = new.player_id
     and v.idea_id is distinct from new.idea_id;

  if v_allocated + new.points > v_budget then
    raise exception 'That would put you over % points', v_budget;
  end if;

  return new;
end;
$$ language plpgsql;

drop trigger if exists category_votes_enforce on category_votes;
create trigger category_votes_enforce
  before insert or update on category_votes
  for each row execute function enforce_category_vote();


-- ---------------------------------------------------------------
-- Duplicate detection
-- ---------------------------------------------------------------
-- Ten weeks of obscure music across eighteen people. Somebody will
-- resubmit something. Warn, never block: a reprise might be the joke.

create or replace function song_seen_before(
  p_league_id bigint, p_external_id text, p_round_id bigint
) returns table (round_number smallint, round_title text, submitted_by text)
as $$
  select r.round_number, r.title, p.name
    from submissions s
    join rounds r  on r.id = s.round_id
    join players p on p.id = s.player_id
   where r.league_id = p_league_id
     and s.external_id = p_external_id
     and s.round_id <> p_round_id
   order by r.round_number;
$$ language sql stable;

commit;
