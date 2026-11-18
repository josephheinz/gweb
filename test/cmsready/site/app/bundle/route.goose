import std;
import net.http;
import gweb;
import gweb.http.files;
import gweb.http.stream;
import cms.store;

// /bundle: a download built while it is sent (1.6), as a backup tar would be: a line per file, then its bytes.
fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    res.content_type.append("application/octet-stream");
    http::set_header(res, "Content-Disposition", "attachment; filename=\"bundle.bin\"");
    var s = gweb::stream_begin(req, ctx, res);
    if !s.ok { return; }
    for rel in ["m1/up.txt", "m1/big.bin", "m1/missing.txt"] {
        var line: u8[>..] = [];
        format(line, rel, " ", gweb::file_size(cms::MEDIA, rel), "\n");
        if !gweb::stream_write(s, line) { return; }
        if gweb::file_size(cms::MEDIA, rel) >= 0 && gweb::stream_file(s, cms::MEDIA, rel) < 0 { return; }
    }
    gweb::stream_end(ctx, s);
}
