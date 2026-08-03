-- Owner-authored, track-only music collections. Lists are independent of
-- queue, playback, Diary, reviews, and per-track status. Every child object's
-- visibility derives from its current, nondeleted parent list.

create function public.normalize_music_list_tags(p_tags text[])
returns text[]
language sql
immutable
set search_path = public
as $$
  select coalesce(array_agg(normalized_tag order by first_position), '{}'::text[])
  from (
    select lower(btrim(tag)) as normalized_tag, min(position) as first_position
    from unnest(coalesce(p_tags, '{}'::text[])) with ordinality supplied(tag, position)
    where tag is not null and btrim(tag) <> ''
    group by lower(btrim(tag))
  ) normalized;
$$;

create function public.music_list_tags_are_valid(p_tags text[])
returns boolean
language sql
immutable
set search_path = public
as $$
  select
    p_tags is not null
    and p_tags = public.normalize_music_list_tags(p_tags)
    and cardinality(p_tags) <= 10
    and coalesce(
      (select bool_and(char_length(tag) <= 30) from unnest(p_tags) tag),
      true
    );
$$;

create table public.music_lists (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  title text not null check (char_length(btrim(title)) between 1 and 120),
  description text not null default '' check (char_length(description) <= 5000),
  tags text[] not null default '{}',
  is_ranked boolean not null default false,
  visibility public.social_visibility not null default 'private',
  entries_revision bigint not null default 0 check (entries_revision >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint music_lists_tags_valid check (public.music_list_tags_are_valid(tags)),
  constraint music_lists_deleted_after_creation check (
    deleted_at is null or deleted_at >= created_at
  )
);

create table public.music_list_entries (
  id uuid primary key default gen_random_uuid(),
  list_id uuid not null references public.music_lists(id) on delete cascade,
  canonical_track_id uuid not null references public.canonical_tracks(id) on delete restrict,
  position integer not null check (position > 0),
  note text not null default '' check (char_length(note) <= 1000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint music_list_entries_track_unique unique (list_id, canonical_track_id),
  constraint music_list_entries_position_unique unique (list_id, position)
    deferrable initially immediate
);

create table public.music_list_likes (
  list_id uuid not null references public.music_lists(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (list_id, profile_id)
);

create table public.music_list_comments (
  id uuid primary key default gen_random_uuid(),
  list_id uuid not null references public.music_lists(id) on delete cascade,
  author_id uuid not null references public.profiles(id) on delete cascade,
  body text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint music_list_comments_body_valid check (
    (deleted_at is null and char_length(btrim(body)) between 1 and 2000)
    or (deleted_at is not null and body = '')
  ),
  constraint music_list_comments_deleted_after_creation check (
    deleted_at is null or deleted_at >= created_at
  )
);

create index music_lists_owner_page_idx
  on public.music_lists(owner_id, updated_at desc, id desc)
  where deleted_at is null;
create index music_lists_visible_page_idx
  on public.music_lists(visibility, updated_at desc, id desc)
  where deleted_at is null and visibility <> 'private';
create index music_list_entries_track_idx
  on public.music_list_entries(canonical_track_id, list_id);
create index music_list_likes_profile_page_idx
  on public.music_list_likes(profile_id, created_at desc, list_id);
create index music_list_comments_page_idx
  on public.music_list_comments(list_id, created_at desc, id desc)
  where deleted_at is null;

create trigger music_lists_updated_at
before update on public.music_lists
for each row execute function public.set_updated_at();
create trigger music_list_entries_updated_at
before update on public.music_list_entries
for each row execute function public.set_updated_at();
create trigger music_list_comments_updated_at
before update on public.music_list_comments
for each row execute function public.set_updated_at();

alter table public.music_lists enable row level security;
alter table public.music_list_entries enable row level security;
alter table public.music_list_likes enable row level security;
alter table public.music_list_comments enable row level security;

create function public.can_view_music_list(p_list_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null and exists (
    select 1
    from public.music_lists list
    where list.id = p_list_id
      and list.deleted_at is null
      and public.can_view_social(list.owner_id, list.visibility)
  );
$$;

create policy "view visible music lists"
on public.music_lists
for select to authenticated
using (
  deleted_at is null
  and public.can_view_social(owner_id, visibility)
);

create policy "view entries of visible music lists"
on public.music_list_entries
for select to authenticated
using (public.can_view_music_list(list_id));

create policy "view unblocked likes of visible music lists"
on public.music_list_likes
for select to authenticated
using (
  public.can_view_music_list(list_id)
  and not public.social_accounts_are_blocked(auth.uid(), profile_id)
);

create policy "view unblocked comments of visible music lists"
on public.music_list_comments
for select to authenticated
using (
  deleted_at is null
  and public.can_view_music_list(list_id)
  and not public.social_accounts_are_blocked(auth.uid(), author_id)
);

revoke insert, update, delete on
  public.music_lists,
  public.music_list_entries,
  public.music_list_likes,
  public.music_list_comments
from authenticated;
grant select on
  public.music_lists,
  public.music_list_entries,
  public.music_list_likes,
  public.music_list_comments
to authenticated;

create function public.create_music_list(
  p_title text,
  p_description text default '',
  p_tags text[] default '{}',
  p_is_ranked boolean default false,
  p_visibility public.social_visibility default 'private'
)
returns public.music_lists
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_title text := nullif(btrim(coalesce(p_title, '')), '');
  v_description text := btrim(coalesce(p_description, ''));
  v_tags text[] := public.normalize_music_list_tags(p_tags);
  v_list public.music_lists%rowtype;
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if v_title is null or char_length(v_title) > 120 then
    raise exception 'a list title between 1 and 120 characters is required'
      using errcode = '22023';
  end if;
  if char_length(v_description) > 5000 then
    raise exception 'a list description must not exceed 5000 characters'
      using errcode = '22023';
  end if;
  if cardinality(v_tags) > 10
    or exists (select 1 from unnest(v_tags) tag where char_length(tag) > 30)
  then
    raise exception 'lists support at most ten tags of thirty characters each'
      using errcode = '22023';
  end if;
  if p_is_ranked is null or p_visibility is null then
    raise exception 'ranked and visibility values are required' using errcode = '22004';
  end if;

  insert into public.music_lists(
    owner_id, title, description, tags, is_ranked, visibility
  ) values (
    v_actor_id, v_title, v_description, v_tags, p_is_ranked, p_visibility
  )
  returning * into v_list;
  return v_list;
end;
$$;

create function public.update_music_list(
  p_list_id uuid,
  p_title text,
  p_description text,
  p_tags text[],
  p_is_ranked boolean,
  p_visibility public.social_visibility
)
returns public.music_lists
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_title text := nullif(btrim(coalesce(p_title, '')), '');
  v_description text := btrim(coalesce(p_description, ''));
  v_tags text[] := public.normalize_music_list_tags(p_tags);
  v_list public.music_lists%rowtype;
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if v_title is null or char_length(v_title) > 120 then
    raise exception 'a list title between 1 and 120 characters is required'
      using errcode = '22023';
  end if;
  if char_length(v_description) > 5000 then
    raise exception 'a list description must not exceed 5000 characters'
      using errcode = '22023';
  end if;
  if cardinality(v_tags) > 10
    or exists (select 1 from unnest(v_tags) tag where char_length(tag) > 30)
  then
    raise exception 'lists support at most ten tags of thirty characters each'
      using errcode = '22023';
  end if;
  if p_is_ranked is null or p_visibility is null then
    raise exception 'ranked and visibility values are required' using errcode = '22004';
  end if;

  update public.music_lists
  set title = v_title,
      description = v_description,
      tags = v_tags,
      is_ranked = p_is_ranked,
      visibility = p_visibility
  where id = p_list_id
    and owner_id = v_actor_id
    and deleted_at is null
  returning * into v_list;
  if not found then
    raise exception 'music list not found' using errcode = 'P0002';
  end if;
  return v_list;
end;
$$;

-- Atomically save the complete editor draft. Required draft inputs come first
-- so an update can never omit p_entries and accidentally replace it with an
-- empty default. Named PostgREST callers are insensitive to declaration order.
create function public.save_music_list(
  p_title text,
  p_description text,
  p_tags text[],
  p_is_ranked boolean,
  p_visibility public.social_visibility,
  p_entries jsonb,
  p_list_id uuid default null,
  p_expected_revision bigint default null
)
returns public.music_lists
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_title text := nullif(btrim(coalesce(p_title, '')), '');
  v_description text := btrim(coalesce(p_description, ''));
  v_tags text[] := public.normalize_music_list_tags(p_tags);
  v_track_ids uuid[] := '{}'::uuid[];
  v_notes text[] := '{}'::text[];
  v_item jsonb;
  v_track_id uuid;
  v_note text;
  v_index integer;
  v_list public.music_lists%rowtype;
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if v_title is null or char_length(v_title) > 120 then
    raise exception 'a list title between 1 and 120 characters is required'
      using errcode = '22023';
  end if;
  if char_length(v_description) > 5000 then
    raise exception 'a list description must not exceed 5000 characters'
      using errcode = '22023';
  end if;
  if cardinality(v_tags) > 10
    or exists (select 1 from unnest(v_tags) tag where char_length(tag) > 30)
  then
    raise exception 'lists support at most ten tags of thirty characters each'
      using errcode = '22023';
  end if;
  if p_is_ranked is null or p_visibility is null then
    raise exception 'ranked and visibility values are required' using errcode = '22004';
  end if;
  if p_entries is null or jsonb_typeof(p_entries) <> 'array' then
    raise exception 'list entries must be a JSON array' using errcode = '22023';
  end if;
  if jsonb_array_length(p_entries) > 1000 then
    raise exception 'a music list may contain at most 1000 tracks' using errcode = '22023';
  end if;

  -- Parse and validate the entire draft before locking or writing its parent.
  for v_item in select value from jsonb_array_elements(p_entries)
  loop
    if jsonb_typeof(v_item) <> 'object'
      or not (v_item ? 'canonical_track_id')
      or not (v_item ? 'note')
      or (select count(*) from jsonb_object_keys(v_item)) <> 2
      or jsonb_typeof(v_item -> 'canonical_track_id') <> 'string'
      or jsonb_typeof(v_item -> 'note') <> 'string'
    then
      raise exception 'each list entry must contain only canonical_track_id and note strings'
        using errcode = '22023';
    end if;
    begin
      v_track_id := (v_item ->> 'canonical_track_id')::uuid;
    exception when invalid_text_representation then
      raise exception 'each list entry must contain a valid canonical track id'
        using errcode = '22023';
    end;
    v_note := btrim(v_item ->> 'note');
    if char_length(v_note) > 1000 then
      raise exception 'an entry note must not exceed 1000 characters'
        using errcode = '22023';
    end if;
    v_track_ids := array_append(v_track_ids, v_track_id);
    v_notes := array_append(v_notes, v_note);
  end loop;

  if cardinality(v_track_ids) <> (
    select count(distinct track_id) from unnest(v_track_ids) supplied(track_id)
  ) then
    raise exception 'a canonical track may appear only once in a music list'
      using errcode = '22023';
  end if;
  if cardinality(v_track_ids) <> (
    select count(*) from public.canonical_tracks where id = any(v_track_ids)
  ) then
    raise exception 'one or more canonical tracks were not found' using errcode = 'P0002';
  end if;

  if p_list_id is null then
    if p_expected_revision is not null then
      raise exception 'a new music list cannot have an expected revision'
        using errcode = '22023';
    end if;
    insert into public.music_lists(
      owner_id, title, description, tags, is_ranked, visibility
    ) values (
      v_actor_id, v_title, v_description, v_tags, p_is_ranked, p_visibility
    )
    returning * into v_list;

    if cardinality(v_track_ids) > 0 then
      for v_index in 1..cardinality(v_track_ids)
      loop
        insert into public.music_list_entries(
          list_id, canonical_track_id, position, note
        ) values (
          v_list.id, v_track_ids[v_index], v_index, v_notes[v_index]
        );
      end loop;
    end if;
    -- Revision zero is the authoritative initial snapshot, even when the
    -- snapshot contains entries. The first subsequent mutation must expect 0
    -- and advances it to 1.
    return v_list;
  end if;

  select * into v_list
  from public.music_lists
  where id = p_list_id and owner_id = v_actor_id and deleted_at is null
  for update;
  if not found then
    raise exception 'music list not found' using errcode = 'P0002';
  end if;
  if p_expected_revision is null or v_list.entries_revision <> p_expected_revision then
    raise exception 'music list entries changed; refresh and try again'
      using errcode = '40001', detail = 'music_list_revision_conflict';
  end if;

  set constraints music_list_entries_position_unique deferred;
  if cardinality(v_track_ids) = 0 then
    delete from public.music_list_entries where list_id = p_list_id;
  else
    delete from public.music_list_entries
    where list_id = p_list_id and not (canonical_track_id = any(v_track_ids));

    for v_index in 1..cardinality(v_track_ids)
    loop
      update public.music_list_entries
      set position = v_index,
          note = v_notes[v_index]
      where list_id = p_list_id
        and canonical_track_id = v_track_ids[v_index];
      if not found then
        insert into public.music_list_entries(
          list_id, canonical_track_id, position, note
        ) values (
          p_list_id, v_track_ids[v_index], v_index, v_notes[v_index]
        );
      end if;
    end loop;
  end if;

  update public.music_lists
  set title = v_title,
      description = v_description,
      tags = v_tags,
      is_ranked = p_is_ranked,
      visibility = p_visibility,
      entries_revision = entries_revision + 1,
      updated_at = now()
  where id = p_list_id
  returning * into v_list;
  return v_list;
end;
$$;

create function public.delete_music_list(p_list_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  update public.music_lists
  set deleted_at = now()
  where id = p_list_id
    and owner_id = auth.uid()
    and deleted_at is null;
  return found;
end;
$$;

create function public.add_music_list_entry(
  p_list_id uuid,
  p_canonical_track_id uuid,
  p_note text,
  p_expected_revision bigint
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_note text := btrim(coalesce(p_note, ''));
  v_list public.music_lists%rowtype;
  v_entry public.music_list_entries%rowtype;
  v_position integer;
  v_revision bigint;
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if char_length(v_note) > 1000 then
    raise exception 'an entry note must not exceed 1000 characters' using errcode = '22023';
  end if;

  select * into v_list
  from public.music_lists
  where id = p_list_id and owner_id = v_actor_id and deleted_at is null
  for update;
  if not found then
    raise exception 'music list not found' using errcode = 'P0002';
  end if;
  if p_expected_revision is null or v_list.entries_revision <> p_expected_revision then
    raise exception 'music list entries changed; refresh and try again'
      using errcode = '40001', detail = 'music_list_revision_conflict';
  end if;
  if not exists (
    select 1 from public.canonical_tracks where id = p_canonical_track_id
  ) then
    raise exception 'canonical track not found' using errcode = 'P0002';
  end if;
  if (select count(*) from public.music_list_entries where list_id = p_list_id) >= 1000 then
    raise exception 'a music list may contain at most 1000 tracks' using errcode = '22023';
  end if;

  select coalesce(max(position), 0) + 1 into v_position
  from public.music_list_entries
  where list_id = p_list_id;
  insert into public.music_list_entries(list_id, canonical_track_id, position, note)
  values (p_list_id, p_canonical_track_id, v_position, v_note)
  returning * into v_entry;

  update public.music_lists
  set entries_revision = entries_revision + 1,
      updated_at = now()
  where id = p_list_id
  returning entries_revision into v_revision;

  return jsonb_build_object(
    'entry', to_jsonb(v_entry),
    'entries_revision', v_revision
  );
end;
$$;

create function public.update_music_list_entry_note(
  p_entry_id uuid,
  p_note text,
  p_expected_revision bigint
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_note text := btrim(coalesce(p_note, ''));
  v_list_id uuid;
  v_list public.music_lists%rowtype;
  v_entry public.music_list_entries%rowtype;
  v_revision bigint;
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if char_length(v_note) > 1000 then
    raise exception 'an entry note must not exceed 1000 characters' using errcode = '22023';
  end if;

  select list_id into v_list_id from public.music_list_entries where id = p_entry_id;
  if not found then
    raise exception 'music list entry not found' using errcode = 'P0002';
  end if;
  select * into v_list
  from public.music_lists
  where id = v_list_id and owner_id = v_actor_id and deleted_at is null
  for update;
  if not found then
    raise exception 'music list entry not found' using errcode = 'P0002';
  end if;
  if p_expected_revision is null or v_list.entries_revision <> p_expected_revision then
    raise exception 'music list entries changed; refresh and try again'
      using errcode = '40001', detail = 'music_list_revision_conflict';
  end if;

  select * into v_entry
  from public.music_list_entries
  where id = p_entry_id and list_id = v_list_id;
  if not found then
    raise exception 'music list entry not found' using errcode = 'P0002';
  end if;

  update public.music_list_entries
  set note = v_note
  where id = p_entry_id and list_id = v_list_id
  returning * into v_entry;
  if not found then
    raise exception 'music list entry not found' using errcode = 'P0002';
  end if;

  update public.music_lists
  set entries_revision = entries_revision + 1,
      updated_at = now()
  where id = v_list_id
  returning entries_revision into v_revision;

  return jsonb_build_object(
    'entry', to_jsonb(v_entry),
    'entries_revision', v_revision
  );
end;
$$;

create function public.remove_music_list_entry(
  p_entry_id uuid,
  p_expected_revision bigint
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_list_id uuid;
  v_position integer;
  v_list public.music_lists%rowtype;
  v_revision bigint;
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  select list_id, position into v_list_id, v_position
  from public.music_list_entries where id = p_entry_id;
  if not found then
    raise exception 'music list entry not found' using errcode = 'P0002';
  end if;
  select * into v_list
  from public.music_lists
  where id = v_list_id and owner_id = v_actor_id and deleted_at is null
  for update;
  if not found then
    raise exception 'music list entry not found' using errcode = 'P0002';
  end if;
  if p_expected_revision is null or v_list.entries_revision <> p_expected_revision then
    raise exception 'music list entries changed; refresh and try again'
      using errcode = '40001', detail = 'music_list_revision_conflict';
  end if;

  select position into v_position
  from public.music_list_entries
  where id = p_entry_id and list_id = v_list_id;
  if not found then
    raise exception 'music list entry not found' using errcode = 'P0002';
  end if;

  set constraints music_list_entries_position_unique deferred;
  delete from public.music_list_entries
  where id = p_entry_id and list_id = v_list_id;
  if not found then
    raise exception 'music list entry not found' using errcode = 'P0002';
  end if;
  update public.music_list_entries
  set position = position - 1
  where list_id = v_list_id and position > v_position;

  update public.music_lists
  set entries_revision = entries_revision + 1,
      updated_at = now()
  where id = v_list_id
  returning entries_revision into v_revision;
  return v_revision;
end;
$$;

create function public.reorder_music_list_entries(
  p_list_id uuid,
  p_ordered_entry_ids uuid[],
  p_expected_revision bigint
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_list public.music_lists%rowtype;
  v_entry_count integer;
  v_revision bigint;
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  select * into v_list
  from public.music_lists
  where id = p_list_id and owner_id = v_actor_id and deleted_at is null
  for update;
  if not found then
    raise exception 'music list not found' using errcode = 'P0002';
  end if;
  if p_expected_revision is null or v_list.entries_revision <> p_expected_revision then
    raise exception 'music list entries changed; refresh and try again'
      using errcode = '40001', detail = 'music_list_revision_conflict';
  end if;

  select count(*) into v_entry_count
  from public.music_list_entries where list_id = p_list_id;
  if p_ordered_entry_ids is null
    or cardinality(p_ordered_entry_ids) <> v_entry_count
    or exists (
      select 1
      from unnest(p_ordered_entry_ids) supplied(entry_id)
      group by supplied.entry_id
      having count(*) > 1
    )
    or exists (
      select 1
      from unnest(p_ordered_entry_ids) supplied(entry_id)
      left join public.music_list_entries entry
        on entry.id = supplied.entry_id and entry.list_id = p_list_id
      where entry.id is null
    )
  then
    raise exception 'ordered entry ids must be an exact duplicate-free list permutation'
      using errcode = '22023';
  end if;

  set constraints music_list_entries_position_unique deferred;
  update public.music_list_entries entry
  set position = supplied.position::integer
  from unnest(p_ordered_entry_ids) with ordinality supplied(entry_id, position)
  where entry.id = supplied.entry_id and entry.list_id = p_list_id;

  update public.music_lists
  set entries_revision = entries_revision + 1,
      updated_at = now()
  where id = p_list_id
  returning entries_revision into v_revision;
  return v_revision;
end;
$$;

create function public.set_music_list_liked(
  p_list_id uuid,
  p_is_liked boolean
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_owner_id uuid;
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if p_is_liked is null then
    raise exception 'liked state is required' using errcode = '22004';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('music-list-like:' || p_list_id::text || ':' || v_actor_id::text, 0)
  );
  if not p_is_liked then
    delete from public.music_list_likes
    where list_id = p_list_id and profile_id = v_actor_id;
    return false;
  end if;

  select owner_id into v_owner_id
  from public.music_lists
  where id = p_list_id
    and deleted_at is null
    and public.can_view_social(owner_id, visibility)
  for key share;
  if not found then
    raise exception 'music list unavailable' using errcode = '42501';
  end if;
  insert into public.music_list_likes(list_id, profile_id)
  values (p_list_id, v_actor_id)
  on conflict (list_id, profile_id) do nothing;
  return true;
end;
$$;

create function public.add_music_list_comment(
  p_list_id uuid,
  p_body text
)
returns public.music_list_comments
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_body text := nullif(btrim(coalesce(p_body, '')), '');
  v_owner_id uuid;
  v_comment public.music_list_comments%rowtype;
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if v_body is null or char_length(v_body) > 2000 then
    raise exception 'a comment between 1 and 2000 characters is required'
      using errcode = '22023';
  end if;
  select owner_id into v_owner_id
  from public.music_lists
  where id = p_list_id
    and deleted_at is null
    and public.can_view_social(owner_id, visibility)
  for key share;
  if not found then
    raise exception 'music list unavailable' using errcode = '42501';
  end if;
  insert into public.music_list_comments(list_id, author_id, body)
  values (p_list_id, v_actor_id, v_body)
  returning * into v_comment;
  return v_comment;
end;
$$;

create function public.delete_music_list_comment(p_comment_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  update public.music_list_comments comment
  set body = '', deleted_at = now()
  from public.music_lists list
  where comment.id = p_comment_id
    and comment.list_id = list.id
    and comment.deleted_at is null
    and (comment.author_id = v_actor_id or list.owner_id = v_actor_id);
  return found;
end;
$$;

create function public.list_profile_music_lists(
  p_profile_id uuid,
  p_before_updated_at timestamptz default null,
  p_before_id uuid default null,
  p_limit integer default 50
)
returns setof public.music_lists
language plpgsql
stable
security invoker
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if p_profile_id is null then
    raise exception 'profile id is required' using errcode = '22004';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'profile list page size must be between 1 and 100'
      using errcode = '22023';
  end if;
  if (p_before_updated_at is null) <> (p_before_id is null) then
    raise exception 'profile list cursor timestamp and id must be provided together'
      using errcode = '22023';
  end if;

  return query
  select list.*
  from public.music_lists list
  where list.owner_id = p_profile_id
    and list.deleted_at is null
    and public.can_view_social(list.owner_id, list.visibility)
    and (
      p_before_updated_at is null
      or list.updated_at < p_before_updated_at
      or (list.updated_at = p_before_updated_at and list.id < p_before_id)
    )
  order by list.updated_at desc, list.id desc
  limit p_limit;
end;
$$;

create function public.get_music_list(p_list_id uuid)
returns public.music_lists
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_list public.music_lists%rowtype;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  select * into v_list
  from public.music_lists
  where id = p_list_id and deleted_at is null;
  if not found then
    raise exception 'music list unavailable' using errcode = '42501';
  end if;
  return v_list;
end;
$$;

create function public.list_music_list_entries(
  p_list_id uuid,
  p_after_position integer default null,
  p_limit integer default 100
)
returns setof public.music_list_entries
language plpgsql
stable
security invoker
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'list entry page size must be between 1 and 100'
      using errcode = '22023';
  end if;
  if p_after_position is not null and p_after_position < 0 then
    raise exception 'entry cursor position cannot be negative' using errcode = '22023';
  end if;
  if not public.can_view_music_list(p_list_id) then
    raise exception 'music list unavailable' using errcode = '42501';
  end if;

  return query
  select entry.*
  from public.music_list_entries entry
  where entry.list_id = p_list_id
    and (p_after_position is null or entry.position > p_after_position)
  order by entry.position asc
  limit p_limit;
end;
$$;

create function public.list_music_list_comments(
  p_list_id uuid,
  p_before_created_at timestamptz default null,
  p_before_id uuid default null,
  p_limit integer default 50
)
returns setof public.music_list_comments
language plpgsql
stable
security invoker
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'list comment page size must be between 1 and 100'
      using errcode = '22023';
  end if;
  if (p_before_created_at is null) <> (p_before_id is null) then
    raise exception 'comment cursor timestamp and id must be provided together'
      using errcode = '22023';
  end if;
  if not public.can_view_music_list(p_list_id) then
    raise exception 'music list unavailable' using errcode = '42501';
  end if;

  return query
  select comment.*
  from public.music_list_comments comment
  where comment.list_id = p_list_id
    and comment.deleted_at is null
    and not public.social_accounts_are_blocked(auth.uid(), comment.author_id)
    and (
      p_before_created_at is null
      or comment.created_at < p_before_created_at
      or (comment.created_at = p_before_created_at and comment.id < p_before_id)
    )
  order by comment.created_at desc, comment.id desc
  limit p_limit;
end;
$$;

create function public.get_music_list_engagement(p_list_id uuid)
returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if not public.can_view_music_list(p_list_id) then
    raise exception 'music list unavailable' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'entry_count', (
      select count(*) from public.music_list_entries entry
      where entry.list_id = p_list_id
    ),
    'like_count', (
      select count(*) from public.music_list_likes liked
      where liked.list_id = p_list_id
    ),
    'comment_count', (
      select count(*) from public.music_list_comments comment
      where comment.list_id = p_list_id and comment.deleted_at is null
    ),
    'viewer_has_liked', exists (
      select 1 from public.music_list_likes liked
      where liked.list_id = p_list_id and liked.profile_id = auth.uid()
    )
  );
end;
$$;

-- A list enters following Activity once, on its first nonprivate publication.
-- PostgreSQL forbids safely using an ALTER TYPE ADD VALUE enum value elsewhere
-- in the same migration transaction. Convert the event discriminator to
-- constrained text; existing Swift/PostgREST contracts already decode strings.
drop policy "view current followed social activity" on public.social_activity_events;
alter table public.social_activity_events
  drop constraint if exists social_activity_events_check;
alter table public.social_activity_events
  alter column kind type text using kind::text;
alter table public.social_activity_events
  add column list_id uuid;
alter table public.social_activity_events
  add constraint social_activity_events_kind_valid check (
    kind in ('diary_logged', 'review_published', 'list_published')
  ),
  add constraint social_activity_events_object_shape check (
    (kind = 'diary_logged' and diary_entry_id is not null and review_id is null and list_id is null)
    or
    (kind = 'review_published' and review_id is not null and diary_entry_id is null and list_id is null)
    or
    (kind = 'list_published' and list_id is not null and diary_entry_id is null and review_id is null)
  );

create unique index social_activity_list_object_unique
  on public.social_activity_events(list_id)
  where list_id is not null;

create policy "view current followed social activity"
on public.social_activity_events
for select to authenticated
using (
  not public.social_accounts_are_blocked(auth.uid(), actor_id)
  and (
    actor_id = auth.uid()
    or exists (
      select 1 from public.social_follows follow
      where follow.follower_id = auth.uid()
        and follow.followed_id = actor_id
        and follow.state = 'accepted'
    )
  )
  and (
    (
      kind = 'diary_logged'
      and exists (
        select 1 from public.listening_history_entries entry
        where entry.id = diary_entry_id
          and entry.profile_id = actor_id
          and entry.source = 'manual'
          and entry.visibility = 'followers'
      )
    )
    or
    (
      kind = 'review_published'
      and exists (
        select 1 from public.music_reviews review
        where review.id = review_id
          and review.profile_id = actor_id
          and review.deleted_at is null
          and review.visibility = 'followers'
      )
    )
    or
    (
      kind = 'list_published'
      and exists (
        select 1 from public.music_lists list
        where list.id = list_id
          and list.owner_id = actor_id
          and list.deleted_at is null
          and list.visibility <> 'private'
          and public.can_view_social(list.owner_id, list.visibility)
      )
    )
  )
);

create function public.emit_music_list_social_activity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.deleted_at is null
    and new.visibility <> 'private'
    and (
      tg_op = 'INSERT'
      or (tg_op = 'UPDATE' and old.visibility = 'private')
    )
  then
    insert into public.social_activity_events(actor_id, kind, list_id)
    values (new.owner_id, 'list_published', new.id)
    on conflict (list_id) where list_id is not null do nothing;
  end if;
  return new;
end;
$$;

create trigger music_lists_emit_social_activity_insert
after insert on public.music_lists
for each row execute function public.emit_music_list_social_activity();
create trigger music_lists_emit_social_activity_visibility
after update of visibility on public.music_lists
for each row execute function public.emit_music_list_social_activity();

-- Engagement notifications reuse the existing recipient-only inbox.
alter table public.social_notifications
  add column music_list_id uuid references public.music_lists(id) on delete cascade,
  add column music_list_comment_id uuid references public.music_list_comments(id) on delete cascade;
alter table public.social_notifications
  drop constraint if exists social_notifications_kind_check;
alter table public.social_notifications
  add constraint social_notifications_kind_check check (
    kind in (
      'follow_request', 'follow_accepted', 'review_comment', 'review_reaction',
      'music_list_like', 'music_list_comment'
    )
  ),
  add constraint social_notifications_object_shape check (
    (kind in ('follow_request', 'follow_accepted')
      and review_id is null and music_list_id is null and music_list_comment_id is null)
    or
    (kind in ('review_comment', 'review_reaction')
      and review_id is not null and music_list_id is null and music_list_comment_id is null)
    or
    (kind = 'music_list_like'
      and review_id is null and music_list_id is not null and music_list_comment_id is null)
    or
    (kind = 'music_list_comment'
      and review_id is null and music_list_id is not null and music_list_comment_id is not null)
  );

create unique index social_notifications_music_list_like_unique
  on public.social_notifications(recipient_id, actor_id, music_list_id)
  where kind = 'music_list_like';
create unique index social_notifications_music_list_comment_unique
  on public.social_notifications(music_list_comment_id)
  where kind = 'music_list_comment';

create function public.notify_music_list_like()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner_id uuid;
begin
  select owner_id into v_owner_id
  from public.music_lists
  where id = new.list_id and deleted_at is null;
  if v_owner_id is not null and v_owner_id <> new.profile_id then
    insert into public.social_notifications(
      recipient_id, actor_id, kind, music_list_id
    ) values (
      v_owner_id, new.profile_id, 'music_list_like', new.list_id
    )
    on conflict (recipient_id, actor_id, music_list_id)
      where kind = 'music_list_like'
      do nothing;
  end if;
  return new;
end;
$$;

create trigger music_list_likes_notify
after insert on public.music_list_likes
for each row execute function public.notify_music_list_like();

create function public.notify_music_list_comment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner_id uuid;
begin
  select owner_id into v_owner_id
  from public.music_lists
  where id = new.list_id and deleted_at is null;
  if v_owner_id is not null and v_owner_id <> new.author_id then
    insert into public.social_notifications(
      recipient_id, actor_id, kind, music_list_id, music_list_comment_id
    ) values (
      v_owner_id, new.author_id, 'music_list_comment', new.list_id, new.id
    )
    on conflict (music_list_comment_id)
      where kind = 'music_list_comment'
      do nothing;
  end if;
  return new;
end;
$$;

create trigger music_list_comments_notify
after insert on public.music_list_comments
for each row execute function public.notify_music_list_comment();

do $$
declare
  v_table_name text;
begin
  foreach v_table_name in array array[
    'music_lists', 'music_list_entries', 'music_list_likes', 'music_list_comments'
  ] loop
    if not exists (
      select 1
      from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = v_table_name
    ) then
      execute format('alter publication supabase_realtime add table public.%I', v_table_name);
    end if;
  end loop;
end;
$$;

revoke all on function public.normalize_music_list_tags(text[]) from public;
revoke all on function public.music_list_tags_are_valid(text[]) from public;
revoke all on function public.can_view_music_list(uuid) from public;
revoke all on function public.emit_music_list_social_activity() from public;
revoke all on function public.notify_music_list_like() from public;
revoke all on function public.notify_music_list_comment() from public;
revoke all on function public.create_music_list(text, text, text[], boolean, public.social_visibility) from public;
revoke all on function public.update_music_list(uuid, text, text, text[], boolean, public.social_visibility) from public;
revoke all on function public.save_music_list(text, text, text[], boolean, public.social_visibility, jsonb, uuid, bigint) from public;
revoke all on function public.delete_music_list(uuid) from public;
revoke all on function public.add_music_list_entry(uuid, uuid, text, bigint) from public;
revoke all on function public.update_music_list_entry_note(uuid, text, bigint) from public;
revoke all on function public.remove_music_list_entry(uuid, bigint) from public;
revoke all on function public.reorder_music_list_entries(uuid, uuid[], bigint) from public;
revoke all on function public.set_music_list_liked(uuid, boolean) from public;
revoke all on function public.add_music_list_comment(uuid, text) from public;
revoke all on function public.delete_music_list_comment(uuid) from public;
revoke all on function public.list_profile_music_lists(uuid, timestamptz, uuid, integer) from public;
revoke all on function public.get_music_list(uuid) from public;
revoke all on function public.list_music_list_entries(uuid, integer, integer) from public;
revoke all on function public.list_music_list_comments(uuid, timestamptz, uuid, integer) from public;
revoke all on function public.get_music_list_engagement(uuid) from public;

grant execute on function public.can_view_music_list(uuid) to authenticated;
grant execute on function public.create_music_list(text, text, text[], boolean, public.social_visibility) to authenticated;
grant execute on function public.update_music_list(uuid, text, text, text[], boolean, public.social_visibility) to authenticated;
grant execute on function public.save_music_list(text, text, text[], boolean, public.social_visibility, jsonb, uuid, bigint) to authenticated;
grant execute on function public.delete_music_list(uuid) to authenticated;
grant execute on function public.add_music_list_entry(uuid, uuid, text, bigint) to authenticated;
grant execute on function public.update_music_list_entry_note(uuid, text, bigint) to authenticated;
grant execute on function public.remove_music_list_entry(uuid, bigint) to authenticated;
grant execute on function public.reorder_music_list_entries(uuid, uuid[], bigint) to authenticated;
grant execute on function public.set_music_list_liked(uuid, boolean) to authenticated;
grant execute on function public.add_music_list_comment(uuid, text) to authenticated;
grant execute on function public.delete_music_list_comment(uuid) to authenticated;
grant execute on function public.list_profile_music_lists(uuid, timestamptz, uuid, integer) to authenticated;
grant execute on function public.get_music_list(uuid) to authenticated;
grant execute on function public.list_music_list_entries(uuid, integer, integer) to authenticated;
grant execute on function public.list_music_list_comments(uuid, timestamptz, uuid, integer) to authenticated;
grant execute on function public.get_music_list_engagement(uuid) to authenticated;
