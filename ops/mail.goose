// Part of gweb. Import with `import gweb.ops.mail;`.
// One plain-text or text+HTML message to one recipient. GWEB_MAIL picks the transport: log, off, or smtp://host:port
// to a relay on loopback or a private network (no TLS and no AUTH here; see docs/DEPLOY.md).

namespace gweb;

import std;
import net;
import net.http;
import gweb;
import ops.log;
import http.files;

// to, from and reply_to are one plain address (user@host). from "" is GWEB_MAIL_FROM.
root struct Mail { to: u8[..320], from: u8[..320] = "", reply_to: u8[..320] = "", subject: u8[..256],
                   text: u8[>..], html: u8[>..] = "" }

const MAIL_CONNECT_MS = 5000;
const MAIL_TOTAL_MS = 10000;
let B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

var _mail_off_logged = false;

// ---------------------------------------------------------------- message

fn _b64_std(out: u8[>..]&, s: const u8[:]) {
    var i = 0;
    while i < s.len {
        let left = s.len - i;
        let a = s[i] as i64;
        let b = if left > 1 { s[i + 1] as i64 } else { 0 };
        let c = if left > 2 { s[i + 2] as i64 } else { 0 };
        out.push(B64[a >> 2]);
        out.push(B64[((a & 3) << 4) | (b >> 4)]);
        out.push(if left > 1 { B64[((b & 15) << 2) | (c >> 6)] } else { '=' });
        out.push(if left > 2 { B64[c & 63] } else { '=' });
        i += 3;
    }
}

fn _is_ascii(s: const u8[:]) -> bool {
    for c in s { if c >= 128 { return false; } }
    return true;
}

// CR, LF or NUL: what could end a header line or a value.
fn _has_ctl(s: const u8[:]) -> bool {
    for c in s { if c == 13 || c == 10 || c == 0 { return true; } }
    return false;
}

// A plain address: one @ with text on both sides, no space, control byte or any of <>()[],;:\"
fn _addr_ok(s: const u8[:]) -> bool {
    if s.len < 3 { return false; }
    var at = 0;
    for i in s.len {
        let c = s[i];
        if c <= ' ' || c >= 127 { return false; }
        if c == '<' || c == '>' || c == '(' || c == ')' || c == '[' || c == ']' || c == ',' || c == ';' || c == ':' || c == 92 || c == 34 { return false; }
        if c == '@' { at += 1; if i == 0 || i == s.len - 1 { return false; } }
    }
    return at == 1;
}

// Subject as an RFC 2047 encoded word list (=?utf-8?B?...?=, at most 36 bytes each, never inside a character).
fn _encode_subject(out: u8[>..]&, s: const u8[:]) {
    var i = 0;
    while i < s.len {
        var j = min(i + 36, s.len);
        while j < s.len && j > i + 1 && (s[j] & 0xC0) == 0x80 { j -= 1; }
        if i > 0 { out.append("\r\n "); }
        out.append("=?utf-8?B?");
        _b64_std(out, s[i..j]);
        out.append("?=");
        i = j;
    }
}

// s with bare LF and bare CR as CRLF, and a CRLF at the end.
fn _crlf(out: u8[>..]&, s: const u8[:]) {
    var i = 0;
    while i < s.len {
        let c = s[i];
        if c == 13 { out.append("\r\n"); if i + 1 < s.len && s[i + 1] == 10 { i += 1; } }
        else if c == 10 { out.append("\r\n"); }
        else { out.push(c); }
        i += 1;
    }
    if out.len < 2 || out[out.len - 2] != 13 || out[out.len - 1] != 10 { out.append("\r\n"); }
}

fn _short_lines(s: const u8[:]) -> bool {
    var run = 0;
    for c in s {
        if c == 10 { run = 0; } else { run += 1; if run > 998 { return false; } }
    }
    return true;
}

// Content-Transfer-Encoding and the body: 7bit when it is ASCII with lines up to 998 bytes, else base64 (76 columns).
fn _mail_body(out: u8[>..]&, s: const u8[:]) {
    var body: u8[>..] = [];
    _crlf(body, s);
    if _is_ascii(body) && _short_lines(body) && find(body, "\0") < 0 {
        out.append("Content-Transfer-Encoding: 7bit\r\n\r\n");
        out.append(body);
        return;
    }
    out.append("Content-Transfer-Encoding: base64\r\n\r\n");
    var i = 0;
    while i < body.len {
        let n = min(57, body.len - i);
        _b64_std(out, body[i..i + n]);
        out.append("\r\n");
        i += n;
    }
}

