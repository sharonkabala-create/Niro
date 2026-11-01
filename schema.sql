-- =====================================================================
--  Niro · מסד הנתונים (גרסה 1)
--  להדביק את כל הקובץ ב-Supabase → SQL Editor → New query → Run
--  אפשר להריץ שוב בבטחה: הקובץ יוצר רק מה שעוד לא קיים ומעדכן פונקציות.
-- =====================================================================

-- ---------- מרחק במטרים בין שתי נקודות (נוסחת Haversine) ----------
create or replace function public.dist_m(lat1 double precision, lng1 double precision,
                                         lat2 double precision, lng2 double precision)
returns double precision language sql immutable as $$
  select 2 * 6371000 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)))
$$;

-- ---------- טבלאות ----------
create table if not exists public.profiles (
  id         uuid primary key references auth.users on delete cascade,
  name       text not null check (char_length(name) between 1 and 30),
  bio        text not null default '' check (char_length(bio) <= 80),
  photo_url  text,
  updated_at timestamptz not null default now()
);

-- המיקום של כל משתמש. אף אחד לא יכול לקרוא את הטבלה הזו ישירות, רק דרך הפונקציות.
create table if not exists public.presence (
  user_id   uuid primary key references auth.users on delete cascade,
  lat       double precision not null,
  lng       double precision not null,
  radius    int not null default 150 check (radius between 50 and 250),
  last_seen timestamptz not null default now()
);
create index if not exists presence_lat_lng on public.presence (lat, lng);

create table if not exists public.blocks (
  blocker    uuid references auth.users on delete cascade,
  blocked    uuid references auth.users on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker, blocked)
);

create table if not exists public.reports (
  id         bigint generated always as identity primary key,
  reporter   uuid references auth.users on delete set null,
  reported   uuid,
  reason     text check (char_length(reason) <= 500),
  created_at timestamptz not null default now()
);

create table if not exists public.square_messages (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users on delete cascade,
  lat        double precision not null,
  lng        double precision not null,
  body       text check (char_length(body) <= 1000),
  image_url  text,
  created_at timestamptz not null default now(),
  check (body is not null or image_url is not null)
);
create index if not exists square_time on public.square_messages (created_at);

create table if not exists public.chats (
  id            bigint generated always as identity primary key,
  requester     uuid not null references auth.users on delete cascade,
  recipient     uuid not null references auth.users on delete cascade,
  status        text not null default 'pending' check (status in ('pending','active','declined','closed')),
  radius        int not null,
  closed_reason text,
  created_at    timestamptz not null default now()
);

create table if not exists public.private_messages (
  id         bigint generated always as identity primary key,
  chat_id    bigint not null references public.chats on delete cascade,
  sender     uuid not null references auth.users on delete cascade,
  body       text check (char_length(body) <= 1000),
  image_url  text,
  created_at timestamptz not null default now(),
  check (body is not null or image_url is not null)
);
create index if not exists private_by_chat on public.private_messages (chat_id, id);

create table if not exists public.groups (
  id          bigint generated always as identity primary key,
  name        text not null check (char_length(name) between 1 and 40),
  kind        text not null check (kind in ('cafe','shop','building','other')),
  lat         double precision not null,
  lng         double precision not null,
  radius      int not null default 150,
  created_by  uuid references auth.users on delete set null,
  created_at  timestamptz not null default now(),
  last_active timestamptz not null default now()
);

create table if not exists public.group_members (
  group_id  bigint references public.groups on delete cascade,
  user_id   uuid references auth.users on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);

create table if not exists public.group_messages (
  id         bigint generated always as identity primary key,
  group_id   bigint not null references public.groups on delete cascade,
  user_id    uuid not null references auth.users on delete cascade,
  body       text check (char_length(body) <= 1000),
  image_url  text,
  created_at timestamptz not null default now(),
  check (body is not null or image_url is not null)
);
create index if not exists group_msgs_by_group on public.group_messages (group_id, id);

-- ---------- הרשאות: כל הטבלאות נעולות, גישה רק דרך הפונקציות ----------
alter table public.profiles         enable row level security;
alter table public.presence         enable row level security;
alter table public.blocks           enable row level security;
alter table public.reports          enable row level security;
alter table public.square_messages  enable row level security;
alter table public.chats            enable row level security;
alter table public.private_messages enable row level security;
alter table public.groups           enable row level security;
alter table public.group_members    enable row level security;
alter table public.group_messages   enable row level security;

