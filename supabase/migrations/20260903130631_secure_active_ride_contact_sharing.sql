drop policy if exists profiles_read on public.profiles;

create policy profiles_read
on public.profiles for select to authenticated
using (
  id = (select auth.uid())
  or public.is_admin()
  or exists (
    select 1
    from public.rides r
    where r.status in ('accepted', 'driver_arriving', 'driver_arrived', 'in_progress')
      and (
        (r.customer_id = (select auth.uid()) and r.driver_id = profiles.id)
        or
        (r.driver_id = (select auth.uid()) and r.customer_id = profiles.id)
      )
  )
);

create or replace function public.active_ride_contact(p_ride_id uuid)
returns table (
  contact_id uuid,
  full_name text,
  phone text,
  role public.user_role
)
language sql
stable
security invoker
set search_path = ''
as $$
  select contact.id, contact.full_name, contact.phone, contact.role
  from public.rides ride
  join public.profiles contact
    on contact.id = case
      when ride.customer_id = (select auth.uid()) then ride.driver_id
      else ride.customer_id
    end
  where ride.id = p_ride_id
    and (select auth.uid()) in (ride.customer_id, ride.driver_id)
    and ride.status in ('accepted', 'driver_arriving', 'driver_arrived', 'in_progress');
$$;

revoke all on function public.active_ride_contact(uuid) from public, anon;
grant execute on function public.active_ride_contact(uuid) to authenticated;
