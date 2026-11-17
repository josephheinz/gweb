import std;
import net.http;
import gweb;
import gweb.testing;

// gweb test applies the server's body limits: a body over --max-body reaches the page as ctx.too_large.
fn test_too_large_page(t: gweb::Tester&) {
    var body: u8[>..] = [];
    for i in 1100000 { body.push('a'); }
    t.headers.append("Accept: text/html");
    let res = site::post_form(t, "/files", body);
    gweb::expect_status(t, res, 413);
    gweb::expect_contains(t, res.body, "<h1 id=\"files-error\">413: This request is too large. The limit is 1 MiB.</h1>");
}

fn test_too_large_hook(t: gweb::Tester&) {
    var body: u8[>..] = [];
    for i in 300000 { body.push('a'); }
    let res = site::request(t, "POST", "/files/hooked", body, "multipart/form-data; boundary=zz");
    gweb::expect_status(t, res, 303);
    gweb::expect_header(t, res, "location", "/files/hooked?ue=Files+can+be+at+most+195.3+KiB");
}
