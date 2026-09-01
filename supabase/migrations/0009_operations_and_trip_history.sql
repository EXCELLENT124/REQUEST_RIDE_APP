alter table public.rides
  add column if not exists cancellation_reason text,
  add column if not exists cancelled_by uuid references public.profiles(id);

alter table public.driver_documents
  add column if not exists file_name text,
  add column if not exists mime_type text,
  add column if not exists file_size_bytes bigint,
  add column if not exists expires_at date;

alter table public.vehicles add column if not exists body_type text;
alter table public.vehicles drop constraint if exists vehicles_body_type_check;
alter table public.vehicles add constraint vehicles_body_type_check check (
  body_type is null or body_type in
    ('sedan','hatchback','suv','mpv','coupe','station_wagon')
);

create or replace function private.submit_driver_application_internal(p_proof_of_address text)
returns void language plpgsql security definer set search_path = '' as $$
declare required_count integer;
begin
  if (select auth.uid()) is null or not exists (
    select 1 from public.profiles where id=(select auth.uid()) and role='driver'
  ) then raise exception 'Driver account required'; end if;
  if length(trim(coalesce(p_proof_of_address,''))) < 8 then
    raise exception 'A complete residential address is required';
  end if;
  if not exists (
    select 1 from public.vehicles where driver_id=(select auth.uid())
      and body_type in ('sedan','hatchback','suv','mpv','coupe','station_wagon')
      and length(trim(make)) >= 2 and length(trim(model)) >= 1
      and length(trim(colour)) >= 2 and length(trim(number_plate)) >= 3
      and year between 2000 and extract(year from now())::integer + 1
  ) then raise exception 'Complete valid car information is required; bakkies are not accepted'; end if;
  select count(distinct type) into required_count from public.driver_documents
    where driver_id=(select auth.uid())
      and mime_type in ('application/pdf','image/jpeg','image/png')
      and file_size_bytes between 1 and 10485760;
  if required_count <> 7 then raise exception 'All seven valid documents are required'; end if;
  if exists (
    select 1 from unnest(array['drivers_licence','professional_driving_permit','roadworthy','insurance']::public.document_type[]) required(type)
    where not exists (
      select 1 from public.driver_documents document
      where document.driver_id=(select auth.uid()) and document.type=required.type
        and document.expires_at > current_date
    )
  ) then raise exception 'Licence, PrDP, roadworthy and insurance expiry dates must be valid'; end if;
  update public.driver_applications set status='pending',proof_of_address_text=trim(p_proof_of_address),submitted_at=now(),rejection_reason=null
  where driver_id=(select auth.uid()) and status in ('draft','rejected');
  if not found then raise exception 'Application cannot be submitted in its current state'; end if;
end; $$;
revoke all on function private.submit_driver_application_internal(text) from public,anon;
grant execute on function private.submit_driver_application_internal(text) to authenticated;
create or replace function public.submit_driver_application(p_proof_of_address text)
returns void language sql security invoker set search_path='' as $$
  select private.submit_driver_application_internal(p_proof_of_address);
$$;
revoke all on function public.submit_driver_application(text) from public,anon;
grant execute on function public.submit_driver_application(text) to authenticated;

create or replace function private.cancel_ride_internal(p_ride_id uuid,p_reason text)
returns void language plpgsql security definer set search_path='' as $$
declare v public.rides; recipient uuid;
begin
  if (select auth.uid()) is null or length(trim(coalesce(p_reason,''))) < 3 then raise exception 'A cancellation reason is required'; end if;
  select * into strict v from public.rides where id=p_ride_id for update;
  if (select auth.uid()) not in (v.customer_id,v.driver_id) then raise exception 'Only a ride participant can cancel'; end if;
  if v.status not in ('searching','accepted','driver_arriving','driver_arrived') then raise exception 'This ride can no longer be cancelled'; end if;
  update public.rides set status='cancelled',cancelled_at=now(),cancelled_by=(select auth.uid()),cancellation_reason=trim(p_reason) where id=p_ride_id;
  recipient := case when (select auth.uid())=v.customer_id then v.driver_id else v.customer_id end;
  if recipient is not null then insert into public.notifications(user_id,title,body,data)
    values(recipient,'Ride cancelled','The ride was cancelled: '||trim(p_reason),jsonb_build_object('ride_id',p_ride_id,'type','ride_cancelled'));
  end if;
end; $$;
revoke all on function private.cancel_ride_internal(uuid,text) from public,anon;
grant execute on function private.cancel_ride_internal(uuid,text) to authenticated;
create or replace function public.cancel_ride(p_ride_id uuid,p_reason text)
returns void language sql security invoker set search_path='' as $$ select private.cancel_ride_internal(p_ride_id,p_reason); $$;
revoke all on function public.cancel_ride(uuid,text) from public,anon;
grant execute on function public.cancel_ride(uuid,text) to authenticated;

create or replace function private.rate_ride_internal(p_ride_id uuid,p_score smallint,p_comment text)
returns void language plpgsql security definer set search_path='' as $$
declare v public.rides; subject uuid;
begin
  if (select auth.uid()) is null or p_score not between 1 and 5 then raise exception 'Rating must be from 1 to 5'; end if;
  select * into strict v from public.rides where id=p_ride_id and status='completed';
  if (select auth.uid())=v.customer_id then subject:=v.driver_id;
  elsif (select auth.uid())=v.driver_id then subject:=v.customer_id;
  else raise exception 'Only ride participants can rate'; end if;
  if subject is null then raise exception 'The other participant is missing'; end if;
  insert into public.ratings(ride_id,author_id,subject_id,score,comment)
  values(p_ride_id,(select auth.uid()),subject,p_score,nullif(trim(coalesce(p_comment,'')),''))
  on conflict(ride_id,author_id) do update set score=excluded.score,comment=excluded.comment;
