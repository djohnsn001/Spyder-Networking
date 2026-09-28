# Handoff: legal pages on the Bolas website

**For:** a Claude Code session opened in `~/Code Apps/bolas-web` (the landing page, hosted on
Cloudflare). **Not** for this repo. Written 2026-09-28 from `docs/legal/drafts/` in the `bolas`
app repo (branch `feature/legal-compliance`).

Paste this to that session:

> Read this handoff and do steps 1–4. Explain each step before doing it. Don't publish or deploy
> anything, and don't remove the DRAFT banners, until Zane says the drafts have been reviewed by a
> lawyer.

---

## Why

The App Store and Google Play listings need public URLs for the privacy policy, terms, and (for
Google) a way to request account deletion without the app. The app already links to these paths
(`src/lib/legal/config.ts`):

| Path | Source draft (in the `bolas` repo) |
|---|---|
| `/privacy` | `docs/legal/drafts/privacy-policy.md` |
| `/terms` | `docs/legal/drafts/terms-of-service.md` |
| `/guidelines` | `docs/legal/drafts/community-guidelines.md` |
| `/safety` | `docs/legal/drafts/safety-tips.md` |
| `/delete-account` | `docs/legal/drafts/delete-account-page.md` |

Keep these exact paths: the app links to `{{SITE}}/privacy` etc., so changing them breaks the app's
links.

## Step 1: the five pages

- Copy each draft in, keeping the text as-is. Strip the `<!-- notes for reviewers -->` comments.
  **Keep** the "DRAFT: not legal advice" banner until Zane says the review is done.
- Each page shows a **"Last updated"** date. Use the effective date, which must match
  `TERMS_VERSION` in the app (currently the placeholder `2026-10-01`).
- Leave every `{{PLACEHOLDER}}` visible, and list them for Zane. Don't invent a company name,
  address, email, or state.
- Plain, readable pages: good contrast, real headings (h1/h2), tables as real tables, and a width
  that reads well on phones.
- The pages must work without JavaScript and without a login. App store reviewers open them
  directly.

## Step 2: footer on every page

On **every** page of the site (landing page included): the legal entity name (placeholder
`{{LEGAL_ENTITY_NAME}}`), the contact email (`{{CONTACT_EMAIL}}`), and links to Privacy, Terms,
Community Guidelines, Safety Tips, and Delete account.

## Step 3: check the landing page's claims

List anything on the landing page that isn't true yet, for Zane to fix. For example:

- user numbers or "join thousands of founders"
- testimonials or quotes from people who didn't actually say them
- "safest," "#1," "verified users," "background-checked" (Bolas does **not** verify identities or
  run background checks)
- features that aren't built (e.g. notifications, discovery filters, intros) described as if they
  exist
- privacy promises that go beyond the privacy policy

Don't rewrite the copy yourself. Just list it with a suggested fix.

## Step 4: cookies and tracking

- List every script, embed, font, and analytics tool the site loads, and whether it sets cookies
  or tracks visitors (e.g. Google Analytics, Meta Pixel, Hotjar, embedded videos). Check the
  Cloudflare settings too, e.g. Web Analytics, which is cookieless.
- If there are **no** tracking cookies (only strictly necessary ones, or cookieless analytics),
  **no cookie banner is needed** for a U.S.-only site. Write that finding down.
- If tracking or advertising cookies **do** exist, **stop and ask Zane** before adding anything.
  The app's privacy policy says Bolas does no tracking, so the site shouldn't either. The fix is
  more likely removing the tracker than adding a banner.
- The waitlist form collects an email. Make sure the form says what it's for (e.g. "We'll email
  you when Bolas launches") and links to `/privacy`.

## Also note for Zane

- The waitlist table is in the same Supabase project as the app. When someone deletes their Bolas
  account, any waitlist row with the same email is deleted too.
- Nothing goes live until Zane says a lawyer has reviewed the drafts.
