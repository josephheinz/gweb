import std;
import net.http;
import gweb;
import gweb.testing;

// 1.7: the token is started only when the reply shows it, so a page without a form stays cacheable and sets no cookie.
fn test_no_form_no_cookie(t: gweb::Tester&) {
    t.cookies.clear();
    let res = site::get(t, "/contact");
    gweb::expect_status(t, res, 200);
    gweb::expect_not_contains(t, res.body, "_csrf");
    gweb::expect_no_header(t, res, "set-cookie");
    gweb::expect_no_header(t, res, "cache-control");
}

fn test_form_starts_token(t: gweb::Tester&) {
    t.cookies.clear();
    let res = site::get(t, "/contact?form=1");
    gweb::expect_contains(t, res.body, "name=\"_csrf\" value=\"");
    gweb::expect_header(t, res, "cache-control", "no-store");
    let c, has = gweb::header_of(res, "set-cookie");
    gweb::expect(t, has && starts_with(c, "gw_csrf=") && c.len > 40, "a gw_csrf cookie");
    if c.len <= 40 { return; }
    let tok = c[8..40];
    gweb::expect_contains(t, res.body, tok);
    // The browser has the cookie now: the next form reuses it, with no new cookie, and is still not cached.
    let again = site::get(t, "/contact?form=1");
    gweb::expect_no_header(t, again, "set-cookie");
    gweb::expect_header(t, again, "cache-control", "no-store");
    gweb::expect_contains(t, again.body, tok);
}

// A POST is checked whatever the GET rendered: no token, 403.
fn test_post_checked_without_form(t: gweb::Tester&) {
    t.cookies.clear();
    site::get(t, "/contact");
    t.auto_csrf = false;
    let res = site::post_form(t, "/contact", "x=1");
    t.auto_csrf = true;
    gweb::expect_status(t, res, 403);
}
