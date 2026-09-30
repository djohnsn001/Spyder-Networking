-- Security M2: fix the SEED accounts (@bolas-seed.local) so they follow the
-- new profile rules. THIS ONE WRITES. It only touches seed accounts, and only
-- usernames/interests; it matches scripts/seed-data.js after the M2 update.
--
-- Run it on a project BEFORE pushing 20260929050000, then rerun
-- m2_profile_limit_violations.sql. Everything is in one transaction: if
-- anything fails, nothing changes.

begin;

update public.profiles p
set username = v.new_username,
    interests = v.new_interests
from auth.users u,
  (values
    ('ava_builds',  'ava_builds',   array['Marketplace', 'Consumer']),
    ('marcuswebb',  'marcuswebb',   array['AI / ML', 'SaaS']),
    ('bella_g',     'bella_g',      array['Health', 'Education']),
    ('priya.patel', 'priya_patel',  array['Sustainability', 'E-commerce']),
    ('jordanlee',   'jordanlee',    array['Health', 'Consumer']),
    ('liam_oc',     'liam_oc',      array['Marketplace', 'Consumer']),
    ('sofia.r',     'sofia_r',      array['Marketplace']),
    ('tbrooks',     'tbrooks',      array['Education']),
    ('gracekim',    'gracekim',     array['E-commerce', 'Marketplace']),
    ('noah_w',      'noah_w',       array['Sustainability', 'Hardware']),
    ('maya.t',      'maya_t',       array['Hardware', 'Sustainability']),
    ('ethanpark',   'ethanpark',    array['Creator tools', 'Social'])
  ) as v(old_username, new_username, new_interests)
where u.id = p.id
  and u.email like '%@bolas-seed.local'
  and p.username = v.old_username;

commit;
