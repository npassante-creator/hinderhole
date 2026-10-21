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
  select s.player_id, s.round_id
    into v_submitter, v_sub_round
    from submissions s
   where s.id = new.submission_id;
  if v_sub_round is distinct from new.round_id then
    raise exception 'Submission % does not belong to round %', new.submission_id, new.round_id;
  end if;
  if v_submitter = new.voter_id then
    raise exception 'Players cannot vote for their own submission';
  end if;
  if not can_vote(new.round_id, new.voter_id) then
    raise exception 'Player % is not eligible to vote in round %', new.voter_id, new.round_id;
  end if;
  if new.points > v_max_per_song then
    raise exception 'Max % points on a single song', v_max_per_song;
  end if;
  select coalesce(sum(points), 0) into v_allocated
    from votes
   where round_id = new.round_id
     and voter_id = new.voter_id
     and submission_id is distinct from new.submission_id;
  if v_allocated + new.points > v_budget then
    raise exception 'Vote budget exceeded: % of % points already allocated', v_allocated, v_budget;
  end if;
  return new;
end;
$$ language plpgsql;
