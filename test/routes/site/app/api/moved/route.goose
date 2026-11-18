import std;
import net.http;
import gweb;

// gweb::redirect keeps a body and Content-Type the handler wrote (1.8), and with none sends neither.
fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    if req.query == "body=1" {
        gweb::html(res, http::Status.Ok);
        res.body.append("<a href=\"/api/hello\">moved</a>");
    }
    gweb::redirect(ctx, "/api/hello", 301);
}
