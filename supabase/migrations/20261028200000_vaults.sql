-- End-to-end encryption (D39): notes, places, titles, folder names and history arrive already encrypted with a
-- per-account vault key. The server keeps that key only wrapped by a key derived from the user's sync passphrase.

create table public.vaults (
  user_id uuid primary key default auth.uid() references auth.users (id) on delete cascade,
  salt text not null,      -- PBKDF2 salt for the passphrase, base64
  wrapped text not null,   -- AES-GCM(vault key) under the passphrase key, base64
  created_at timestamptz not null default now()
);

alter table public.vaults enable row level security;
create policy "own vault" on public.vaults for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
