-- Music League: unspent points come off your own score
--
-- If you were eligible to vote and left points on the table, the
-- remainder is subtracted from what your song earned that round. Spend
-- seven of ten and you lose three.
--
-- Computed rather than stored, so it stays correct if someone votes late
-- or the commissioner reopens a round.
--
-- Two things it deliberately does not do:
--
--   It does not touch anyone who was not eligible to vote. Being locked
--   out for a missed song is already the penalty for that; charging them
--   again for not voting would be punishing the same miss twice.
--
--   It does not apply to rounds before the rule existed. The league
--   agreed to this going forward, so the starting round is explicit.

begin;

alter table leagues
  add column if not exists vote_penalty_from_round smallint;


/**
 * Unspent points per player per revealed round, for rounds the rule
 * covers. Only rows with something owed.
 */
create or replace view v_vote_penalties as
select
  r.id        as round_id,
  r.league_id,
  m.player_id,
  (l.points_per_voter - coalesce(sum(v.points), 0))::int as unspent
from rounds r
join leagues l     on l.id = r.league_id
join memberships m on m.league_id = r.league_id
left join votes v  on v.round_id = r.id and v.voter_id = m.player_id
where r.status = 'revealed'
  and l.vote_penalty_from_round is not null
  and r.round_number >= l.vote_penalty_from_round
  and can_vote(r.id, m.player_id)
group by r.id, r.league_id, m.player_id, l.points_per_voter
having (l.points_per_voter - coalesce(sum(v.points), 0)) > 0;

commit;


-- Turn the rule on from a given round, e.g. from round 3 onward:
--
--   update leagues set vote_penalty_from_round = 3 where id = 1;
--
-- Turn it off again:
--
--   update leagues set vote_penalty_from_round = null where id = 1;
