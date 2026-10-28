-- MemoryNotes cloud copy: every device keeps its own SQLite database and syncs through these tables.
-- Times are milliseconds since 1970 (double precision), exactly as the apps store them.

create sequence public.sync_seq;

create table public.notes (
  id uuid primary key,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  kind text not null check (kind in ('app', 'url')),
  target text not null,
  label text not null default '',
  body_md text not null default '',
  created_at double precision not null,
  updated_at double precision not null,
  deleted_at double precision,
  seq bigint not null default nextval('public.sync_seq')  -- pull cursor: "everything after seq N"
);
create index notes_user_seq on public.notes (user_id, seq);

-- The calendar's history: a note as it was at the end of each local day it was edited.
create table public.snapshots (
  note_id uuid not null references public.notes (id) on delete cascade,
  day text not null,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  body_md text not null,
  updated_at double precision not null,
  seq bigint not null default nextval('public.sync_seq'),
  primary key (note_id, day)
);
create index snapshots_user_seq on public.snapshots (user_id, seq);

-- Last writer wins by updated_at, so a device that was offline can't overwrite newer text with older text.
-- Deletes are tombstones that stay deleted. Every accepted write gets a new seq for the pullers.
create function public.sync_accept() returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then
    new.user_id := old.user_id;
    if new.updated_at < old.updated_at then return old; end if;
    if tg_table_name = 'notes' and old.deleted_at is not null then
      new.deleted_at := old.deleted_at;
    end if;
  end if;
  new.seq := nextval('public.sync_seq');
  return new;
end $$;

create trigger notes_sync before insert or update on public.notes for each row execute function public.sync_accept();
create trigger snapshots_sync before insert or update on public.snapshots for each row execute function public.sync_accept();

alter table public.notes enable row level security;
alter table public.snapshots enable row level security;
create policy "own notes" on public.notes for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "own snapshots" on public.snapshots for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- Live updates for the other devices.
alter publication supabase_realtime add table public.notes;
