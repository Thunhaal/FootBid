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
