import std;
import net.http;
import gweb;
import gweb.testing;

// http::set_header(res, "Content-Type", ...) replaces the type, not adds a second (1.8).
fn test_set_header_content_type(t: gweb::Tester&) {
    let res = site::get(t, "/api/typed?kind=header");
    gweb::expect_status(t, res, 200);
    gweb::expect_header(t, res, "Content-Type", "text/csv; charset=utf-8");
    gweb::expect_header(t, res, "X-Rows", "1");
    gweb::expect_eq(t, find(res.headers, "text/plain"), -1, "no default type left");
    gweb::expect_eq(t, count_of(res.headers, "ontent-type:") + count_of(res.headers, "ontent-Type:"), 0, "no Content-Type line in headers");
    let twice = site::get(t, "/api/typed?kind=twice");
    gweb::expect_header(t, twice, "Content-Type", "application/xml");
}

fn test_reply_helper(t: gweb::Tester&) {
    let res = site::get(t, "/api/typed");
    gweb::expect_status(t, res, 200);
    gweb::expect_header(t, res, "Content-Type", "application/rss+xml; charset=utf-8");
    gweb::expect_eq(t, res.body, "<rss/>", "the body");
}

fn count_of(text: const u8[:], needle: const u8[:]) -> i64 {
    var n = 0;
    var i = 0;
    while i < text.len {
        let at = find(text[i..], needle);
        if at < 0 { break; }
        n += 1;
        i += at + needle.len;
    }
    return n;
}
