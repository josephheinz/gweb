import std;
import net.http;
import gweb;
import gweb.site.errors;

struct Props { n: i64 }

// A 4xx from gweb::fail: the error page, and in dev no overlay (1.6).
fn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    gweb::fail(ctx, 404, "That page is in the trash.");
    return Props { n: 0 };
}
