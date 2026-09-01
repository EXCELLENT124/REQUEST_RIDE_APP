create index if not exists rides_cancelled_by_idx
  on public.rides(cancelled_by)
  where cancelled_by is not null;
