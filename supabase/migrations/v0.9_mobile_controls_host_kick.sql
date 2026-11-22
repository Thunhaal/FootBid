-- FootBid v0.9 migration
-- Mobile-first setup and quick bidding are frontend-only. This migration adds
-- exact category-count validation and secure host kick / contestant leave actions.
-- Apply once after v0.8.

-- Keep the helper private: callers must use the checked public RPCs below.
CREATE OR REPLACE FUNCTION footbid_private.fb_remove_contestant(
  p_room_code text,
  p_team_id uuid,
  p_actor_id uuid,
  p_host_override boolean
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_room public.fb_rooms;
  v_actor_team_id uuid;
  v_actor_is_host boolean;
  v_team public.fb_teams;
  v_active uuid[];
  v_was_leading boolean := false;
  v_opening_price integer;
  v_base_price numeric;
  v_multiplier numeric;
  v_team_name text;
  v_player_name text;
BEGIN
  SELECT * INTO v_room
  FROM public.fb_rooms r
  WHERE r.room_code=upper(trim(p_room_code))
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Room code not found.';
  END IF;

  SELECT m.team_id,m.is_host
  INTO v_actor_team_id,v_actor_is_host
  FROM public.fb_members m
  WHERE m.room_id=v_room.id AND m.user_id=p_actor_id;

  IF v_actor_team_id IS NULL THEN
    RAISE EXCEPTION 'You are not a member of this room.';
  END IF;

  IF p_host_override THEN
    IF NOT coalesce(v_actor_is_host,false) THEN
      RAISE EXCEPTION 'Only the organiser can kick another contestant.';
    END IF;
    IF p_team_id=v_actor_team_id THEN
      RAISE EXCEPTION 'The organiser cannot kick their own team.';
    END IF;
  ELSE
    IF coalesce(v_actor_is_host,false) THEN
      RAISE EXCEPTION 'The organiser cannot leave their own room.';
    END IF;
    IF p_team_id IS DISTINCT FROM v_actor_team_id THEN
      RAISE EXCEPTION 'You can only leave your own team.';
    END IF;
  END IF;

  SELECT * INTO v_team
  FROM public.fb_teams t
  WHERE t.id=p_team_id AND t.room_id=v_room.id
  FOR UPDATE;

  IF NOT FOUND OR NOT v_team.seat_claimed THEN
    RAISE EXCEPTION 'That contestant is no longer seated in this room.';
  END IF;

  IF EXISTS(
    SELECT 1 FROM public.fb_members m
    WHERE m.room_id=v_room.id AND m.team_id=p_team_id AND m.is_host=true
  ) THEN
    RAISE EXCEPTION 'The organiser team cannot be removed.';
  END IF;

  v_team_name := v_team.team_name;
  v_was_leading := (v_room.highest_bidder_team_id=p_team_id);

  IF NOT p_host_override AND v_was_leading THEN
    RAISE EXCEPTION 'You cannot leave the room while your team is the highest bidder. Ask the organiser to kick you if you need to exit immediately.';
  END IF;
  v_active := array_remove(coalesce(v_room.active_team_ids,'{}'::uuid[]),p_team_id);
  v_player_name := coalesce(v_room.current_player->>'name','');

  IF v_room.status='live' AND v_room.current_player IS NOT NULL AND v_was_leading THEN
    v_base_price := coalesce(
      nullif(v_room.current_player->>'base_price','')::numeric,
      nullif(v_room.settings->'tierOpeningBids'->>(v_room.current_player->>'tier'),'')::numeric,
      nullif(v_room.current_player->>'startBid','')::numeric,
      65
    );
    v_multiplier := coalesce(
      nullif(v_room.settings->'openingPriceMultipliers'->>(v_room.current_player->>'category'),'')::numeric,
      1.0
    );
    v_opening_price := greatest(1,round(v_base_price*v_multiplier)::integer);
  END IF;

  -- Deleting the team cascades its membership and bid audit rows.
  -- This makes the removal authoritative: the old device loses room membership.
  DELETE FROM public.fb_teams
  WHERE id=p_team_id AND room_id=v_room.id;

  IF v_room.status='live' AND v_room.current_player IS NOT NULL THEN
    IF coalesce(cardinality(v_active),0)=0 THEN
      UPDATE public.fb_rooms
      SET status='ready',
          unsold_ids=array_append(unsold_ids,v_room.current_player_id),
          current_player_id=NULL,
          current_player=NULL,
          current_bid=0,
          highest_bidder_team_id=NULL,
          active_team_ids='{}'::uuid[],
          last_message='UNSOLD! ' || v_player_name || ' received no remaining bids after ' || v_team_name || ' left the room.'
      WHERE id=v_room.id;

      PERFORM footbid_private.fb_advance_to_next_player(v_room.id);
    ELSE
      UPDATE public.fb_rooms
      SET active_team_ids=v_active,
          highest_bidder_team_id=CASE WHEN v_was_leading THEN NULL ELSE highest_bidder_team_id END,
          current_bid=CASE WHEN v_was_leading THEN v_opening_price ELSE current_bid END,
          last_message=CASE
            WHEN v_was_leading THEN v_team_name || ' was removed. The current lot is reopened at its opening price of ' || v_opening_price::text || ' points.'
            ELSE v_team_name || ' was removed. ' || cardinality(v_active)::text || ' contestants remain in this lot.'
          END
      WHERE id=v_room.id;

      -- If only the existing highest bidder remains, settle immediately.
      IF NOT v_was_leading
         AND cardinality(v_active)=1
         AND v_room.highest_bidder_team_id IS NOT NULL
         AND v_active[1]=v_room.highest_bidder_team_id THEN
        PERFORM footbid_private.fb_complete_lot(
          v_room.id,
          v_room.highest_bidder_team_id,
          v_room.current_bid,
          'last-standing'
        );
      END IF;
    END IF;
  ELSE
    UPDATE public.fb_rooms
    SET last_message=v_team_name || CASE WHEN p_host_override THEN ' was kicked out by the organiser.' ELSE ' left the room.' END
    WHERE id=v_room.id;
  END IF;

  RETURN jsonb_build_object(
    'status','removed',
    'team_id',p_team_id,
    'team_name',v_team_name,
    'current_lot_reopened',v_was_leading
  );
END;
$$;

REVOKE ALL ON FUNCTION footbid_private.fb_remove_contestant(text,uuid,uuid,boolean) FROM public,anon,authenticated;

CREATE OR REPLACE FUNCTION public.fb_host_kick_team(
  p_room_code text,
  p_team_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RETURN footbid_private.fb_remove_contestant(
    p_room_code,p_team_id,(SELECT auth.uid()),true
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.fb_leave_room(
  p_room_code text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_team_id uuid;
  v_room_id uuid;
BEGIN
  SELECT m.team_id,m.room_id
  INTO v_team_id,v_room_id
  FROM public.fb_members m
  JOIN public.fb_rooms r ON r.id=m.room_id
  WHERE r.room_code=upper(trim(p_room_code))
    AND m.user_id=(SELECT auth.uid());

  IF v_team_id IS NULL THEN
    RAISE EXCEPTION 'You are not a member of this room.';
  END IF;

  RETURN footbid_private.fb_remove_contestant(
    p_room_code,v_team_id,(SELECT auth.uid()),false
  );
END;
$$;

-- v0.9 room creation records and verifies the exact category counts supplied by the organiser.
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
  v_requested integer;
  v_actual integer;
  v_total integer := 0;
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

  IF v_pool_count<90 OR v_pool_count>489 THEN
    RAISE EXCEPTION 'The auction must contain between 90 and 489 players.';
  END IF;
  IF v_pool_count < array_length(p_team_names,1) * (p_settings->>'squadSize')::integer THEN
    RAISE EXCEPTION 'Player pool must contain enough players for every configured squad.';
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
  ) THEN
    RAISE EXCEPTION 'Player queue contains a player outside the selected player pool.';
  END IF;

  IF p_settings ? 'categoryCounts' THEN
    IF jsonb_typeof(p_settings->'categoryCounts')<>'object' THEN
      RAISE EXCEPTION 'Category counts must be a Current / Icon / Hero object.';
    END IF;

    FOREACH v_category IN ARRAY ARRAY['Current','Icon','Hero'] LOOP
      BEGIN
        v_requested:=coalesce((p_settings->'categoryCounts'->>v_category)::integer,-1);
      EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'The % category count must be a whole number.',v_category;
      END;

      IF v_requested<0 THEN
        RAISE EXCEPTION 'The % category count cannot be negative.',v_category;
      END IF;

      SELECT count(*) INTO v_actual
      FROM jsonb_array_elements(p_pool_players) AS p(value)
      WHERE p.value->>'category'=v_category;

      IF v_actual<>v_requested THEN
        RAISE EXCEPTION 'The selected % count (%) does not match the player pool (%).',v_category,v_requested,v_actual;
      END IF;

      v_total:=v_total+v_requested;
    END LOOP;

    IF v_total<>v_pool_count THEN
      RAISE EXCEPTION 'Current, Icon and Hero counts must add up to the exact auction size.';
    END IF;
  ELSE
    -- Backward compatibility for rooms created by earlier v0.8 clients.
    FOREACH v_category IN ARRAY ARRAY['Current','Icon','Hero'] LOOP
      IF NOT EXISTS(
        SELECT 1 FROM jsonb_array_elements(p_pool_players) AS p(value)
        WHERE p.value->>'category'=v_category
      ) THEN
        RAISE EXCEPTION 'Legacy player pools must include Current, Icon and Hero categories.';
      END IF;
    END LOOP;
  END IF;

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

  RETURN jsonb_build_object(
    'room_id',v_room_id,
    'room_code',v_code,
    'my_team_id',(SELECT m.team_id FROM public.fb_members m WHERE m.room_id=v_room_id AND m.user_id=v_user)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.fb_host_kick_team(text,uuid) FROM public,anon;
REVOKE ALL ON FUNCTION public.fb_leave_room(text) FROM public,anon;
REVOKE ALL ON FUNCTION public.fb_create_room(text[],jsonb,jsonb,text[]) FROM public,anon;
GRANT EXECUTE ON FUNCTION public.fb_create_room(text[],jsonb,jsonb,text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fb_host_kick_team(text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fb_leave_room(text) TO authenticated;

-- These RPCs use SECURITY DEFINER and enforce membership/host checks internally.
