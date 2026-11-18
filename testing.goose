// Part of gweb. Import with `import gweb.testing;`.

namespace gweb;

import std;
import net;
import net.http;
import gweb;

let TEST_CSRF = "00000000000000000000000000000000";
let FORM_HEX = "0123456789ABCDEF";

// headers: extra lines for the next request only. cookies: the jar, "name=value; name=value". host: the Host header of
// every request ("test"), for an app that serves several hosts. client_ip: the peer address gweb::client_ip reports
// ("": none, as before 1.6). trust_proxy: as GWEB_TRUST_PROXY, so an X-Forwarded-For in headers is the client.
// mails: the messages mail_send logged (1.8), each whole, appended; cut when full. upload_dir: where a multipart request's files go (1.6), emptied by each gweb test run.
struct Tester { failures: i64 = 0, checks: i64 = 0, name: u8[..128] = "",
                auto_csrf: bool = true, headers: u8[..2048] = "",
                cookies: u8[..4096] = "", host: u8[..128] = "test",
                client_ip: u8[..64] = "", trust_proxy: bool = false, upload_dir: u8[..256] = ".gweb.test/uploads", mails: u8[..16384] = "" }

// Moves the messages mail_send logged since the last call into t.mails; each request and each test does it, so call it
// after a mail_send of your own.
fn take_mails(t: Tester&) {
    let room = t.mails.cap - t.mails.len;
    t.mails.append(_mail_out[..min(_mail_out.len, room)]);
    _mail_out.clear();
}

// The boundary of gweb::multipart_field and multipart_file, which site::post_multipart closes.
let TEST_BOUNDARY = "gweb-test-boundary-7d1f";

// Appends a text part to a multipart body for site::post_multipart.
fn multipart_field(out: u8[>..]&, name: const u8[:], value: const u8[:]) {
    format(out, "--", TEST_BOUNDARY, "\r\nContent-Disposition: form-data; name=\"", name, "\"\r\n\r\n", value, "\r\n");
}

// Appends a file part to a multipart body for site::post_multipart.
fn multipart_file(out: u8[>..]&, name: const u8[:], filename: const u8[:], content_type: const u8[:], data: const u8[:]) {
    format(out, "--", TEST_BOUNDARY, "\r\nContent-Disposition: form-data; name=\"", name, "\"; filename=\"", filename, "\"\r\n");
    format(out, "Content-Type: ", content_type, "\r\n\r\n");
    out.append(data);
    out.append("\r\n");
}

// Sends parts (multipart_field, multipart_file) as multipart/form-data; called by the generated site::post_multipart.
fn _test_multipart<D, S>(t: Tester&, target: const u8[:], parts: const u8[:]) -> http::Response {
    var body: u8[>..] = [];
    body.append(parts);
    format(body, "--", TEST_BOUNDARY, "--\r\n");
    var ct: u8[>..] = [];
    format(ct, "multipart/form-data; boundary=", TEST_BOUNDARY);
    return _test_send(t, "POST", target, body, ct, D, S);
}

// The value of a jar cookie; "" when absent.
fn _jar_get(t: const Tester&, name: const u8[:]) -> const u8[:], bool {
    var i = 0;
    while i <= t.cookies.len {
        var j = i;
        while j < t.cookies.len && t.cookies[j] != ';' { j += 1; }
        let key, value, has = split_once(trim(t.cookies[i..j]), '=');
        if has && key == name { return value, true; }
        i = j + 1;
    }
    return "", false;
}

// Drops name from the jar, then adds name=value when keep is set.
fn _jar_put(t: Tester&, name: const u8[:], value: const u8[:], keep: bool) {
    var out: u8[>..] = [];
    var i = 0;
    while i <= t.cookies.len {
        var j = i;
        while j < t.cookies.len && t.cookies[j] != ';' { j += 1; }
        let ent = trim(t.cookies[i..j]);
        let key, rest, has = split_once(ent, '=');
        if ent.len > 0 && !(has && key == name) {
            if out.len > 0 { out.append("; "); }
            out.append(ent);
        }
        i = j + 1;
    }
    if keep {
        if out.len > 0 { out.append("; "); }
        format(out, name, "=", value);
    }
    if out.len > t.cookies.cap { return; }
    t.cookies.clear();
    t.cookies.append(out);
}

