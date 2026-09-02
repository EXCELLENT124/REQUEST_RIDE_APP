create or replace function private.cancel_ride_internal(
  p_ride_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.rides;
  recipient uuid;
begin
  if (select auth.uid()) is null
     or length(trim(coalesce(p_reason, ''))) < 3 then
    raise exception 'A cancellation reason is required';
  end if;

  select *
  into strict v
  from public.rides
  where id = p_ride_id
  for update;

  if (select auth.uid()) not in (v.customer_id, v.driver_id) then
    raise exception 'Only a ride participant can cancel';
  end if;

  if v.status not in (
    'searching',
    'accepted',
    'driver_arriving',
    'driver_arrived',
    'in_progress'
  ) then
    raise exception 'This ride can no longer be cancelled';
  end if;

  update public.rides
  set status = 'cancelled',
      cancelled_at = now(),
      cancelled_by = (select auth.uid()),
      cancellation_reason = trim(p_reason)
  where id = p_ride_id;

  recipient := case
    when (select auth.uid()) = v.customer_id then v.driver_id
    else v.customer_id
  end;

  if recipient is not null then
    insert into public.notifications(user_id, title, body, data)
    values (
      recipient,
      'Ride cancelled',
      'The ride was cancelled: ' || trim(p_reason),
      jsonb_build_object('ride_id', p_ride_id, 'type', 'ride_cancelled')
    );
  end if;
end;
$$;

revoke all on function private.cancel_ride_internal(uuid, text)
  from public, anon;
grant execute on function private.cancel_ride_internal(uuid, text)
  to authenticated;