// Appends the whole message (RFC 5322, CRLF lines, ending in CRLF) at unix time now. False with err set when a header
// value has CR, LF or NUL, an address is not plain, or there is no sender. from is the default for m.from.
fn mail_build(out: u8[>..]&, m: const Mail&, from: const u8[:], now: i64, err: u8[>..]&) -> bool {
    let sender = if m.from.len > 0 { m.from[..] } else { from };
    if sender.len == 0 { err.append("no sender: set Mail.from or GWEB_MAIL_FROM"); return false; }
    if _has_ctl(sender) || _has_ctl(m.to) || _has_ctl(m.reply_to) || _has_ctl(m.subject) {
        err.append("a header value has CR, LF or NUL");
        return false;
    }
    if !_addr_ok(sender) { err.append("from is not a plain address"); return false; }
    if !_addr_ok(m.to) { err.append("to is not a plain address"); return false; }
    if m.reply_to.len > 0 && !_addr_ok(m.reply_to) { err.append("reply_to is not a plain address"); return false; }
    if m.text.len == 0 && m.html.len == 0 { err.append("empty body"); return false; }
    var id: u8[>..] = [];
    c_rand_hex(id, 12);
    let _u, domain, _h = split_once(sender, '@');
    format(out, "From: ", sender, "\r\nTo: ", m.to, "\r\n");
    if m.reply_to.len > 0 { format(out, "Reply-To: ", m.reply_to, "\r\n"); }
    out.append("Subject: ");
    if _is_ascii(m.subject) { out.append(m.subject); } else { _encode_subject(out, m.subject); }
    out.append("\r\nDate: ");
    var date: u8[>..] = [];
    _http_date(date, now);
    out.append(date[..date.len - 3]);
    format(out, "+0000\r\nMessage-ID: <", id, "@", domain, ">\r\nMIME-Version: 1.0\r\n");
    if m.html.len == 0 {
        out.append("Content-Type: text/plain; charset=utf-8\r\n");
        _mail_body(out, m.text);
        return true;
    }
    var b: u8[>..] = [];
    c_rand_hex(b, 12);
    format(out, "Content-Type: multipart/alternative; boundary=\"gweb", b, "\"\r\n\r\n");
    format(out, "--gweb", b, "\r\nContent-Type: text/plain; charset=utf-8\r\n");
    _mail_body(out, m.text);
    format(out, "--gweb", b, "\r\nContent-Type: text/html; charset=utf-8\r\n");
    _mail_body(out, m.html);
    format(out, "--gweb", b, "--\r\n");
    return true;
}

// msg with a dot added to every line that starts with one (SMTP DATA, RFC 5321 4.5.2). msg ends in CRLF.
fn _dot_stuff(out: u8[>..]&, msg: const u8[:]) {
    var line_start = true;
    for c in msg {
        if line_start && c == '.' { out.push('.'); }
        out.push(c);
        line_start = c == 10;
    }
}

// ---------------------------------------------------------------- config

// 127.0.0.0/8, 10/8, 172.16/12, 192.168/16 as a dotted quad.
fn _ipv4_private(h: const u8[:]) -> bool {
    var n: i64[4] = [0, 0, 0, 0];
    var k = 0;
    var digits = 0;
    for c in h {
        if c == '.' {
            if digits == 0 || k >= 3 { return false; }
            k += 1;
            digits = 0;
        } else if c >= '0' && c <= '9' {
            n[k] = n[k] * 10 + (c - '0');
            digits += 1;
            if digits > 3 || n[k] > 255 { return false; }
        } else {
            return false;
        }
    }
    if k != 3 || digits == 0 { return false; }
    return n[0] == 127 || n[0] == 10 || (n[0] == 172 && n[1] >= 16 && n[1] <= 31) || (n[0] == 192 && n[1] == 168);
}

// ::1, or fc00::/7: a first group of four hex digits that starts fc or fd.
fn _ipv6_private(h: const u8[:]) -> bool {
    if h == "::1" { return true; }
    var colons = 0;
    for c in h {
        let hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
        if c == ':' { colons += 1; } else if !hex { return false; }
    }
    if colons < 2 || h.len < 5 || h[4] != ':' { return false; }
    let a = h[0] | 32;
    let b = h[1] | 32;
    return a == 'f' && (b == 'c' || b == 'd') && find(h[..4], ":") < 0;
}

