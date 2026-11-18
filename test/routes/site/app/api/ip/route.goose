import std;
import net.http;
import gweb;
import gweb.auth.rate;

// The client address, and a per-address limit of 2 a minute.
fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    if !gweb::rate_limit(req, ctx, res, "ip", 2, 60) { return; }
    var ip: u8[>..] = [];
    gweb::client_ip(req, ctx, ip);
    http::text(res, http::Status.Ok, "");
    format(res.body, "ip=", ip);
}
