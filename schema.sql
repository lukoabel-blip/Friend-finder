-- Friend Radar: Supabase schema. Paste into the SQL editor of a new Supabase project and run once.
-- Every table has row level security: people only ever see themselves and accepted friends.

create table public.profiles (
  id uuid primary key references auth.users on delete cascade,
  name text not null check (char_length(name) between 1 and 24),
  code text not null unique,
  created_at timestamptz not null default now()
);

create table public.friendships (
  id uuid primary key default gen_random_uuid(),
  requester uuid not null references public.profiles on delete cascade,
  addressee uuid not null references public.profiles on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted')),
  created_at timestamptz not null default now(),
  unique (requester, addressee),
  check (requester <> addressee)
);

create table public.locations (
  user_id uuid primary key references public.profiles on delete cascade,
  lat double precision not null,
  lng double precision not null,
  updated_at timestamptz not null default now()
);

create table public.places (
  user_id uuid not null references public.profiles on delete cascade,
  kind text not null check (kind in ('home','school','work')),
  lat double precision not null,
  lng double precision not null,
  primary key (user_id, kind)
);

create table public.waypoints (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null references public.profiles on delete cascade,
  title text not null check (char_length(title) between 1 and 40),
  kind text not null default 'Hang out',
  lat double precision not null,
  lng double precision not null,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create table public.waypoint_joins (
  waypoint_id uuid not null references public.waypoints on delete cascade,
  user_id uuid not null references public.profiles on delete cascade,
  primary key (waypoint_id, user_id)
);

-- Helpers (security definer so policies can consult friendships without recursion)
create function public.is_friend(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() in (a, b) and exists (select 1 from friendships
    where status = 'accepted' and ((requester = a and addressee = b) or (requester = b and addressee = a)));
$$;

create function public.is_linked(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() in (a, b) and exists (select 1 from friendships
    where (requester = a and addressee = b) or (requester = b and addressee = a));
$$;

-- New account -> profile with a random 8 character friend code
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, name, code)
  values (new.id,
          left(coalesce(nullif(trim(new.raw_user_meta_data->>'name'), ''), 'Player'), 24),
          upper(substr(md5(random()::text || new.id::text), 1, 8)));
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Friend requests go through functions so nobody can forge a friendship row
create function public.send_friend_request(friend_code text) returns void
language plpgsql security definer set search_path = public as $$
declare target uuid; me uuid := auth.uid();
begin
  if me is null then raise exception 'Sign in first.'; end if;
  select id into target from profiles where code = upper(trim(friend_code));
  if target is null then raise exception 'No one has that friend code.'; end if;
  if target = me then raise exception 'That is your own code.'; end if;
  -- they already asked you: accept instead
  update friendships set status = 'accepted' where requester = target and addressee = me;
  if found then return; end if;
  insert into friendships (requester, addressee) values (me, target) on conflict do nothing;
end $$;

create function public.accept_friend_request(request_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update friendships set status = 'accepted' where id = request_id and addressee = auth.uid();
  if not found then raise exception 'Request not found.'; end if;
end $$;

revoke execute on function public.send_friend_request(text), public.accept_friend_request(uuid) from anon, public;
grant execute on function public.send_friend_request(text), public.accept_friend_request(uuid) to authenticated;
revoke execute on function public.handle_new_user() from anon, authenticated, public;
revoke execute on function public.is_friend(uuid, uuid), public.is_linked(uuid, uuid) from anon, public;
grant execute on function public.is_friend(uuid, uuid), public.is_linked(uuid, uuid) to authenticated;

-- Row level security
alter table public.profiles       enable row level security;
alter table public.friendships    enable row level security;
alter table public.locations      enable row level security;
alter table public.places         enable row level security;
alter table public.waypoints      enable row level security;
alter table public.waypoint_joins enable row level security;

create policy "see self and linked people" on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_linked(id, auth.uid()));
create policy "rename self" on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

create policy "see own friendships" on public.friendships for select to authenticated
  using (requester = auth.uid() or addressee = auth.uid());
create policy "remove or decline" on public.friendships for delete to authenticated
  using (requester = auth.uid() or addressee = auth.uid());

create policy "see self and friends" on public.locations for select to authenticated
  using (user_id = auth.uid() or public.is_friend(user_id, auth.uid()));
create policy "share own location" on public.locations for insert to authenticated with check (user_id = auth.uid());
create policy "move own location"  on public.locations for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "hide own location"  on public.locations for delete to authenticated using (user_id = auth.uid());

create policy "own places only" on public.places for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "see own and friends' waypoints" on public.waypoints for select to authenticated
  using (owner = auth.uid() or public.is_friend(owner, auth.uid()));
create policy "post waypoint"   on public.waypoints for insert to authenticated with check (owner = auth.uid());
create policy "remove waypoint" on public.waypoints for delete to authenticated using (owner = auth.uid());

create policy "see joins on visible waypoints" on public.waypoint_joins for select to authenticated
  using (exists (select 1 from public.waypoints w where w.id = waypoint_id
                 and (w.owner = auth.uid() or public.is_friend(w.owner, auth.uid()))));
create policy "join a friend's waypoint" on public.waypoint_joins for insert to authenticated
  with check (user_id = auth.uid() and exists (select 1 from public.waypoints w where w.id = waypoint_id
              and (w.owner = auth.uid() or public.is_friend(w.owner, auth.uid()))));
create policy "leave waypoint" on public.waypoint_joins for delete to authenticated using (user_id = auth.uid());

-- Permanent markers: any number of homes, workplaces, schools and repeat meetup spots.
-- The app shares new markers with accepted friends by default; the owner can make any private.
-- (The older `places` table above is no longer used by the app.)
create table public.markers (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null references public.profiles on delete cascade,
  kind text not null check (kind in ('home','work','school','meetup')),
  name text not null check (char_length(name) between 1 and 30),
  lat double precision not null,
  lng double precision not null,
  shared boolean not null default false,
  created_at timestamptz not null default now()
);
create index markers_owner_idx on public.markers (owner);
alter table public.markers enable row level security;

create policy "see own markers and friends' shared ones" on public.markers for select to authenticated
  using (owner = auth.uid() or (shared and public.is_friend(owner, auth.uid())));
create policy "add marker"    on public.markers for insert to authenticated with check (owner = auth.uid());
create policy "edit marker"   on public.markers for update to authenticated using (owner = auth.uid()) with check (owner = auth.uid());
create policy "remove marker" on public.markers for delete to authenticated using (owner = auth.uid());
