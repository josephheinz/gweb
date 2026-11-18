import std;
import net.http;
import gweb;

// The package's middleware does not run for this route; the app's does (1.6).
const MIDDLEWARE = false;

fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) { http::text(res, http::Status.Ok, "healthy"); }
