-- Transactional wallet/game functions. Run after schema.sql in Supabase SQL Editor.
create or replace function public.play_game(p_player_id uuid, p_pick_one integer, p_pick_two integer, p_bet bigint)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_coins bigint; v_dice integer[]; v_matches integer; v_payout bigint; v_multiplier integer := 0;
begin
  if p_pick_one not between 1 and 6 or p_pick_two not between 1 and 6 or p_bet < 1 or p_bet > 1000000 then
    raise exception 'Invalid picks or bet';
  end if;
  select coins into v_coins from profiles where id = p_player_id for update;
  if not found then raise exception 'Player profile not found'; end if;
  if v_coins < p_bet then raise exception 'Insufficient coins'; end if;
  v_dice := array[
    floor(random()*6)::integer+1, floor(random()*6)::integer+1,
    floor(random()*6)::integer+1, floor(random()*6)::integer+1,
    floor(random()*6)::integer+1, floor(random()*6)::integer+1
  ];
  if p_pick_one = p_pick_two then
    select count(*) into v_matches from unnest(v_dice) d where d = p_pick_one;
  else
    select count(*) into v_matches from unnest(v_dice) d where d = p_pick_one or d = p_pick_two;
  end if;
  v_multiplier := case v_matches when 3 then 2 when 4 then 4 when 5 then 8 when 6 then 15 else 0 end;
  v_payout := p_bet * v_multiplier;
  update profiles set coins = coins - p_bet + v_payout, played = played + 1,
    won = won + case when v_payout > p_bet then 1 else 0 end, updated_at = now()
    where id = p_player_id returning coins into v_coins;
  insert into game_history(player_id,pick_one,pick_two,dice,bet,matches,payout)
    values(p_player_id,p_pick_one,p_pick_two,v_dice,p_bet,v_matches,v_payout);
  insert into wallet_ledger(player_id,delta,reason)
    values(p_player_id,-p_bet,'game bet');
  if v_payout > 0 then
    insert into wallet_ledger(player_id,delta,reason) values(p_player_id,v_payout,'game payout');
  end if;
  return jsonb_build_object('dice',v_dice,'matches',v_matches,'bet',p_bet,'payout',v_payout,'coins',v_coins);
end; $$;

create or replace function public.adjust_player_coins(p_player_id uuid, p_delta bigint, p_reason text, p_host_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_coins bigint;
begin
  if p_delta = 0 or abs(p_delta) > 1000000 then raise exception 'Invalid adjustment'; end if;
  update profiles set coins = coins + p_delta, updated_at = now()
    where id = p_player_id and coins + p_delta >= 0 returning coins into v_coins;
  if not found then raise exception 'Player not found or balance would become negative'; end if;
  insert into wallet_ledger(player_id,delta,reason,created_by)
    values(p_player_id,p_delta,left(coalesce(p_reason,'host adjustment'),120),p_host_id);
  return jsonb_build_object('player_id',p_player_id,'delta',p_delta,'coins',v_coins);
end; $$;

create or replace function public.review_payment(p_request_id uuid, p_status text, p_reviewer uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_row payment_requests%rowtype; v_coins bigint;
begin
  if p_status not in ('approved','rejected','completed') then raise exception 'Invalid status'; end if;
  select * into v_row from payment_requests where id = p_request_id for update;
  if not found then raise exception 'Request not found'; end if;
  if v_row.status <> 'pending' then raise exception 'Request already reviewed'; end if;
  if p_status = 'approved' and v_row.request_type = 'buy' then
    update profiles set coins = coins + v_row.coins, updated_at = now()
      where id = v_row.player_id returning coins into v_coins;
    insert into wallet_ledger(player_id,delta,reason,reference_id,created_by)
      values(v_row.player_id,v_row.coins,'approved coin purchase',v_row.id,p_reviewer);
  elsif p_status = 'approved' and v_row.request_type = 'exchange' then
    update profiles set coins = coins - v_row.coins, updated_at = now()
      where id = v_row.player_id and coins >= v_row.coins returning coins into v_coins;
    if not found then raise exception 'Player has insufficient coins'; end if;
    insert into wallet_ledger(player_id,delta,reason,reference_id,created_by)
      values(v_row.player_id,-v_row.coins,'approved coin exchange',v_row.id,p_reviewer);
  end if;
  update payment_requests set status = p_status, reviewed_by = p_reviewer, reviewed_at = now()
    where id = p_request_id;
  return jsonb_build_object('id',p_request_id,'status',p_status,'coins',v_coins);
end; $$;

revoke all on function public.play_game(uuid,integer,integer,bigint) from public, anon, authenticated;
revoke all on function public.adjust_player_coins(uuid,bigint,text,uuid) from public, anon, authenticated;
revoke all on function public.review_payment(uuid,text,uuid) from public, anon, authenticated;
grant execute on function public.play_game(uuid,integer,integer,bigint) to service_role;
grant execute on function public.adjust_player_coins(uuid,bigint,text,uuid) to service_role;
grant execute on function public.review_payment(uuid,text,uuid) to service_role;
