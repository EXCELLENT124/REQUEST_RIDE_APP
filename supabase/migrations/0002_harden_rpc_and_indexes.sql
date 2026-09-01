-- Keep privileged implementations outside the exposed API schema.
create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

create or replace function private.request_ride_internal(p_pickup_lat double precision, p_pickup_lng double precision, p_pickup_address text, p_destination_lat double precision, p_destination_lng double precision, p_destination_address text, p_distance_km numeric, p_duration_minutes integer) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_rule public.fare_rules;
begin
  if (select auth.uid()) is null or not exists(select 1 from public.profiles where id=(select auth.uid()) and role='customer') then raise exception 'Customer account required'; end if;
  if p_pickup_lat not between -90 and 90 or p_destination_lat not between -90 and 90 or p_pickup_lng not between -180 and 180 or p_destination_lng not between -180 and 180 or p_distance_km < 0 or p_duration_minutes < 0 then raise exception 'Invalid ride parameters'; end if;
  select * into strict v_rule from public.fare_rules where active order by effective_from desc limit 1;
  insert into public.rides(customer_id,pickup_lat,pickup_lng,pickup_address,destination_lat,destination_lng,destination_address,estimated_distance_km,estimated_duration_minutes,estimated_fare,fare_rule_id)
  values((select auth.uid()),p_pickup_lat,p_pickup_lng,p_pickup_address,p_destination_lat,p_destination_lng,p_destination_address,p_distance_km,p_duration_minutes,public.estimate_fare(p_distance_km,p_duration_minutes),v_rule.id) returning id into v_id;
  return v_id;
end;
$$;

create or replace function private.set_driver_availability_internal(p_online boolean,p_lat double precision,p_lng double precision) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then raise exception 'Authentication required'; end if;
  if p_lat is not null and p_lat not between -90 and 90 or p_lng is not null and p_lng not between -180 and 180 then raise exception 'Invalid location'; end if;
  if p_online and not exists(select 1 from public.driver_applications where driver_id=(select auth.uid()) and status='approved') then raise exception 'Driver is not approved'; end if;
  insert into public.driver_availability(driver_id,is_online,latitude,longitude,last_seen_at) values((select auth.uid()),p_online,p_lat,p_lng,now())
  on conflict(driver_id) do update set is_online=excluded.is_online,latitude=coalesce(excluded.latitude,public.driver_availability.latitude),longitude=coalesce(excluded.longitude,public.driver_availability.longitude),last_seen_at=now();
end;
$$;

create or replace function private.accept_ride_internal(p_ride_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null or not exists(select 1 from public.driver_applications where driver_id=(select auth.uid()) and status='approved') then raise exception 'Driver is not approved'; end if;
  if not exists(select 1 from public.driver_availability where driver_id=(select auth.uid()) and is_online) then raise exception 'Driver is offline'; end if;
  update public.rides set driver_id=(select auth.uid()),vehicle_id=(select id from public.vehicles where driver_id=(select auth.uid())),status='accepted',accepted_at=now() where id=p_ride_id and status='searching';
  if not found then raise exception 'Ride is no longer available'; end if;
end;
$$;

create or replace function private.transition_ride_internal(p_ride_id uuid,p_next_status public.ride_status) returns void
language plpgsql security definer set search_path = '' as $$
declare v public.rides; allowed boolean := false;
begin
  if (select auth.uid()) is null then raise exception 'Authentication required'; end if;
  select * into strict v from public.rides where id=p_ride_id for update;
  if (select auth.uid()) not in (v.customer_id,v.driver_id) and not public.is_admin() then raise exception 'Not a ride participant'; end if;
  allowed := (v.status='accepted' and p_next_status in ('driver_arriving','cancelled')) or (v.status='driver_arriving' and p_next_status in ('driver_arrived','cancelled')) or (v.status='driver_arrived' and p_next_status in ('in_progress','cancelled')) or (v.status='in_progress' and p_next_status='completed') or (v.status='searching' and p_next_status='cancelled');
  if not allowed then raise exception 'Invalid ride transition'; end if;
  update public.rides set status=p_next_status,started_at=case when p_next_status='in_progress' then now() else started_at end,completed_at=case when p_next_status='completed' then now() else completed_at end,cancelled_at=case when p_next_status='cancelled' then now() else cancelled_at end where id=p_ride_id;
end;
$$;

create or replace function private.update_driver_location_internal(p_lat double precision,p_lng double precision,p_ride_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then raise exception 'Invalid location update'; end if;
  update public.driver_availability set latitude=p_lat,longitude=p_lng,last_seen_at=now() where driver_id=(select auth.uid());
  if not found then raise exception 'Driver availability record missing'; end if;
  if p_ride_id is not null then
    if not exists(select 1 from public.rides where id=p_ride_id and driver_id=(select auth.uid()) and status in ('accepted','driver_arriving','driver_arrived','in_progress')) then raise exception 'No active ride'; end if;
    insert into public.ride_tracking(ride_id,driver_id,latitude,longitude,recorded_at) values(p_ride_id,(select auth.uid()),p_lat,p_lng,now()) on conflict(ride_id) do update set latitude=excluded.latitude,longitude=excluded.longitude,recorded_at=now();
  end if;
end;
$$;

revoke execute on all functions in schema private from public, anon;
grant execute on function private.request_ride_internal(double precision,double precision,text,double precision,double precision,text,numeric,integer),private.set_driver_availability_internal(boolean,double precision,double precision),private.accept_ride_internal(uuid),private.transition_ride_internal(uuid,public.ride_status),private.update_driver_location_internal(double precision,double precision,uuid) to authenticated;

create or replace function public.request_ride(p_pickup_lat double precision,p_pickup_lng double precision,p_pickup_address text,p_destination_lat double precision,p_destination_lng double precision,p_destination_address text,p_distance_km numeric,p_duration_minutes integer) returns uuid language sql security invoker set search_path='' as $$ select private.request_ride_internal(p_pickup_lat,p_pickup_lng,p_pickup_address,p_destination_lat,p_destination_lng,p_destination_address,p_distance_km,p_duration_minutes); $$;
create or replace function public.set_driver_availability(p_online boolean,p_lat double precision default null,p_lng double precision default null) returns void language sql security invoker set search_path='' as $$ select private.set_driver_availability_internal(p_online,p_lat,p_lng); $$;
create or replace function public.accept_ride(p_ride_id uuid) returns void language sql security invoker set search_path='' as $$ select private.accept_ride_internal(p_ride_id); $$;
create or replace function public.transition_ride(p_ride_id uuid,p_next_status public.ride_status) returns void language sql security invoker set search_path='' as $$ select private.transition_ride_internal(p_ride_id,p_next_status); $$;
create or replace function public.update_driver_location(p_lat double precision,p_lng double precision,p_ride_id uuid default null) returns void language sql security invoker set search_path='' as $$ select private.update_driver_location_internal(p_lat,p_lng,p_ride_id); $$;

create index if not exists driver_applications_reviewed_by_idx on public.driver_applications(reviewed_by);
create index if not exists driver_documents_verified_by_idx on public.driver_documents(verified_by);
create index if not exists fare_rules_created_by_idx on public.fare_rules(created_by);
create index if not exists notifications_user_created_idx on public.notifications(user_id,created_at desc);
create index if not exists ratings_author_idx on public.ratings(author_id);
create index if not exists ratings_subject_idx on public.ratings(subject_id);
create index if not exists ride_tracking_driver_idx on public.ride_tracking(driver_id);
create index if not exists rides_fare_rule_idx on public.rides(fare_rule_id);
create index if not exists rides_vehicle_idx on public.rides(vehicle_id);
