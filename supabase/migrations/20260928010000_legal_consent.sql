-- Consent records: which Terms version each user accepted, when, and that
-- they confirmed they're 18+.
-- Plan: docs/plans/legal-compliance.md (Phase 2).
--
-- Deviation from the plan (Zane's call on flag M1, 2026-09-28): the plan put
-- three columns on profiles, but every signed-in user can read every profile
-- column. Consent lives in its own table instead, readable only by its owner
-- and writable by nobody but the two definer functions below — so no guard
-- trigger is needed, and editing a profile can't touch it.
--
-- We store THAT someone confirmed 18+, never a birth date (data minimization).
-- Times always come from the server's now(), so nothing can be backdated.

-- ---------------------------------------------------------------------------
-- Current version (one place)
-- ---------------------------------------------------------------------------

-- Must match TERMS_VERSION in src/lib/legal/config.ts. Bump both (with a new
-- migration) when the Terms change; everyone is then asked to accept again.
-- '2026-10-01' is a placeholder date until the reviewed Terms are published.
create or replace function public._current_terms_version()
returns text
language sql
immutable
set search_path = public
as $$
  select '2026-10-01'
$$;

revoke execute on function public._current_terms_version() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Table
-- ---------------------------------------------------------------------------

-- One row per Terms version a user accepted; the first acceptance of a
-- version is the one kept.
create table public.user_consents (
  user_id uuid not null references public.profiles (id) on delete cascade,
  terms_version text not null check (char_length(terms_version) between 1 and 20),
  accepted_at timestamptz not null default now(),
  age_confirmed_at timestamptz not null default now(),
  primary key (user_id, terms_version)
);

alter table public.user_consents enable row level security;

create policy "Users see their own consent records"
  on public.user_consents
  for select
  to authenticated
  using (user_id = auth.uid());
-- No insert/update/delete policies: only handle_new_user and accept_terms
-- write here.

grant select on public.user_consents to anon;
grant select, insert, update, delete on public.user_consents to authenticated;
grant select, insert, update, delete on public.user_consents to service_role;

-- ---------------------------------------------------------------------------
-- Record consent at sign-up
-- ---------------------------------------------------------------------------

-- Same as before (auto-create the empty profile), plus: when the sign-up
-- call passed options.data = { terms_version, age_confirmed: true } and the
-- version is current, record consent with the server's time. Anything else
-- (older app, web sign-up, stale version) records nothing, and the app's
-- consent gate asks once after sign-in.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id)
  values (new.id)
  on conflict (id) do nothing;

  if coalesce(new.raw_user_meta_data ->> 'age_confirmed', '') = 'true'
     and new.raw_user_meta_data ->> 'terms_version' = public._current_terms_version() then
    insert into public.user_consents (user_id, terms_version, accepted_at, age_confirmed_at)
    values (new.id, public._current_terms_version(), now(), now())
    on conflict (user_id, terms_version) do nothing;
  end if;

  return new;
end;
$$;

revoke execute on function public.handle_new_user() from anon, authenticated, public;

-- ---------------------------------------------------------------------------
-- accept_terms: existing users, and every future Terms update
-- ---------------------------------------------------------------------------

-- Returns one of:
--   { outcome: 'accepted' }
--   { outcome: 'stale_version', current_version }   the app has old Terms text
--   { outcome: 'age_required' }                      the 18+ box wasn't checked
create or replace function public.accept_terms(p_version text, p_age_confirmed boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_current text := public._current_terms_version();
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  if p_version is distinct from v_current then
    return jsonb_build_object('outcome', 'stale_version', 'current_version', v_current);
  end if;

  if p_age_confirmed is not true then
    return jsonb_build_object('outcome', 'age_required');
  end if;

  insert into public.user_consents (user_id, terms_version, accepted_at, age_confirmed_at)
  values (v_me, v_current, now(), now())
  on conflict (user_id, terms_version) do nothing;

  return jsonb_build_object('outcome', 'accepted');
end;
$$;

revoke execute on function public.accept_terms(text, boolean) from public, anon;
grant execute on function public.accept_terms(text, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- get_my_consent_status: what the app's consent gate asks
-- ---------------------------------------------------------------------------

-- Returns { current_version, accepted_version, accepted_at, needs_acceptance }.
-- accepted_version / accepted_at are the caller's most recent acceptance
-- (null if none). Definer only so it can read _current_terms_version().
create or replace function public.get_my_consent_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_current text := public._current_terms_version();
  v_latest public.user_consents%rowtype;
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  select * into v_latest
  from public.user_consents c
  where c.user_id = v_me
  order by c.accepted_at desc, c.terms_version desc
  limit 1;

  return jsonb_build_object(
    'current_version', v_current,
    'accepted_version', v_latest.terms_version,
    'accepted_at', v_latest.accepted_at,
    'needs_acceptance', not exists (
      select 1 from public.user_consents c
      where c.user_id = v_me and c.terms_version = v_current
    )
  );
end;
$$;

revoke execute on function public.get_my_consent_status() from public, anon;
grant execute on function public.get_my_consent_status() to authenticated;
