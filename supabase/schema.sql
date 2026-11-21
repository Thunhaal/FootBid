-- FootBid v0.5 multiplayer schema
-- Run this entire file once in Supabase SQL Editor.
-- Uses anonymous Supabase Auth identities; enable Auth > Sign In / Providers > Anonymous.

create extension if not exists pgcrypto;
create schema if not exists footbid_private;

create table if not exists public.fb_rooms (
  id uuid primary key default gen_random_uuid(),
  room_code text unique not null,
  created_by uuid not null references auth.users(id) on delete cascade,
  status text not null default 'lobby' check (status in ('lobby','ready','live','finished')),
  settings jsonb not null,
  pool_players jsonb not null,
  player_queue text[] not null,
  sold_ids text[] not null default '{}',
  unsold_ids text[] not null default '{}',
  current_player_id text,
  current_player jsonb,
  current_bid integer not null default 0,
  highest_bidder_team_id uuid,
  active_team_ids uuid[] not null default '{}',
  last_message text not null default 'Room created. Waiting for contestants.',
  created_at timestamptz not null default now()
);

create table if not exists public.fb_teams (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.fb_rooms(id) on delete cascade,
  team_name text not null,
  seat_claimed boolean not null default false,
  budget_remaining integer not null,
  purchases jsonb not null default '[]'::jsonb,
  formation text not null default '4-3-3',
  lineup jsonb not null default '{}'::jsonb,
  submitted boolean not null default false,
  created_at timestamptz not null default now(),
  unique(room_id, team_name)
);

