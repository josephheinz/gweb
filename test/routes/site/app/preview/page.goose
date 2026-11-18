import std;
import net.http;
import gweb;

struct Props { ok: bool }

// A load that takes res may set headers and still render (goose-cms ask 7: a preview is no-store).
fn load(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) -> Props {
    http::set_header(res, "Cache-Control", "no-store");
    return Props { ok: true };
}
