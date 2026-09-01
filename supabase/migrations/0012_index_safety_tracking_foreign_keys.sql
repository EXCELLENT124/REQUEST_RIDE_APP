create index if not exists ride_tracking_history_driver_idx
  on public.ride_tracking_history(driver_id);
create index if not exists safety_incidents_ride_idx
  on public.safety_incidents(ride_id)
  where ride_id is not null;
