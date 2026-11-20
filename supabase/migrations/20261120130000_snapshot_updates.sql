-- Snapshots have no deleted_at, and PL/pgSQL prepares an IF condition whole: "tg_table_name in (...) and
-- old.deleted_at is not null" failed on every snapshot update ("record old has no field deleted_at", HTTP 400), so a
-- day's snapshot reached the server once and never again (D79). The deletion check now runs only for tables with it.
create or replace function public.sync_accept() returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then
    new.user_id := old.user_id;
    if new.updated_at < old.updated_at then return old; end if;
    if tg_table_name in ('notes', 'folders') then
      if old.deleted_at is not null then new.deleted_at := old.deleted_at; end if;  -- deleted stays deleted
    end if;
  end if;
  new.seq := nextval('public.sync_seq');
  return new;
end $$;
