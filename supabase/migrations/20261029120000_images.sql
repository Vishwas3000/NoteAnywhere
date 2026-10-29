-- Pasted and dropped images (D53). The bytes live in the private "images" bucket at <user id>/<image id>, already
-- AES-GCM sealed with the account's vault key; this table tells other devices which images to fetch.

create table public.images (
  id uuid primary key,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  type text not null,  -- image/png, image/jpeg…: the format only, like a note's kind
  created_at double precision not null,
  seq bigint not null default nextval('public.sync_seq')
);
create index images_user_seq on public.images (user_id, seq);

-- Images never change, so only a new row needs a seq; on insert sync_accept does just that.
create trigger images_sync before insert on public.images for each row execute function public.sync_accept();

alter table public.images enable row level security;
create policy "own images" on public.images for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- Private bucket; 21 MiB fits the apps' 20 MiB cap plus the encryption overhead.
insert into storage.buckets (id, name, public, file_size_limit) values ('images', 'images', false, 22020096)
  on conflict (id) do nothing;

-- Each account reads and writes only its own folder. Uploads replace (x-upsert), so update too; nothing deletes.
create policy "own image files read" on storage.objects for select to authenticated
  using (bucket_id = 'images' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "own image files add" on storage.objects for insert to authenticated
  with check (bucket_id = 'images' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "own image files replace" on storage.objects for update to authenticated
  using (bucket_id = 'images' and (storage.foldername(name))[1] = (select auth.uid())::text)
  with check (bucket_id = 'images' and (storage.foldername(name))[1] = (select auth.uid())::text);
