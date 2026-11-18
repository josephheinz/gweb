import std;
import net.http;
import gweb;
import gweb.auth.csrf;

const CSRF = false;   // an anonymous form: no token, so its page stays cacheable; origin_ok is the check

fn POST(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    if !gweb::origin_ok(req, ctx, res) { return; }
    var to: u8[>..] = [];
    var text: u8[>..] = [];
    if !gweb::query(req, "email", to) || !gweb::query(req, "text", text) {
        http::text(res, http::Status.BadRequest, "email and text\n");
        return;
    }
    let job: jobs::Job = jobs::Job.Mail { to: to, subject: "Thanks", text: text };
    if jobs::enqueue(ctx, job) { http::text(res, http::Status.Accepted, "queued\n"); }
    else { http::text(res, http::Status.ServiceUnavailable, "job queue refused\n"); }
}
