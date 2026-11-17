import std;
import net.http;
import gweb;

const MAX_UPLOAD = 200000;

struct Props { ue: u8[..200] }

fn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    var p = Props { ue: "" };
    var ue: u8[>..] = [];
    gweb::query(req, "ue", ue);
    p.ue.append(ue[..min(ue.len, 200)]);
    return p;
}

fn POST(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    gweb::redirect(ctx, "/thanks", 303);
    return load(req, ctx);
}

// A body over MAX_UPLOAD or --max-upload: back to the form, keeping its query, with the limit in ue.
fn too_large(req: const http::Request&, ctx: gweb::Ctx&, limit: i64) {
    var to: u8[>..] = [];
    format(to, req.path, "?", req.query, if req.query.len > 0 { "&" } else { "" }, "ue=Files+can+be+at+most+");
    var size: u8[>..] = [];
    gweb::size_text(size, limit);
    for c in size { if c == ' ' { to.push('+'); } else { to.push(c); } }
    gweb::redirect(ctx, to, 303);
}
