create or replace function private.review_driver_internal(p_driver_id uuid,p_approve boolean,p_reason text default null) returns void
language plpgsql security definer set search_path='' as $$
begin
  if (select auth.uid()) is null or not public.is_admin() then raise exception 'Administrator access required'; end if;
  if p_approve and not exists(select 1 from public.vehicles v where v.driver_id=p_driver_id and v.vehicle_type='car') then raise exception 'An eligible car is required'; end if;
  if p_approve and (select count(distinct d.type) from public.driver_documents d where d.driver_id=p_driver_id) < 5 then raise exception 'Required driver documents are missing'; end if;
  update public.driver_applications set status=case when p_approve then 'approved'::public.approval_status else 'rejected'::public.approval_status end,rejection_reason=case when p_approve then null else nullif(trim(p_reason),'') end,reviewed_at=now(),reviewed_by=(select auth.uid()),updated_at=now() where driver_id=p_driver_id and status='pending';
  if not found then raise exception 'Pending application not found'; end if;
  update public.driver_documents set verified=p_approve,verified_by=case when p_approve then (select auth.uid()) else null end,verified_at=case when p_approve then now() else null end where driver_id=p_driver_id;
end;
$$;
revoke execute on function private.review_driver_internal(uuid,boolean,text) from public,anon;
grant execute on function private.review_driver_internal(uuid,boolean,text) to authenticated;

create or replace function public.review_driver(p_driver_id uuid,p_approve boolean,p_reason text default null) returns void
language sql security invoker set search_path='' as $$ select private.review_driver_internal(p_driver_id,p_approve,p_reason); $$;
revoke execute on function public.review_driver(uuid,boolean,text) from public,anon;
grant execute on function public.review_driver(uuid,boolean,text) to authenticated;

create policy documents_admin_update on public.driver_documents for update to authenticated using(public.is_admin()) with check(public.is_admin());
grant update on public.driver_documents to authenticated;
