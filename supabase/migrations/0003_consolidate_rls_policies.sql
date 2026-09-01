drop policy applications_driver_update on public.driver_applications;
drop policy applications_admin_update on public.driver_applications;
create policy applications_update on public.driver_applications for update to authenticated
using (public.is_admin() or (driver_id=(select auth.uid()) and status in ('draft','rejected')))
with check (public.is_admin() or (driver_id=(select auth.uid()) and status in ('draft','pending')));

drop policy availability_self on public.driver_availability;
drop policy availability_nearby on public.driver_availability;
create policy availability_read on public.driver_availability for select to authenticated
using (driver_id=(select auth.uid()) or public.is_admin() or (is_online and exists(select 1 from public.driver_applications a where a.driver_id=driver_availability.driver_id and a.status='approved')));

drop policy fares_read on public.fare_rules;
drop policy fares_admin on public.fare_rules;
create policy fares_read on public.fare_rules for select to authenticated using(active or public.is_admin());
create policy fares_insert_admin on public.fare_rules for insert to authenticated with check(public.is_admin());
create policy fares_update_admin on public.fare_rules for update to authenticated using(public.is_admin()) with check(public.is_admin());
create policy fares_delete_admin on public.fare_rules for delete to authenticated using(public.is_admin());

drop policy vehicles_write on public.vehicles;
create policy vehicles_insert_self on public.vehicles for insert to authenticated with check(driver_id=(select auth.uid()));
create policy vehicles_update_self on public.vehicles for update to authenticated using(driver_id=(select auth.uid())) with check(driver_id=(select auth.uid()));
create policy vehicles_delete_self on public.vehicles for delete to authenticated using(driver_id=(select auth.uid()));
