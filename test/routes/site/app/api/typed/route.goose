import std;
import net.http;
import gweb;

// A reply of another type, three ways (1.8): http::set_header replaces the Content-Type, gweb::reply sets type, status
// and body, and a header set twice leaves one.
fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    if req.query == "kind=header" {
        http::set_header(res, "content-type", "text/csv; charset=utf-8");
        http::set_header(res, "X-Rows", "1");
        res.body.append("a,b\n1,2\n");
    } else if req.query == "kind=twice" {
        http::set_header(res, "Content-Type", "text/csv");
        http::set_header(res, "Content-Type", "application/xml");
        res.body.append("<a/>");
    } else {
        gweb::reply(res, http::Status.Ok, "application/rss+xml; charset=utf-8", "<rss/>");
    }
}
