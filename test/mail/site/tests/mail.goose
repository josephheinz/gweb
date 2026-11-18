import std;
import net.http;
import gweb;
import gweb.testing;

// The jobs recipe from the README: the handler queues, run sends. A test runs the job itself.
fn test_job_sends(t: gweb::Tester&) {
    var ctx = gweb::_new_ctx(0, -1);
    let job: jobs::Job = jobs::Job.Mail { to: "ann@example.com", subject: "Thanks, Ann", text: "We got it." };
    check_sent(t, ctx, job);
}

fn check_sent(t: gweb::Tester&, ctx: gweb::Ctx&, job: const jobs::Job&) {
    gweb::expect(t, jobs::run(job, ctx), "the job succeeds with the log transport");
    gweb::take_mails(t);
    gweb::expect_contains(t, t.mails, "Subject: Thanks, Ann");
    gweb::expect_contains(t, t.mails, "To: ann@example.com");
    gweb::expect_contains(t, t.mails, "We got it.");
}

// The queue runs only in the server, so under gweb test the handler's enqueue is refused; its input check still runs.
fn test_handler_checks_input(t: gweb::Tester&) {
    site::get(t, "/");
    let res = site::post_form(t, "/contact", "x=1");
    gweb::expect_status(t, res, 400);
}

fn test_bad_address_fails_the_job(t: gweb::Tester&) {
    var ctx = gweb::_new_ctx(0, -1);
    let job: jobs::Job = jobs::Job.Mail { to: "x@y.z\r\nBcc: q@r.s", subject: "Hi", text: "t" };
    gweb::expect(t, !jobs::run(job, ctx), "an injected address fails the job");
    gweb::take_mails(t);
    gweb::expect_not_contains(t, t.mails, "Bcc: q@r.s");
}
