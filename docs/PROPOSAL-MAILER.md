# Proposal: a minimal mailer

Status: proposal (blind developer review, contact form step). Not implemented.

## Problem

A contact form or a signup wants to send one email. gweb has no mailer, so an app logs from a job and stops there, or
shells out. The two needs are a dev transport that shows the message without sending it, and SMTP for production.

## Why not now

goose-net has `net::connect` but no TLS. SMTP to a provider needs STARTTLS (port 587) or implicit TLS (465), and
`AUTH` over plain TCP would send the password in clear. A plain-TCP SMTP client is only safe to a relay on the same
host or a private network (a local Postfix, a sidecar). Shipping that as "SMTP" invites the unsafe setup, so this
waits for TLS in goose-net, or ships with the relay limit stated and enforced.

## Proposal

1. **API** (`import gweb.mail;`):

   ```goose
   struct Mail { to: u8[..320], from: u8[..320] = "", reply_to: u8[..320] = "",
                 subject: u8[..256], text: u8[>..], html: u8[>..] = "" }
   fn mail_send(ctx: gweb::Ctx&, m: const gweb::Mail&) -> bool   // false: refused or failed; logged with the reason
   ```

   One recipient per message: no CC or BCC in the first version. `from` defaults to `GWEB_MAIL_FROM`. Header values
   with CR or LF are refused, so a form field cannot inject headers. `html` set: `multipart/alternative` with `text`.

2. **Transports**, chosen by `GWEB_MAIL` (stable names):
   - `log` (default in `gweb dev` and `gweb test`): writes the whole message to the log at Info and returns true.
     In route tests, `t.mails` keeps the messages so a test can `expect_contains(t, t.mails, "Subject: Thanks")`.
   - `smtp://host:port`: plain SMTP (`EHLO`, `MAIL FROM`, `RCPT TO`, `DATA` with dot-stuffing, `QUIT`), with a
     5 s connect and 10 s total timeout. Allowed hosts: loopback and private addresses only, until goose-net has
     TLS; any other host exits the server with 2 at startup and says why. No `AUTH`.
   - `off`: `mail_send` returns false and logs once. The default in production when `GWEB_MAIL` is unset.

3. **Where to call it.** From a job, not the request: `jobs::enqueue(ctx, Job.Mail { .. })` then `gweb::mail_send`
   in `run`, so a slow relay does not hold a worker and a failure is retried with backoff. The README recipe shows this.

4. **Later, with TLS:** `smtps://` and `smtp+starttls://` with `GWEB_MAIL_USER` and `GWEB_MAIL_PASSWORD`
   (the password a secret, like `GWEB_SECRET`), and public hosts allowed.

## Size

About 250 lines of Goose (message builder, header checks, SMTP dialogue, the log transport), the `t.mails` jar in
`testing.goose`, and a test against a fake SMTP server in `test/` (python3 `smtpd`-style script on loopback).

## Decisions needed

- Ship the relay-only SMTP now, or wait for TLS in goose-net.
- `off` vs `log` as the production default when `GWEB_MAIL` is unset (`off` is proposed: no message bodies in
  production logs).
- Whether `mail_send` belongs in gweb or in a package (`goose-mail`) that gweb documents.
