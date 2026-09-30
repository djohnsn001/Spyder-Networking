-- Security item M6 (step 1 of 2): lock down the website's waitlist.
--
-- Before: anon could insert any text as an "email", and inserting an email
-- that was already there failed with a unique-violation error, which told
-- anyone whether a given address was on the list.
--
-- After this migration:
--   * emails must be <= 254 chars and look like name@domain.tld,
--   * every email is stored trimmed and lower-cased (trigger),
--   * the website joins through join_waitlist(), which answers { ok: true }
--     whether or not the email was already there,
--   * anon/authenticated can't read, change, or delete rows.
--
-- The old "Anyone can join the waitlist" insert policy STAYS for now so the
-- current website form keeps working. Step 2 (dropping it) lives in
-- supabase/pending-migrations/m6_step2_drop_waitlist_anon_insert.sql and
-- must not be moved in until the website calls join_waitlist().

-- 1. Tidy existing rows: trim + lower-case. When two rows only differ by
--    case, the first one wins and the others are left as they are (nothing
--    is deleted); supabase/queries/m6_waitlist_check.sql lists them.
with ranked as (
  select id,
         lower(btrim(email)) as norm,
         row_number() over (
           partition by lower(btrim(email))
           order by (email = lower(btrim(email))) desc, created_at, id
         ) as rn
  from public.waitlist
)
update public.waitlist w
set email = r.norm
from ranked r
where w.id = r.id and r.rn = 1 and w.email <> r.norm;

-- 2. The email check. NOT VALID so a strange old row can't make this push
--    fail; it's validated right below when every row passes.
alter table public.waitlist
  add constraint waitlist_email_valid check (
    char_length(email) <= 254
    and email ~ '^[^[:space:][:cntrl:]@]+@[^[:space:][:cntrl:]@]+\.[^[:space:][:cntrl:]@]+$'
  ) not valid;

do $$
begin
  if not exists (
    select 1 from public.waitlist
    where not (
      char_length(email) <= 254
      and email ~ '^[^[:space:][:cntrl:]@]+@[^[:space:][:cntrl:]@]+\.[^[:space:][:cntrl:]@]+$'
    )
  ) then
    alter table public.waitlist validate constraint waitlist_email_valid;
  else
    raise notice 'waitlist_email_valid left NOT VALID: run supabase/queries/m6_waitlist_check.sql';
  end if;
end
$$;

-- 3. Store every new or changed email trimmed and lower-cased.
create or replace function public._waitlist_normalize_email()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.email := lower(btrim(new.email));
  return new;
end;
$$;

revoke all on function public._waitlist_normalize_email() from public, anon, authenticated;

create trigger waitlist_normalize_email
  before insert or update of email on public.waitlist
  for each row execute function public._waitlist_normalize_email();

-- 4. Nobody outside the team reads or edits the list. anon keeps INSERT
--    only until step 2 (the current website still inserts directly).
revoke select, update, delete, truncate, references, trigger
  on public.waitlist from anon, authenticated;
revoke insert on public.waitlist from authenticated;

-- 5. The website's way in. Deliberately callable WITHOUT a signed-in user
--    (the website has no accounts), so unlike other definer functions
--    there's no auth.uid() check (AGENTS.md rule 4 exception).
--    A valid email always gets { ok: true }, new or already on the list.
--    A malformed one raises 'invalid_email' (that reveals nothing about
--    who is on the list).
create or replace function public.join_waitlist(p_email text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    insert into public.waitlist (email)
    values (p_email)
    on conflict (email) do nothing;
  exception when check_violation or not_null_violation then
    raise exception 'invalid_email' using errcode = '22023';
  end;
  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.join_waitlist(text) from public, anon, authenticated;
grant execute on function public.join_waitlist(text) to anon, service_role;
