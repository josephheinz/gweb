import std;
import gweb;
import gweb.ops.mail;

enum Job { Mail { to: u8[..320], subject: u8[..256], text: u8[..2048] } }

fn run(job: const Job&, ctx: gweb::Ctx&) -> bool {              // false: retried with backoff
    match job {
        Mail j => {
            var m = gweb::Mail { to: j.to, subject: j.subject, text: j.text };
            return gweb::mail_send(ctx, m);
        },
    }
}
