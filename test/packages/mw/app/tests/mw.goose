import std;
import net.http;
import gweb;
import gweb.testing;

fn test_middleware_off(t: gweb::Tester&) {
    let h = site::get(t, "/admin/health");
    gweb::expect_status(t, h, 200);
    gweb::expect_header(t, h, "x-app", "1");
    let u = site::get(t, "/admin/users");
    gweb::expect_status(t, u, 403);
}
