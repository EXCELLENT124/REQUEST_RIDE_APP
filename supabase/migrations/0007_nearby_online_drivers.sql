create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

create or replace function private.nearby_online_drivers(
  p_lat double precision,
  p_lng double precision
)
returns table (
  driver_id uuid,
  full_name text,
  vehicle_make text,
  vehicle_model text,
  vehicle_colour text,
  number_plate text,
  latitude double precision,
  longitude double precision,
  distance_km double precision,
  last_seen_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null or not exists (
    select 1 from public.profiles
    where id = (select auth.uid()) and role in ('customer', 'admin')
  ) then
    raise exception 'Customer or administrator account required';
  end if;

  if p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'Invalid customer location';
  end if;

  return query
  select
    availability.driver_id,
    profile.full_name,
    vehicle.make,
    vehicle.model,
    vehicle.colour,
    vehicle.number_plate,
    availability.latitude,
    availability.longitude,
    6371.0 * 2.0 * asin(sqrt(least(1.0,
      power(sin(radians((availability.latitude - p_lat) / 2.0)), 2) +
      cos(radians(p_lat)) * cos(radians(availability.latitude)) *
      power(sin(radians((availability.longitude - p_lng) / 2.0)), 2)
    ))) as distance_km,
    availability.last_seen_at
  from public.driver_availability availability
  join public.driver_applications application
    on application.driver_id = availability.driver_id
   and application.status = 'approved'
  join public.profiles profile on profile.id = availability.driver_id
  join public.vehicles vehicle on vehicle.driver_id = availability.driver_id
  where availability.is_online
    and availability.latitude is not null
    and availability.longitude is not null
    and availability.last_seen_at > now() - interval '2 minutes'
  order by distance_km, availability.last_seen_at desc;
end;
$$;

revoke all on function private.nearby_online_drivers(double precision, double precision)
  from public, anon;
grant execute on function private.nearby_online_drivers(double precision, double precision)
  to authenticated;

create or replace function public.nearby_online_drivers(
  p_lat double precision,
  p_lng double precision
)
returns table (
  driver_id uuid,
  full_name text,
  vehicle_make text,
  vehicle_model text,
  vehicle_colour text,
  number_plate text,
  latitude double precision,
  longitude double precision,
  distance_km double precision,
  last_seen_at timestamptz
)
language sql
stable
security invoker
set search_path = ''
as $$
  select * from private.nearby_online_drivers(p_lat, p_lng);
$$;

revoke all on function public.nearby_online_drivers(double precision, double precision)
  from public, anon;
grant execute on function public.nearby_online_drivers(double precision, double precision)
  to authenticated;

create index if not exists driver_availability_online_recent_idx
  on public.driver_availability(last_seen_at desc)
  where is_online and latitude is not null and longitude is not null;