// True when attrs holds Max-Age=0 and not Max-Age=0<digit>.
fn _max_age_zero(attrs: const u8[:]) -> bool {
    let i = find(attrs, "Max-Age=0");
    if i < 0 { return false; }
    let end = i + 9;
    return end >= attrs.len || attrs[end] < '0' || attrs[end] > '9';
}

fn _jar_update(t: Tester&, headers: const u8[:]) {
    var i = 0;
    while i < headers.len {
        var j = i;
        while j < headers.len && headers[j] != '\n' { j += 1; }
        let line = trim(headers[i..j]);
        i = j + 1;
        if line.len < 11 || !http::eq_nocase(line[..11], "set-cookie:") { continue; }
        let rest = trim(line[11..]);
        let pair, attrs, has_attrs = split_once(rest, ';');
        let first = if has_attrs { pair } else { rest };
        let name, value, has = split_once(first, '=');
        if !has || name.len == 0 { continue; }
        _jar_put(t, name, value, !(has_attrs && _max_age_zero(attrs)));
    }
}

// Runs one request through the app's dispatcher (D) and static files (S), with no socket.
fn _test_send<D, S>(t: Tester&, method: const u8[:], target: const u8[:], body: const u8[:], content_type: const u8[:]) -> http::Response {
    if t.auto_csrf && method != "GET" {
        let have, has = _jar_get(t, "gw_csrf");
        if !has { _jar_put(t, "gw_csrf", TEST_CSRF, true); }
    }
    var raw: u8[>..] = [];
    format(raw, method, " ", target, " HTTP/1.1\r\nHost: ", t.host, "\r\n");
    if t.cookies.len > 0 { format(raw, "Cookie: ", t.cookies, "\r\n"); }
    if t.auto_csrf && method != "GET" {
        let tok, has = _jar_get(t, "gw_csrf");
        if has { format(raw, "X-CSRF-Token: ", tok, "\r\n"); }
    }
    if body.len > 0 { format(raw, "Content-Type: ", content_type, "\r\nContent-Length: ", body.len, "\r\n"); }
    if t.headers.len > 0 {
        raw.append(t.headers);
        if raw[raw.len - 1] != '\n' { raw.append("\r\n"); }
        t.headers.clear();
    }
    raw.append("\r\n");
    raw.append(body);

    _quiet_client_errors = true;
    _mail_capture = true;
    var res = http::new_response();
    // req points into raw, so raw stays alive until the reply is built
    let req, parsed = http::parse_request(raw);
    match parsed {
        Ready => {},
        _ => {
            expect(t, false, "test request did not parse");
            http::json_error(res, http::Status.BadRequest, "test request did not parse");
            return res;
        },
    }
    var cfg = _default_config();
    cfg.workers = 1;
    cfg.auth.trust_proxy = t.trust_proxy;
    var key_err: u8[>..] = [];
    if !_dev_secret(cfg.auth.keys, key_err) { expect(t, false, key_err); }   // sessions work in tests, as in gweb dev
    var ctx = _new_ctx(0, -1);
    ctx._peer.append(t.client_ip);
    // As run_worker: uploads go to t.upload_dir, with the server's limits, and the unsaved ones are deleted after the reply.
    if _is_multipart(req) && t.upload_dir.len > 0 && c_up_mkdir(t.upload_dir) != 0 { ctx.upload_dir.append(t.upload_dir); }
    ctx.upload_parts = cfg.upload_parts;
    ctx.upload_files = min(cfg.upload_files, ctx.uploads.cap);
    ctx.upload_text = cfg.upload_text;
    // As run_worker: a body over --max-upload (multipart) or --max-body reaches the app as ctx.too_large.
    let limit = if _is_multipart(req) { cfg.max_upload } else { cfg.max_body };
    if body.len > limit { ctx.too_large = limit; }
    let static_index, dev = _respond(req, ctx, -1, cfg, res, D);
    if static_index >= 0 { res.body.append(S(static_index)); }
    if req.method == http::Method.Head { res.body.clear(); }
    for i in ctx.uploads.len { if ctx.uploads[i].path.len > 0 { c_up_unlink(ctx.uploads[i].path); } }
    _jar_update(t, res.headers);
    take_mails(t);
    return res;
}

