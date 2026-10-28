-- Pins, colour labels, locked (encrypted) notes and folders, synced like notes (D37).

alter table public.notes
  add column pinned boolean not null default false,
  add column folder_id uuid,  -- no foreign key: a note may arrive before its folder
  add column color text,
  add column locked boolean not null default false;  -- body_md then holds an encrypted envelope

create table public.folders (
  id uuid primary key,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name text not null,
  updated_at double precision not null,
  deleted_at double precision,
  seq bigint not null default nextval('public.sync_seq')
);
create index folders_user_seq on public.folders (user_id, seq);

-- Same newer-wins rule; deleted folders stay deleted too.
create or replace function public.sync_accept() returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then
    new.user_id := old.user_id;
    if new.updated_at < old.updated_at then return old; end if;
    if tg_table_name in ('notes', 'folders') and old.deleted_at is not null then
      new.deleted_at := old.deleted_at;
    end if;
  end if;
  new.seq := nextval('public.sync_seq');
  return new;
end $$;

create trigger folders_sync before insert or update on public.folders for each row execute function public.sync_accept();

alter table public.folders enable row level security;
create policy "own folders" on public.folders for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

alter publication supabase_realtime add table public.folders;
