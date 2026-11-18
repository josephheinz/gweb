// Sends one message with mail_send, for test/mail.sh: GWEB_MAIL and GWEB_MAIL_FROM from the environment, the body from the file
// named by the first argument. Prints the log lines; exits 0 when mail_send is true, else 1.
//   goose build -o mail_send test/mail_send.goose
import gweb from "..";
import gweb.ops.mail;
import net from "../../goose-net";
import net.http;
import std;
import os;

fn main() {
    let a = args();
    var body: u8[>..] = [];
    if a.len > 1 { read_file(a[1], body); }
    var ctx = gweb::_new_ctx(0, -1);
    var m = gweb::Mail { to: "ann@example.com", subject: "Gr\xC3\xBC\xC3\x9Fe, Ann", text: "" };
    m.text.append(body);
    exit(if gweb::mail_send(ctx, m) { 0 } else { 1 });
}
