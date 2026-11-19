// Part of gweb. Import with `import gweb.auth.csrf;`.

namespace gweb;

import std;
import net;
import net.http;
import gweb;
import forms.form;

const CSRF_LEN = 32;
let CSRF_HEX = "0123456789abcdef";

// "__Host-gw_csrf" behind an HTTPS proxy, else "gw_csrf". X-Forwarded-Proto is read only when trust is true
// (GWEB_TRUST_PROXY): a client can send that header itself.
fn _csrf_cookie_name(req: const http::Request&, trust: bool) -> const u8[:] {
    return if _forwarded_https(req, trust) { "__Host-gw_csrf" } else { "gw_csrf" };
}

// True when trust is on and the request says X-Forwarded-Proto: https.
fn _forwarded_https(req: const http::Request&, trust: bool) -> bool {
    if !trust { return false; }
    let proto, has = http::header(req, "x-forwarded-proto");
    return has && trim(proto) == "https";
}

// Exactly 32 lowercase hex digits.
fn _csrf_valid(t: const u8[:]) -> bool {
    if t.len != CSRF_LEN { return false; }
    for c in t { if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) { return false; } }
    return true;
}

// Puts the request's token, or a new one, in ctx.csrf without starting it (1.7). The generated page, not-found
// and error replies call this before load; _csrf_end starts the token only when the reply body shows it.
// False when no entropy is available. Does nothing when a token is already there.
fn _csrf_arm(req: const http::Request&, ctx: Ctx&) -> bool {
    if ctx.csrf.len > 0 { return true; }
    let name = _csrf_cookie_name(req, ctx.auth.trust_proxy);
    ctx._csrf_host = starts_with(name, "__Host-");
    let sent, has = http::cookie(req, name);
    if has && _csrf_valid(sent) {
        ctx.csrf.append(sent);
        ctx._csrf_new = false;
        ctx._csrf_armed = true;
        return true;
    }
    var raw: u8[..16] = [0; 16];
    if c_entropy(raw) == 0 { return false; }
    for b in raw {
        ctx.csrf.push(CSRF_HEX[(b >> 4) as i64]);
        ctx.csrf.push(CSRF_HEX[(b & 15) as i64]);
    }
    ctx._csrf_new = true;
    ctx._csrf_armed = true;
    return true;
}

// Starts the token now: reuses the request's or makes one, sets its cookie when new and Cache-Control: no-store,
// whatever the page then renders. False after writing a 500.
fn csrf_begin(req: const http::Request&, ctx: Ctx&, res: http::Response&) -> bool {
    no_store(res);
    if ctx.csrf.len > 0 && !ctx._csrf_armed { return true; }
    if _csrf_arm(req, ctx) && _csrf_commit(ctx) { return true; }
    ctx.csrf.clear();
    ctx._csrf_armed = false;
    http::json_error(res, http::Status.InternalServerError, "csrf token unavailable");
    return false;
}

// Compares without an early exit, so timing does not tell how many bytes matched.
fn _token_equal(a: const u8[:], b: const u8[:]) -> bool {
    if a.len != CSRF_LEN || b.len != CSRF_LEN { return false; }
    var diff = 0;
    for i in CSRF_LEN { diff |= a[i] ^ b[i]; }
    return diff == 0;
}

// True for GET, HEAD, OPTIONS and Other; for the rest, false after writing a 403.
// A present X-CSRF-Token header is the only token read; otherwise the _csrf field of the body.
fn _csrf_ok(req: const http::Request&, ctx: const Ctx&, res: http::Response&) -> bool {
    return _csrf_check(req, ctx, res, false);
}

// For a page whose page.goose says `const CSRF_PUBLIC = true;`: as _csrf_ok, and a post may instead carry the public form
// token: the field _csrf_pub equal to the cookie gw_csrf_pub (__Host-gw_csrf_pub behind an https proxy), a cookie of its own
// that never replaces gw_csrf. For a form on a cacheable page, written without JavaScript (cms::form_csrf); no route or page
// takes it unless it says so.
fn _csrf_ok_public(req: const http::Request&, ctx: const Ctx&, res: http::Response&) -> bool {
    return _csrf_check(req, ctx, res, true);
}

fn _csrf_check(req: const http::Request&, ctx: const Ctx&, res: http::Response&, public: bool) -> bool {
    let m = req.method;
    if m == http::Method.Get || m == http::Method.Head || m == http::Method.Options || m == http::Method.Other { return true; }

    let site, has_site = http::header(req, "sec-fetch-site");
    if has_site && trim(site) != "same-origin" && trim(site) != "none" {
        http::text(res, http::Status.Forbidden, "cross-site request refused\n");
        return false;
    }

    let cookie, has_cookie = http::cookie(req, _csrf_cookie_name(req, ctx.auth.trust_proxy));
    var sent: u8[>..] = [];
    let head, has_head = http::header(req, "x-csrf-token");
    if has_head { sent.append(trim(head)); } else { form(req, "_csrf", sent); }
    if has_cookie && _csrf_valid(cookie) && _token_equal(cookie, sent) { return true; }
    if public && !has_head {
        var pname: u8[>..] = [];
        pname.append(_csrf_cookie_name(req, ctx.auth.trust_proxy));
        pname.append("_pub");
        let pc, has_pc = http::cookie(req, pname);
        var ps: u8[>..] = [];
        form(req, "_csrf_pub", ps);
        if has_pc && _csrf_valid(pc) && _token_equal(pc, ps) { return true; }
    }
    http::text(res, http::Status.Forbidden, "CSRF token missing or wrong; reload the page and try again\n");
    return false;
}

// For an anonymous form on a cacheable page (1.8.1): the route says `const CSRF = false;` and calls this first. The page
// then shows no token, so it stays cacheable and sets no cookie. True for a safe method. For the rest it wants a browser
// that says the request is from this site: Sec-Fetch-Site same-origin, else an Origin (or, with none, a Referer) whose
// host is the request's Host. Anything else, a missing header included, is a 403 and false. Use it only where a forged
// post does no harm beyond what any visitor could do (a vote, a signup, a message): it is not a login check. Pair it with
// gweb::rate_limit.
fn origin_ok(req: const http::Request&, ctx: const Ctx&, res: http::Response&) -> bool {
    let m = req.method;
    if m == http::Method.Get || m == http::Method.Head || m == http::Method.Options || m == http::Method.Other { return true; }
    let site, has_site = http::header(req, "sec-fetch-site");
    if has_site { if trim(site) == "same-origin" { return true; } }
    else {
        var host: u8[>..] = [];
        let fh, has_fh = http::header(req, "x-forwarded-host");
        let h, has_h = http::header(req, "host");
        if ctx.auth.trust_proxy && has_fh { host.append(trim(fh)); } else if has_h { host.append(trim(h)); }
        let o, has_o = http::header(req, "origin");
        var got = has_o;
        var ref: u8[>..] = [];
        if got { ref.append(trim(o)); }
        else {
            let r, has_r = http::header(req, "referer");
            if has_r { ref.append(trim(r)); got = true; }
        }
        if got && host.len > 0 {
            let sch = find(ref, "://");
            if sch > 0 {
                let rest = ref[sch + 3..];
                var end = 0;
                while end < rest.len && rest[end] != '/' && rest[end] != '?' && rest[end] != '#' { end += 1; }
                if http::eq_nocase(rest[..end], host) { return true; }
            }
        }
    }
    http::text(res, http::Status.Forbidden, "cross-site request refused\n");
    return false;
}
