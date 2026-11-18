import std;
import net.http;
import gweb;
import gweb.testing;

// t.client_ip is the peer address (1.6); "" by default, as before. The Tester is shared by every test of a run.
fn test_client_ip(t: gweb::Tester&) {
    gweb::expect_contains(t, site::get(t, "/api/ip").body, "ip=");
    t.client_ip.append("192.0.2.7");
    let res = site::get(t, "/api/ip");
    gweb::expect_status(t, res, 200);
    gweb::expect_contains(t, res.body, "ip=192.0.2.7");
    gweb::expect_eq(t, res.body, "ip=192.0.2.7", "gweb::expect_eq of text");
    gweb::expect_eq(t, http::code(res.status), 200, "gweb::expect_eq of numbers");
}

// A per-address limit: each address has its own bucket.
fn test_rate_limit_per_address(t: gweb::Tester&) {
    t.client_ip.clear();
    t.client_ip.append("192.0.2.8");
    let a = site::get(t, "/api/ip");
    let b = site::get(t, "/api/ip");
    let c = site::get(t, "/api/ip");
    gweb::expect_status(t, a, 200);
    gweb::expect_status(t, b, 200);
    gweb::expect_status(t, c, 429);
    t.client_ip.clear();
    t.client_ip.append("192.0.2.9");
    let d = site::get(t, "/api/ip");
    gweb::expect_status(t, d, 200);
}

// t.trust_proxy: the last X-Forwarded-For item is the client, as behind a proxy with GWEB_TRUST_PROXY.
fn test_trust_proxy(t: gweb::Tester&) {
    t.client_ip.clear();
    t.client_ip.append("10.0.0.1");
    t.headers.append("X-Forwarded-For: 198.51.100.1, 198.51.100.2\r\n");
    gweb::expect_contains(t, site::get(t, "/api/ip").body, "ip=10.0.0.1");
    t.trust_proxy = true;
    t.headers.append("X-Forwarded-For: 198.51.100.1, 198.51.100.2\r\n");
    gweb::expect_contains(t, site::get(t, "/api/ip").body, "ip=198.51.100.2");
}

// site::post_multipart: the file goes to t.upload_dir and is deleted after the reply.
fn test_upload(t: gweb::Tester&) {
    t.client_ip.clear();
    t.trust_proxy = false;
    var parts: u8[>..] = [];
    gweb::multipart_field(parts, "title", "Logo");
    gweb::multipart_file(parts, "file", "logo.png", "image/png", "\x89PNG\r\n\x1a\n0123");
    let res = site::post_multipart(t, "/api/upload", parts);
    gweb::expect_status(t, res, 200);
    gweb::expect_contains(t, res.body, "title=Logo name=logo.png size=12 type=image/png");
    var none: u8[>..] = [];
    gweb::multipart_field(none, "title", "x");
    let r2 = site::post_multipart(t, "/api/upload", none);
    gweb::expect_status(t, r2, 422);
}
