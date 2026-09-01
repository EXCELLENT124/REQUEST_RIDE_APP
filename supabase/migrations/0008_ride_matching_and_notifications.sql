create table if not exists public.ride_offers (
  ride_id uuid not null references public.rides(id) on delete cascade,
  driver_id uuid not null references public.profiles(id) on delete cascade,
  distance_km numeric(10,2) not null check (distance_km >= 0),
  available_at timestamptz not null default now(),
  accepted_at timestamptz,
  declined_at timestamptz,
  created_at timestamptz not null default now(),
  primary key (ride_id, driver_id)
);

alter table public.ride_offers enable row level security;
create policy ride_offers_driver_read on public.ride_offers
  for select to authenticated
  using (driver_id = (select auth.uid()) or public.is_admin());
grant select on public.ride_offers to authenticated;
create index if not exists ride_offers_driver_available_idx
  on public.ride_offers(driver_id, available_at)
  where accepted_at is null and declined_at is null;

create or replace function private.create_ride_offers(p_ride_id uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_ride public.rides;
begin
  select * into strict v_ride from public.rides where id = p_ride_id;
  insert into public.ride_offers(ride_id, driver_id, distance_km, available_at)
  select p_ride_id, availability.driver_id, distance.distance_km,
    now() + case
      when distance.distance_km <= 10 then interval '0 seconds'
      when distance.distance_km <= 25 then interval '30 seconds'
      else interval '60 seconds'
    end
  from public.driver_availability availability
  join public.driver_applications application
    on application.driver_id = availability.driver_id
   and application.status = 'approved'
  cross join lateral (
    select 6371.0 * 2.0 * asin(sqrt(least(1.0,
      power(sin(radians((availability.latitude - v_ride.pickup_lat) / 2.0)), 2) +
      cos(radians(v_ride.pickup_lat)) * cos(radians(availability.latitude)) *
      power(sin(radians((availability.longitude - v_ride.pickup_lng) / 2.0)), 2)
    ))) as distance_km
  ) distance
  where availability.is_online
    and availability.latitude is not null
    and availability.longitude is not null
    and availability.last_seen_at > now() - interval '2 minutes'
  order by distance.distance_km
  limit 20
  on conflict do nothing;
end;
$$;
revoke all on function private.create_ride_offers(uuid) from public, anon, authenticated;

create or replace function private.request_ride_internal(p_pickup_lat double precision, p_pickup_lng double precision, p_pickup_address text, p_destination_lat double precision, p_destination_lng double precision, p_destination_address text, p_distance_km numeric, p_duration_minutes integer) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_rule public.fare_rules;
begin
  if (select auth.uid()) is null or not exists(select 1 from public.profiles where id=(select auth.uid()) and role='customer') then raise exception 'Customer account required'; end if;
  if p_pickup_lat not between -90 and 90 or p_destination_lat not between -90 and 90 or p_pickup_lng not between -180 and 180 or p_destination_lng not between -180 and 180 or p_distance_km < 0 or p_duration_minutes < 0 then raise exception 'Invalid ride parameters'; end if;
  select * into strict v_rule from public.fare_rules where active order by effective_from desc limit 1;
  insert into public.rides(customer_id,pickup_lat,pickup_lng,pickup_address,destination_lat,destination_lng,destination_address,estimated_distance_km,estimated_duration_minutes,estimated_fare,fare_rule_id)
  values((select auth.uid()),p_pickup_lat,p_pickup_lng,p_pickup_address,p_destination_lat,p_destination_lng,p_destination_address,p_distance_km,p_duration_minutes,public.estimate_fare(p_distance_km,p_duration_minutes),v_rule.id) returning id into v_id;
  perform private.create_ride_offers(v_id);
  return v_id;
end;
$$;

create or replace function private.available_ride_requests_internal()
returns setof public.rides
language sql stable security definer set search_path = '' as $$
  select ride.*
  from public.ride_offers offer
  join public.rides ride on ride.id = offer.ride_id
  where offer.driver_id = (select auth.uid())
    and offer.available_at <= now()
    and offer.declined_at is null
    and ride.status = 'searching'
  order by offer.distance_km, ride.requested_at;
$$;
revoke all on function private.available_ride_requests_internal() from public, anon;
grant execute on function private.available_ride_requests_internal() to authenticated;

create or replace function public.available_ride_requests()
returns setof public.rides
language sql stable security invoker set search_path = '' as $$
  select * from private.available_ride_requests_internal();
$$;
revoke all on function public.available_ride_requests() from public, anon;
grant execute on function public.available_ride_requests() to authenticated;

create or replace function private.accept_ride_internal(p_ride_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_customer uuid;
begin
  if (select auth.uid()) is null or not exists(select 1 from public.driver_applications where driver_id=(select auth.uid()) and status='approved') then raise exception 'Driver is not approved'; end if;
  if not exists(select 1 from public.driver_availability where driver_id=(select auth.uid()) and is_online and last_seen_at > now() - interval '2 minutes') then raise exception 'Driver is offline'; end if;
  if not exists(select 1 from public.ride_offers where ride_id=p_ride_id and driver_id=(select auth.uid()) and available_at <= now() and declined_at is null) then raise exception 'This ride was not offered to you'; end if;
  update public.rides set driver_id=(select auth.uid()),vehicle_id=(select id from public.vehicles where driver_id=(select auth.uid())),status='accepted',accepted_at=now()
  where id=p_ride_id and status='searching' returning customer_id into v_customer;
  if not found then raise exception 'Ride is no longer available'; end if;
  update public.ride_offers set accepted_at=now() where ride_id=p_ride_id and driver_id=(select auth.uid());
  insert into public.notifications(user_id,title,body,data)
  values(v_customer,'Driver found','Your driver accepted the ride.',jsonb_build_object('ride_id',p_ride_id,'type','ride_accepted'));
end;
$$;

create or replace function private.transition_ride_internal(p_ride_id uuid,p_next_status public.ride_status) returns void
language plpgsql security definer set search_path = '' as $$
declare v public.rides; allowed boolean := false; v_recipient uuid; v_message text;
begin
  if (select auth.uid()) is null then raise exception 'Authentication required'; end if;
  select * into strict v from public.rides where id=p_ride_id for update;
  if (select auth.uid()) not in (v.customer_id,v.driver_id) and not public.is_admin() then raise exception 'Not a ride participant'; end if;
  allowed := (v.status='accepted' and p_next_status in ('driver_arriving','cancelled')) or (v.status='driver_arriving' and p_next_status in ('driver_arrived','cancelled')) or (v.status='driver_arrived' and p_next_status in ('in_progress','cancelled')) or (v.status='in_progress' and p_next_status='completed') or (v.status='searching' and p_next_status='cancelled');
  if not allowed then raise exception 'Invalid ride transition'; end if;
  update public.rides set status=p_next_status,started_at=case when p_next_status='in_progress' then now() else started_at end,completed_at=case when p_next_status='completed' then now() else completed_at end,cancelled_at=case when p_next_status='cancelled' then now() else cancelled_at end where id=p_ride_id;
  v_recipient := case when (select auth.uid()) = v.customer_id then v.driver_id else v.customer_id end;
  v_message := case p_next_status when 'driver_arriving' then 'Your driver is on the way.' when 'driver_arrived' then 'Your driver has arrived.' when 'in_progress' then 'Your trip has started.' when 'completed' then 'Your trip is complete.' else 'The ride was cancelled.' end;
  if v_recipient is not null then
    insert into public.notifications(user_id,title,body,data)
    values(v_recipient,'Ride update',v_message,jsonb_build_object('ride_id',p_ride_id,'type','ride_status','status',p_next_status));
  end if;
end;
$$;

do $$ begin
  alter publication supabase_realtime add table public.ride_offers;
exception when duplicate_object then null;
end $$;
