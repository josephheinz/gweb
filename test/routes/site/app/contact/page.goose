import std;
import net.http;
import gweb;

// The form, and so the CSRF token, only with ?form=1: as a catch-all page that has one form type among many.
struct Props { form: bool }

fn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    var v: u8[>..] = [];
    return Props { form: gweb::query(req, "form", v) && v == "1" };
}

fn POST(req: const http::Request&, ctx: gweb::Ctx&) -> Props { return Props { form: true }; }
