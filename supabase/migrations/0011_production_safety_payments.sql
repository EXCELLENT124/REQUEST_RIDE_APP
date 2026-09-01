alter table public.profiles
  add column if not exists emergency_contact_name text,
  add column if not exists emergency_contact_phone text,
  add column if not exists privacy_consent_at timestamptz,
  add column if not exists deletion_requested_at timestamptz;

alter table public.rides
  add column if not exists actual_distance_km numeric(10,2),
  add column if not exists actual_duration_minutes integer,
  add column if not exists payment_method text not null default 'cash',
  add column if not exists payment_status text not null default 'unpaid';
alter table public.rides drop constraint if exists rides_payment_method_check;
alter table public.rides add constraint rides_payment_method_check check (payment_method in ('cash','card'));
alter table public.rides drop constraint if exists rides_payment_status_check;
alter table public.rides add constraint rides_payment_status_check check (payment_status in ('unpaid','pending','paid','failed','refunded'));

create table public.ride_tracking_history (
  id bigint generated always as identity primary key,
  ride_id uuid not null references public.rides(id) on delete cascade,
  driver_id uuid not null references public.profiles(id),
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  recorded_at timestamptz not null default now()
);
create index ride_tracking_history_ride_time_idx on public.ride_tracking_history(ride_id,recorded_at);
alter table public.ride_tracking_history enable row level security;
create policy tracking_history_participants on public.ride_tracking_history for select to authenticated using (
  exists(select 1 from public.rides r where r.id=ride_id and ((select auth.uid()) in (r.customer_id,r.driver_id) or public.is_admin()))
);
grant select on public.ride_tracking_history to authenticated;

