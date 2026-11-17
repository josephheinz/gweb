import std;
import net.http;
import gweb;

// No MAX_UPLOAD and no too_large: a body over --max-upload gets gweb's 413, through files/error.html for a browser.
struct Props { ok: bool }

fn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props { Props { ok: true } }

fn POST(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    gweb::redirect(ctx, "/thanks", 303);
    return Props { ok: true };
}
