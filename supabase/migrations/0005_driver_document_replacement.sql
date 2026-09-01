drop policy documents_admin_update on public.driver_documents;
create policy documents_update on public.driver_documents for update to authenticated
using (public.is_admin() or (driver_id=(select auth.uid()) and verified=false))
with check (public.is_admin() or (driver_id=(select auth.uid()) and verified=false));