fn expect(t: Tester&, ok: bool, what: const u8[:]) {
    t.checks += 1;
    if !ok {
        t.failures += 1;
        print("FAIL ", t.name, ": ", what);
    }
}

// Text equality that shows both values on failure: "what: got 'a', want 'b'" (1.6).
fn expect_eq(t: Tester&, got: const u8[:], want: const u8[:], what: const u8[:]) {
    var msg: u8[>..] = [];
    format(msg, what, ": got '", got, "', want '", want, "'");
    expect(t, got == want, msg);
}

// Number equality, as expect_eq for text.
fn expect_eq(t: Tester&, got: i64, want: i64, what: const u8[:]) {
    var msg: u8[>..] = [];
    format(msg, what, ": got ", got, ", want ", want);
    expect(t, got == want, msg);
}

fn expect_status(t: Tester&, res: const http::Response&, code: i64) {
    var msg: u8[..64] = "";
    format(msg, "status ", http::code(res.status), ", want ", code);
    expect(t, http::code(res.status) == code, msg);
}

fn expect_contains(t: Tester&, text: const u8[:], needle: const u8[:]) {
    var msg: u8[>..] = [];
    format(msg, "'", text, "' lacks '", needle, "'");
    expect(t, find(text, needle) >= 0, msg);
}

// The opposite of expect_contains (1.7).
fn expect_not_contains(t: Tester&, text: const u8[:], needle: const u8[:]) {
    var msg: u8[>..] = [];
    format(msg, "'", text, "' has '", needle, "'");
    expect(t, find(text, needle) < 0, msg);
}

// No header with this name (case-insensitive), as for a reply that must not set a cookie (1.7).
fn expect_no_header(t: Tester&, res: const http::Response&, name: const u8[:]) {
    let got, has = header_of(res, name);
    var msg: u8[>..] = [];
    format(msg, "header ", name, " is '", got, "', want none");
    expect(t, !has, msg);
}

fn expect_header(t: Tester&, res: const http::Response&, name: const u8[:], value: const u8[:]) {
    let got, has = header_of(res, name);
    var msg: u8[>..] = [];
    format(msg, "header ", name, " is '", got, "', want '", value, "'");
    expect(t, has && got == value, msg);
}

// The first header with this name (case-insensitive); has is false when absent.
// Content-Type lives in res.content_type, not res.headers.
fn header_of(res: const http::Response&, name: const u8[:]) -> const u8[:], bool {
    if http::eq_nocase(name, "content-type") { return res.content_type, res.content_type.len > 0; }
    let v, has = http::find_header(res.headers, name);
    return v, has;
}

// Appends &name=value, URL-encoded (no leading & when out is empty).
fn form_field(out: u8[>..]&, name: const u8[:], value: const u8[:]) {
    if out.len > 0 { out.push('&'); }
    form_encode(out, name);
    out.push('=');
    form_encode(out, value);
}

fn form_encode(out: u8[>..]&, s: const u8[:]) {
    for c in s {
        if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' || c == '~' {
            out.push(c);
        } else {
            out.push('%');
            out.push(FORM_HEX[c >> 4]);
            out.push(FORM_HEX[c & 15]);
        }
    }
}
