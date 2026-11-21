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
