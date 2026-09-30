# Waitlist form change (security item M6), for bolas-web

Hey! I'm locking down the `waitlist` table in Supabase. Right now anyone with the public key can
insert any text, and the "already exists" error (23505) tells anyone whether an email is on the
list. The fix is a database function the form calls instead of inserting into the table.

## 0. Switch to the new publishable key

Supabase is retiring the old `anon` key (the long `eyJ...` one). The site's `.env.production` still
uses it as `NEXT_PUBLIC_SUPABASE_ANON_KEY`, and once I turn the legacy keys off the waitlist form
stops working. The replacement is the **publishable** key: Supabase dashboard → the production
project (`fhevoocpcnrjxyjvitai`) → Project Settings → API Keys → `sb_publishable_...`. It's just as
public as the anon key, so it's fine in the browser and in the build env.

1. Swap the value in `.env.production`, `.env.local`, and the Cloudflare build env. Renaming the
   variable to `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` is optional; if you rename it, update
   `src/lib/supabase.ts` to match. `createClient(url, key)` works the same with either key.
2. Deploy, and check the form still works.
3. Tell me, so I can turn the legacy keys off.

## 1. Switch the form to the RPC (please do this first)

In `src/components/WaitlistForm.tsx`, replace the insert:

```ts
const { error } = await supabase.rpc("join_waitlist", { p_email: email });

if (error) {
  setErrorMessage(
    error.message === "invalid_email"
      ? "That doesn't look like an email address."
      : "That didn't go through. Check your connection and try again.",
  );
  setStatus("error");
  return;
}
setStatus("success");
```

- A valid email **always** gets `{ ok: true }`, even if it's already on the list. That's the
  point: the response no longer reveals who's signed up. There's no 23505 to check anymore.
- A malformed email (over 254 characters, no `@`, no dot in the domain, spaces) returns an error
  whose message is `invalid_email`.
- The database trims and lower-cases emails, so the form doesn't need to.
- Keep the honeypot. It's still useful.

**Remove `notifyN8n()` from the form.** The form can't tell new from existing signups anymore, so
it would re-send the welcome email to anyone who submits twice. The n8n webhook URL is also public
in the page source, so anyone can POST any email address to it and make us send welcome emails to
strangers. I'll send the welcome email from the database instead (a Supabase Database Webhook on
new `waitlist` rows, with a secret header). It only fires for new signups, since duplicates insert
nothing. Let me know when you deploy so I can switch it on the same day.

Once the new form is live I'll remove the old direct-insert permission. After that, the old
`.from("waitlist").insert(...)` code stops working, so please tell me when it's deployed.

## 2. Add Cloudflare Turnstile (bot check)

1. In the Cloudflare dashboard, go to **Turnstile → Add widget** for the site's domain(s) and
   `localhost`. Choose **Managed** mode. You get a **site key** (public) and a **secret key**
   (private).
2. Put the site key in `.env.local` / the Cloudflare build env as
   `NEXT_PUBLIC_TURNSTILE_SITE_KEY`. **The secret key never goes in the website.** Send it to me
   privately; it goes into Supabase secrets.
3. Render the widget in the form and keep the token it gives you, for example:

```tsx
import Script from "next/script";
// ...
const [turnstileToken, setTurnstileToken] = useState("");
const widgetRef = useRef<HTMLDivElement>(null);

<Script
  src="https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit"
  onLoad={() => {
    window.turnstile.render(widgetRef.current!, {
      sitekey: process.env.NEXT_PUBLIC_TURNSTILE_SITE_KEY!,
      callback: (token: string) => setTurnstileToken(token),
      "expired-callback": () => setTurnstileToken(""),
    });
  }}
/>
<div ref={widgetRef} />
```

   Disable the submit button until there's a token. Tokens are single-use and expire after 5
   minutes, so call `window.turnstile.reset()` after each submit.

4. **Important: a token only means something if a server checks it.** The site is a static export,
   so it has no server of its own. If the form just calls `join_waitlist` directly, a bot can skip
   the widget and call the database function with the public key. The plan: I'll add a small
   Supabase Edge Function, `join-waitlist`. It checks the token with Cloudflare using the secret
   key, then adds the email. After that I'll turn off public access to the RPC. Once the function
   exists, the form's call changes to:

```ts
const { data, error } = await supabase.functions.invoke("join-waitlist", {
  body: { email, turnstileToken },
});
```

   Same responses as above (`{ ok: true }` or `invalid_email`), plus a `captcha_failed` error
   that should say "Please try the check again". Until the function exists, do step 1 with the
   plain RPC.

5. Add Cloudflare Turnstile to the privacy page's list of service providers (it's a bot check that
   processes the visitor's browser/IP data). It sets no tracking cookies, so it doesn't change the
   cookie page's "no banner" finding.

## Order

0. You switch to the publishable key (section 0) and deploy. Tell me, and I turn the legacy keys
   off.
1. You deploy the RPC form (section 1, without `notifyN8n`). Tell me.
2. I switch on the welcome-email webhook and remove direct inserts.
3. Turnstile: you add the widget and send me the secret key. I build `join-waitlist`, then you
   switch the call to it.
