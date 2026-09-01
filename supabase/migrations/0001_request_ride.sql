-- Request Ride initial schema. Apply through the Supabase migration workflow.
create extension if not exists pgcrypto;

create type public.user_role as enum ('customer', 'driver', 'admin');
create type public.approval_status as enum ('draft', 'pending', 'approved', 'rejected', 'suspended');
create type public.ride_status as enum ('searching', 'accepted', 'driver_arriving', 'driver_arrived', 'in_progress', 'completed', 'cancelled');
create type public.document_type as enum ('drivers_licence', 'professional_driving_permit', 'vehicle_registration', 'roadworthy', 'insurance', 'proof_of_address', 'identity_document');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null check (length(trim(full_name)) >= 2),
  phone text,
  role public.user_role not null default 'customer',
  average_rating numeric(3,2) not null default 0 check (average_rating between 0 and 5),
  rating_count integer not null default 0 check (rating_count >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.driver_applications (
  driver_id uuid primary key references public.profiles(id) on delete cascade,
  status public.approval_status not null default 'draft',
  proof_of_address_text text,
  rejection_reason text,
  submitted_at timestamptz,
  reviewed_at timestamptz,
  reviewed_by uuid references public.profiles(id),
  updated_at timestamptz not null default now()
);

create table public.vehicles (
  id uuid primary key default gen_random_uuid(),
  driver_id uuid not null unique references public.profiles(id) on delete cascade,
  make text not null,
  model text not null,
  year integer not null check (year between 1990 and 2100),
  colour text not null,
  number_plate text not null unique,
  vehicle_type text not null default 'car' check (vehicle_type = 'car'),
  seat_count smallint not null default 4 check (seat_count between 4 and 8),
  created_at timestamptz not null default now()
);

create table public.driver_documents (
  id uuid primary key default gen_random_uuid(),
  driver_id uuid not null references public.profiles(id) on delete cascade,
  type public.document_type not null,
  storage_path text not null,
  expires_on date,
  verified boolean not null default false,
  verified_by uuid references public.profiles(id),
  verified_at timestamptz,
  created_at timestamptz not null default now(),
  unique (driver_id, type)
);

create table public.driver_availability (
  driver_id uuid primary key references public.profiles(id) on delete cascade,
  is_online boolean not null default false,
  latitude double precision check (latitude between -90 and 90),
  longitude double precision check (longitude between -180 and 180),
  heading double precision,
  last_seen_at timestamptz not null default now()
);

create table public.fare_rules (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  currency char(3) not null default 'ZAR' check (currency = 'ZAR'),
  base_fare numeric(10,2) not null check (base_fare >= 0),
  per_km numeric(10,2) not null check (per_km >= 0),
  per_minute numeric(10,2) not null check (per_minute >= 0),
  minimum_fare numeric(10,2) not null check (minimum_fare >= 0),
  booking_fee numeric(10,2) not null default 0 check (booking_fee >= 0),
  active boolean not null default false,
  effective_from timestamptz not null default now(),
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);
create unique index one_active_fare_rule on public.fare_rules(active) where active;

create table public.rides (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.profiles(id),
  driver_id uuid references public.profiles(id),
  vehicle_id uuid references public.vehicles(id),
  status public.ride_status not null default 'searching',
  pickup_lat double precision not null check (pickup_lat between -90 and 90),
  pickup_lng double precision not null check (pickup_lng between -180 and 180),
  pickup_address text,
  destination_lat double precision not null check (destination_lat between -90 and 90),
  destination_lng double precision not null check (destination_lng between -180 and 180),
  destination_address text,
  estimated_distance_km numeric(10,2) not null check (estimated_distance_km >= 0),
  estimated_duration_minutes integer not null check (estimated_duration_minutes >= 0),
  estimated_fare numeric(10,2) not null check (estimated_fare >= 0),
  final_fare numeric(10,2) check (final_fare >= 0),
  fare_rule_id uuid not null references public.fare_rules(id),
  requested_at timestamptz not null default now(),
  accepted_at timestamptz,
  started_at timestamptz,
  completed_at timestamptz,
  cancelled_at timestamptz
);
create index rides_customer_idx on public.rides(customer_id, requested_at desc);
create index rides_driver_idx on public.rides(driver_id, requested_at desc);
create index rides_searching_idx on public.rides(requested_at) where status = 'searching';

create table public.ride_tracking (
  ride_id uuid primary key references public.rides(id) on delete cascade,
  driver_id uuid not null references public.profiles(id),
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  heading double precision,
  speed_mps double precision,
  recorded_at timestamptz not null default now()
);

create table public.ratings (
  id uuid primary key default gen_random_uuid(),
  ride_id uuid not null references public.rides(id) on delete cascade,
  author_id uuid not null references public.profiles(id),
  subject_id uuid not null references public.profiles(id),
  score smallint not null check (score between 1 and 5),
  comment text check (length(comment) <= 1000),
  created_at timestamptz not null default now(),
  unique (ride_id, author_id),
  check (author_id <> subject_id)
);

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  title text not null,
  body text not null,
  data jsonb not null default '{}',
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create or replace function public.is_admin() returns boolean language sql stable security invoker set search_path = '' as $$
  select exists(select 1 from public.profiles p where p.id = (select auth.uid()) and p.role = 'admin');
$$;

create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path = '' as $$
declare requested public.user_role;
begin
  requested := case when new.raw_user_meta_data->>'requested_role' = 'driver' then 'driver'::public.user_role else 'customer'::public.user_role end;
  insert into public.profiles(id, full_name, role) values (new.id, coalesce(nullif(trim(new.raw_user_meta_data->>'full_name'), ''), 'New user'), requested);
  if requested = 'driver' then insert into public.driver_applications(driver_id) values (new.id); end if;
  return new;
end;
$$;
revoke execute on function public.handle_new_user() from public, anon, authenticated;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

create or replace function public.estimate_fare(p_distance_km numeric, p_duration_minutes integer) returns numeric
language sql stable security invoker set search_path = '' as $$
  select round(greatest(f.minimum_fare, f.base_fare + f.booking_fee + f.per_km * greatest(p_distance_km, 0) + f.per_minute * greatest(p_duration_minutes, 0)), 2)
  from public.fare_rules f where f.active order by f.effective_from desc limit 1;
$$;

create or replace function public.request_ride(p_pickup_lat double precision, p_pickup_lng double precision, p_pickup_address text, p_destination_lat double precision, p_destination_lng double precision, p_destination_address text, p_distance_km numeric, p_duration_minutes integer) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_rule public.fare_rules;
begin
  if not exists(select 1 from public.profiles where id = (select auth.uid()) and role = 'customer') then raise exception 'Customer account required'; end if;
  select * into strict v_rule from public.fare_rules where active order by effective_from desc limit 1;
  insert into public.rides(customer_id, pickup_lat, pickup_lng, pickup_address, destination_lat, destination_lng, destination_address, estimated_distance_km, estimated_duration_minutes, estimated_fare, fare_rule_id)
  values ((select auth.uid()), p_pickup_lat, p_pickup_lng, p_pickup_address, p_destination_lat, p_destination_lng, p_destination_address, p_distance_km, p_duration_minutes, public.estimate_fare(p_distance_km,p_duration_minutes), v_rule.id) returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.set_driver_availability(p_online boolean, p_lat double precision default null, p_lng double precision default null) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_online and not exists(select 1 from public.driver_applications where driver_id = (select auth.uid()) and status = 'approved') then raise exception 'Driver is not approved'; end if;
  insert into public.driver_availability(driver_id,is_online,latitude,longitude,last_seen_at) values ((select auth.uid()),p_online,p_lat,p_lng,now())
  on conflict(driver_id) do update set is_online=excluded.is_online, latitude=coalesce(excluded.latitude,public.driver_availability.latitude), longitude=coalesce(excluded.longitude,public.driver_availability.longitude), last_seen_at=now();
end;
$$;

create or replace function public.accept_ride(p_ride_id uuid) returns void language plpgsql security definer set search_path = '' as $$
begin
  if not exists(select 1 from public.driver_applications where driver_id=(select auth.uid()) and status='approved') then raise exception 'Driver is not approved'; end if;
  update public.rides set driver_id=(select auth.uid()), vehicle_id=(select id from public.vehicles where driver_id=(select auth.uid())), status='accepted', accepted_at=now()
  where id=p_ride_id and status='searching';
  if not found then raise exception 'Ride is no longer available'; end if;
end;
$$;

create or replace function public.transition_ride(p_ride_id uuid, p_next_status public.ride_status) returns void language plpgsql security definer set search_path = '' as $$
declare v public.rides; allowed boolean := false;
begin
  select * into strict v from public.rides where id=p_ride_id for update;
  if (select auth.uid()) not in (v.customer_id,v.driver_id) and not public.is_admin() then raise exception 'Not a ride participant'; end if;
  allowed := (v.status='accepted' and p_next_status in ('driver_arriving','cancelled')) or (v.status='driver_arriving' and p_next_status in ('driver_arrived','cancelled')) or (v.status='driver_arrived' and p_next_status in ('in_progress','cancelled')) or (v.status='in_progress' and p_next_status='completed') or (v.status='searching' and p_next_status='cancelled');
  if not allowed then raise exception 'Invalid ride transition'; end if;
  update public.rides set status=p_next_status, started_at=case when p_next_status='in_progress' then now() else started_at end, completed_at=case when p_next_status='completed' then now() else completed_at end, cancelled_at=case when p_next_status='cancelled' then now() else cancelled_at end where id=p_ride_id;
end;
$$;

create or replace function public.update_driver_location(p_lat double precision, p_lng double precision, p_ride_id uuid default null) returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.driver_availability set latitude=p_lat,longitude=p_lng,last_seen_at=now() where driver_id=(select auth.uid());
  if p_ride_id is not null then
    if not exists(select 1 from public.rides where id=p_ride_id and driver_id=(select auth.uid()) and status in ('accepted','driver_arriving','driver_arrived','in_progress')) then raise exception 'No active ride'; end if;
    insert into public.ride_tracking(ride_id,driver_id,latitude,longitude,recorded_at) values(p_ride_id,(select auth.uid()),p_lat,p_lng,now()) on conflict(ride_id) do update set latitude=excluded.latitude,longitude=excluded.longitude,recorded_at=now();
  end if;
end;
$$;

alter table public.profiles enable row level security;
alter table public.driver_applications enable row level security;
alter table public.vehicles enable row level security;
alter table public.driver_documents enable row level security;
alter table public.driver_availability enable row level security;
alter table public.fare_rules enable row level security;
alter table public.rides enable row level security;
alter table public.ride_tracking enable row level security;
alter table public.ratings enable row level security;
alter table public.notifications enable row level security;

create policy profiles_read on public.profiles for select to authenticated using (id=(select auth.uid()) or public.is_admin() or exists(select 1 from public.rides r where (r.customer_id=(select auth.uid()) and r.driver_id=profiles.id) or (r.driver_id=(select auth.uid()) and r.customer_id=profiles.id)));
create policy profiles_update_self on public.profiles for update to authenticated using(id=(select auth.uid())) with check(id=(select auth.uid()) and role=(select p.role from public.profiles p where p.id=(select auth.uid())));
create policy applications_read on public.driver_applications for select to authenticated using(driver_id=(select auth.uid()) or public.is_admin());
create policy applications_driver_update on public.driver_applications for update to authenticated using(driver_id=(select auth.uid()) and status in ('draft','rejected')) with check(driver_id=(select auth.uid()) and status in ('draft','pending'));
create policy applications_admin_update on public.driver_applications for update to authenticated using(public.is_admin()) with check(public.is_admin());
create policy vehicles_read on public.vehicles for select to authenticated using(driver_id=(select auth.uid()) or public.is_admin() or exists(select 1 from public.rides r where r.vehicle_id=vehicles.id and (r.customer_id=(select auth.uid()) or r.driver_id=(select auth.uid()))));
create policy vehicles_write on public.vehicles for all to authenticated using(driver_id=(select auth.uid())) with check(driver_id=(select auth.uid()));
create policy documents_read on public.driver_documents for select to authenticated using(driver_id=(select auth.uid()) or public.is_admin());
create policy documents_write on public.driver_documents for insert to authenticated with check(driver_id=(select auth.uid()) and verified=false);
create policy availability_self on public.driver_availability for select to authenticated using(driver_id=(select auth.uid()) or public.is_admin());
create policy availability_nearby on public.driver_availability for select to authenticated using(is_online and exists(select 1 from public.driver_applications a where a.driver_id=driver_availability.driver_id and a.status='approved'));
create policy fares_read on public.fare_rules for select to authenticated using(active or public.is_admin());
create policy fares_admin on public.fare_rules for all to authenticated using(public.is_admin()) with check(public.is_admin());
create policy rides_participants_read on public.rides for select to authenticated using(customer_id=(select auth.uid()) or driver_id=(select auth.uid()) or public.is_admin() or (status='searching' and exists(select 1 from public.driver_applications a where a.driver_id=(select auth.uid()) and a.status='approved')));
create policy tracking_participants on public.ride_tracking for select to authenticated using(exists(select 1 from public.rides r where r.id=ride_id and ((select auth.uid()) in (r.customer_id,r.driver_id) or public.is_admin())));
create policy ratings_read on public.ratings for select to authenticated using(author_id=(select auth.uid()) or subject_id=(select auth.uid()) or public.is_admin());
create policy ratings_insert on public.ratings for insert to authenticated with check(author_id=(select auth.uid()) and exists(select 1 from public.rides r where r.id=ride_id and r.status='completed' and (select auth.uid()) in (r.customer_id,r.driver_id) and subject_id in (r.customer_id,r.driver_id)));
create policy notifications_self on public.notifications for select to authenticated using(user_id=(select auth.uid()));
create policy notifications_update on public.notifications for update to authenticated using(user_id=(select auth.uid())) with check(user_id=(select auth.uid()));

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values ('driver-documents','driver-documents',false,10485760,array['application/pdf','image/jpeg','image/png']) on conflict(id) do nothing;
create policy driver_document_upload on storage.objects for insert to authenticated with check(bucket_id='driver-documents' and (storage.foldername(name))[1]=(select auth.uid())::text);
create policy driver_document_read on storage.objects for select to authenticated using(bucket_id='driver-documents' and ((storage.foldername(name))[1]=(select auth.uid())::text or public.is_admin()));
create policy driver_document_update on storage.objects for update to authenticated using(bucket_id='driver-documents' and (storage.foldername(name))[1]=(select auth.uid())::text) with check(bucket_id='driver-documents' and (storage.foldername(name))[1]=(select auth.uid())::text);

grant select,update on public.profiles to authenticated;
grant select,update on public.driver_applications to authenticated;
grant select,insert,update,delete on public.vehicles to authenticated;
grant select,insert on public.driver_documents to authenticated;
grant select on public.driver_availability,public.rides,public.ride_tracking to authenticated;
grant select,insert,update,delete on public.fare_rules to authenticated;
grant select,insert on public.ratings to authenticated;
grant select,update on public.notifications to authenticated;
revoke execute on function public.request_ride(double precision,double precision,text,double precision,double precision,text,numeric,integer),public.set_driver_availability(boolean,double precision,double precision),public.accept_ride(uuid),public.transition_ride(uuid,public.ride_status),public.update_driver_location(double precision,double precision,uuid) from public, anon;
grant execute on function public.is_admin(),public.estimate_fare(numeric,integer),public.request_ride(double precision,double precision,text,double precision,double precision,text,numeric,integer),public.set_driver_availability(boolean,double precision,double precision),public.accept_ride(uuid),public.transition_ride(uuid,public.ride_status),public.update_driver_location(double precision,double precision,uuid) to authenticated;

insert into public.fare_rules(name,base_fare,per_km,per_minute,minimum_fare,booking_fee,active)
values ('Standard launch rate',12.00,8.50,1.20,35.00,3.00,true);

alter publication supabase_realtime add table public.rides, public.ride_tracking, public.notifications;
