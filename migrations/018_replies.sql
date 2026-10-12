-- comment_replies: threaded replies on the results page.
--
-- Replies are only permitted once a round is revealed, enforced by a
-- trigger. Authors are named from the start (anonymity is not needed;
-- the reveal already names comment authors and identities are visible).
--
-- No unique constraint: multiple replies per person per comment are fine.

begin;

create table comment_replies (
  id         bigserial primary key,
  comment_id bigint not null references comments(id) on delete cascade,
  author_id  bigint not null references players(id)  on delete cascade,
  body       text   not null check (length(btrim(body)) > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index comment_replies_comment_idx on comment_replies (comment_id);

-- Gate: replies only on revealed rounds.
create or replace function enforce_reply_rules() returns trigger as $$
declare
  v_status round_status;
begin
  select r.status into v_status
    from comments c
    join rounds r on r.id = c.round_id
   where c.id = new.comment_id;

  if v_status is distinct from 'revealed' then
    raise exception 'Replies are only open after a round is revealed';
  end if;

  new.updated_at := now();
  return new;
end;
$$ language plpgsql;

create trigger reply_enforce_rules
  before insert or update on comment_replies
  for each row execute function enforce_reply_rules();

commit;
