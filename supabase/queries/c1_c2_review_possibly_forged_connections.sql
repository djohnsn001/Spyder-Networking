-- Review for security items C1/C2 (READ-ONLY).
--
-- Lists accepted connections made through the request flow (method =
-- 'request') where the two people have never exchanged a message. A forged
-- connection (inserted as 'accepted', or re-pointed by the addressee before
-- 20260929000000) would look exactly like this. Most rows will be innocent
-- (people who connected and never chatted); look for the patterns in the
-- "why look" notes below.
--
-- It only reads. The first line makes the whole run read-only, so even a
-- mistake can't write. Paste it into the Supabase SQL editor, or:
--   npx supabase db query --linked -f supabase/queries/c1_c2_review_possibly_forged_connections.sql
-- (check which project is linked first: cat supabase/.temp/project-ref)
--
-- Why look closer at a row:
--   - created_at earlier than both accounts could have found each other
--     (e.g. seconds after the requester signed up)
--   - one requester with many accepted, silent connections
--   - the addressee says they never accepted it
-- Connections from before 2026-09-27 have method = 'legacy'; to include them,
-- change the filter to method in ('request', 'legacy').

set transaction read only;

select
  c.id as connection_id,
  c.created_at,
  c.requester_id,
  rp.username as requester_username,
  c.addressee_id,
  ap.username as addressee_username,
  c.level,
  -- How many accepted, silent request-connections this requester has in
  -- total: a high number from one account is the main red flag.
  count(*) over (partition by c.requester_id) as silent_accepted_from_requester,
  ru.created_at as requester_signed_up_at,
  au.created_at as addressee_signed_up_at
from public.connections c
left join public.profiles rp on rp.id = c.requester_id
left join public.profiles ap on ap.id = c.addressee_id
left join auth.users ru on ru.id = c.requester_id
left join auth.users au on au.id = c.addressee_id
where c.status = 'accepted'
  and c.method = 'request'
  and not exists (
    select 1
    from public.conversations cv
    join public.messages m on m.conversation_id = cv.id
    where not cv.is_group
      and least(cv.user_a_id, cv.user_b_id) = least(c.requester_id, c.addressee_id)
      and greatest(cv.user_a_id, cv.user_b_id) = greatest(c.requester_id, c.addressee_id)
  )
order by silent_accepted_from_requester desc, c.created_at desc;
