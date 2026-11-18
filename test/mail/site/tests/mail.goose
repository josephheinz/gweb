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

// gweb::run_jobs(t) runs what the handler queued, so the test sees the mail.
fn test_queued_job_runs(t: gweb::Tester&) {
    site::get(t, "/");
    let res = site::post_form(t, "/contact?email=bo%40example.com&text=Hello+Bo", "x=1");
    gweb::expect_status(t, res, 202);
    gweb::expect_eq(t, gweb::run_jobs(t), 1, "one job ran");
    gweb::expect_contains(t, t.mails, "To: bo@example.com");
    gweb::expect_contains(t, t.mails, "Hello Bo");
}

// A handler's input check runs under gweb test too.
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

// const CSRF = false plus gweb::origin_ok: same origin passes (no cookie, no token), another origin or none is refused.
fn test_origin_check(t: gweb::Tester&) {
    t.auto_csrf = false;
    let q = "/contact?email=bo%40example.com&text=Hi";
    t.headers.append("Origin: http://evil.example\r\n");
    let r1 = site::post_form(t, q, "x=1");
    gweb::expect_status(t, r1, 403);
    let r2 = site::post_form(t, q, "x=1");
    gweb::expect_status(t, r2, 403);   // no header at all
    t.headers.append("Origin: http://test\r\n");
    let ok = site::post_form(t, q, "x=1");
    gweb::expect_status(t, ok, 202);
    gweb::expect_not_contains(t, ok.headers, "Set-Cookie");
    t.headers.append("Sec-Fetch-Site: cross-site\r\nOrigin: http://test\r\n");
    let r3 = site::post_form(t, q, "x=1");
    gweb::expect_status(t, r3, 403);
}
