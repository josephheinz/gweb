# Forms and CSRF

Every page `fn POST` and every `route.goose` with `POST`, `PUT`, `PATCH` or
`DELETE` checks a CSRF token. A request without it gets 403.

```html
<form method="post" action="/notes">
  @gweb::csrf_field(ctx)
  <input name="text">
  <button>Add</button>
</form>
```

```goose
var text: u8[>..] = [];
gweb::form(req, "text", text);        // import gweb.forms.form;
```

A script sends the token in a header instead:

```html
<meta name="csrf-token" content="{gweb::csrf_token(ctx)}">
```

It sends that value as `X-CSRF-Token`.

## Rules

- The token is a cookie, `gw_csrf`, with the same value in a hidden `_csrf`
  field. `_csrf` is a reserved field name.
- The token starts (cookie and `Cache-Control: no-store`) only on a reply
  whose body shows it, wherever the field was written. A page that rendered
  no form this time sends neither, so it can be cached (1.7).
  `gweb::csrf_begin(req, ctx, res)` starts it at once, for a token used
  outside the body.
- Every page `fn POST` and unsafe route method checks the token, whether or
  not the page's GET rendered a form.
- A form with `gw-target` sends its hidden field with the fragment POST.
- A bad token gets 403. A request with `Sec-Fetch-Site` other than
  `same-origin` or `none` gets 403 too.
- A page whose `page.goose` says `const CSRF_PUBLIC = true;` also takes a public form token for its POST: the field `_csrf_pub` equal to the cookie `gw_csrf_pub` (`__Host-` behind an https proxy), a cookie of its own that never replaces `gw_csrf`. It is for a form on a cacheable page without JavaScript (goose-cms `@cms::form_csrf`) where a forged post harms nobody; no other page or route takes it.
- A route opts out with `const CSRF = false;` on a line of its own. Use it
  for APIs called by clients that are not browsers, and for webhooks. Such a
  route must not trust cookies. Pages cannot opt out.
- Behind a proxy that sends `X-Forwarded-Proto: https` the cookie is
  `__Host-gw_csrf` with `Secure`.

Full reference: [README](../../README.md#csrf).
