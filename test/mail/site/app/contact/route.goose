import std;
import net.http;
import gweb;

fn POST(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
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
