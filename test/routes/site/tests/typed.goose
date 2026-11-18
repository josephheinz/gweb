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

fn test_redirect_body(t: gweb::Tester&) {
    let bare = site::get(t, "/api/moved");
    gweb::expect_status(t, bare, 301);
    gweb::expect_header(t, bare, "Location", "/api/hello");
    gweb::expect_eq(t, bare.body, "", "no body");
    gweb::expect_no_header(t, bare, "Content-Type");
    let with = site::get(t, "/api/moved?body=1");
    gweb::expect_status(t, with, 301);
    gweb::expect_header(t, with, "Location", "/api/hello");
    gweb::expect_header(t, with, "Content-Type", "text/html; charset=utf-8");
    gweb::expect_contains(t, with.body, "<a href=\"/api/hello\">");
}

// What a temporary can go to (1.8): text (`.body`, `.headers`, `.content_type` of a reply) and a status code. A whole reply
// cannot (goose binds no temporary to a const&): keep it in a variable, in a block if the name is in the way.
fn test_expect_temporaries(t: gweb::Tester&) {
    gweb::expect_contains(t, site::get(t, "/api/typed").body, "<rss/>");
    gweb::expect_eq(t, site::get(t, "/api/typed").content_type, "application/rss+xml; charset=utf-8", "the type");
    gweb::expect_eq(t, http::code(site::get(t, "/api/typed").status), 200, "http::code of a status");
    { let r = site::get(t, "/api/typed"); gweb::expect_status(t, r, 200); }
    // a 4xx the handler answers is not logged as an error (see the run's output)
    { let r = site::post_form(t, "/api/upload", ""); gweb::expect_status(t, r, 422); }
}
