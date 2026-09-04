create or replace function private.update_driver_location_internal(
  p_lat double precision,
  p_lng double precision,
  p_ride_id uuid,
  p_heading double precision,
  p_speed_mps double precision
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null
    or p_lat not between -90 and 90
    or p_lng not between -180 and 180
    or (p_heading is not null and p_heading not between 0 and 360)
    or (p_speed_mps is not null and p_speed_mps < 0)
  then
    raise exception 'Invalid location update';
  end if;

  update public.driver_availability
  set latitude = p_lat,
      longitude = p_lng,
      heading = p_heading,
      last_seen_at = now()
  where driver_id = (select auth.uid());
  if not found then raise exception 'Driver availability record missing'; end if;

  if p_ride_id is not null then
    if not exists (
      select 1 from public.rides
      where id = p_ride_id
        and driver_id = (select auth.uid())
        and status in ('accepted', 'driver_arriving', 'driver_arrived', 'in_progress')
    ) then
      raise exception 'No active ride';
    end if;

    insert into public.ride_tracking(
      ride_id, driver_id, latitude, longitude, heading, speed_mps, recorded_at
    ) values (
      p_ride_id, (select auth.uid()), p_lat, p_lng, p_heading, p_speed_mps, now()
    )
    on conflict(ride_id) do update set
      latitude = excluded.latitude,
      longitude = excluded.longitude,
      heading = excluded.heading,
      speed_mps = excluded.speed_mps,
      recorded_at = now();

    insert into public.ride_tracking_history(
      ride_id, driver_id, latitude, longitude
    ) values (
      p_ride_id, (select auth.uid()), p_lat, p_lng
    );
  end if;
end;
$$;

revoke all on function private.update_driver_location_internal(
  double precision, double precision, uuid, double precision, double precision
) from public, anon;
grant execute on function private.update_driver_location_internal(
  double precision, double precision, uuid, double precision, double precision
) to authenticated;

create or replace function public.update_driver_location(
  p_lat double precision,
  p_lng double precision,
  p_ride_id uuid default null,
  p_heading double precision default null,
  p_speed_mps double precision default null
) returns void
language sql
security invoker
set search_path = ''
as $$
  select private.update_driver_location_internal(
    p_lat, p_lng, p_ride_id, p_heading, p_speed_mps
  );
$$;

revoke all on function public.update_driver_location(
  double precision, double precision, uuid, double precision, double precision
) from public, anon;
grant execute on function public.update_driver_location(
  double precision, double precision, uuid, double precision, double precision
) to authenticated;