fn _host_allowed(h: const u8[:]) -> bool {
    if h == "localhost" { return true; }
    return _ipv4_private(h) || _ipv6_private(h);
}

// Transports from GWEB_MAIL.
const MAIL_LOG = 0;
const MAIL_SMTP = 1;
const MAIL_OFF = 2;

// GWEB_MAIL as spec (trimmed; "" is unset, which means log when dev or under gweb test, else off): the transport, and for
// smtp the host (no brackets) and port. -1 with err set when it is not usable.
fn _mail_parse(spec: const u8[:], dev: bool, host: u8[>..]&, port: i64&, err: u8[>..]&) -> i64 {
    if spec.len == 0 { return if dev || _mail_capture { MAIL_LOG } else { MAIL_OFF }; }
    if spec == "log" { return MAIL_LOG; }
    if spec == "off" { return MAIL_OFF; }
    if !starts_with(spec, "smtp://") {
        if starts_with(spec, "smtps://") || starts_with(spec, "smtp+starttls://") {
            format(err, "GWEB_MAIL: no TLS client yet; use smtp:// to a relay on this host or a private network");
        } else {
            format(err, "GWEB_MAIL: want log, off or smtp://host:port");
        }
        return -1;
    }
    let rest = spec[7..];
    var h: u8[>..] = [];
    var p: u8[>..] = [];
    if starts_with(rest, "[") {
        let close = find(rest, "]");
        if close < 0 { format(err, "GWEB_MAIL: bad address in ", spec); return -1; }
        h.append(rest[1..close]);
        let tail = rest[close + 1..];
        if tail.len > 0 {
            if tail[0] != ':' { format(err, "GWEB_MAIL: bad address in ", spec); return -1; }
            p.append(tail[1..]);
        }
    } else {
        let hh, pp, has = split_once(rest, ':');
        h.append(hh);
        if has { p.append(pp); }
    }
    port = 25;
    if p.len > 0 {
        let n, ok = parse_int(p);
        if !ok || n <= 0 || n > 65535 { format(err, "GWEB_MAIL: bad port in ", spec); return -1; }
        port = n;
    }
    if h.len == 0 || find(h, "/") >= 0 { format(err, "GWEB_MAIL: want smtp://host:port"); return -1; }
    if !_host_allowed(h) {
        format(err, "GWEB_MAIL: ", h, " is not loopback or a private address; plain SMTP has no TLS, so use a local relay");
        return -1;
    }
    host.append(h);
    return MAIL_SMTP;
}

fn _mail_env(spec: u8[>..]&, dev: bool&) {
    var e: u8[>..] = [];
    env("GWEB_MAIL", e);
    spec.append(trim(e));
    var name: u8[>..] = [];
    _environment(name);
    dev = name == "development";
}

// The text for the generated main to print (and exit 2) when GWEB_MAIL is set and unusable; "" when fine.
fn mail_check_config() -> u8[>..] {
    var spec: u8[>..] = [];
    var dev = false;
    _mail_env(spec, dev);
    var host: u8[>..] = [];
    var port = 0;
    var err: u8[>..] = [];
    _mail_parse(spec, dev, host, port, err);
    return err;
}

// ---------------------------------------------------------------- transports

// Reads one SMTP reply (all its lines) into buf; its code, or -1 on an error or a timeout.
fn _smtp_reply(conn: net::Socket, start_us: i64, buf: u8[>..]&) -> i64 {
    buf.clear();
    loop {
        let left = MAIL_TOTAL_MS - (c_now_us() - start_us) / 1000;
        if left <= 0 { return -1; }
        conn.set_timeout(left);
        if net::recv(conn, buf, 4096) <= 0 { return -1; }
        if buf.len > 65536 { return -1; }
        if buf.len >= 5 && buf[buf.len - 2] == 13 && buf[buf.len - 1] == 10 {
            var ls = buf.len - 2;
            while ls > 0 && buf[ls - 1] != 10 { ls -= 1; }
            let line = buf[ls..];
            if line.len >= 5 && line[3] == ' ' {
                let n, ok = parse_int(line[..3]);
                return if ok { n } else { -1 };
            }
        }
    }
}

fn _smtp_send(conn: net::Socket, start_us: i64, data: const u8[:]) -> bool {
    let left = MAIL_TOTAL_MS - (c_now_us() - start_us) / 1000;
    if left <= 0 { return false; }
    conn.set_timeout(left);
    return conn.send(data);
}