drop policy if exists "profiles readable" on public.profiles;
create policy "profiles readable" on public.profiles for select to authenticated using (true);
drop policy if exists "profile insert own" on public.profiles;
create policy "profile insert own" on public.profiles for insert to authenticated with check (id = auth.uid());
drop policy if exists "profile update own" on public.profiles;
create policy "profile update own" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- ---------- פונקציות עזר פנימיות ----------
create or replace function public._is_blocked(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from blocks where (blocker = a and blocked = b) or (blocker = b and blocked = a))
$$;

create or replace function public._fresh(ts timestamptz) returns boolean
language sql stable as $$ select ts > now() - interval '5 minutes' $$;

-- נועל שיחות שאחד הצדדים התרחק בהן, ומוחק את ההודעות שלהן
create or replace function public._sweep_chats(uid uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  with gone as (
    update chats c set status = 'closed', closed_reason = 'left'
    where (c.requester = uid or c.recipient = uid)
      and c.status in ('pending','active')
      and not exists (
        select 1 from presence a, presence b
        where a.user_id = c.requester and b.user_id = c.recipient
          and _fresh(a.last_seen) and _fresh(b.last_seen)
          and dist_m(a.lat, a.lng, b.lat, b.lng) <= c.radius)
    returning c.id)
  delete from private_messages m using gone where m.chat_id = gone.id;

  delete from chats where status in ('closed','declined') and created_at < now() - interval '6 hours';
end $$;

-- ---------- מיקום ----------
create or replace function public.update_presence(p_lat double precision, p_lng double precision, p_radius int)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  if p_lat not between -90 and 90 or p_lng not between -180 and 180 then raise exception 'bad_location'; end if;
  insert into presence (user_id, lat, lng, radius, last_seen)
  values (auth.uid(), p_lat, p_lng, greatest(50, least(250, coalesce(p_radius,150))), now())
  on conflict (user_id) do update
    set lat = excluded.lat, lng = excluded.lng, radius = excluded.radius, last_seen = now();
  delete from presence where last_seen < now() - interval '1 day';
end $$;

create or replace function public.go_offline() returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from presence where user_id = auth.uid();
  perform _sweep_chats(auth.uid());
  delete from group_members where user_id = auth.uid();
end $$;

-- ---------- מי בסביבה ----------
-- מחזיר מרחק מעוגל ל-10 מטר בלבד. מיקום מדויק לא יוצא מהשרת.
create or replace function public.nearby_people()
returns table (id uuid, name text, bio text, photo_url text, distance int, in_range boolean)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare me presence;
begin
  select * into me from presence where user_id = auth.uid() and _fresh(last_seen);
  if not found then return; end if;
  return query
    select p.id, p.name, p.bio, p.photo_url,
           (round(d.m / 10) * 10)::int,
           d.m <= me.radius
    from presence pr
    cross join lateral (select dist_m(me.lat, me.lng, pr.lat, pr.lng) as m) d
    join profiles p on p.id = pr.user_id
    where pr.user_id <> auth.uid()
      and _fresh(pr.last_seen)
      and pr.lat between me.lat - 0.0046 and me.lat + 0.0046   -- ~500 מטר
      and d.m <= me.radius * 2
      and not _is_blocked(auth.uid(), pr.user_id)
    order by d.m
    limit 100;
end $$;

-- ---------- הכיכר ----------
create or replace function public.post_square(p_body text, p_image text default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare me presence; new_id bigint;
begin
  select * into me from presence where user_id = auth.uid() and _fresh(last_seen);
  if not found then raise exception 'not_present'; end if;
  insert into square_messages (user_id, lat, lng, body, image_url)
  values (auth.uid(), me.lat, me.lng, nullif(trim(p_body), ''), p_image)
  returning id into new_id;
  delete from square_messages where created_at < now() - interval '24 hours';
  return new_id;
end $$;

create or replace function public.get_square(p_after bigint default 0)
returns table (id bigint, user_id uuid, name text, photo_url text, body text, image_url text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare me presence;
begin
  select * into me from presence where user_id = auth.uid() and _fresh(last_seen);
  if not found then return; end if;
  return query
    select m.id, m.user_id, p.name, p.photo_url, m.body, m.image_url, m.created_at
    from square_messages m join profiles p on p.id = m.user_id
    where m.id > coalesce(p_after, 0)
      and m.created_at > now() - interval '6 hours'
      and dist_m(me.lat, me.lng, m.lat, m.lng) <= me.radius
      and not _is_blocked(auth.uid(), m.user_id)
    order by m.id
    limit 200;
end $$;

-- ---------- שיחות פרטיות ----------
create or replace function public.request_chat(p_target uuid)
returns bigint language plpgsql security definer set search_path = public as $$
declare me presence; them presence; new_id bigint;
begin
  select * into me from presence where user_id = auth.uid() and _fresh(last_seen);
  if not found then raise exception 'not_present'; end if;
  select * into them from presence where user_id = p_target and _fresh(last_seen);
  if not found or dist_m(me.lat, me.lng, them.lat, them.lng) > me.radius then raise exception 'out_of_range'; end if;
  if _is_blocked(auth.uid(), p_target) then raise exception 'blocked'; end if;
  if exists (select 1 from chats
             where status in ('pending','active')
               and ((requester = auth.uid() and recipient = p_target) or (requester = p_target and recipient = auth.uid())))
  then raise exception 'already_open'; end if;
  delete from chats where status in ('declined','closed')
    and ((requester = auth.uid() and recipient = p_target) or (requester = p_target and recipient = auth.uid()));
  insert into chats (requester, recipient, radius) values (auth.uid(), p_target, me.radius) returning id into new_id;
  return new_id;
end $$;

create or replace function public.respond_chat(p_chat bigint, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _sweep_chats(auth.uid());
  update chats set status = case when p_accept then 'active' else 'declined' end
  where id = p_chat and recipient = auth.uid() and status = 'pending';
  if not found then raise exception 'not_pending'; end if;
end $$;

create or replace function public.my_chats()
returns table (id bigint, other_id uuid, other_name text, other_photo text, status text, i_requested boolean,
               distance int, closed_reason text, last_id bigint, last_body text, last_image boolean, last_sender uuid)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
begin
  if auth.uid() is null then return; end if;
  perform _sweep_chats(auth.uid());
  return query
    select c.id, o.id, o.name, o.photo_url, c.status, c.requester = auth.uid(),
           case when _fresh(a.last_seen) and _fresh(b.last_seen)
                then (round(dist_m(a.lat, a.lng, b.lat, b.lng) / 10) * 10)::int end,
           c.closed_reason, lm.id, lm.body, lm.image_url is not null, lm.sender
    from chats c
    join profiles o on o.id = case when c.requester = auth.uid() then c.recipient else c.requester end
    left join presence a on a.user_id = c.requester
    left join presence b on b.user_id = c.recipient
    left join lateral (select pm.id, pm.body, pm.image_url, pm.sender from private_messages pm
                       where pm.chat_id = c.id order by pm.id desc limit 1) lm on true
    where (c.requester = auth.uid() or c.recipient = auth.uid())
      -- בקשה שנדחתה לא מוצגת למי שדחה אותה
      and not (c.status = 'declined' and c.recipient = auth.uid())
    order by c.created_at desc;
end $$;

create or replace function public.send_private(p_chat bigint, p_body text, p_image text default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare new_id bigint;
begin
  perform _sweep_chats(auth.uid());
  if not exists (select 1 from chats where id = p_chat and status = 'active'
                 and (requester = auth.uid() or recipient = auth.uid())) then
    raise exception 'chat_locked';
  end if;
  insert into private_messages (chat_id, sender, body, image_url)
  values (p_chat, auth.uid(), nullif(trim(p_body), ''), p_image) returning id into new_id;
  return new_id;
end $$;

create or replace function public.get_private(p_chat bigint, p_after bigint default 0)
returns table (id bigint, sender uuid, body text, image_url text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not exists (select 1 from chats where id = p_chat and (requester = auth.uid() or recipient = auth.uid())) then return; end if;
  return query
    select m.id, m.sender, m.body, m.image_url, m.created_at
    from private_messages m where m.chat_id = p_chat and m.id > coalesce(p_after, 0)
    order by m.id limit 500;
end $$;

-- סוגר שיחה (לכל צד) ומוחק אותה ואת ההודעות שלה
create or replace function public.dismiss_chat(p_chat bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from chats where id = p_chat and (requester = auth.uid() or recipient = auth.uid());
end $$;

-- ---------- קבוצות לפי מקום ----------
create or replace function public.create_group(p_name text, p_kind text)
returns bigint language plpgsql security definer set search_path = public as $$
declare me presence; new_id bigint;
begin
  select * into me from presence where user_id = auth.uid() and _fresh(last_seen);
  if not found then raise exception 'not_present'; end if;
  insert into groups (name, kind, lat, lng, created_by)
  values (trim(p_name), coalesce(p_kind,'other'), me.lat, me.lng, auth.uid()) returning id into new_id;
  insert into group_members (group_id, user_id) values (new_id, auth.uid());
  return new_id;
end $$;

create or replace function public.nearby_groups()
returns table (id bigint, name text, kind text, distance int, members_here int, joined boolean, can_join boolean, last_id bigint)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare me presence;
begin
  select * into me from presence where user_id = auth.uid() and _fresh(last_seen);
  if not found then
    delete from group_members where user_id = auth.uid();
    return;
  end if;
  -- מי שהתרחק מהמקום יוצא מהקבוצה
  delete from group_members gm using groups g
  where gm.group_id = g.id and gm.user_id = auth.uid()
    and dist_m(me.lat, me.lng, g.lat, g.lng) > g.radius;

  return query
    select g.id, g.name, g.kind,
           (round(dist_m(me.lat, me.lng, g.lat, g.lng) / 10) * 10)::int,
           (select count(*)::int from group_members gm join presence pr on pr.user_id = gm.user_id
              where gm.group_id = g.id and _fresh(pr.last_seen)
                and dist_m(pr.lat, pr.lng, g.lat, g.lng) <= g.radius),
           exists (select 1 from group_members gm where gm.group_id = g.id and gm.user_id = auth.uid()),
           dist_m(me.lat, me.lng, g.lat, g.lng) <= g.radius,
           (select max(m.id) from group_messages m where m.group_id = g.id)
    from groups g
    where g.last_active > now() - interval '7 days'
      and g.lat between me.lat - 0.0046 and me.lat + 0.0046
      and dist_m(me.lat, me.lng, g.lat, g.lng) <= greatest(me.radius, g.radius)
    order by 6 desc, 4
    limit 50;
end $$;

create or replace function public.join_group(p_group bigint)
returns void language plpgsql security definer set search_path = public as $$
declare me presence;
begin
  select * into me from presence where user_id = auth.uid() and _fresh(last_seen);
  if not found then raise exception 'not_present'; end if;
  if not exists (select 1 from groups g where g.id = p_group and dist_m(me.lat, me.lng, g.lat, g.lng) <= g.radius)
  then raise exception 'out_of_range'; end if;
  insert into group_members (group_id, user_id) values (p_group, auth.uid()) on conflict do nothing;
end $$;

create or replace function public.leave_group(p_group bigint)
returns void language sql security definer set search_path = public as $$
  delete from group_members where group_id = p_group and user_id = auth.uid()
$$;

create or replace function public.send_group(p_group bigint, p_body text, p_image text default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare me presence; new_id bigint;
begin
  select * into me from presence where user_id = auth.uid() and _fresh(last_seen);
  if not found then raise exception 'not_present'; end if;
  if not exists (select 1 from group_members gm join groups g on g.id = gm.group_id
                 where gm.group_id = p_group and gm.user_id = auth.uid()
                   and dist_m(me.lat, me.lng, g.lat, g.lng) <= g.radius)
  then raise exception 'not_member'; end if;
  insert into group_messages (group_id, user_id, body, image_url)
  values (p_group, auth.uid(), nullif(trim(p_body), ''), p_image) returning id into new_id;
  update groups set last_active = now() where id = p_group;
  delete from group_messages where created_at < now() - interval '48 hours';
  return new_id;
end $$;

create or replace function public.get_group(p_group bigint, p_after bigint default 0)
returns table (id bigint, user_id uuid, name text, photo_url text, body text, image_url text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not exists (select 1 from group_members where group_id = p_group and user_id = auth.uid()) then return; end if;
  return query
    select m.id, m.user_id, p.name, p.photo_url, m.body, m.image_url, m.created_at
    from group_messages m join profiles p on p.id = m.user_id
    where m.group_id = p_group and m.id > coalesce(p_after, 0)
      and not _is_blocked(auth.uid(), m.user_id)
    order by m.id limit 300;
end $$;

-- ---------- חסימה ודיווח ----------
create or replace function public.block_user(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or p_user = auth.uid() then raise exception 'bad_request'; end if;
  insert into blocks (blocker, blocked) values (auth.uid(), p_user) on conflict do nothing;
  delete from chats where (requester = auth.uid() and recipient = p_user) or (requester = p_user and recipient = auth.uid());
end $$;

create or replace function public.report_user(p_user uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  insert into reports (reporter, reported, reason) values (auth.uid(), p_user, left(coalesce(p_reason,''), 500));
end $$;

-- ---------- מי מורשה להריץ מה ----------
revoke execute on all functions in schema public from public, anon;
grant  execute on all functions in schema public to authenticated;
revoke execute on function public._sweep_chats(uuid) from authenticated;
revoke execute on function public._is_blocked(uuid, uuid) from authenticated;

-- ---------- אחסון תמונות ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photos', 'photos', true, 3145728, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

drop policy if exists "niro upload own photos" on storage.objects;
create policy "niro upload own photos" on storage.objects for insert to authenticated
  with check (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "niro delete own photos" on storage.objects;
create policy "niro delete own photos" on storage.objects for delete to authenticated
  using (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);
