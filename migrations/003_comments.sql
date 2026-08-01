-- Music League: comments become independent of votes
-- Any eligible player can comment on any song, whether or not they gave it points.

begin;

create table comments (
  id            bigserial primary key,
  round_id      bigint not null references rounds(id) on delete cascade,
  submission_id bigint not null references submissions(id) on delete cascade,
  author_id     bigint not null references players(id) on delete cascade,
  body          text not null check (length(btrim(body)) > 0),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (submission_id, author_id)   -- one comment per person per song, editable
);

create index comments_submission_idx on comments (submission_id);
create index comments_round_idx on comments (round_id);


-- Migrate anything already sitting on votes, then drop the column.
insert into comments (round_id, submission_id, author_id, body, created_at)
select round_id, submission_id, voter_id, comment, created_at
from votes
where comment is not null and length(btrim(comment)) > 0
on conflict do nothing;

alter table votes drop column comment;


-- ---------------------------------------------------------------
-- Comment rules
-- ---------------------------------------------------------------

create or replace function enforce_comment_rules() returns trigger as $$
declare
  v_status    round_status;
  v_submitter bigint;
  v_sub_round bigint;
begin
  select status into v_status from rounds where id = new.round_id;

  -- Comments are open during voting and stay open after the reveal.
  if v_status not in ('voting', 'revealed') then
    raise exception 'Round % is not open for comments (status: %)',
      new.round_id, v_status;
  end if;

  select s.player_id, s.round_id
    into v_submitter, v_sub_round
    from submissions s
   where s.id = new.submission_id;

  if v_sub_round is distinct from new.round_id then
    raise exception 'Submission % does not belong to round %',
      new.submission_id, new.round_id;
  end if;

  -- Commenting on your own song would give you away before the reveal.
  -- Use submissions.note for "why I picked this" instead.
  if v_submitter = new.author_id then
    raise exception 'Players cannot comment on their own submission';
  end if;

  -- Same eligibility gate as voting: submitted on time, or admin waiver.
  if not can_vote(new.round_id, new.author_id) then
    raise exception 'Player % is not eligible to participate in round %',
      new.author_id, new.round_id;
  end if;

  new.updated_at := now();
  return new;
end;
$$ language plpgsql;

create trigger comments_enforce_rules
  before insert or update on comments
  for each row execute function enforce_comment_rules();


-- ---------------------------------------------------------------
-- Anonymity
-- ---------------------------------------------------------------
-- Serve comments from this view, never from the table directly.
-- author_id is null until the round is revealed, so the client
-- physically cannot leak it.

create view v_public_comments as
select
  c.id,
  c.round_id,
  c.submission_id,
  case when r.status = 'revealed' then c.author_id end as author_id,
  case when r.status = 'revealed' then p.name end      as author_name,
  c.body,
  c.created_at
from comments c
join rounds  r on r.id = c.round_id
join players p on p.id = c.author_id;

commit;