create table public.payment_transactions (
  id uuid primary key default gen_random_uuid(),
  ride_id uuid not null unique references public.rides(id) on delete cascade,
  customer_id uuid not null references public.profiles(id),
  amount numeric(10,2) not null check(amount >= 0),
  currency char(3) not null default 'ZAR' check(currency='ZAR'),
  method text not null check(method in ('cash','card')),
  status text not null check(status in ('unpaid','pending','paid','failed','refunded')),
  provider_reference text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.payment_transactions enable row level security;
create policy payment_participants_read on public.payment_transactions for select to authenticated using (
  customer_id=(select auth.uid()) or public.is_admin() or exists(select 1 from public.rides r where r.id=ride_id and r.driver_id=(select auth.uid()))
);
grant select on public.payment_transactions to authenticated;

create table public.safety_incidents (
  id uuid primary key default gen_random_uuid(),
  ride_id uuid references public.rides(id),
  reported_by uuid not null references public.profiles(id),
  latitude double precision,
  longitude double precision,
  incident_type text not null check(incident_type in ('sos','unsafe_driving','harassment','accident','other')),
  details text,
  status text not null default 'open' check(status in ('open','reviewing','resolved')),
  created_at timestamptz not null default now()
);
alter table public.safety_incidents enable row level security;
create policy safety_report_self on public.safety_incidents for insert to authenticated with check(reported_by=(select auth.uid()));
create policy safety_read_self_admin on public.safety_incidents for select to authenticated using(reported_by=(select auth.uid()) or public.is_admin());
grant select,insert on public.safety_incidents to authenticated;

create table public.account_deletion_requests (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  requested_at timestamptz not null default now(),
  status text not null default 'pending' check(status in ('pending','processing','completed','cancelled'))
);
alter table public.account_deletion_requests enable row level security;
create policy deletion_request_self on public.account_deletion_requests for select to authenticated using(user_id=(select auth.uid()));
grant select on public.account_deletion_requests to authenticated;

create or replace function private.set_ride_payment_method_internal(p_ride_id uuid,p_method text)
returns void language plpgsql security definer set search_path='' as $$
begin
  if p_method not in ('cash','card') then raise exception 'Invalid payment method'; end if;
  update public.rides set payment_method=p_method where id=p_ride_id and customer_id=(select auth.uid()) and status='searching';
  if not found then raise exception 'Payment method cannot be changed'; end if;
end; $$;
revoke all on function private.set_ride_payment_method_internal(uuid,text) from public,anon;
grant execute on function private.set_ride_payment_method_internal(uuid,text) to authenticated;
create or replace function public.set_ride_payment_method(p_ride_id uuid,p_method text) returns void language sql security invoker set search_path='' as $$ select private.set_ride_payment_method_internal(p_ride_id,p_method); $$;
revoke all on function public.set_ride_payment_method(uuid,text) from public,anon;
grant execute on function public.set_ride_payment_method(uuid,text) to authenticated;

create or replace function private.report_safety_incident_internal(p_ride_id uuid,p_type text,p_details text,p_lat double precision,p_lng double precision)
returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid;
begin
  if p_type not in ('sos','unsafe_driving','harassment','accident','other') then raise exception 'Invalid incident type'; end if;
  if p_ride_id is not null and not exists(select 1 from public.rides where id=p_ride_id and (select auth.uid()) in (customer_id,driver_id)) then raise exception 'Not a ride participant'; end if;
  insert into public.safety_incidents(ride_id,reported_by,latitude,longitude,incident_type,details)
  values(p_ride_id,(select auth.uid()),p_lat,p_lng,p_type,nullif(trim(coalesce(p_details,'')),'')) returning id into result;
  insert into public.notifications(user_id,title,body,data)
  select id,'Safety alert','A new safety incident requires review.',jsonb_build_object('incident_id',result,'ride_id',p_ride_id)
  from public.profiles where role='admin';
  return result;
end; $$;
revoke all on function private.report_safety_incident_internal(uuid,text,text,double precision,double precision) from public,anon;
grant execute on function private.report_safety_incident_internal(uuid,text,text,double precision,double precision) to authenticated;
create or replace function public.report_safety_incident(p_ride_id uuid,p_type text,p_details text,p_lat double precision default null,p_lng double precision default null) returns uuid language sql security invoker set search_path='' as $$ select private.report_safety_incident_internal(p_ride_id,p_type,p_details,p_lat,p_lng); $$;
revoke all on function public.report_safety_incident(uuid,text,text,double precision,double precision) from public,anon;
grant execute on function public.report_safety_incident(uuid,text,text,double precision,double precision) to authenticated;

create or replace function private.update_profile_internal(p_full_name text,p_phone text,p_emergency_name text,p_emergency_phone text,p_consent boolean)
returns void language plpgsql security definer set search_path='' as $$
begin
  if length(trim(coalesce(p_full_name,''))) < 2 then raise exception 'Full name is required'; end if;
  update public.profiles set full_name=trim(p_full_name),phone=nullif(trim(coalesce(p_phone,'')),''),emergency_contact_name=nullif(trim(coalesce(p_emergency_name,'')),''),emergency_contact_phone=nullif(trim(coalesce(p_emergency_phone,'')),''),privacy_consent_at=case when p_consent then coalesce(privacy_consent_at,now()) else null end where id=(select auth.uid());
end; $$;
revoke all on function private.update_profile_internal(text,text,text,text,boolean) from public,anon;
grant execute on function private.update_profile_internal(text,text,text,text,boolean) to authenticated;
create or replace function public.update_my_profile(p_full_name text,p_phone text,p_emergency_name text,p_emergency_phone text,p_consent boolean) returns void language sql security invoker set search_path='' as $$ select private.update_profile_internal(p_full_name,p_phone,p_emergency_name,p_emergency_phone,p_consent); $$;
revoke all on function public.update_my_profile(text,text,text,text,boolean) from public,anon;
grant execute on function public.update_my_profile(text,text,text,text,boolean) to authenticated;

create or replace function private.request_account_deletion_internal()
returns void language plpgsql security definer set search_path='' as $$
begin
  insert into public.account_deletion_requests(user_id) values((select auth.uid())) on conflict(user_id) do update set requested_at=now(),status='pending';
  update public.profiles set deletion_requested_at=now() where id=(select auth.uid());
  update public.driver_availability set is_online=false where driver_id=(select auth.uid());
end; $$;
revoke all on function private.request_account_deletion_internal() from public,anon;
grant execute on function private.request_account_deletion_internal() to authenticated;
create or replace function public.request_account_deletion() returns void language sql security invoker set search_path='' as $$ select private.request_account_deletion_internal(); $$;
revoke all on function public.request_account_deletion() from public,anon;
grant execute on function public.request_account_deletion() to authenticated;

create or replace function private.update_driver_location_internal(p_lat double precision,p_lng double precision,p_ride_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then raise exception 'Invalid location update'; end if;
  update public.driver_availability set latitude=p_lat,longitude=p_lng,last_seen_at=now() where driver_id=(select auth.uid());
  if not found then raise exception 'Driver availability record missing'; end if;
  if p_ride_id is not null then
    if not exists(select 1 from public.rides where id=p_ride_id and driver_id=(select auth.uid()) and status in ('accepted','driver_arriving','driver_arrived','in_progress')) then raise exception 'No active ride'; end if;
    insert into public.ride_tracking(ride_id,driver_id,latitude,longitude,recorded_at) values(p_ride_id,(select auth.uid()),p_lat,p_lng,now()) on conflict(ride_id) do update set latitude=excluded.latitude,longitude=excluded.longitude,recorded_at=now();
    insert into public.ride_tracking_history(ride_id,driver_id,latitude,longitude) values(p_ride_id,(select auth.uid()),p_lat,p_lng);
  end if;
end; $$;

create or replace function private.transition_ride_internal(p_ride_id uuid,p_next_status public.ride_status) returns void
language plpgsql security definer set search_path = '' as $$
declare v public.rides; allowed boolean := false; v_recipient uuid; v_message text; distance_value numeric; duration_value integer; fare_value numeric; rule_value public.fare_rules;
begin
  if (select auth.uid()) is null then raise exception 'Authentication required'; end if;
  select * into strict v from public.rides where id=p_ride_id for update;
  if (select auth.uid()) not in (v.customer_id,v.driver_id) and not public.is_admin() then raise exception 'Not a ride participant'; end if;
  allowed := (v.status='accepted' and p_next_status='driver_arriving') or (v.status='driver_arriving' and p_next_status='driver_arrived') or (v.status='driver_arrived' and p_next_status='in_progress') or (v.status='in_progress' and p_next_status='completed');
  if not allowed then raise exception 'Invalid ride transition'; end if;
  if p_next_status='completed' then
    with points as (select latitude,longitude,lag(latitude) over(order by recorded_at) prev_lat,lag(longitude) over(order by recorded_at) prev_lng from public.ride_tracking_history where ride_id=p_ride_id)
    select coalesce(sum(6371*2*asin(sqrt(least(1,power(sin(radians((latitude-prev_lat)/2)),2)+cos(radians(prev_lat))*cos(radians(latitude))*power(sin(radians((longitude-prev_lng)/2)),2))))),0) into distance_value from points where prev_lat is not null;
    distance_value:=greatest(distance_value,v.estimated_distance_km);
    duration_value:=greatest(1,ceil(extract(epoch from (now()-v.started_at))/60)::integer);
    select * into strict rule_value from public.fare_rules where id=v.fare_rule_id;
    fare_value:=round(greatest(rule_value.minimum_fare,rule_value.base_fare+rule_value.booking_fee+rule_value.per_km*distance_value+rule_value.per_minute*duration_value),2);
  end if;
  update public.rides set status=p_next_status,started_at=case when p_next_status='in_progress' then now() else started_at end,completed_at=case when p_next_status='completed' then now() else completed_at end,actual_distance_km=case when p_next_status='completed' then distance_value else actual_distance_km end,actual_duration_minutes=case when p_next_status='completed' then duration_value else actual_duration_minutes end,final_fare=case when p_next_status='completed' then fare_value else final_fare end,payment_status=case when p_next_status='completed' and payment_method='card' then 'pending' when p_next_status='completed' then 'unpaid' else payment_status end where id=p_ride_id;
  if p_next_status='completed' then insert into public.payment_transactions(ride_id,customer_id,amount,method,status) values(p_ride_id,v.customer_id,fare_value,v.payment_method,case when v.payment_method='card' then 'pending' else 'unpaid' end) on conflict(ride_id) do nothing; end if;
  v_recipient:=case when (select auth.uid())=v.customer_id then v.driver_id else v.customer_id end;
  v_message:=case p_next_status when 'driver_arriving' then 'Your driver is on the way.' when 'driver_arrived' then 'Your driver has arrived.' when 'in_progress' then 'Your trip has started.' else 'Your trip is complete. Final fare: R'||fare_value::text end;
  if v_recipient is not null then insert into public.notifications(user_id,title,body,data) values(v_recipient,'Ride update',v_message,jsonb_build_object('ride_id',p_ride_id,'type','ride_status','status',p_next_status)); end if;
end; $$;

create index if not exists payment_transactions_customer_idx on public.payment_transactions(customer_id,created_at desc);
create index if not exists safety_incidents_reporter_idx on public.safety_incidents(reported_by,created_at desc);
