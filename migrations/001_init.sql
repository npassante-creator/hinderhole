-- Music League: initial schema
-- Postgres 14+
-- All timestamps are timestamptz. Deadlines are set in America/Los_Angeles
-- and stored as UTC.

begin;

create extension if not exists citext;

create type round_status as enum ('draft', 'submitting', 'voting', 'revealed');
create type source_type as enum ('youtube', 'spotify', 'upload');
create type member_role as enum ('admin', 'player');


-- ---------------------------------------------------------------
-- People and leagues
-- ---------------------------------------------------------------

create table players (
  id            bigserial primary key,
  name          text not null,
  email         citext not null unique,
  created_at    timestamptz not null default now()
);

create table leagues (
  id               bigserial primary key,
  name             text not null,
  points_per_voter smallint not null default 10 check (points_per_voter between 1 and 100),
  max_per_song     smallint not null default 10 check (max_per_song between 1 and 100),
  created_by       bigint not null references players(id),
  created_at       timestamptz not null default now()
);

create table memberships (
  league_id  bigint not null references leagues(id) on delete cascade,
  player_id  bigint not null references players(id) on delete cascade,
  role       member_role not null default 'player',
  joined_at  timestamptz not null default now(),
  primary key (league_id, player_id)
);


-- ---------------------------------------------------------------
-- Rounds
-- ---------------------------------------------------------------

create table rounds (
  id              bigserial primary key,
  league_id       bigint not null references leagues(id) on delete cascade,
  round_number    smallint not null,
  title           text not null,
  description     text,
  status          round_status not null default 'draft',
  submit_deadline timestamptz,
  vote_deadline   timestamptz,
  created_at      timestamptz not null default now(),
  unique (league_id, round_number),
  check (vote_deadline is null or submit_deadline is null
         or vote_deadline > submit_deadline)
);

-- A league can have at most one round collecting submissions and at most
-- one round open for voting at any given time. They are allowed to overlap,
-- which is what makes the Friday-submit / Wednesday-vote cadence work.
create unique index rounds_one_submitting
  on rounds (league_id) where status = 'submitting';

create unique index rounds_one_voting
  on rounds (league_id) where status = 'voting';


-- ---------------------------------------------------------------
-- Submissions
-- ---------------------------------------------------------------

create table submissions (
  id            bigserial primary key,
  round_id      bigint not null references rounds(id) on delete cascade,
  player_id     bigint not null references players(id) on delete cascade,
  source        source_type not null,
  source_url    text not null,
  external_id   text,            -- YouTube video id, Spotify track id, storage key
  title         text,
  artist        text,
  thumbnail_url text,
  duration_s    int,
  note          text,            -- optional "why I picked this", shown at reveal
  submitted_at  timestamptz not null default now(),
  is_late       boolean not null default false,
  unique (round_id, player_id)
);

create index submissions_round_idx on submissions (round_id);


-- ---------------------------------------------------------------
-- Voting eligibility waivers (the admin allowance)
-- ---------------------------------------------------------------

create table vote_waivers (
  round_id   bigint not null references rounds(id) on delete cascade,
  player_id  bigint not null references players(id) on delete cascade,
  granted_by bigint not null references players(id),
  reason     text,
  granted_at timestamptz not null default now(),
  primary key (round_id, player_id)
);


-- ---------------------------------------------------------------
-- Votes
-- ---------------------------------------------------------------

create table votes (
  id            bigserial primary key,
  round_id      bigint not null references rounds(id) on delete cascade,
  voter_id      bigint not null references players(id) on delete cascade,
  submission_id bigint not null references submissions(id) on delete cascade,
  points        smallint not null check (points > 0),
  comment       text,
  created_at    timestamptz not null default now(),
  unique (round_id, voter_id, submission_id)
);

create index votes_submission_idx on votes (submission_id);
create index votes_round_voter_idx on votes (round_id, voter_id);


-- ---------------------------------------------------------------
-- Vote integrity
-- ---------------------------------------------------------------

-- Is this player allowed to vote in this round?
-- Yes if they submitted on time, or if an admin granted a waiver.
create or replace function can_vote(p_round_id bigint, p_player_id bigint)
returns boolean as $$
  select exists (
    select 1 from submissions s
    where s.round_id = p_round_id
      and s.player_id = p_player_id
      and s.is_late = false
  ) or exists (
    select 1 from vote_waivers w
    where w.round_id = p_round_id
      and w.player_id = p_player_id
  );
$$ language sql stable;


create or replace function enforce_vote_rules() returns trigger as $$
declare
  v_budget       smallint;
  v_max_per_song smallint;
  v_allocated    int;
  v_submitter    bigint;
  v_sub_round    bigint;
begin
  select l.points_per_voter, l.max_per_song
    into v_budget, v_max_per_song
    from rounds r
    join leagues l on l.id = r.league_id
   where r.id = new.round_id;

  -- The submission must belong to the round being voted on.
  select s.player_id, s.round_id
    into v_submitter, v_sub_round
    from submissions s
   where s.id = new.submission_id;

  if v_sub_round is distinct from new.round_id then
    raise exception 'Submission % does not belong to round %',
      new.submission_id, new.round_id;
  end if;

  -- No voting for yourself.
  if v_submitter = new.voter_id then
    raise exception 'Players cannot vote for their own submission';
  end if;

  -- Missed the submission deadline and no admin waiver.
  if not can_vote(new.round_id, new.voter_id) then
    raise exception 'Player % is not eligible to vote in round %',
      new.voter_id, new.round_id;
  end if;

  if new.points > v_max_per_song then
    raise exception 'Max % points on a single song', v_max_per_song;
  end if;

  -- Total allocation across the round cannot exceed the budget.
  select coalesce(sum(points), 0) into v_allocated
    from votes
   where round_id = new.round_id
     and voter_id = new.voter_id
     and id is distinct from new.id;

  if v_allocated + new.points > v_budget then
    raise exception 'Vote budget exceeded: % of % points already allocated',
      v_allocated, v_budget;
  end if;

  return new;
end;
$$ language plpgsql;

create trigger votes_enforce_rules
  before insert or update on votes
  for each row execute function enforce_vote_rules();


-- Votes are only accepted while the round is open for voting.
create or replace function enforce_voting_window() returns trigger as $$
declare
  v_status round_status;
begin
  select status into v_status from rounds where id = new.round_id;
  if v_status <> 'voting' then
    raise exception 'Round % is not open for voting (status: %)',
      new.round_id, v_status;
  end if;
  return new;
end;
$$ language plpgsql;

create trigger votes_enforce_window
  before insert or update on votes
  for each row execute function enforce_voting_window();


-- ---------------------------------------------------------------
-- Reporting
-- ---------------------------------------------------------------

create view v_round_results as
select
  s.round_id,
  s.id                       as submission_id,
  s.player_id,
  s.title,
  s.artist,
  coalesce(sum(v.points), 0) as points,
  count(v.id)                as voter_count,
  rank() over (partition by s.round_id
               order by coalesce(sum(v.points), 0) desc) as place
from submissions s
left join votes v on v.submission_id = s.id
group by s.round_id, s.id, s.player_id, s.title, s.artist;


create view v_standings as
select
  r.league_id,
  s.player_id,
  p.name,
  coalesce(sum(v.points), 0) as total_points,
  count(distinct s.round_id) as rounds_played
from submissions s
join rounds  r on r.id = s.round_id
join players p on p.id = s.player_id
left join votes v on v.submission_id = s.id
where r.status = 'revealed'
group by r.league_id, s.player_id, p.name;

commit;
