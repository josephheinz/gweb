import net.http;
import gweb;

// Refuses everything under the mount, as a login check would.
fn before(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) -> bool {
    http::text(res, http::Status.Forbidden, "package middleware");
    return false;
}
