> DRAFT: not legal advice. Must be reviewed before publishing.

<!--
Notes for reviewers (delete before publishing):
- Every fact here comes from docs/legal/data-inventory.md. If the app changes, update the
  inventory first, then this page.
- Placeholders: {{LEGAL_ENTITY_NAME}}, {{CONTACT_EMAIL}}, {{SUPPORT_EMAIL}}, {{MAILING_ADDRESS}},
  {{SITE}}, {{EFFECTIVE_DATE}} (should match TERMS_VERSION / _current_terms_version, now 2026-10-01).
- Launch area: United States only (Zane, 2026-09-28). No GDPR section. If Bolas launches outside
  the U.S., this policy needs a lawyer's rewrite first.
- State privacy laws (e.g. California's CCPA/CPRA) mostly apply above size thresholds Bolas doesn't
  meet yet. This draft offers the core rights to everyone instead of naming specific laws; ask the
  lawyer whether any state-specific section is needed.
-->

# Bolas Privacy Policy

**Effective date:** {{EFFECTIVE_DATE}}

Bolas is a networking app for people who want to start things. This policy explains what
information Bolas collects, why, who can see it, how long we keep it, and the choices you have.
We've tried to write it in plain language. If anything is unclear, email us at {{CONTACT_EMAIL}}.

**The short version**

- We collect what the app needs to work: your account, your profile, your connections, your
  messages, and, only in specific situations, your location.
- **We don't sell your information, we don't show ads, and we don't track you across other apps or
  websites.**
- Location is **off by default**. When you turn on "Show me on the map," people you've met in person
  see your **approximate area** (a few square kilometers), never your exact spot.
- You can delete your account at any time in **Settings → Delete account**, and it really deletes.
- Bolas is for adults **18 and older**.

## 1. Who we are

Bolas is operated by {{LEGAL_ENTITY_NAME}} ("Bolas," "we," "us"), {{MAILING_ADDRESS}}. Bolas is
offered in the United States.

## 2. What we collect and why

### Information you give us

| What | Why |
|---|---|
| **Email address and password** | To create your account and let you log in, and to send account emails such as confirming your email or resetting your password. We store your password only as a secure hash, never in readable form. |
| **Your confirmation that you're 18 or older, and your agreement to our Terms** | To make sure Bolas is only used by adults, and to keep a record of when you agreed and to which version. We record *that* you confirmed you're 18+, **not your birth date**. |
| **Profile: username** (required), and optionally your **name, profile photo, bio, interests, business stage, and city** | To show other people who you are and what you're building. |
| **Connections and connection requests** | To build your network (your "Web"). |
| **Messages** you send to your connections | To deliver them. |
| **Events** you create (title, description, time, and the place you pick) and events you mark as **Going** | To show events on the map and let attendees find them. |
| **Reports** you file, and **blocks** you make | To keep people safe. See section 5. |
| **Support requests** you email us | To help you. |

### Information collected when you use certain features

| What | When | Why |
|---|---|---|
| **Approximate location for the Web Map** | Only if you turn on **Show me on the map** (it's off by default), each time you open the Map. | So people you've met in person can see roughly where you are. Our server snaps your position to a grid about 2 km across **before storing it**; your exact position is never stored for the map. |
| **Precise location while connecting in person** | Only on the **Connect** screen: when you tap phones, show your QR code, or scan someone's. | To check you're really with the person you're connecting with. **Tapping:** your coordinates are erased as soon as the match is decided, and the record is deleted within about 10 minutes. **Your QR code:** it carries your location rounded to about 100 m, erased the moment someone uses the code (unused codes are deleted within an hour). **Scanning:** your location is compared with the code's and not stored. |
| **The city you met someone in** | When you connect in person (tap or QR code). | To show "Met in Boise." We keep only the city name, never coordinates. |
| **Camera** | Only when you scan a QR code. | Scanning happens on your phone. **No images are sent to us.** |
| **Motion sensor** | Only on the Tap screen. | To detect the tap. Motion data stays on your phone. |
| **Photo library** | Only when you choose a profile photo. | We receive only the one photo you pick. |

The app asks your phone's permission before using location, camera, motion, or photos, and you
can say no. Bolas still works without them, but the features above won't.

### Information collected automatically

- **Login and security data:** your account's sign-in times, the IP address and device type
  (user agent) of your current login session, and, if you turn on two-step verification, the
  secret your authenticator app uses to make codes. We use these to keep you logged in and to protect
  accounts.
- **Server logs:** our hosting provider records technical logs of requests (such as IP address,
  time, and which part of the service was used). These are kept for about a day.

We do **not** use analytics, advertising, or crash-reporting tools, and we don't collect your
contacts, browsing history, or advertising identifier.

## 3. Who can see your information

| Information | Who can see it |
|---|---|
| Your profile (username, name, photo, bio, interests, stage, city) | Other signed-in Bolas users, **except** people you've blocked or who blocked you. Your **profile photo** is stored at a web address that anyone who has the link can open. |
| That you're connected with someone | The two of you. Others may see it indirectly: your number of connections, "mutual connections" you share with them, attendance at events, and, on the Web Map, lines between two people they've both met in person. |
| Where and when you met someone | Only the two of you. |
| Your approximate map location | Only people you've **met in person** (tap or QR), and only while "Show me on the map" is on. |
| Your messages | You and the person you're messaging. Messages are encrypted in transit but **not end-to-end encrypted**, so our team can access them if needed, for example to investigate a report. The other person can also technically tell when you last opened your conversation, though the app doesn't show this. |
| Events you host | Public events: any signed-in user. Connections-only events: you and your connections. Everyone sees an **approximate area** until they tap Going. The exact place is shown only to you, people going, and our moderators. |
| Events you're going to | The host, and your own connections. Everyone sees only the total count. |
| Your email, consent record, blocks, and reports | Only you (and our team). The people you block or report are **never told**. |

## 4. Who we share information with

We **don't sell** your personal information, and we don't share it for advertising. We share it
only:

- **With service providers who run Bolas for us:**
  - **Supabase**, our database, login, and file storage provider. It stores almost everything
    described above.
  - **Apple** and **Google**, through your phone's built-in services. When you're on the Tap or
    Scan screen, your phone sends your coordinates to Apple (iPhone) or Google (Android) to look up
    the city name. Maps are drawn by Apple Maps on iPhone and by Google Maps on Android.
  - **Google Maps on Android** collects some technical information about its own use, such as
    your IP address, device information, and a Google Maps identifier, to run and improve Google's
    services. See [Google's Privacy Policy](https://policies.google.com/privacy).
  - **Expo** (the tools we use to build the app) doesn't receive your personal information when
    you use the app.
- **With other users,** as described in section 3.
- **For safety and the law:** if we believe in good faith that it's needed to follow the law or a
  valid legal request, to protect someone from harm, or to enforce our Terms. This includes
  reporting child sexual abuse material to the National Center for Missing & Exploited Children
  (NCMEC), as U.S. law requires.
- **If Bolas changes hands:** if we're involved in a merger, acquisition, or sale of assets, your
  information may be transferred, and this policy (or one at least as protective) will still apply
  to it.

## 5. Safety, reports, and moderation

- **Reports.** When you report someone, we save the report along with a copy of their profile (and
  the reported message, if any) as it was at that moment, so we can review it even if they change
  or delete it. We review reports within 24 hours.
- **Blocks.** When you block someone, you disappear from each other's view everywhere in Bolas.
  They aren't notified.
- **Content filter.** We automatically reject usernames, names, bios, and event text that contain
  words or phrases on our blocked list.
- **Suspensions.** If an account breaks our rules, we may suspend it (it becomes invisible and
  can't post) or delete it.

## 6. How long we keep information

| Information | How long |
|---|---|
| Account, profile, connections, consent records, blocks | Until you delete your account |
| Messages | Until you or the other person deletes their account, which deletes the whole conversation for both of you |
| Web Map location | Until you turn off "Show me on the map" (deleted right away), or 7 days after your last Map visit |
| Precise tap location | Coordinates erased as soon as the match is decided (within about a minute at most); the record is deleted within about 10 minutes |
| QR codes | About 1 hour |
| Events | Until 30 days after the event ends (longer only while a report about it is under review), or until the host deletes it |
| Login session data (IP, device type) | While you're logged in |
| Server logs | About 1 day |
| Reports and moderation records | Kept, because they're needed to keep the community safe. If you delete your account, reports stay but are **no longer linked to your account**. A report can still include the copy of the profile or message that was reported. |

Our hosting provider may keep backups for a limited time. Data in backups is deleted when the
backups expire.

## 7. Your choices and rights

You can, at any time:

- **See and edit your profile**, in **Profile → Edit**.
- **Turn off location on the map**, in **Settings → Show me on the map**. Your saved location is
  deleted immediately.
- **Say no to phone permissions**, or turn them off later in your phone's settings.
- **Block people**, and **unblock** them in **Settings → Blocked users**.
- **Delete your account**, in **Settings → Delete account**. This permanently deletes your account,
  profile, photos, connections, conversations (for both people), events, and location, and
  unlinks your reports from you. It can't be undone. If you no longer have the app, see
  [{{SITE}}/delete-account]({{SITE}}/delete-account).
- **Ask for a copy of your information, or ask us to correct or delete it,** by emailing
  {{CONTACT_EMAIL}} from the email address on your account. We'll respond within 30 days. We may
  need to confirm it's really you first.

We won't treat you differently for using these rights.

**Do Not Track:** we don't track you across other sites or apps, so there's nothing for a "Do Not
Track" signal to turn off.

## 8. Bolas is for adults

Bolas is only for people **18 and older**. Everyone must confirm they're 18 or older to sign up.
We don't knowingly collect information from anyone under 18. If we learn that a user is under 18,
we'll delete their account. If you believe someone under 18 is using Bolas, report their profile
in the app or email {{CONTACT_EMAIL}}.

## 9. Security

We protect your information with reasonable safeguards. Connections to Bolas are encrypted (HTTPS),
passwords are stored only as secure hashes, and our database limits what each account can read
and change. No system is perfectly secure, though, so we can't guarantee absolute security. If we
learn of a breach affecting your information, we'll notify you as the law requires.

## 10. Changes to this policy

If we change this policy, we'll update the effective date above. If the changes are significant,
we'll tell you in the app, and ask you to agree again when needed, before they apply to you.

## 11. Contact us

Questions or requests: **{{CONTACT_EMAIL}}**
{{LEGAL_ENTITY_NAME}}, {{MAILING_ADDRESS}}