// One command and its reply; false (with why set) unless the reply code is a or b.
fn _smtp_step(conn: net::Socket, start_us: i64, cmd: const u8[:], a: i64, b: i64, why: u8[>..]&) -> bool {
    if cmd.len > 0 && !_smtp_send(conn, start_us, cmd) { format(why, "send failed"); return false; }
    var buf: u8[>..] = [];
    let code = _smtp_reply(conn, start_us, buf);
    if code < 0 { format(why, "no reply (timeout or closed)"); return false; }
    if code != a && code != b {
        format(why, "server said ", trim(buf[..min(buf.len, 200)]));
        return false;
    }
    return true;
}

// The dialogue: greeting, EHLO, MAIL FROM, RCPT TO, DATA, the message, QUIT. No AUTH, no TLS.
fn _smtp_deliver(host: const u8[:], port: i64, sender: const u8[:], to: const u8[:], msg: const u8[:], why: u8[>..]&) -> bool {
    let start = c_now_us();
    let conn = net::connect(host, port, MAIL_CONNECT_MS);
    if !conn.ok() { format(why, "cannot connect to ", host, ":", port, ": ", net::last_error()); return false; }
    var cmd: u8[>..] = [];
    var ok = _smtp_step(conn, start, "", 220, 220, why);
    if ok { ok = _smtp_step(conn, start, "EHLO localhost\r\n", 250, 250, why); }
    if ok { format(cmd, "MAIL FROM:<", sender, ">\r\n"); ok = _smtp_step(conn, start, cmd, 250, 250, why); }
    if ok { cmd.clear(); format(cmd, "RCPT TO:<", to, ">\r\n"); ok = _smtp_step(conn, start, cmd, 250, 251, why); }
    if ok { ok = _smtp_step(conn, start, "DATA\r\n", 354, 354, why); }
    if ok {
        var body: u8[>..] = [];
        _dot_stuff(body, msg);
        body.append(".\r\n");
        ok = _smtp_step(conn, start, body, 250, 250, why);
    }
    if ok {
        var quit_why: u8[>..] = [];
        _smtp_step(conn, start, "QUIT\r\n", 221, 221, quit_why);
    }
    conn.close();
    return ok;
}

// ---------------------------------------------------------------- send

fn _mail_fail(ctx: const Ctx&, why: const u8[:]) -> bool {
    var msg: u8[>..] = [];
    format(msg, "mail not sent: ", why);
    log_warn(ctx, msg);
    return false;
}

// Sends m by the GWEB_MAIL transport. False when refused or failed, with the reason logged. Call it from a job, so a
// slow relay holds no request and a failure is retried (see README, Mail).
fn mail_send(ctx: Ctx&, m: const Mail&) -> bool {
    var spec: u8[>..] = [];
    var dev = false;
    _mail_env(spec, dev);
    var from: u8[>..] = [];
    env("GWEB_MAIL_FROM", from);
    // gweb test reads no .env file: its sender is test@localhost unless GWEB_MAIL_FROM is in the environment.
    let sender = if trim(from).len == 0 && _mail_capture { "test@localhost" } else { trim(from) };
    return _mail_deliver(ctx, m, spec, sender, dev);
}

// mail_send with GWEB_MAIL as spec, GWEB_MAIL_FROM as from, and dev for GWEB_ENV=development.
fn _mail_deliver(ctx: Ctx&, m: const Mail&, spec: const u8[:], from: const u8[:], dev: bool) -> bool {
    var host: u8[>..] = [];
    var port = 0;
    var err: u8[>..] = [];
    let kind = _mail_parse(spec, dev, host, port, err);
    if kind < 0 { return _mail_fail(ctx, err); }
    if kind == MAIL_OFF {
        if !_mail_off_logged {
            _mail_off_logged = true;
            log_warn(ctx, "mail is off (GWEB_MAIL unset or off): messages are not sent");
        }
        return false;
    }
    var msg: u8[>..] = [];
    if !mail_build(msg, m, from, time() as i64, err) { return _mail_fail(ctx, err); }
    if kind == MAIL_LOG {
        var line: u8[>..] = [];
        format(line, "mail (log transport):\n", msg);
        _log_message(Level.Info, line);
        if _mail_capture { _mail_out.append(msg[..min(msg.len, _mail_out.cap - _mail_out.len)]); }
        return true;
    }
    let sender = if m.from.len > 0 { m.from[..] } else { from };
    var why: u8[>..] = [];
    if !_smtp_deliver(host, port, sender, m.to, msg, why) { return _mail_fail(ctx, why); }
    return true;
}
