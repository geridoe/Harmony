do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'profiles',
    'social_follows',
    'profile_blocks',
    'listening_presence',
    'listening_history_entries',
    'music_reviews',
    'review_comments',
    'review_reactions'
  ] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = table_name
    ) then
      execute format('alter publication supabase_realtime add table public.%I', table_name);
    end if;
  end loop;
end;
$$;
