> DRAFT: not legal advice. Must be reviewed before publishing.

<!--
Notes for reviewers (delete before publishing):
- This is the public page Google Play requires: a way to ask for deletion WITHOUT reinstalling the
  app. Its URL ({{SITE}}/delete-account) goes into Play Console → Data safety → "Delete account URL".
- Google asks that the page name the app and the developer as shown on the Play listing, give the
  steps, and say what's deleted, what's kept, and for how long.
- Promise to keep: email requests are handled within 30 days. Handle them by deleting the account
  in the Supabase dashboard (Authentication → Users → delete) after checking that the email came
  from the account's address. The same cascades as in-app deletion then run, but avatar files have
  to be deleted by hand in Storage → avatars → <user id>. Consider adding an admin tool later.
- Placeholders: {{SITE}}, {{SUPPORT_EMAIL}}, {{LEGAL_ENTITY_NAME}}.
-->

# Delete your Bolas account

**App:** Bolas · **Developer:** {{LEGAL_ENTITY_NAME}}

## In the app (fastest)

1. Open Bolas and go to your **Profile** tab.
2. Open **Settings**.
3. Tap **Delete account** (under Account).
4. Type your username, then tap **Delete my account**.

Your account is deleted right away.

## Without the app

Email **{{SUPPORT_EMAIL}}** **from the email address you use for Bolas**, with the subject
**"Delete my account."** We'll confirm the request came from you, then delete your account
**within 30 days** and email you when it's done.

## What gets deleted

- Your account (email and password) and your profile, including your name, username, photos, bio,
  and interests
- Your connections and connection requests
- Your conversations. They're deleted for the other person too.
- Events you host, and your RSVPs to other events
- Your saved map location, your blocks, and your agreement records
- Any waitlist signup that uses the same email address

## What we keep

- **Safety reports** you filed, or that other people filed about you, are kept so we can keep the
  community safe. They're **no longer linked to your account**, but a report can still include the
  copy of the profile or message that was reported.
- **Moderation records** of actions our team took, with your account removed from them.
- Our hosting provider's **technical logs** (about 1 day) and **backups** are deleted on their own
  schedule, after which nothing of your account remains in them.

Deleting your account can't be undone. If you want to use Bolas again later, you'll need to create
a new account.

Questions: {{SUPPORT_EMAIL}}
