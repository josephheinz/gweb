import std;
import net.http;
import gweb;
import gweb.testing;

// A form post over --max-body: the HTML page for Accept: text/html (a browser), JSON for curl's and fetch's `*/*` (1.8).
fn test_too_large_form_is_html(t: gweb::Tester&) {
    var big: u8[>..] = [];
    gweb::form_field(big, "title", "x");
    big.append("&pad=");
    for i in 1100000 { big.push('a'); }
    t.headers.append("Accept: text/html,application/xhtml+xml\r\n");
    let res = site::post_form(t, "/api/upload", big);
    gweb::expect_status(t, res, 413);
    gweb::expect_contains(t, res.content_type, "text/html");
    t.headers.append("Accept: */*\r\n");
    let j = site::post_form(t, "/api/upload", big);
    gweb::expect_status(t, j, 413);
    gweb::expect_contains(t, j.content_type, "application/json");
}
