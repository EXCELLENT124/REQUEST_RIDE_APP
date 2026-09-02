alter table public.ride_offers
  add column if not exists decline_reason text;

create or replace function private.request_ride_for_driver_internal(
  p_pickup_lat double precision,
  p_pickup_lng double precision,
  p_pickup_address text,
  p_destination_lat double precision,
  p_destination_lng double precision,
  p_destination_address text,
  p_distance_km numeric,
  p_duration_minutes integer,
  p_driver_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_rule public.fare_rules;
  v_driver_distance numeric(10, 2);
begin
  if (select auth.uid()) is null
     or not exists (
       select 1
       from public.profiles
       where id = (select auth.uid())
         and role = 'customer'
     ) then
    raise exception 'Customer account required';
  end if;

  if p_pickup_lat not between -90 and 90
     or p_destination_lat not between -90 and 90
     or p_pickup_lng not between -180 and 180
     or p_destination_lng not between -180 and 180
     or p_distance_km < 0
     or p_duration_minutes < 0 then
    raise exception 'Invalid ride parameters';
  end if;

  if exists (
    select 1
    from public.rides
    where customer_id = (select auth.uid())
      and status in (
        'searching',
        'accepted',
        'driver_arriving',
        'driver_arrived',
        'in_progress'
      )
  ) then
    raise exception 'You already have an active ride';
  end if;

  select (
    6371.0 * 2.0 * asin(sqrt(least(1.0,
      power(sin(radians((availability.latitude - p_pickup_lat) / 2.0)), 2) +
      cos(radians(p_pickup_lat)) * cos(radians(availability.latitude)) *
      power(sin(radians((availability.longitude - p_pickup_lng) / 2.0)), 2)
    )))
  )::numeric(10, 2)
  into v_driver_distance
  from public.driver_availability availability
  join public.driver_applications application
    on application.driver_id = availability.driver_id
   and application.status = 'approved'
  join public.vehicles vehicle
    on vehicle.driver_id = availability.driver_id
   and vehicle.vehicle_type = 'car'
  where availability.driver_id = p_driver_id
    and availability.is_online
    and availability.latitude is not null
    and availability.longitude is not null
    and availability.last_seen_at > now() - interval '2 minutes';

  if v_driver_distance is null then
    raise exception 'The selected driver is no longer available';
  end if;

  select *
  into strict v_rule
  from public.fare_rules
  where active
  order by effective_from desc
  limit 1;

  insert into public.rides(
    customer_id,
    pickup_lat,
    pickup_lng,
    pickup_address,
    destination_lat,
    destination_lng,
    destination_address,
    estimated_distance_km,
    estimated_duration_minutes,
    estimated_fare,
    fare_rule_id
  )
  values (
    (select auth.uid()),
    p_pickup_lat,
    p_pickup_lng,
    p_pickup_address,
    p_destination_lat,
    p_destination_lng,
    p_destination_address,
    p_distance_km,
    p_duration_minutes,
    public.estimate_fare(p_distance_km, p_duration_minutes),
    v_rule.id
  )
  returning id into v_id;

  insert into public.ride_offers(
    ride_id,
    driver_id,
    distance_km,
    available_at
  )
  values (v_id, p_driver_id, v_driver_distance, now());

  insert into public.notifications(user_id, title, body, data)
  values (
    p_driver_id,
    'New selected ride request',
    'A customer selected you for a ride.',
    jsonb_build_object(
      'ride_id', v_id,
      'type', 'targeted_ride_request'
    )
  );

  return v_id;
end;
$$;

revoke all on function private.request_ride_for_driver_internal(
  double precision,
  double precision,
  text,
  double precision,
  double precision,
  text,
  numeric,
  integer,
  uuid
) from public, anon;
grant execute on function private.request_ride_for_driver_internal(
  double precision,
  double precision,
  text,
  double precision,
  double precision,
  text,
  numeric,
  integer,
  uuid
) to authenticated;

create or replace function public.request_ride_for_driver(
  p_pickup_lat double precision,
  p_pickup_lng double precision,
  p_pickup_address text,
  p_destination_lat double precision,
  p_destination_lng double precision,
  p_destination_address text,
  p_distance_km numeric,
  p_duration_minutes integer,
  p_driver_id uuid
)
returns uuid
language sql
security invoker
set search_path = ''
as $$
  select private.request_ride_for_driver_internal(
    p_pickup_lat,
    p_pickup_lng,
    p_pickup_address,
    p_destination_lat,
    p_destination_lng,
    p_destination_address,
    p_distance_km,
    p_duration_minutes,
    p_driver_id
  );
$$;

revoke all on function public.request_ride_for_driver(
  double precision,
  double precision,
  text,
  double precision,
  double precision,
  text,
  numeric,
  integer,
  uuid
) from public, anon;
grant execute on function public.request_ride_for_driver(
  double precision,
  double precision,
  text,
  double precision,
  double precision,
  text,
  numeric,
  integer,
  uuid
) to authenticated;

create or replace function private.decline_ride_offer_internal(
  p_ride_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_customer_id uuid;
begin
  if (select auth.uid()) is null
     or length(trim(coalesce(p_reason, ''))) < 3 then
    raise exception 'A rejection reason is required';
  end if;

  if not exists (
    select 1
    from public.ride_offers
    where ride_id = p_ride_id
      and driver_id = (select auth.uid())
      and available_at <= now()
      and accepted_at is null
      and declined_at is null
  ) then
    raise exception 'This ride request is not available to reject';
  end if;

  update public.rides
  set status = 'cancelled',
      cancelled_at = now(),
      cancelled_by = (select auth.uid()),
      cancellation_reason = 'Driver rejected: ' || trim(p_reason)
  where id = p_ride_id
    and status = 'searching'
  returning customer_id into v_customer_id;

  if not found then
    raise exception 'Ride is no longer available';
  end if;

  update public.ride_offers
  set declined_at = now(),
      decline_reason = trim(p_reason)
  where ride_id = p_ride_id
    and driver_id = (select auth.uid());

  insert into public.notifications(user_id, title, body, data)
  values (
    v_customer_id,
    'Driver unavailable',
    'The selected driver rejected the request: ' || trim(p_reason),
    jsonb_build_object(
      'ride_id', p_ride_id,
      'type', 'ride_rejected',
      'reason', trim(p_reason)
    )
  );
end;
$$;

revoke all on function private.decline_ride_offer_internal(uuid, text)
  from public, anon;
grant execute on function private.decline_ride_offer_internal(uuid, text)
  to authenticated;

create or replace function public.decline_ride_offer(
  p_ride_id uuid,
  p_reason text
)
returns void
language sql
security invoker
set search_path = ''
as $$
  select private.decline_ride_offer_internal(p_ride_id, p_reason);
$$;

revoke all on function public.decline_ride_offer(uuid, text)
  from public, anon;
grant execute on function public.decline_ride_offer(uuid, text)
  to authenticated;
