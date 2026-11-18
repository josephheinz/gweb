// The mailer (ops/mail.goose) without a relay: message building, header injection, dot-stuffing, the host allow-list,
// GWEB_MAIL, and the log transport. The SMTP dialogue has its own test (test/mail.sh).
//   goose build test/mail_test.goose && test/mail_test
import gweb from "..";
import gweb.ops.mail;
import gweb.testing;
import net from "../../goose-net";
import net.http;
import std;

var failures = 0;
var checks = 0;

fn check(ok: bool, what: const u8[:]) {
    checks += 1;
    if !ok { failures += 1; print("FAIL ", what); }
}
fn has(text: const u8[:], needle: const u8[:], what: const u8[:]) {
    checks += 1;
    if find(text, needle) < 0 { failures += 1; print("FAIL ", what, ": no '", needle, "' in ", text); }
}
fn lacks(text: const u8[:], needle: const u8[:], what: const u8[:]) {
    checks += 1;
    if find(text, needle) >= 0 { failures += 1; print("FAIL ", what, ": has '", needle, "'"); }
}

var M = gweb::Mail { to: "", subject: "", text: "" };

// Resets M to a message from site@example.org and returns it.
fn simple(to: const u8[:], subject: const u8[:], text: const u8[:]) -> gweb::Mail& {
    M.to.clear(); M.to.append(to);
    M.from.clear(); M.from.append("site@example.org");
    M.reply_to.clear();
    M.subject.clear(); M.subject.append(subject);
    M.text.clear(); M.text.append(text);
    M.html.clear();
    return M;
}

// Builds m; ok and the message (or the refusal) come back.
fn build(m: const gweb::Mail&, out: u8[>..]&) -> bool {
    var err: u8[>..] = [];
    let ok = gweb::mail_build(out, m, "", 784111777, err);
    if !ok { out.append(err); }
    return ok;
}

fn test_build() {
    var out: u8[>..] = [];
    let m = simple("ann@example.com", "Thanks", "Hello\nworld");
    check(build(m, out), "plain message builds");
    has(out, "From: site@example.org\r\nTo: ann@example.com\r\nSubject: Thanks\r\nDate: Sun, 06 Nov 1994 08:49:37 +0000\r\n", "headers in order");
    has(out, "Message-ID: <", "message id");
    has(out, "@example.org>\r\nMIME-Version: 1.0\r\n", "message id domain and MIME-Version");
    has(out, "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 7bit\r\n\r\nHello\r\nworld\r\n", "body with CRLF");
    check(out[out.len - 2] == 13 && out[out.len - 1] == 10, "ends in CRLF");
    lacks(out, "Reply-To", "no reply-to when empty");
    for i in out.len { if out[i] == 10 && (i == 0 || out[i - 1] != 13) { check(false, "bare LF at offset"); } }
}

fn test_default_from() {
    var out: u8[>..] = [];
    var m = gweb::Mail { to: "a@b.c", subject: "s", text: "t" };
    var err: u8[>..] = [];
    check(!gweb::mail_build(out, m, "", 0, err), "no sender refused");
    has(err, "no sender", "no sender reason");
    out.clear();
    check(gweb::mail_build(out, m, "d@e.f", 0, err), "default from used");
    has(out, "From: d@e.f\r\n", "default from header");
}

fn test_utf8() {
    var out: u8[>..] = [];
    let m = simple("a@b.c", "Gr\xC3\xBC\xC3\x9Fe", "caf\xC3\xA9");
    check(build(m, out), "utf-8 builds");
    has(out, "Subject: =?utf-8?B?R3LDvMOfZQ==?=\r\n", "subject encoded word");
    has(out, "Content-Transfer-Encoding: base64\r\n\r\nY2Fmw6kNCg==\r\n", "non-ASCII body is base64");
    out.clear();
    var long: u8[>..] = [];
    for i in 60 { long.append("\xC3\xA9"); }
    let m2 = simple("a@b.c", long, "x");
    check(build(m2, out), "long utf-8 subject builds");
    has(out, "?=\r\n =?utf-8?B?", "long subject is folded");
    var longest = 0;
    var run = 0;
    for c in out { if c == 10 { run = 0; } else { run += 1; longest = max(longest, run); } }
    check(longest <= 78, "no header line over 78 bytes");
}

fn test_html() {
    var out: u8[>..] = [];
    let m = simple("a@b.c", "s", "plain");
    m.html.append("<p>rich</p>");
    check(build(m, out), "html builds");
    has(out, "Content-Type: multipart/alternative; boundary=\"gweb", "multipart header");
    has(out, "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 7bit\r\n\r\nplain\r\n", "text part");
    has(out, "Content-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: 7bit\r\n\r\n<p>rich</p>\r\n", "html part");
    has(out, "--\r\n", "closing boundary");
}

