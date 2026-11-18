import std;
import net.http;
import gweb;

// A public/ file read from server code (1.6).
fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    var data: u8[>..] = [];
    let ok = gweb::public_file("/hello.txt", data);
    var none: u8[>..] = [];
    let missing = gweb::public_file("/nope.txt", none);
    http::text(res, http::Status.Ok, "");
    format(res.body, "ok=", ok, " missing=", missing, " ", data);
}
