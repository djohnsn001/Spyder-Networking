-- Two levels of connection:
--   acquaintance — the existing remote flow (send request -> pending -> accepted)
--   in_person    — only earned by meeting in person (QR scan or phone bump)
--
-- The core rule: no client can ever set level = 'in_person' itself. Only the
-- security-definer functions below (and the QR/bump RPCs that call them in
-- later migrations) can, enforced by the connections_guard trigger. That
-- covers the mobile app, the web app, and any hand-crafted API call alike.

create type public.connection_level as enum ('acquaintance', 'in_person');
create type public.connection_method as enum ('request', 'qr', 'bump', 'legacy');

alter table public.connections
  add column level public.connection_level not null default 'acquaintance',
  add column method public.connection_method not null default 'request',
  -- When and where (city name only, never coordinates) two people met.
  add column met_at timestamptz,
  add column met_city text,
  -- Short window after an in-person connect where either person can undo it.
  add column undo_until timestamptz,
  -- The row's previous state, so undoing an upgrade restores it exactly.
  -- Null means the connection was brand new, so undo deletes it.
  add column undo_snapshot jsonb;

-- Every connection made before this migration came from the request flow.
-- Pending rows stay pending; nothing is deleted.
update public.connections set method = 'legacy';

alter table public.connections
  add constraint connections_in_person_is_accepted
    check (level <> 'in_person' or (status = 'accepted' and met_at is not null)),
  add constraint connections_met_city_len
    check (met_city is null or char_length(met_city) <= 80);

create index if not exists connections_level_idx on public.connections (level);

-- Guard: trusted functions set the transaction-local flag bolas.trusted_write
-- before writing. Every other write is forced to stay a plain acquaintance.
-- Clients reach the database only through PostgREST, which can't call
-- set_config, so they can't set the flag themselves — and it resets at the
-- end of every transaction.
create or replace function public.connections_guard()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if coalesce(current_setting('bolas.trusted_write', true), '') = 'on' then
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.level := 'acquaintance';
    new.method := 'request';
    new.met_at := null;
    new.met_city := null;
    new.undo_until := null;
    new.undo_snapshot := null;
  elsif tg_op = 'UPDATE' then
    if new.level is distinct from old.level
      or new.method is distinct from old.method
      or new.met_at is distinct from old.met_at
      or new.met_city is distinct from old.met_city
      or new.undo_until is distinct from old.undo_until
      or new.undo_snapshot is distinct from old.undo_snapshot then
      raise exception 'Connection level can only change through an in-person connect'
        using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;

create trigger connections_guard
  before insert or update on public.connections
  for each row execute function public.connections_guard();

-- Trigger functions run automatically; no client role needs to call them.
revoke execute on function public.connections_guard() from anon, authenticated, public;

-- Great-circle distance in meters between two points (haversine). Used by
-- bump matching later; no PostGIS needed. Internal only.
create or replace function public._distance_m(lat1 float8, lng1 float8, lat2 float8, lng2 float8)
returns float8
language sql
immutable
set search_path = public
as $$
  select 2 * 6371000 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)
  ));
$$;

revoke execute on function public._distance_m(float8, float8, float8, float8) from anon, authenticated, public;

-- The one place an in-person connection gets created or upgraded. Called by
-- the QR and bump RPCs (later migrations), never by clients directly.
--   no row yet             -> insert as accepted + in_person      ('created')
--   pending / acquaintance -> upgrade, saving the old state        ('upgraded')
--   already in_person      -> no change                            ('already_connected')
create or replace function public._connect_in_person(
  p_a uuid,
  p_b uuid,
  p_method public.connection_method,
  p_city text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_conn public.connections%rowtype;
  v_outcome text;
  v_city text := nullif(left(trim(coalesce(p_city, '')), 80), '');
begin
  if p_a = p_b then
    raise exception 'self_connect' using errcode = 'P0001';
  end if;

  -- No blocks table exists yet. When one does, refuse here if either user
  -- blocked the other: return jsonb_build_object('outcome', 'unavailable').

  perform set_config('bolas.trusted_write', 'on', true);

  select * into v_conn
  from public.connections
  where (requester_id = p_a and addressee_id = p_b)
     or (requester_id = p_b and addressee_id = p_a)
  for update;

  if not found then
    begin
      insert into public.connections
        (requester_id, addressee_id, status, level, method, met_at, met_city, undo_until, undo_snapshot)
      values
        (p_a, p_b, 'accepted', 'in_person', p_method, now(), v_city, now() + interval '30 seconds', null)
      returning * into v_conn;
      v_outcome := 'created';
    exception when unique_violation then
      -- Both phones raced and the other call created it first.
      select * into v_conn
      from public.connections
      where (requester_id = p_a and addressee_id = p_b)
         or (requester_id = p_b and addressee_id = p_a);
      v_outcome := 'already_connected';
    end;

  elsif v_conn.level = 'in_person' then
    v_outcome := 'already_connected';

  else
    update public.connections set
      undo_snapshot = jsonb_build_object(
        'status', v_conn.status,
        'level', v_conn.level,
        'method', v_conn.method,
        'met_at', v_conn.met_at,
        'met_city', v_conn.met_city
      ),
      status = 'accepted',
      level = 'in_person',
      method = p_method,
      met_at = now(),
      met_city = v_city,
      undo_until = now() + interval '30 seconds'
    where id = v_conn.id
    returning * into v_conn;
    v_outcome := 'upgraded';
  end if;

  perform set_config('bolas.trusted_write', 'off', true);

  return jsonb_build_object(
    'outcome', v_outcome,
    'connection_id', v_conn.id,
    'met_city', v_conn.met_city,
    'undo_until', v_conn.undo_until
  );
end;
$$;

revoke execute on function public._connect_in_person(uuid, uuid, public.connection_method, text)
  from anon, authenticated, public;

-- Either person can undo an in-person connect while undo_until hasn't passed
-- (the app shows ~10s; the server allows 30s to cover lag). A brand-new
-- connection is deleted; an upgrade is restored from its snapshot.
create or replace function public.undo_in_person_connection(p_connection_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_conn public.connections%rowtype;
  v_snap jsonb;
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  select * into v_conn
  from public.connections
  where id = p_connection_id
    and (requester_id = v_me or addressee_id = v_me)
  for update;

  if not found then
    return jsonb_build_object('outcome', 'not_found');
  end if;

  if v_conn.undo_until is null or now() > v_conn.undo_until then
    return jsonb_build_object('outcome', 'too_late');
  end if;

  perform set_config('bolas.trusted_write', 'on', true);

  v_snap := v_conn.undo_snapshot;
  if v_snap is null then
    delete from public.connections where id = v_conn.id;
  else
    update public.connections set
      status = v_snap ->> 'status',
      level = (v_snap ->> 'level')::public.connection_level,
      method = (v_snap ->> 'method')::public.connection_method,
      met_at = (v_snap ->> 'met_at')::timestamptz,
      met_city = v_snap ->> 'met_city',
      undo_until = null,
      undo_snapshot = null
    where id = v_conn.id;
  end if;

  perform set_config('bolas.trusted_write', 'off', true);

  return jsonb_build_object('outcome', 'undone');
end;
$$;

revoke execute on function public.undo_in_person_connection(uuid) from anon, public;
grant execute on function public.undo_in_person_connection(uuid) to authenticated;