fn test_reply_to() {
    var out: u8[>..] = [];
    let m = simple("a@b.c", "s", "t");
    m.reply_to.append("visitor@example.net");
    check(build(m, out), "reply-to builds");
    has(out, "Reply-To: visitor@example.net\r\n", "reply-to header");
}

fn test_injection() {
    var out: u8[>..] = [];
    check(!build(simple("a@b.c", "hi\r\nBcc: x@y.z", "t"), out), "CRLF in subject refused");
    has(out, "CR, LF or NUL", "reason");
    out.clear();
    check(!build(simple("a@b.c\nBcc: x@y.z", "s", "t"), out), "LF in to refused");
    out.clear();
    check(!build(simple("a@b.c", "s\rx", "t"), out), "CR in subject refused");
    out.clear();
    check(!build(simple("a@b.c", "s\0x", "t"), out), "NUL in subject refused");
    out.clear();
    let m = simple("a@b.c", "s", "t");
    m.reply_to.append("r@b.c\r\nX: y");
    check(!build(m, out), "CRLF in reply_to refused");
    out.clear();
    let f = simple("a@b.c", "s", "t");
    f.from.clear();
    f.from.append("x@y.z\r\nBcc: q@r.s");
    check(!build(f, out), "CRLF in from refused");
    out.clear();
    // A body may hold anything: it is a body.
    check(build(simple("a@b.c", "s", "line\r\nBcc: not-a-header"), out), "CRLF in the body is fine");
}

fn test_addresses() {
    check(gweb::_addr_ok("a@b.c"), "plain address");
    check(!gweb::_addr_ok("a b@c.d"), "space refused");
    check(!gweb::_addr_ok("a@b@c.d"), "two @ refused");
    check(!gweb::_addr_ok("@b.c"), "no local part refused");
    check(!gweb::_addr_ok("a@"), "no domain refused");
    check(!gweb::_addr_ok("Ann <a@b.c>"), "display name refused");
    check(!gweb::_addr_ok("a@b.c,d@e.f"), "two recipients refused");
    check(!gweb::_addr_ok("<a@b.c>"), "angle brackets refused");
    var out: u8[>..] = [];
    check(!build(simple("not-an-address", "s", "t"), out), "to must be an address");
    out.clear();
    check(!build(simple("a@b.c", "s", ""), out), "empty body refused");
}

fn test_dot_stuffing() {
    var out: u8[>..] = [];
    gweb::_dot_stuff(out, ".start\r\nmid\r\n.\r\n..two\r\nend.\r\n");
    check(out == "..start\r\nmid\r\n..\r\n...two\r\nend.\r\n", "dot-stuffing");
    out.clear();
    var body: u8[>..] = [];
    body.append("one\n.hidden\n");
    let m = simple("a@b.c", "s", body);
    var msg: u8[>..] = [];
    check(build(m, msg), "dotted body builds");
    gweb::_dot_stuff(out, msg);
    has(out, "\r\n..hidden\r\n", "stuffed in a message");
}

fn test_long_lines_base64() {
    var big: u8[>..] = [];
    for i in 1200 { big.push('a'); }
    var out: u8[>..] = [];
    check(build(simple("a@b.c", "s", big), out), "long line builds");
    has(out, "Content-Transfer-Encoding: base64", "over 998 per line goes base64");
}

fn test_hosts() {
    check(gweb::_host_allowed("localhost"), "localhost");
    check(gweb::_host_allowed("127.0.0.1"), "127.0.0.1");
    check(gweb::_host_allowed("127.3.4.5"), "127/8");
    check(gweb::_host_allowed("10.1.2.3"), "10/8");
    check(gweb::_host_allowed("172.16.0.1") && gweb::_host_allowed("172.31.255.1"), "172.16/12 edges");
    check(!gweb::_host_allowed("172.15.0.1") && !gweb::_host_allowed("172.32.0.1"), "outside 172.16/12");
    check(gweb::_host_allowed("192.168.1.9"), "192.168/16");
    check(!gweb::_host_allowed("192.169.1.9"), "192.169 is public");
    check(!gweb::_host_allowed("8.8.8.8"), "public v4");
    check(!gweb::_host_allowed("1.2.3"), "short v4");
    check(!gweb::_host_allowed("10.0.0.256"), "bad octet");
    check(!gweb::_host_allowed("10.0.0.1.5"), "five octets");
    check(gweb::_host_allowed("::1"), "::1");
    check(gweb::_host_allowed("fd12:3456::1") && gweb::_host_allowed("fc00::1"), "fc00::/7");
    check(!gweb::_host_allowed("fe80::1"), "link-local v6 refused");
    check(!gweb::_host_allowed("2001:db8::1"), "public v6");
    check(!gweb::_host_allowed("smtp.example.com"), "a name is refused");
    check(!gweb::_host_allowed("localhost.example.com"), "localhost.* is a name");
    check(!gweb::_host_allowed("mail.internal"), "private-looking name refused");
}