create table if not exists public.fb_members (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.fb_rooms(id) on delete cascade,
  team_id uuid not null references public.fb_teams(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  is_host boolean not null default false,
  joined_at timestamptz not null default now(),
  unique(room_id, user_id),
  unique(room_id, team_id)
);

create table if not exists public.fb_bids (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.fb_rooms(id) on delete cascade,
  team_id uuid not null references public.fb_teams(id) on delete cascade,
  player_id text not null,
  amount integer not null check (amount > 0),
  created_at timestamptz not null default now()
);

create index if not exists fb_teams_room_idx on public.fb_teams(room_id);
create index if not exists fb_members_user_room_idx on public.fb_members(user_id, room_id);
create index if not exists fb_bids_room_idx on public.fb_bids(room_id, created_at);

alter table public.fb_rooms enable row level security;
alter table public.fb_teams enable row level security;
alter table public.fb_members enable row level security;
alter table public.fb_bids enable row level security;

-- No browser receives direct INSERT/UPDATE/DELETE privileges. Mutations go through
-- the checked database functions below. Team/member identity is never directly exposed.
revoke all on public.fb_rooms, public.fb_teams, public.fb_members, public.fb_bids from public, anon, authenticated;
grant usage on schema footbid_private to authenticated;
grant select on public.fb_rooms, public.fb_teams, public.fb_bids to authenticated;

create or replace function footbid_private.fb_is_room_member(p_room_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.fb_members m
    where m.room_id = p_room_id and m.user_id = (select auth.uid())
  );
$$;

revoke all on function footbid_private.fb_is_room_member(uuid) from public, anon;
grant execute on function footbid_private.fb_is_room_member(uuid) to authenticated;

drop policy if exists fb_room_member_read_rooms on public.fb_rooms;
create policy fb_room_member_read_rooms on public.fb_rooms
for select to authenticated
using ((select footbid_private.fb_is_room_member(id)));

drop policy if exists fb_room_member_read_teams on public.fb_teams;
create policy fb_room_member_read_teams on public.fb_teams
for select to authenticated
using ((select footbid_private.fb_is_room_member(room_id)));

drop policy if exists fb_room_member_read_bids on public.fb_bids;
create policy fb_room_member_read_bids on public.fb_bids
for select to authenticated
using ((select footbid_private.fb_is_room_member(room_id)));

-- fb_members deliberately has no SELECT policy and no SELECT grant.
-- A caller can only learn their own team identity through an authorized RPC.

create or replace function public.fb_create_room(
  p_team_names text[],
  p_settings jsonb,
  p_pool_players jsonb,
  p_queue text[]
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := (select auth.uid());
  v_room_id uuid;
  v_team_id uuid;
  v_code text;
  v_name text;
  v_index integer := 0;
  v_pool_count integer;
  v_queue_count integer;
  v_tier text;
  v_required integer;
begin
  if v_user is null then raise exception 'Sign in before creating a room.'; end if;
  if coalesce(array_length(p_team_names,1),0) < 2 or array_length(p_team_names,1) > 8 then
    raise exception 'A room needs between 2 and 8 teams.';
  end if;
  if exists (select 1 from unnest(p_team_names) as n(team_name) where trim(team_name)='') then
    raise exception 'Team names cannot be blank.';
  end if;
  if (select count(distinct lower(trim(team_name))) from unnest(p_team_names) as n(team_name)) <> array_length(p_team_names,1) then
    raise exception 'Team names must be unique.';
  end if;
  if coalesce((p_settings->>'budget')::integer,0) < 50 then raise exception 'Team budget must be at least 50 points.'; end if;
  if coalesce((p_settings->>'squadSize')::integer,0) < 1 then raise exception 'Squad size must be at least one player.'; end if;
  if jsonb_typeof(p_pool_players) <> 'array' then raise exception 'Player pool is invalid.'; end if;
  v_pool_count := jsonb_array_length(p_pool_players);
  v_queue_count := coalesce(array_length(p_queue,1),0);
  if v_pool_count < 90 then raise exception 'Every auction must contain at least 90 players.'; end if;
  if coalesce((p_settings->>'auctionPoolSize')::integer,v_pool_count) <> v_pool_count then
    raise exception 'Auction pool size setting does not match the selected player pool.';
  end if;
  if v_queue_count <> v_pool_count then raise exception 'Player queue does not match the selected player pool.'; end if;
  if (select count(distinct player_id) from unnest(p_queue) as q(player_id)) <> v_queue_count then raise exception 'Player queue contains duplicate players.'; end if;
  if (select count(distinct p.value->>'id') from jsonb_array_elements(p_pool_players) as p(value)) <> v_pool_count then
    raise exception 'Player pool contains duplicate or missing player IDs.';
  end if;
  if exists (select 1 from jsonb_each_text(p_settings->'tierOpeningBids') as bids(tier,amount) where amount::integer < 1) then
    raise exception 'Tier opening prices must be positive whole numbers.';
  end if;
  if exists (
    select 1 from unnest(p_queue) as q(player_id)
    where not exists (select 1 from jsonb_array_elements(p_pool_players) as p(value) where p.value->>'id'=q.player_id)
  ) then raise exception 'Player queue contains a player outside the selected pool.'; end if;

  for v_tier, v_required in
    select * from (values ('ICON',12),('LEGENDARY',18),('WORLD CLASS',20),('ELITE',20),('RISING STAR',20)) as quotas(tier,required_count)
  loop
    if (select count(*) from jsonb_array_elements(p_pool_players) as p(value) where p.value->>'tier'=v_tier) < v_required then
      raise exception 'Selected pool needs at least % players in tier %.', v_required, v_tier;
    end if;
  end loop;

  loop
    v_code := upper(substr(replace(gen_random_uuid()::text,'-',''),1,6));
    exit when not exists(select 1 from public.fb_rooms r where r.room_code=v_code);
  end loop;

  insert into public.fb_rooms(room_code,created_by,settings,pool_players,player_queue)
    values(v_code,v_user,p_settings,p_pool_players,p_queue)
    returning id into v_room_id;

  foreach v_name in array p_team_names loop
    v_index := v_index + 1;
    insert into public.fb_teams(room_id,team_name,seat_claimed,budget_remaining)
      values(v_room_id,trim(v_name),v_index=1,(p_settings->>'budget')::integer)
      returning id into v_team_id;
    if v_index=1 then
      insert into public.fb_members(room_id,team_id,user_id,is_host)
        values(v_room_id,v_team_id,v_user,true);
    end if;
  end loop;

  return jsonb_build_object('room_id',v_room_id,'room_code',v_code,'my_team_id',
    (select m.team_id from public.fb_members m where m.room_id=v_room_id and m.user_id=v_user));
end;
$$;

create or replace function public.fb_get_room_lobby(p_room_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_room public.fb_rooms; v_user uuid := (select auth.uid()); v_my_team uuid;
begin
  if v_user is null then raise exception 'Sign in before joining a room.'; end if;
  select * into v_room from public.fb_rooms r where r.room_code=upper(trim(p_room_code));
  if not found then raise exception 'Room code not found.'; end if;
  select m.team_id into v_my_team from public.fb_members m where m.room_id=v_room.id and m.user_id=v_user;
  return jsonb_build_object(
    'room_id',v_room.id,'room_code',v_room.room_code,'status',v_room.status,
    'settings',v_room.settings,'my_team_id',v_my_team,
    'teams',(select coalesce(jsonb_agg(jsonb_build_object('id',t.id,'team_name',t.team_name,'is_seated',t.seat_claimed) order by t.created_at),'[]'::jsonb)
             from public.fb_teams t where t.room_id=v_room.id)
  );
end;
$$;

create or replace function public.fb_join_room(p_room_code text,p_team_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_user uuid := (select auth.uid()); v_room public.fb_rooms; v_existing uuid; v_team public.fb_teams;
begin
  if v_user is null then raise exception 'Sign in before joining a room.'; end if;
  select * into v_room from public.fb_rooms r where r.room_code=upper(trim(p_room_code)) for update;
  if not found then raise exception 'Room code not found.'; end if;
  select m.team_id into v_existing from public.fb_members m where m.room_id=v_room.id and m.user_id=v_user;
  if v_existing is not null then
    return jsonb_build_object('room_id',v_room.id,'room_code',v_room.room_code,'my_team_id',v_existing);
  end if;
  if v_room.status <> 'lobby' then raise exception 'This auction has already started. Joining is closed.'; end if;
  select * into v_team from public.fb_teams t where t.id=p_team_id and t.room_id=v_room.id for update;
  if not found then raise exception 'That team does not belong to this room.'; end if;
  if v_team.seat_claimed then raise exception 'That team has already been claimed. Choose another team.'; end if;
  update public.fb_teams set seat_claimed=true where id=v_team.id;
  insert into public.fb_members(room_id,team_id,user_id,is_host) values(v_room.id,v_team.id,v_user,false);
  update public.fb_rooms set last_message=v_team.team_name || ' joined the room.' where id=v_room.id;
  return jsonb_build_object('room_id',v_room.id,'room_code',v_room.room_code,'my_team_id',v_team.id);
end;
$$;

create or replace function public.fb_room_snapshot(p_room_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room public.fb_rooms;
  v_user uuid := (select auth.uid());
  v_my_team uuid;
  v_is_host boolean;
begin
  select * into v_room from public.fb_rooms r where r.room_code=upper(trim(p_room_code));
  if not found then raise exception 'Room code not found.'; end if;
  select m.team_id,m.is_host into v_my_team,v_is_host
    from public.fb_members m where m.room_id=v_room.id and m.user_id=v_user;
  if v_my_team is null then raise exception 'You are not a member of this room.'; end if;

  return jsonb_build_object(
    'room_id',v_room.id,'room_code',v_room.room_code,'status',v_room.status,
    'settings',v_room.settings,'pool_players',v_room.pool_players,
    'queue_count',coalesce(array_length(v_room.player_queue,1),0),
    'current_player',v_room.current_player,'current_bid',v_room.current_bid,
    'highest_bidder_team_id',v_room.highest_bidder_team_id,
    'active_team_ids',to_jsonb(v_room.active_team_ids),'last_message',v_room.last_message,
    'my_team_id',v_my_team,'is_host',coalesce(v_is_host,false),
    'teams',(select coalesce(jsonb_agg(jsonb_build_object(
      'id',t.id,'team_name',t.team_name,'is_seated',t.seat_claimed,
      'budget_remaining',t.budget_remaining,'purchases',t.purchases,
      'formation',t.formation,'lineup',t.lineup,'submitted',t.submitted,
      'is_mine',(t.id=v_my_team)
    ) order by t.created_at),'[]'::jsonb) from public.fb_teams t where t.room_id=v_room.id)
  );
end;
$$;

create or replace function footbid_private.fb_complete_lot(
  p_room_id uuid,p_winner_team_id uuid,p_price integer,p_reason text
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_room public.fb_rooms; v_team public.fb_teams;
begin
  select * into v_room from public.fb_rooms r where r.id=p_room_id for update;
  select * into v_team from public.fb_teams t where t.id=p_winner_team_id and t.room_id=p_room_id for update;
  if v_room.current_player is null or not found then raise exception 'Auction lot is no longer active.'; end if;
  if v_team.budget_remaining < p_price then raise exception 'Winning team no longer has enough points.'; end if;

  update public.fb_teams
    set budget_remaining=budget_remaining-p_price,
        purchases=purchases || jsonb_build_array(jsonb_build_object(
          'playerId',v_room.current_player->>'id','price',p_price
        ))
    where id=v_team.id;

  update public.fb_rooms
    set status='ready',sold_ids=array_append(sold_ids,v_room.current_player->>'id'),
        current_player_id=null,current_player=null,current_bid=0,
        highest_bidder_team_id=null,active_team_ids='{}',last_message=
          'SOLD! ' || (v_room.current_player->>'name') || ' goes to ' || v_team.team_name ||
          ' for ' || p_price::text || ' points' ||
          case when p_reason='last-standing' then ' — last team remaining.' else '.' end
    where id=p_room_id;
end;
$$;

create or replace function public.fb_start_next_player(p_room_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room public.fb_rooms;
  v_host boolean;
  v_player_id text;
  v_player jsonb;
  v_remaining text[];
  v_active uuid[];
  v_price integer;
begin
  select * into v_room from public.fb_rooms r where r.room_code=upper(trim(p_room_code)) for update;
  if not found then raise exception 'Room code not found.'; end if;
  select m.is_host into v_host from public.fb_members m where m.room_id=v_room.id and m.user_id=(select auth.uid());
  if not coalesce(v_host,false) then raise exception 'Only the organiser can reveal the next player.'; end if;
  if v_room.status='live' then raise exception 'Finish the current player auction first.'; end if;
  if v_room.status='finished' then raise exception 'The auction is already complete.'; end if;
  if v_room.status='lobby' and exists(select 1 from public.fb_teams t where t.room_id=v_room.id and t.seat_claimed=false) then
    raise exception 'Wait until every contestant has claimed a team before starting.';
  end if;

  v_active := array(
    select t.id from public.fb_teams t
    where t.room_id=v_room.id and t.seat_claimed=true and t.submitted=false
      and jsonb_array_length(t.purchases) < (v_room.settings->>'squadSize')::integer
  );
  if coalesce(array_length(v_active,1),0)=0 then
    update public.fb_rooms set status='finished',last_message='All teams have submitted or filled their squads. Auction complete.'
      where id=v_room.id;
    return jsonb_build_object('status','finished');
  end if;

  if coalesce(array_length(v_room.player_queue,1),0)=0 then
    update public.fb_rooms set status='finished',last_message='All selected players have been auctioned. Finalise your formations and submit your teams.'
      where id=v_room.id;
    return jsonb_build_object('status','finished');
  end if;

  v_player_id := v_room.player_queue[1];
  if array_length(v_room.player_queue,1)>1 then
    v_remaining := v_room.player_queue[2:array_length(v_room.player_queue,1)];
  else
    v_remaining := '{}';
  end if;
  select p.value into v_player from jsonb_array_elements(v_room.pool_players) as p(value) where p.value->>'id'=v_player_id;
  if v_player is null then raise exception 'Player % was not found in this room pool.',v_player_id; end if;
  v_price := coalesce((v_room.settings->'tierOpeningBids'->>(v_player->>'tier'))::integer,(v_player->>'startBid')::integer);

  update public.fb_rooms set status='live',player_queue=v_remaining,
    current_player_id=v_player_id,current_player=v_player,current_bid=v_price,
    highest_bidder_team_id=null,active_team_ids=v_active,
    last_message=(v_player->>'name') || ' is on the block. Opening bid: ' || v_price::text || ' points. No timer.'
    where id=v_room.id;
  return jsonb_build_object('status','live','current_player_id',v_player_id,'opening_bid',v_price);
end;
$$;

create or replace function public.fb_place_bid(p_room_code text,p_amount integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room public.fb_rooms;
  v_team_id uuid;
  v_team public.fb_teams;
  v_minimum integer;
begin
  select * into v_room from public.fb_rooms r where r.room_code=upper(trim(p_room_code)) for update;
  if not found or v_room.status <> 'live' or v_room.current_player is null then raise exception 'There is no live auction.'; end if;
  select m.team_id into v_team_id from public.fb_members m where m.room_id=v_room.id and m.user_id=(select auth.uid());
  if v_team_id is null then raise exception 'You are not a contestant in this room.'; end if;
  if not coalesce(v_team_id=any(v_room.active_team_ids),false) then raise exception 'Your team has quit this player auction.'; end if;
  if v_room.highest_bidder_team_id=v_team_id then raise exception 'Your team is already the highest bidder.'; end if;
  v_minimum := case when v_room.highest_bidder_team_id is null then v_room.current_bid else v_room.current_bid+1 end;
  if p_amount is null or p_amount < v_minimum then raise exception 'Bid must be at least % points.',v_minimum; end if;
  select * into v_team from public.fb_teams t where t.id=v_team_id for update;
  if v_team.submitted then raise exception 'Your team has already submitted its final squad.'; end if;
  if jsonb_array_length(v_team.purchases) >= (v_room.settings->>'squadSize')::integer then raise exception 'Your squad is already full.'; end if;
  if v_team.budget_remaining < p_amount then raise exception 'Your team does not have enough points.'; end if;

  update public.fb_rooms set current_bid=p_amount,highest_bidder_team_id=v_team_id,
    last_message=v_team.team_name || ' bids ' || p_amount::text || ' points.'
    where id=v_room.id;
  insert into public.fb_bids(room_id,team_id,player_id,amount)
    values(v_room.id,v_team_id,v_room.current_player_id,p_amount);

  if cardinality(v_room.active_team_ids)=1 then
    perform footbid_private.fb_complete_lot(v_room.id,v_team_id,p_amount,'last-standing');
    return jsonb_build_object('status','sold','winner_team_id',v_team_id,'price',p_amount);
  end if;
  return jsonb_build_object('status','bid-placed','amount',p_amount);
end;
$$;

create or replace function public.fb_quit_lot(p_room_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room public.fb_rooms;
  v_team_id uuid;
  v_team public.fb_teams;
  v_active uuid[];
  v_player_name text;
begin
  select * into v_room from public.fb_rooms r where r.room_code=upper(trim(p_room_code)) for update;
  if not found or v_room.status <> 'live' or v_room.current_player is null then raise exception 'There is no live auction.'; end if;
  select m.team_id into v_team_id from public.fb_members m where m.room_id=v_room.id and m.user_id=(select auth.uid());
  if v_team_id is null then raise exception 'You are not a contestant in this room.'; end if;
  if v_room.highest_bidder_team_id=v_team_id then raise exception 'The highest bidder cannot quit while leading this player.'; end if;
  if not coalesce(v_team_id=any(v_room.active_team_ids),false) then raise exception 'Your team has already quit this lot.'; end if;

  select * into v_team from public.fb_teams t where t.id=v_team_id;
  v_active := array_remove(v_room.active_team_ids,v_team_id);
  if cardinality(v_active)=0 then
    v_player_name := v_room.current_player->>'name';
    update public.fb_rooms set status='ready',unsold_ids=array_append(unsold_ids,current_player_id),
      current_player_id=null,current_player=null,current_bid=0,highest_bidder_team_id=null,
      active_team_ids='{}',last_message='UNSOLD! ' || v_player_name || ' received no bids; every team quit.'
      where id=v_room.id;
    return jsonb_build_object('status','unsold');
  end if;

  if cardinality(v_active)=1 and v_room.highest_bidder_team_id is not null
      and v_active[1]=v_room.highest_bidder_team_id then
    perform footbid_private.fb_complete_lot(v_room.id,v_room.highest_bidder_team_id,v_room.current_bid,'last-standing');
    return jsonb_build_object('status','sold','winner_team_id',v_room.highest_bidder_team_id,'price',v_room.current_bid);
  end if;

  update public.fb_rooms set active_team_ids=v_active,
    last_message=v_team.team_name || ' quit this player. ' || cardinality(v_active)::text || ' teams remain.'
    where id=v_room.id;
  return jsonb_build_object('status','quit','teams_remaining',cardinality(v_active));
end;
$$;

create or replace function public.fb_update_my_team(
  p_room_code text,p_formation text,p_lineup jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room public.fb_rooms;
  v_team_id uuid;
  v_team public.fb_teams;
  v_entry record;
  v_role text;
  v_player_position text;
  v_slot_no integer;
  v_max_slots integer;
begin
  select * into v_room from public.fb_rooms r where r.room_code=upper(trim(p_room_code)) for update;
  if not found then raise exception 'Room code not found.'; end if;
  select m.team_id into v_team_id from public.fb_members m where m.room_id=v_room.id and m.user_id=(select auth.uid());
  if v_team_id is null then raise exception 'You are not a contestant in this room.'; end if;
  select * into v_team from public.fb_teams t where t.id=v_team_id for update;
  if v_team.submitted then raise exception 'Your team is locked because it has been submitted.'; end if;
  if p_formation is null or p_formation not in ('4-3-3','4-4-2','4-2-3-1','3-5-2','3-4-3','5-3-2') then raise exception 'Formation is not supported.'; end if;
  if p_lineup is null or jsonb_typeof(p_lineup) <> 'object' then raise exception 'Line-up data is invalid.'; end if;
  if (select count(*) from (select value from jsonb_each_text(p_lineup)) x)
     <> (select count(distinct value) from jsonb_each_text(p_lineup)) then
    raise exception 'A player cannot occupy more than one formation slot.';
  end if;

  for v_entry in select key,value from jsonb_each_text(p_lineup) loop
    v_role := split_part(v_entry.key,'-',1);
    if v_role not in ('GK','DEF','MID','FWD') then raise exception 'Invalid formation slot.'; end if;
    begin
      v_slot_no := split_part(v_entry.key,'-',2)::integer;
    exception when others then
      raise exception 'Invalid formation slot.';
    end;
    v_max_slots := case
      when v_role='GK' then 1
      when v_role='DEF' then case p_formation when '3-5-2' then 3 when '3-4-3' then 3 when '5-3-2' then 5 else 4 end
      when v_role='MID' then case p_formation when '4-3-3' then 3 when '4-4-2' then 4 when '4-2-3-1' then 5 when '3-5-2' then 5 when '3-4-3' then 4 else 3 end
      when v_role='FWD' then case p_formation when '4-3-3' then 3 when '4-4-2' then 2 when '4-2-3-1' then 1 when '3-5-2' then 2 when '3-4-3' then 3 else 2 end
      else 0 end;
    if v_slot_no < 1 or v_slot_no > v_max_slots then raise exception 'Slot % is not part of formation %.',v_entry.key,p_formation; end if;
    if not exists (
      select 1 from jsonb_array_elements(v_team.purchases) as purchase(value)
      where purchase.value->>'playerId'=v_entry.value
    ) then raise exception 'You can only assign players owned by your team.'; end if;
    select player.value->>'position' into v_player_position
      from jsonb_array_elements(v_room.pool_players) as player(value)
      where player.value->>'id'=v_entry.value;
    if v_player_position is distinct from v_role then
      raise exception 'Player position does not match formation slot %.',v_entry.key;
    end if;
  end loop;

  update public.fb_teams set formation=p_formation,lineup=p_lineup where id=v_team_id;
  update public.fb_rooms set last_message=v_team.team_name || ' updated its formation to ' || p_formation || '.'
    where id=v_room.id;
  return jsonb_build_object('formation',p_formation,'lineup',p_lineup);
end;
$$;

create or replace function public.fb_submit_my_team(p_room_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_room public.fb_rooms; v_team_id uuid; v_team public.fb_teams;
begin
  select * into v_room from public.fb_rooms r where r.room_code=upper(trim(p_room_code)) for update;
  if not found then raise exception 'Room code not found.'; end if;
  if v_room.status <> 'finished' then raise exception 'The auction must finish before final submission.'; end if;
  select m.team_id into v_team_id from public.fb_members m where m.room_id=v_room.id and m.user_id=(select auth.uid());
  if v_team_id is null then raise exception 'You are not a contestant in this room.'; end if;
  select * into v_team from public.fb_teams t where t.id=v_team_id for update;
  if v_team.submitted then raise exception 'Your team has already been submitted.'; end if;
  update public.fb_teams set submitted=true where id=v_team_id;
  update public.fb_rooms set last_message=v_team.team_name || ' submitted its final team.' where id=v_room.id;
  return jsonb_build_object('submitted',true);
end;
$$;

-- Restrict all public RPCs to authenticated (including anonymous-auth) users.
revoke all on function public.fb_create_room(text[],jsonb,jsonb,text[]) from public, anon;
revoke all on function public.fb_get_room_lobby(text) from public, anon;
revoke all on function public.fb_join_room(text,uuid) from public, anon;
revoke all on function public.fb_room_snapshot(text) from public, anon;
revoke all on function public.fb_start_next_player(text) from public, anon;
revoke all on function public.fb_place_bid(text,integer) from public, anon;
revoke all on function public.fb_quit_lot(text) from public, anon;
revoke all on function public.fb_update_my_team(text,text,jsonb) from public, anon;
revoke all on function public.fb_submit_my_team(text) from public, anon;
revoke all on function footbid_private.fb_complete_lot(uuid,uuid,integer,text) from public, anon, authenticated;

grant execute on function public.fb_create_room(text[],jsonb,jsonb,text[]) to authenticated;
grant execute on function public.fb_get_room_lobby(text) to authenticated;
grant execute on function public.fb_join_room(text,uuid) to authenticated;
grant execute on function public.fb_room_snapshot(text) to authenticated;
grant execute on function public.fb_start_next_player(text) to authenticated;
grant execute on function public.fb_place_bid(text,integer) to authenticated;
grant execute on function public.fb_quit_lot(text) to authenticated;
grant execute on function public.fb_update_my_team(text,text,jsonb) to authenticated;
grant execute on function public.fb_submit_my_team(text) to authenticated;

-- Enable Postgres Changes on the room and team state tables.
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='fb_rooms') then
    execute 'alter publication supabase_realtime add table public.fb_rooms';
  end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='fb_teams') then
    execute 'alter publication supabase_realtime add table public.fb_teams';
  end if;
end $$;


-- v0.7 upgrade included for new installations

-- FootBid v0.7 migration
-- Apply ONCE in Supabase SQL Editor after deploying the v0.7 frontend.
-- Adds editable tactical placements, the 489-player category schema,
-- dataset base-price bidding and automatic next-player advancement.

ALTER TABLE public.fb_teams
  ADD COLUMN IF NOT EXISTS tactical_lineup jsonb NOT NULL DEFAULT '[]'::jsonb;

-- Convert old fixed formation maps to movable tactical placements so historic rooms remain readable.
UPDATE public.fb_teams t
SET tactical_lineup = COALESCE((
  SELECT jsonb_agg(
    jsonb_build_object(
      'playerId', e.value,
      'role', CASE split_part(e.key,'-',1)
        WHEN 'GK' THEN 'GK'
        WHEN 'DEF' THEN CASE WHEN split_part(e.key,'-',2)='1' THEN 'LB'
                              WHEN split_part(e.key,'-',2)='4' THEN 'RB' ELSE 'CB' END
        WHEN 'MID' THEN CASE WHEN split_part(e.key,'-',2)='1' THEN 'DMF'
                              WHEN split_part(e.key,'-',2)='2' THEN 'CMF' ELSE 'AMF' END
        WHEN 'FWD' THEN 'CF'
        ELSE 'CMF' END,
      'x', CASE split_part(e.key,'-',1)
        WHEN 'GK' THEN 50
        WHEN 'DEF' THEN CASE WHEN split_part(e.key,'-',2)='1' THEN 22 WHEN split_part(e.key,'-',2)='4' THEN 78 ELSE 50 END
        WHEN 'MID' THEN CASE WHEN split_part(e.key,'-',2)='1' THEN 35 WHEN split_part(e.key,'-',2)='2' THEN 50 ELSE 65 END
        WHEN 'FWD' THEN 25
        ELSE 50 END,
      'y', CASE split_part(e.key,'-',1)
        WHEN 'GK' THEN 91 WHEN 'DEF' THEN 75 WHEN 'MID' THEN 50 WHEN 'FWD' THEN 25 ELSE 50 END
    )
    ORDER BY e.key
  )
  FROM jsonb_each_text(t.lineup) AS e(key,value)
), '[]'::jsonb)
WHERE jsonb_typeof(t.lineup)='object'
  AND t.tactical_lineup='[]'::jsonb
  AND t.lineup <> '{}'::jsonb;

-- The room snapshot returns the movable placement array rather than the old fixed-slot object.
CREATE OR REPLACE FUNCTION public.fb_room_snapshot(p_room_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_room public.fb_rooms;
  v_user uuid := (SELECT auth.uid());
  v_my_team uuid;
  v_is_host boolean;
BEGIN
  SELECT * INTO v_room FROM public.fb_rooms r WHERE r.room_code=upper(trim(p_room_code));
  IF NOT FOUND THEN RAISE EXCEPTION 'Room code not found.'; END IF;
  SELECT m.team_id,m.is_host INTO v_my_team,v_is_host
    FROM public.fb_members m WHERE m.room_id=v_room.id AND m.user_id=v_user;
  IF v_my_team IS NULL THEN RAISE EXCEPTION 'You are not a member of this room.'; END IF;

  RETURN jsonb_build_object(
    'room_id',v_room.id,'room_code',v_room.room_code,'status',v_room.status,
    'settings',v_room.settings,'pool_players',v_room.pool_players,
    'queue_count',coalesce(array_length(v_room.player_queue,1),0),
    'current_player',v_room.current_player,'current_bid',v_room.current_bid,
    'highest_bidder_team_id',v_room.highest_bidder_team_id,
    'active_team_ids',to_jsonb(v_room.active_team_ids),'last_message',v_room.last_message,
    'my_team_id',v_my_team,'is_host',coalesce(v_is_host,false),
    'teams',(SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id',t.id,'team_name',t.team_name,'is_seated',t.seat_claimed,
      'budget_remaining',t.budget_remaining,'purchases',t.purchases,
      'formation',t.formation,'lineup',coalesce(t.tactical_lineup,'[]'::jsonb),
      'submitted',t.submitted,'is_mine',(t.id=v_my_team)
    ) ORDER BY t.created_at),'[]'::jsonb) FROM public.fb_teams t WHERE t.room_id=v_room.id)
  );
END;
$$;

-- Shared internal function: settle/unsold paths call this to reveal the next player immediately.
CREATE OR REPLACE FUNCTION footbid_private.fb_advance_to_next_player(p_room_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_room public.fb_rooms;
  v_active uuid[];
  v_player_id text;
  v_player jsonb;
  v_remaining text[];
  v_price integer;
  v_previous_message text;
BEGIN
  SELECT * INTO v_room FROM public.fb_rooms r WHERE r.id=p_room_id FOR UPDATE;
  IF NOT FOUND OR v_room.status='finished' THEN RETURN; END IF;
  IF v_room.current_player_id IS NOT NULL THEN RETURN; END IF;

  v_active := ARRAY(
    SELECT t.id FROM public.fb_teams t
    WHERE t.room_id=v_room.id
      AND t.seat_claimed=true
      AND t.submitted=false
      AND jsonb_array_length(t.purchases) < (v_room.settings->>'squadSize')::integer
  );

  IF coalesce(cardinality(v_active),0)=0 THEN
    UPDATE public.fb_rooms
      SET status='finished',
          last_message='All contestant squads are full or submitted. Auction complete.'
      WHERE id=p_room_id;
    RETURN;
  END IF;

  IF coalesce(cardinality(v_room.player_queue),0)=0 THEN
    UPDATE public.fb_rooms
      SET status='finished',
          last_message='All selected players have been auctioned. Arrange your tactical XI and submit your final team.'
      WHERE id=p_room_id;
    RETURN;
  END IF;

  v_player_id := v_room.player_queue[1];
  IF cardinality(v_room.player_queue)>1 THEN
    v_remaining := v_room.player_queue[2:cardinality(v_room.player_queue)];
  ELSE
    v_remaining := '{}';
  END IF;

  SELECT p.value INTO v_player
  FROM jsonb_array_elements(v_room.pool_players) AS p(value)
  WHERE p.value->>'id'=v_player_id;

  IF v_player IS NULL THEN
    RAISE EXCEPTION 'Player % was not found in the room player pool.',v_player_id;
  END IF;

  v_previous_message := v_room.last_message;

  -- New dataset rooms use each player's own base_price. Legacy fields are only fallback support.
  v_price := coalesce(
    nullif(v_player->>'base_price','')::integer,
    nullif(v_room.settings->'tierOpeningBids'->>(v_player->>'tier'),'')::integer,
    nullif(v_player->>'startBid','')::integer,
    65
  );

  UPDATE public.fb_rooms
  SET status='live',
      player_queue=v_remaining,
      current_player_id=v_player_id,
      current_player=v_player,
      current_bid=v_price,
      highest_bidder_team_id=NULL,
      active_team_ids=v_active,
      last_message=CASE
        WHEN coalesce(v_previous_message,'') LIKE 'SOLD! %' OR coalesce(v_previous_message,'') LIKE 'UNSOLD! %'
          THEN v_previous_message || ' NEXT UP: ' || (v_player->>'name') || ' opens at ' || v_price::text || ' points.'
        ELSE (v_player->>'name') || ' is on the block. Opening bid: ' || v_price::text || ' points.'
      END
  WHERE id=p_room_id;
END;
$$;

-- Replace lot settlement to advance to the next player in the same transaction.
CREATE OR REPLACE FUNCTION footbid_private.fb_complete_lot(
  p_room_id uuid,p_winner_team_id uuid,p_price integer,p_reason text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_room public.fb_rooms;
  v_team public.fb_teams;
BEGIN
  SELECT * INTO v_room FROM public.fb_rooms r WHERE r.id=p_room_id FOR UPDATE;
  SELECT * INTO v_team FROM public.fb_teams t WHERE t.id=p_winner_team_id AND t.room_id=p_room_id FOR UPDATE;
  IF v_room.current_player IS NULL OR v_team.id IS NULL THEN
    RAISE EXCEPTION 'Auction lot is no longer active.';
  END IF;
  IF v_team.budget_remaining < p_price THEN
    RAISE EXCEPTION 'Winning team no longer has enough points.';
  END IF;

  UPDATE public.fb_teams
    SET budget_remaining=budget_remaining-p_price,
        purchases=purchases || jsonb_build_array(jsonb_build_object(
          'playerId',v_room.current_player->>'id','price',p_price
        ))
    WHERE id=v_team.id;

  UPDATE public.fb_rooms
    SET status='ready',
        sold_ids=array_append(sold_ids,v_room.current_player->>'id'),
        current_player_id=NULL,current_player=NULL,current_bid=0,
        highest_bidder_team_id=NULL,active_team_ids='{}',
        last_message='SOLD! ' || (v_room.current_player->>'name') || ' goes to ' || v_team.team_name ||
          ' for ' || p_price::text || ' points' ||
          CASE WHEN p_reason='last-standing' THEN ' — all competing teams quit.' ELSE '.' END
    WHERE id=p_room_id;

  PERFORM footbid_private.fb_advance_to_next_player(p_room_id);
END;
$$;

-- Organiser starts only the first lot; subsequent lots are automatic.
CREATE OR REPLACE FUNCTION public.fb_start_next_player(p_room_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_room public.fb_rooms;
  v_host boolean;
BEGIN
  SELECT * INTO v_room FROM public.fb_rooms r
    WHERE r.room_code=upper(trim(p_room_code)) FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Room code not found.'; END IF;

  SELECT m.is_host INTO v_host FROM public.fb_members m
    WHERE m.room_id=v_room.id AND m.user_id=(SELECT auth.uid());
  IF NOT coalesce(v_host,false) THEN
    RAISE EXCEPTION 'Only the organiser can start the auction.';
  END IF;
  IF v_room.status<>'lobby' THEN
    RAISE EXCEPTION 'The auction has already started. Next players advance automatically.';
  END IF;
  IF EXISTS(SELECT 1 FROM public.fb_teams t WHERE t.room_id=v_room.id AND t.seat_claimed=false) THEN
    RAISE EXCEPTION 'Wait until every contestant has claimed a team before starting.';
  END IF;

  PERFORM footbid_private.fb_advance_to_next_player(v_room.id);
  RETURN jsonb_build_object('status','started');
END;
$$;

-- Close an unbid lot and immediately advance if everyone quits before anyone bids.
CREATE OR REPLACE FUNCTION public.fb_quit_lot(p_room_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_room public.fb_rooms;
  v_team_id uuid;
  v_team public.fb_teams;
  v_active uuid[];
  v_player_name text;
BEGIN
  SELECT * INTO v_room FROM public.fb_rooms r
    WHERE r.room_code=upper(trim(p_room_code)) FOR UPDATE;
  IF NOT FOUND OR v_room.status<>'live' OR v_room.current_player IS NULL THEN
    RAISE EXCEPTION 'There is no live auction.';
  END IF;
  SELECT m.team_id INTO v_team_id FROM public.fb_members m
    WHERE m.room_id=v_room.id AND m.user_id=(SELECT auth.uid());
  IF v_team_id IS NULL THEN RAISE EXCEPTION 'You are not a contestant in this room.'; END IF;
  IF v_room.highest_bidder_team_id=v_team_id THEN
    RAISE EXCEPTION 'The highest bidder cannot quit while leading this player.';
  END IF;
  IF NOT coalesce(v_team_id=ANY(v_room.active_team_ids),false) THEN
    RAISE EXCEPTION 'Your team has already quit this player.';
  END IF;

  SELECT * INTO v_team FROM public.fb_teams t WHERE t.id=v_team_id;
  v_active := array_remove(v_room.active_team_ids,v_team_id);

  IF cardinality(v_active)=0 THEN
    v_player_name := v_room.current_player->>'name';
    UPDATE public.fb_rooms
      SET status='ready',
          unsold_ids=array_append(unsold_ids,current_player_id),
          current_player_id=NULL,current_player=NULL,current_bid=0,
          highest_bidder_team_id=NULL,active_team_ids='{}',
          last_message='UNSOLD! ' || v_player_name || ' received no bids; every team quit.'
      WHERE id=v_room.id;
    PERFORM footbid_private.fb_advance_to_next_player(v_room.id);
    RETURN jsonb_build_object('status','unsold-and-advanced');
  END IF;

  IF cardinality(v_active)=1 AND v_room.highest_bidder_team_id IS NOT NULL
      AND v_active[1]=v_room.highest_bidder_team_id THEN
    PERFORM footbid_private.fb_complete_lot(v_room.id,v_room.highest_bidder_team_id,v_room.current_bid,'last-standing');
    RETURN jsonb_build_object('status','sold-and-advanced','winner_team_id',v_room.highest_bidder_team_id,'price',v_room.current_bid);
  END IF;

  UPDATE public.fb_rooms SET active_team_ids=v_active,
    last_message=v_team.team_name || ' quit this player. ' || cardinality(v_active)::text || ' teams remain.'
    WHERE id=v_room.id;
  RETURN jsonb_build_object('status','quit','teams_remaining',cardinality(v_active));
END;
$$;

-- Store a custom array of player placements on the pitch. Only the member's own team can be changed.
CREATE OR REPLACE FUNCTION public.fb_update_my_team(
  p_room_code text,p_formation text,p_lineup jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_room public.fb_rooms;
  v_team_id uuid;
  v_team public.fb_teams;
  v_entry jsonb;
  v_player_id text;
  v_role text;
  v_x numeric;
  v_y numeric;
  v_player jsonb;
  v_allowed text[];
BEGIN
  SELECT * INTO v_room FROM public.fb_rooms r
    WHERE r.room_code=upper(trim(p_room_code)) FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Room code not found.'; END IF;
  SELECT m.team_id INTO v_team_id FROM public.fb_members m
    WHERE m.room_id=v_room.id AND m.user_id=(SELECT auth.uid());
  IF v_team_id IS NULL THEN RAISE EXCEPTION 'You are not a contestant in this room.'; END IF;

  SELECT * INTO v_team FROM public.fb_teams t WHERE t.id=v_team_id FOR UPDATE;
  IF v_team.submitted THEN RAISE EXCEPTION 'Your team is locked because it has been submitted.'; END IF;
  IF p_formation IS NULL OR length(p_formation)>40 THEN RAISE EXCEPTION 'Formation label is invalid.'; END IF;
  IF p_lineup IS NULL OR jsonb_typeof(p_lineup)<>'array' THEN
    RAISE EXCEPTION 'Tactical lineup must be a JSON array of player placements.';
  END IF;
  IF jsonb_array_length(p_lineup)>11 THEN RAISE EXCEPTION 'A starting XI cannot contain more than 11 players.'; END IF;

  IF (
    SELECT count(*) FROM (SELECT value->>'playerId' AS player_id FROM jsonb_array_elements(p_lineup)) x
  ) <> (
    SELECT count(DISTINCT value->>'playerId') FROM jsonb_array_elements(p_lineup)
  ) THEN
    RAISE EXCEPTION 'A player cannot occupy more than one tactical position.';
  END IF;

  FOR v_entry IN SELECT value FROM jsonb_array_elements(p_lineup) LOOP
    IF jsonb_typeof(v_entry)<>'object' THEN
      RAISE EXCEPTION 'Each tactical placement must be a JSON object.';
    END IF;
    v_player_id := v_entry->>'playerId';
    v_role := v_entry->>'role';
    BEGIN
      v_x := (v_entry->>'x')::numeric;
      v_y := (v_entry->>'y')::numeric;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'Each placement needs numeric pitch coordinates.';
    END;

    IF v_player_id IS NULL OR v_role IS NULL OR v_role NOT IN ('GK','CB','LB','RB','DMF','CMF','AMF','SS','CF','LWF','RWF') THEN
      RAISE EXCEPTION 'Player ID or tactical role is invalid.';
    END IF;
    IF v_x IS NULL OR v_y IS NULL OR v_x<0 OR v_x>100 OR v_y<0 OR v_y>100 THEN
      RAISE EXCEPTION 'Pitch coordinates must be between 0 and 100.';
    END IF;
    IF NOT EXISTS(
      SELECT 1 FROM jsonb_array_elements(v_team.purchases) AS purchase(value)
      WHERE purchase.value->>'playerId'=v_player_id
    ) THEN
      RAISE EXCEPTION 'You can only position players owned by your team.';
    END IF;

    SELECT player.value INTO v_player
    FROM jsonb_array_elements(v_room.pool_players) AS player(value)
    WHERE player.value->>'id'=v_player_id;

    IF v_player IS NULL THEN RAISE EXCEPTION 'Player % is not part of this room pool.',v_player_id; END IF;

    v_allowed := CASE v_role
      WHEN 'GK' THEN ARRAY['GK']
      WHEN 'CB' THEN ARRAY['CB']
      WHEN 'LB' THEN ARRAY['LB','LWB']
      WHEN 'RB' THEN ARRAY['RB','RWB']
      WHEN 'DMF' THEN ARRAY['CDM']
      WHEN 'CMF' THEN ARRAY['CM']
      WHEN 'AMF' THEN ARRAY['CAM']
      WHEN 'SS' THEN ARRAY['ST','CF']
      WHEN 'CF' THEN ARRAY['CF','ST']
      WHEN 'LWF' THEN ARRAY['LW','LM']
      WHEN 'RWF' THEN ARRAY['RW','RM']
      ELSE ARRAY[]::text[]
    END;

    IF jsonb_typeof(v_player->'position')='array' THEN
      IF NOT EXISTS(
        SELECT 1 FROM jsonb_array_elements_text(v_player->'position') AS pos(value)
        WHERE pos.value=ANY(v_allowed)
      ) THEN
        RAISE EXCEPTION 'The dataset positions for % do not match tactical role %.',v_player->>'name',v_role;
      END IF;
    ELSE
      -- Legacy rooms have broad GK/DEF/MID/FWD labels; keep them editable after migration.
      IF NOT (
        (v_role='GK' AND v_player->>'position'='GK') OR
        (v_role IN ('CB','LB','RB') AND v_player->>'position'='DEF') OR
        (v_role IN ('DMF','CMF','AMF') AND v_player->>'position'='MID') OR
        (v_role IN ('SS','CF','LWF','RWF') AND v_player->>'position'='FWD')
      ) THEN
        RAISE EXCEPTION 'This legacy player position does not match tactical role %.',v_role;
      END IF;
    END IF;
  END LOOP;

  UPDATE public.fb_teams
    SET formation=p_formation,tactical_lineup=p_lineup
    WHERE id=v_team_id;
  UPDATE public.fb_rooms
    SET last_message=v_team.team_name || ' updated its tactical lineup.'
    WHERE id=v_room.id;
  RETURN jsonb_build_object('formation',p_formation,'lineup',p_lineup);
END;
$$;

-- Replace old tier-based create-room category checks with the dataset's three category labels.
CREATE OR REPLACE FUNCTION public.fb_create_room(
  p_team_names text[],
  p_settings jsonb,
  p_pool_players jsonb,
  p_queue text[]
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := (SELECT auth.uid());
  v_room_id uuid;
  v_team_id uuid;
  v_code text;
  v_name text;
  v_index integer := 0;
  v_pool_count integer;
  v_queue_count integer;
  v_category text;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Sign in before creating a room.'; END IF;
  IF coalesce(array_length(p_team_names,1),0)<2 OR array_length(p_team_names,1)>8 THEN
    RAISE EXCEPTION 'A room needs between 2 and 8 teams.';
  END IF;
  IF (SELECT count(DISTINCT lower(trim(team_name))) FROM unnest(p_team_names) AS n(team_name))<>array_length(p_team_names,1) THEN
    RAISE EXCEPTION 'Team names must be unique.';
  END IF;
  IF coalesce((p_settings->>'budget')::integer,0)<500 THEN RAISE EXCEPTION 'Team budget must be at least 500 points for this player pool.'; END IF;
  IF coalesce((p_settings->>'squadSize')::integer,0)<1 THEN RAISE EXCEPTION 'Squad size must be at least one player.'; END IF;
  IF jsonb_typeof(p_pool_players)<>'array' THEN RAISE EXCEPTION 'Player pool is invalid.'; END IF;
  v_pool_count:=jsonb_array_length(p_pool_players);
  v_queue_count:=coalesce(array_length(p_queue,1),0);
  IF v_pool_count<90 THEN RAISE EXCEPTION 'Every auction must contain at least 90 players.'; END IF;
  IF v_pool_count < array_length(p_team_names,1) * (p_settings->>'squadSize')::integer THEN
    RAISE EXCEPTION 'Player pool must contain enough players for all configured squads.';
  END IF;
  IF v_queue_count<>v_pool_count THEN RAISE EXCEPTION 'Player queue does not match the selected player pool.'; END IF;
  IF (SELECT count(DISTINCT player_id) FROM unnest(p_queue) AS q(player_id))<>v_queue_count THEN
    RAISE EXCEPTION 'Player queue contains duplicate players.';
  END IF;
  IF EXISTS(
    SELECT 1 FROM unnest(p_queue) AS q(player_id)
    WHERE NOT EXISTS(SELECT 1 FROM jsonb_array_elements(p_pool_players) AS p(value) WHERE p.value->>'id'=q.player_id)
  ) THEN RAISE EXCEPTION 'Player queue contains a player outside the selected pool.'; END IF;

  FOREACH v_category IN ARRAY ARRAY['Current','Icon','Hero'] LOOP
    IF NOT EXISTS(
      SELECT 1 FROM jsonb_array_elements(p_pool_players) AS p(value)
      WHERE p.value->>'category'=v_category
    ) THEN RAISE EXCEPTION 'The player pool must include Current, Icon and Hero categories.'; END IF;
  END LOOP;

  LOOP
    v_code:=upper(substr(replace(gen_random_uuid()::text,'-',''),1,6));
    EXIT WHEN NOT EXISTS(SELECT 1 FROM public.fb_rooms r WHERE r.room_code=v_code);
  END LOOP;

  INSERT INTO public.fb_rooms(room_code,created_by,settings,pool_players,player_queue)
    VALUES(v_code,v_user,p_settings,p_pool_players,p_queue)
    RETURNING id INTO v_room_id;

  FOREACH v_name IN ARRAY p_team_names LOOP
    v_index:=v_index+1;
    INSERT INTO public.fb_teams(room_id,team_name,seat_claimed,budget_remaining,formation,tactical_lineup)
      VALUES(v_room_id,trim(v_name),v_index=1,(p_settings->>'budget')::integer,'CUSTOM','[]'::jsonb)
      RETURNING id INTO v_team_id;
    IF v_index=1 THEN
      INSERT INTO public.fb_members(room_id,team_id,user_id,is_host)
        VALUES(v_room_id,v_team_id,v_user,true);
    END IF;
  END LOOP;

  RETURN jsonb_build_object('room_id',v_room_id,'room_code',v_code,'my_team_id',
    (SELECT m.team_id FROM public.fb_members m WHERE m.room_id=v_room_id AND m.user_id=v_user));
END;
$$;

-- Auto-start helper is private; public clients cannot call it directly.
REVOKE ALL ON FUNCTION footbid_private.fb_advance_to_next_player(uuid) FROM public,anon,authenticated;

GRANT EXECUTE ON FUNCTION public.fb_create_room(text[],jsonb,jsonb,text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fb_room_snapshot(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fb_start_next_player(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fb_place_bid(text,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fb_quit_lot(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fb_update_my_team(text,text,jsonb) TO authenticated;

-- FootBid v0.8 migration
-- Apply once after the v0.7 migration. Existing rooms and purchases are preserved.
-- Adds flexible all-player tactical assignments and category-adjusted opening prices.

-- 1) The next player starts at dataset base_price multiplied by the room's category multiplier.
--    When the room has no multiplier settings (older rooms), 1.0x is used.
CREATE OR REPLACE FUNCTION footbid_private.fb_advance_to_next_player(p_room_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_room public.fb_rooms;
  v_active uuid[];
  v_player_id text;
  v_player jsonb;
  v_remaining text[];
  v_price integer;
  v_multiplier numeric;
  v_base_price numeric;
  v_previous_message text;
BEGIN
  SELECT * INTO v_room FROM public.fb_rooms r WHERE r.id=p_room_id FOR UPDATE;
  IF NOT FOUND OR v_room.status='finished' THEN RETURN; END IF;
  IF v_room.current_player_id IS NOT NULL THEN RETURN; END IF;

  v_active := ARRAY(
    SELECT t.id FROM public.fb_teams t
    WHERE t.room_id=v_room.id
      AND t.seat_claimed=true
      AND t.submitted=false
      AND jsonb_array_length(t.purchases) < (v_room.settings->>'squadSize')::integer
  );
  v_previous_message := coalesce(v_room.last_message,'');

  IF coalesce(cardinality(v_active),0)=0 THEN
    UPDATE public.fb_rooms
      SET status='finished',
          last_message=CASE
            WHEN v_previous_message LIKE 'SOLD! %' OR v_previous_message LIKE 'UNSOLD! %'
              THEN v_previous_message || ' AUCTION FINISHED. All contestant squads are full or submitted.'
            ELSE 'All contestant squads are full or submitted. Auction complete.'
          END
      WHERE id=p_room_id;
    RETURN;
  END IF;

  IF coalesce(cardinality(v_room.player_queue),0)=0 THEN
    UPDATE public.fb_rooms
      SET status='finished',
          last_message=CASE
            WHEN v_previous_message LIKE 'SOLD! %' OR v_previous_message LIKE 'UNSOLD! %'
              THEN v_previous_message || ' AUCTION FINISHED. All selected players have been auctioned.'
            ELSE 'All selected players have been auctioned. Arrange your tactical XI and submit your final team.'
          END
      WHERE id=p_room_id;
    RETURN;
  END IF;

  v_player_id := v_room.player_queue[1];
  IF cardinality(v_room.player_queue)>1 THEN
    v_remaining := v_room.player_queue[2:cardinality(v_room.player_queue)];
  ELSE
    v_remaining := '{}';
  END IF;

  SELECT p.value INTO v_player
  FROM jsonb_array_elements(v_room.pool_players) AS p(value)
  WHERE p.value->>'id'=v_player_id;
  IF v_player IS NULL THEN
    RAISE EXCEPTION 'Player % was not found in the room player pool.',v_player_id;
  END IF;

  v_base_price := coalesce(
    nullif(v_player->>'base_price','')::numeric,
    nullif(v_room.settings->'tierOpeningBids'->>(v_player->>'tier'),'')::numeric,
    nullif(v_player->>'startBid','')::numeric,
    65
  );
  v_multiplier := coalesce(
    nullif(v_room.settings->'openingPriceMultipliers'->>(v_player->>'category'),'')::numeric,
    1.0
  );
  v_price := greatest(1,round(v_base_price*v_multiplier)::integer);

  UPDATE public.fb_rooms
  SET status='live',
      player_queue=v_remaining,
      current_player_id=v_player_id,
      current_player=v_player,
      current_bid=v_price,
      highest_bidder_team_id=NULL,
      active_team_ids=v_active,
      last_message=CASE
        WHEN v_previous_message LIKE 'SOLD! %' OR v_previous_message LIKE 'UNSOLD! %'
          THEN v_previous_message || ' NEXT UP: ' || (v_player->>'name') || ' opens at ' || v_price::text || ' points.'
        ELSE (v_player->>'name') || ' is on the block. Opening bid: ' || v_price::text || ' points.'
      END
  WHERE id=p_room_id;
END;
$$;

-- 2) Any purchased player can be assigned to any tactical role.
--    Natural-position fit is a scoring concern, not a database restriction.
CREATE OR REPLACE FUNCTION public.fb_update_my_team(
  p_room_code text,p_formation text,p_lineup jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_room public.fb_rooms;
  v_team_id uuid;
  v_team public.fb_teams;
  v_entry jsonb;
  v_player_id text;
  v_role text;
  v_x numeric;
  v_y numeric;
  v_player jsonb;
BEGIN
  SELECT * INTO v_room FROM public.fb_rooms r
    WHERE r.room_code=upper(trim(p_room_code)) FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Room code not found.'; END IF;

  SELECT m.team_id INTO v_team_id FROM public.fb_members m
    WHERE m.room_id=v_room.id AND m.user_id=(SELECT auth.uid());
  IF v_team_id IS NULL THEN RAISE EXCEPTION 'You are not a contestant in this room.'; END IF;

  SELECT * INTO v_team FROM public.fb_teams t WHERE t.id=v_team_id FOR UPDATE;
  IF v_team.submitted THEN RAISE EXCEPTION 'Your team is locked because it has been submitted.'; END IF;
  IF p_formation IS NULL OR length(p_formation)>40 THEN RAISE EXCEPTION 'Formation label is invalid.'; END IF;
  IF p_lineup IS NULL OR jsonb_typeof(p_lineup)<>'array' THEN
    RAISE EXCEPTION 'Tactical lineup must be a JSON array of player placements.';
  END IF;
  IF jsonb_array_length(p_lineup)>11 THEN
    RAISE EXCEPTION 'A starting XI cannot contain more than 11 players.';
  END IF;

  IF (
    SELECT count(*) FROM (SELECT value->>'playerId' AS player_id FROM jsonb_array_elements(p_lineup)) x
  ) <> (
    SELECT count(DISTINCT value->>'playerId') FROM jsonb_array_elements(p_lineup)
  ) THEN
    RAISE EXCEPTION 'A player cannot occupy more than one tactical position.';
  END IF;

  FOR v_entry IN SELECT value FROM jsonb_array_elements(p_lineup) LOOP
    IF jsonb_typeof(v_entry)<>'object' THEN
      RAISE EXCEPTION 'Each tactical placement must be a JSON object.';
    END IF;
    v_player_id := v_entry->>'playerId';
    v_role := v_entry->>'role';
    BEGIN
      v_x := (v_entry->>'x')::numeric;
      v_y := (v_entry->>'y')::numeric;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'Each placement needs numeric pitch coordinates.';
    END;

    IF v_player_id IS NULL OR v_role IS NULL OR v_role NOT IN (
      'GK','CB','LB','RB','DMF','CMF','AMF','RMF','LMF','SS','CF','LWF','RWF'
    ) THEN
      RAISE EXCEPTION 'Player ID or tactical role is invalid.';
    END IF;
    IF v_x IS NULL OR v_y IS NULL OR v_x<0 OR v_x>100 OR v_y<0 OR v_y>100 THEN
      RAISE EXCEPTION 'Pitch coordinates must be between 0 and 100.';
    END IF;
    IF NOT EXISTS(
      SELECT 1 FROM jsonb_array_elements(v_team.purchases) AS purchase(value)
      WHERE purchase.value->>'playerId'=v_player_id
    ) THEN
      RAISE EXCEPTION 'You can only position players owned by your team.';
    END IF;
    SELECT player.value INTO v_player
    FROM jsonb_array_elements(v_room.pool_players) AS player(value)
    WHERE player.value->>'id'=v_player_id;
    IF v_player IS NULL THEN
      RAISE EXCEPTION 'Player % is not part of this room pool.',v_player_id;
    END IF;
  END LOOP;

  UPDATE public.fb_teams
    SET formation=p_formation,tactical_lineup=p_lineup
    WHERE id=v_team_id;
  UPDATE public.fb_rooms
    SET last_message=v_team.team_name || ' updated its tactical lineup.'
    WHERE id=v_room.id;
  RETURN jsonb_build_object('formation',p_formation,'lineup',p_lineup);
END;
$$;

-- 3) Validate organiser-configured category price multipliers when supplied.
--    Old rooms can omit this property; the auto-advance function defaults to 1.0x.
CREATE OR REPLACE FUNCTION public.fb_create_room(
  p_team_names text[],
  p_settings jsonb,
  p_pool_players jsonb,
  p_queue text[]
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := (SELECT auth.uid());
  v_room_id uuid;
  v_team_id uuid;
  v_code text;
  v_name text;
  v_index integer := 0;
  v_pool_count integer;
  v_queue_count integer;
  v_category text;
  v_multiplier_entry record;
  v_multiplier numeric;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Sign in before creating a room.'; END IF;
  IF coalesce(array_length(p_team_names,1),0)<2 OR array_length(p_team_names,1)>8 THEN
    RAISE EXCEPTION 'A room needs between 2 and 8 teams.';
  END IF;
  IF EXISTS(SELECT 1 FROM unnest(p_team_names) AS n(team_name) WHERE trim(team_name)='') THEN
    RAISE EXCEPTION 'Team names cannot be blank.';
  END IF;
  IF (SELECT count(DISTINCT lower(trim(team_name))) FROM unnest(p_team_names) AS n(team_name))<>array_length(p_team_names,1) THEN
    RAISE EXCEPTION 'Team names must be unique.';
  END IF;
  IF coalesce((p_settings->>'budget')::integer,0)<500 THEN
    RAISE EXCEPTION 'Team budget must be at least 500 points.';
  END IF;
  IF coalesce((p_settings->>'squadSize')::integer,0) NOT IN (11,15,18) THEN
    RAISE EXCEPTION 'Choose a squad size of 11, 15 or 18 players.';
  END IF;
  IF jsonb_typeof(p_pool_players)<>'array' THEN RAISE EXCEPTION 'Player pool is invalid.'; END IF;
  v_pool_count:=jsonb_array_length(p_pool_players);
  v_queue_count:=coalesce(array_length(p_queue,1),0);
  IF v_pool_count<90 THEN RAISE EXCEPTION 'Every auction must contain at least 90 players.'; END IF;
  IF v_pool_count < array_length(p_team_names,1) * (p_settings->>'squadSize')::integer THEN
    RAISE EXCEPTION 'Player pool must contain enough players for all configured squads.';
  END IF;
  IF coalesce((p_settings->>'auctionPoolSize')::integer,v_pool_count)<>v_pool_count THEN
    RAISE EXCEPTION 'Auction pool size setting does not match the selected player pool.';
  END IF;
  IF v_queue_count<>v_pool_count THEN
    RAISE EXCEPTION 'Player queue does not match the selected player pool.';
  END IF;
  IF (SELECT count(DISTINCT player_id) FROM unnest(p_queue) AS q(player_id))<>v_queue_count THEN
    RAISE EXCEPTION 'Player queue contains duplicate players.';
  END IF;
  IF (SELECT count(DISTINCT p.value->>'id') FROM jsonb_array_elements(p_pool_players) AS p(value))<>v_pool_count THEN
    RAISE EXCEPTION 'Player pool contains duplicate or missing player IDs.';
  END IF;
  IF EXISTS(
    SELECT 1 FROM unnest(p_queue) AS q(player_id)
    WHERE NOT EXISTS(SELECT 1 FROM jsonb_array_elements(p_pool_players) AS p(value) WHERE p.value->>'id'=q.player_id)
  ) THEN RAISE EXCEPTION 'Player queue contains a player outside the selected pool.'; END IF;

  FOREACH v_category IN ARRAY ARRAY['Current','Icon','Hero'] LOOP
    IF NOT EXISTS(
      SELECT 1 FROM jsonb_array_elements(p_pool_players) AS p(value)
      WHERE p.value->>'category'=v_category
    ) THEN RAISE EXCEPTION 'The player pool must include Current, Icon and Hero categories.'; END IF;
  END LOOP;

  IF p_settings ? 'openingPriceMultipliers' THEN
    IF jsonb_typeof(p_settings->'openingPriceMultipliers')<>'object' THEN
      RAISE EXCEPTION 'Opening-price multipliers must be a category object.';
    END IF;
    FOR v_multiplier_entry IN
      SELECT key,value FROM jsonb_each_text(p_settings->'openingPriceMultipliers')
    LOOP
      IF v_multiplier_entry.key NOT IN ('Current','Icon','Hero') THEN
        RAISE EXCEPTION 'Unknown player category in opening-price settings.';
      END IF;
      BEGIN
        v_multiplier:=v_multiplier_entry.value::numeric;
      EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'Opening-price multipliers must be numbers.';
      END;
      IF v_multiplier<0.5 OR v_multiplier>3.0 THEN
        RAISE EXCEPTION 'Category opening-price multipliers must be between 0.5x and 3.0x.';
      END IF;
    END LOOP;
  END IF;

  LOOP
    v_code:=upper(substr(replace(gen_random_uuid()::text,'-',''),1,6));
    EXIT WHEN NOT EXISTS(SELECT 1 FROM public.fb_rooms r WHERE r.room_code=v_code);
  END LOOP;

  INSERT INTO public.fb_rooms(room_code,created_by,settings,pool_players,player_queue)
    VALUES(v_code,v_user,p_settings,p_pool_players,p_queue)
    RETURNING id INTO v_room_id;

  FOREACH v_name IN ARRAY p_team_names LOOP
    v_index:=v_index+1;
    INSERT INTO public.fb_teams(room_id,team_name,seat_claimed,budget_remaining,formation,tactical_lineup)
      VALUES(v_room_id,trim(v_name),v_index=1,(p_settings->>'budget')::integer,'CUSTOM','[]'::jsonb)
      RETURNING id INTO v_team_id;
    IF v_index=1 THEN
      INSERT INTO public.fb_members(room_id,team_id,user_id,is_host)
        VALUES(v_room_id,v_team_id,v_user,true);
    END IF;
  END LOOP;

  RETURN jsonb_build_object('room_id',v_room_id,'room_code',v_code,'my_team_id',
    (SELECT m.team_id FROM public.fb_members m WHERE m.room_id=v_room_id AND m.user_id=v_user));
END;
$$;

REVOKE ALL ON FUNCTION footbid_private.fb_advance_to_next_player(uuid) FROM public,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.fb_create_room(text[],jsonb,jsonb,text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fb_update_my_team(text,text,jsonb) TO authenticated;

-- The sale/unsold message is preserved while the next lot is revealed, so every device
-- can show the same announcement toast and then continue to the next player.
