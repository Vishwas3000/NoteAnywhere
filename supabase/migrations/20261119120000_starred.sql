-- Starred notes (D73): a filter, unlike pinned which sorts to the top. Older apps don't send it, and an upsert
-- leaves columns it doesn't name alone, so their edits keep the star.
alter table public.notes add column starred boolean not null default false;