fn config_of(spec: const u8[:]) -> u8[>..] {
    var host: u8[>..] = [];
    var port = 0;
    var err: u8[>..] = [];
    gweb::_mail_parse(spec, false, host, port, err);
    return err;
}

fn test_config() {
    check(config_of("log").len == 0, "log is fine");
    check(config_of("off").len == 0, "off is fine");
    check(config_of("smtp://127.0.0.1:60919").len == 0, "smtp loopback");
    check(config_of("smtp://localhost").len == 0, "smtp localhost, default port");
    check(config_of("smtp://[::1]:2525").len == 0, "smtp [::1]");
    check(config_of("smtp://10.0.0.5:25").len == 0, "smtp private");
    has(config_of("smtp://smtp.example.com:587"), "GWEB_MAIL: smtp.example.com is not loopback or a private address", "public host reason");
    has(config_of("smtp://8.8.8.8:25"), "local relay", "public ip reason");
    has(config_of("smtps://smtp.example.com"), "no TLS client", "smtps says why");
    has(config_of("smtp+starttls://127.0.0.1"), "no TLS client", "starttls says why");
    has(config_of("sendmail"), "want log, off or smtp://host:port", "unknown transport");
    has(config_of("smtp://127.0.0.1:99999"), "bad port", "bad port");
    has(config_of("smtp://127.0.0.1:x"), "bad port", "non-numeric port");
    has(config_of("smtp://"), "want smtp://host:port", "no host");
    check(config_of("").len == 0, "unset is fine");
    var host: u8[>..] = [];
    var port = 0;
    var err: u8[>..] = [];
    check(gweb::_mail_parse("smtp://[::1]:2525", false, host, port, err) == gweb::MAIL_SMTP, "smtp kind");
    check(host == "::1" && port == 2525, "host and port parsed");
}

fn test_log_transport(t: gweb::Tester&) {
    var ctx = gweb::_new_ctx(0, -1);
    var m = gweb::Mail { to: "ann@example.com", subject: "Thanks", text: "hi" };
    check(gweb::_mail_deliver(ctx, m, "log", "env@example.org", false), "log transport returns true");
    gweb::take_mails(t);
    gweb::expect_contains(t, t.mails, "Subject: Thanks");
    gweb::expect_contains(t, t.mails, "From: env@example.org");
    var bad = gweb::Mail { to: "ann@example.com", subject: "x\r\nBcc: z@z.z", text: "hi" };
    check(!gweb::_mail_deliver(ctx, bad, "log", "env@example.org", false), "injection: false");
    gweb::take_mails(t);
    gweb::expect_not_contains(t, t.mails, "Bcc");
    check(!gweb::_mail_deliver(ctx, m, "log", "", false), "no sender: false");
}

fn test_off(t: gweb::Tester&) {
    var ctx = gweb::_new_ctx(0, -1);
    var m = gweb::Mail { to: "ann@example.com", from: "s@example.org", subject: "Quiet", text: "hi" };
    check(!gweb::_mail_deliver(ctx, m, "off", "", false), "off returns false");
    gweb::take_mails(t);
    gweb::expect_not_contains(t, t.mails, "Quiet");
    // Unset: log under gweb test and in dev, off in production.
    check(gweb::_mail_deliver(ctx, m, "", "", false), "unset in a test is log");
    gweb::_mail_capture = false;
    check(!gweb::_mail_deliver(ctx, m, "", "", false), "unset in production is off");
    check(gweb::_mail_deliver(ctx, m, "", "", true), "unset in dev is log");
    gweb::_mail_capture = true;
}

fn main() {
    var t = gweb::Tester { .. };
    gweb::_mail_capture = true;
    test_build();
    test_default_from();
    test_utf8();
    test_html();
    test_reply_to();
    test_injection();
    test_addresses();
    test_dot_stuffing();
    test_long_lines_base64();
    test_hosts();
    test_config();
    test_log_transport(t);
    test_off(t);
    check(t.failures == 0, "expect_* checks");
    if failures > 0 { print("mail_test: ", failures, " of ", checks, " checks failed"); exit(1); }
    print("mail_test: ", checks, " checks passed");
}
