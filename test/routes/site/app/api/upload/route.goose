import std;
import net.http;
import gweb;
import gweb.forms.form;
import gweb.forms.upload;
import gweb.forms.valid;

// A multipart post: the title field and the file's name, size and sniffed type.
fn POST(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    var title: u8[>..] = [];
    gweb::form(req, "title", title);
    var up = gweb::Upload { field: "", filename: "", content_type: "", size: 0, path: "" };
    var errs = gweb::FieldErrors { .. };
    if !gweb::form_upload(ctx, "file", up, errs, true) { http::text(res, http::Status.Other { code: 422 }, "no file"); return; }
    http::text(res, http::Status.Ok, "");
    format(res.body, "title=", title, " name=", up.filename, " size=", up.size, " type=", gweb::sniff(up));
}