end; $$;
revoke all on function private.rate_ride_internal(uuid,smallint,text) from public,anon;
grant execute on function private.rate_ride_internal(uuid,smallint,text) to authenticated;
create or replace function public.rate_ride(p_ride_id uuid,p_score smallint,p_comment text default null)
returns void language sql security invoker set search_path='' as $$ select private.rate_ride_internal(p_ride_id,p_score,p_comment); $$;
revoke all on function public.rate_ride(uuid,smallint,text) from public,anon;
grant execute on function public.rate_ride(uuid,smallint,text) to authenticated;
create policy ratings_update_self on public.ratings for update to authenticated
  using(author_id=(select auth.uid())) with check(author_id=(select auth.uid()));
grant update on public.ratings to authenticated;

create or replace function private.admin_set_fare_internal(p_name text,p_base numeric,p_per_km numeric,p_per_minute numeric,p_minimum numeric,p_booking numeric)
returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid;
begin
  if not public.is_admin() then raise exception 'Administrator account required'; end if;
  if least(p_base,p_per_km,p_per_minute,p_minimum,p_booking) < 0 or length(trim(p_name)) < 2 then raise exception 'Invalid fare values'; end if;
  update public.fare_rules set active=false where active;
  insert into public.fare_rules(name,base_fare,per_km,per_minute,minimum_fare,booking_fee,active,created_by)
  values(trim(p_name),p_base,p_per_km,p_per_minute,p_minimum,p_booking,true,(select auth.uid())) returning id into result;
  return result;
end; $$;
revoke all on function private.admin_set_fare_internal(text,numeric,numeric,numeric,numeric,numeric) from public,anon;
grant execute on function private.admin_set_fare_internal(text,numeric,numeric,numeric,numeric,numeric) to authenticated;
create or replace function public.admin_set_fare(p_name text,p_base numeric,p_per_km numeric,p_per_minute numeric,p_minimum numeric,p_booking numeric)
returns uuid language sql security invoker set search_path='' as $$ select private.admin_set_fare_internal(p_name,p_base,p_per_km,p_per_minute,p_minimum,p_booking); $$;
revoke all on function public.admin_set_fare(text,numeric,numeric,numeric,numeric,numeric) from public,anon;
grant execute on function public.admin_set_fare(text,numeric,numeric,numeric,numeric,numeric) to authenticated;

create or replace function private.admin_set_driver_status_internal(p_driver_id uuid,p_status public.approval_status,p_reason text)
returns void language plpgsql security definer set search_path='' as $$
begin
  if not public.is_admin() then raise exception 'Administrator account required'; end if;
  if p_status not in ('approved','rejected','suspended') then raise exception 'Invalid administrative status'; end if;
  if p_status in ('rejected','suspended') and length(trim(coalesce(p_reason,''))) < 3 then raise exception 'A reason is required'; end if;
  update public.driver_applications set status=p_status,rejection_reason=nullif(trim(coalesce(p_reason,'')),''),reviewed_at=now(),reviewed_by=(select auth.uid()) where driver_id=p_driver_id;
  if not found then raise exception 'Driver application not found'; end if;
  if p_status <> 'approved' then update public.driver_availability set is_online=false where driver_id=p_driver_id; end if;
  insert into public.notifications(user_id,title,body,data) values(p_driver_id,'Driver account update','Your driver status is now '||p_status::text||coalesce(': '||nullif(trim(coalesce(p_reason,'')),''),''),jsonb_build_object('type','driver_status','status',p_status));
end; $$;
revoke all on function private.admin_set_driver_status_internal(uuid,public.approval_status,text) from public,anon;
grant execute on function private.admin_set_driver_status_internal(uuid,public.approval_status,text) to authenticated;
create or replace function public.admin_set_driver_status(p_driver_id uuid,p_status public.approval_status,p_reason text default null)
returns void language sql security invoker set search_path='' as $$ select private.admin_set_driver_status_internal(p_driver_id,p_status,p_reason); $$;
revoke all on function public.admin_set_driver_status(uuid,public.approval_status,text) from public,anon;
grant execute on function public.admin_set_driver_status(uuid,public.approval_status,text) to authenticated;

create or replace function private.review_driver_internal(p_driver_id uuid,p_approve boolean,p_reason text default null) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null or not public.is_admin() then raise exception 'Administrator account required'; end if;
  if not exists(select 1 from public.driver_applications where driver_id=p_driver_id and status='pending') then raise exception 'Driver is not pending review'; end if;
  if p_approve and (select count(distinct type) from public.driver_documents where driver_id=p_driver_id) <> 7 then raise exception 'All seven documents are required'; end if;
  if p_approve and exists(select 1 from public.driver_documents where driver_id=p_driver_id and type in ('drivers_licence','professional_driving_permit','roadworthy','insurance') and (expires_at is null or expires_at <= current_date)) then raise exception 'A required document is expired'; end if;
  if p_approve and not exists(select 1 from public.vehicles where driver_id=p_driver_id and body_type in ('sedan','hatchback','suv','mpv','coupe','station_wagon')) then raise exception 'An eligible car is required'; end if;
  if not p_approve and length(trim(coalesce(p_reason,''))) < 3 then raise exception 'A rejection reason is required'; end if;
  update public.driver_applications set status=case when p_approve then 'approved'::public.approval_status else 'rejected'::public.approval_status end,reviewed_at=now(),reviewed_by=(select auth.uid()),rejection_reason=case when p_approve then null else trim(p_reason) end where driver_id=p_driver_id;
  update public.driver_documents set verified=p_approve,verified_by=case when p_approve then (select auth.uid()) else null end,verified_at=case when p_approve then now() else null end where driver_id=p_driver_id;
end; $$;
