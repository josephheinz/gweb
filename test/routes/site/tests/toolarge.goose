import std;
import net.http;
import gweb;
import gweb.testing;

// A form post over --max-body from a client with no Accept (curl's `*/*`, a bare script) gets the HTML page; a
// request that asks for JSON, or sends fetch's header, gets JSON (1.8).
fn test_too_large_form_is_html(t: gweb::Tester&) {
    var big: u8[>..] = [];
    gweb::form_field(big, "title", "x");
    big.push('&');
    big.append("pad=");
    for i in 1100000 { big.push('a'); }
    let res = site::post_form(t, "/api/upload", big);
    gweb::expect_status(t, res, 413);
    gweb::expect_contains(t, res.content_type, "text/html");
    t.headers.append("Accept: application/json\r\n");
    let j = site::post_form(t, "/api/upload", big);
    gweb::expect_status(t, j, 413);
    gweb::expect_contains(t, j.content_type, "application/json");
    t.headers.append("X-Requested-With: fetch\r\n");
    let x = site::post_form(t, "/api/upload", big);
    gweb::expect_contains(t, x.content_type, "application/json");
}
