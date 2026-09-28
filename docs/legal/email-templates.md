> DRAFT: not legal advice. Must be reviewed before publishing.

# Supabase auth emails: Bolas-branded drafts

Paste these into **Supabase dashboard → Authentication → Emails** (as of 2026-09-28 they're still
the Supabase defaults, which don't say "Bolas" or give a way to reach you). Template variables like
`{{ .ConfirmationURL }}` are filled in by Supabase. Leave them exactly as written. The `{{SUPPORT_EMAIL}}`
and `{{LEGAL_ENTITY_NAME}}` placeholders are ours: replace them before saving.

## Which emails Bolas actually sends

| Template | Sent when | Needed now? |
|---|---|---|
| **Confirm sign up** | Every new account (if "Confirm email" is on in Auth settings) | **Yes** |
| Reset password | Only if someone triggers it from the dashboard. **The app has no "Forgot password" yet** (see note 3). | Paste it anyway |
| Change email address | Not reachable from the app yet | Paste it anyway |
| Password changed / Email address changed (security notifications) | When those change, if notifications are enabled | Recommended |
| Invite user, Magic link / OTP, Reauthentication, phone and MFA notifications | Not used by Bolas | Leave as is |

**All of these are transactional** (about the user's own account). Bolas sends **no marketing
emails**. Any future newsletter or promo email needs: the person's consent, an unsubscribe link
that works, and a physical mailing address in every email (CAN-SPAM).

---

## Confirm sign up

**Subject:** `Confirm your email for Bolas`

```html
<h2>Welcome to Bolas</h2>
<p>Tap the button below to confirm your email address and finish creating your Bolas account.</p>
<p><a href="{{ .ConfirmationURL }}" style="display:inline-block;padding:12px 20px;background:#83655d;color:#fdfbf7;border-radius:12px;text-decoration:none;font-weight:600">Confirm my email</a></p>
<p>Or copy this link into your browser:<br>{{ .ConfirmationURL }}</p>
<p>If you didn't sign up for Bolas, you can ignore this email. No account will be created without
this confirmation.</p>
<hr>
<p style="color:#685a52;font-size:13px">Bolas is for adults 18 and older. Questions? Email
{{SUPPORT_EMAIL}}.<br>{{LEGAL_ENTITY_NAME}}</p>
```

## Reset password

**Subject:** `Reset your Bolas password`

```html
<h2>Reset your password</h2>
<p>Someone asked to reset the password for the Bolas account using {{ .Email }}. If that was you,
tap below to choose a new one.</p>
<p><a href="{{ .ConfirmationURL }}" style="display:inline-block;padding:12px 20px;background:#83655d;color:#fdfbf7;border-radius:12px;text-decoration:none;font-weight:600">Reset my password</a></p>
<p>If you didn't ask for this, you can ignore this email. Your password won't change.</p>
<hr>
<p style="color:#685a52;font-size:13px">Questions? Email {{SUPPORT_EMAIL}}.<br>{{LEGAL_ENTITY_NAME}}</p>
```

## Change email address

**Subject:** `Confirm your new email for Bolas`

```html
<h2>Confirm your new email</h2>
<p>You asked to change your Bolas email from {{ .Email }} to {{ .NewEmail }}. Tap below to
confirm.</p>
<p><a href="{{ .ConfirmationURL }}" style="display:inline-block;padding:12px 20px;background:#83655d;color:#fdfbf7;border-radius:12px;text-decoration:none;font-weight:600">Confirm new email</a></p>
<p>If you didn't ask for this, don't tap the link. Email {{SUPPORT_EMAIL}} right away.</p>
<hr>
<p style="color:#685a52;font-size:13px">{{LEGAL_ENTITY_NAME}}</p>
```

## Security notification: password changed

**Subject:** `Your Bolas password was changed`

```html
<p>The password for your Bolas account ({{ .Email }}) was just changed.</p>
<p>If this was you, you're all set. If it wasn't, email {{SUPPORT_EMAIL}} right away so we can
help secure your account.</p>
<p style="color:#685a52;font-size:13px">{{LEGAL_ENTITY_NAME}}</p>
```

## Security notification: email address changed

**Subject:** `Your Bolas email was changed`

```html
<p>The email on your Bolas account was changed from {{ .OldEmail }} to {{ .Email }}.</p>
<p>If this wasn't you, email {{SUPPORT_EMAIL}} right away.</p>
<p style="color:#685a52;font-size:13px">{{LEGAL_ENTITY_NAME}}</p>
```

---

## Notes

1. **Site URL.** The "Confirm my email" link sends people to the **Site URL** in Authentication →
   URL Configuration after confirming. Make sure it's your real site (e.g. a `{{SITE}}/confirmed`
   page saying "You're confirmed. Go back to the Bolas app and log in"), not `localhost`.
2. **Custom SMTP before launch.** Supabase's built-in email sender is meant for testing: it's
   heavily rate-limited and sends from a Supabase address. Before launch, set up your own sender
   (Authentication → SMTP Settings) with the business email domain, e.g. Resend, Postmark, or
   Amazon SES. It also makes the emails come "from Bolas" instead of Supabase.
3. **Forgot password (recommended, not built).** There's no way to reset a forgotten password in
   the app today, so every lockout becomes a support email. A small "Forgot password?" link on the
   login screen (`supabase.auth.resetPasswordForEmail`) plus a reset screen would fix it. It's not
   a legal requirement; it's on the list for later.
