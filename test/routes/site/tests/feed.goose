import std;
import net.http;
import gweb;
import gweb.testing;

fn test_dates(t: gweb::Tester&) {
    var a: u8[>..] = [];
    gweb::rfc822(a, 0);
    gweb::expect_eq(t, a, "Thu, 01 Jan 1970 00:00:00 GMT", "epoch rfc822");
    var b: u8[>..] = [];
    gweb::rfc822(b, 1763478245);
    gweb::expect_eq(t, b, "Tue, 18 Nov 2025 15:04:05 GMT", "rfc822");
    var c: u8[>..] = [];
    gweb::rfc3339(c, 1763478245);
    gweb::expect_eq(t, c, "2025-11-18T15:04:05Z", "rfc3339");
    var d: u8[>..] = [];
    gweb::rfc3339(d, 951782400);      // 2000-02-29: a leap day
    gweb::expect_eq(t, d, "2000-02-29T00:00:00Z", "leap day");
    var e: u8[>..] = [];
    gweb::xml_escape(e, "a<b>&\"'\x01\x1f\tz");
    gweb::expect_eq(t, e, "a&lt;b&gt;&amp;&quot;&#39;\tz", "xml_escape drops control bytes");
}

fn test_rss(t: gweb::Tester&) {
    let res = site::get(t, "/feed");
    gweb::expect_status(t, res, 200);
    gweb::expect_header(t, res, "Content-Type", "application/rss+xml; charset=utf-8");
    gweb::expect_contains(t, res.body, "<rss version=\"2.0\"");
    gweb::expect_contains(t, res.body, "<title>Tom &amp; Jerry&#39;s &lt;blog&gt;</title>");
    gweb::expect_contains(t, res.body, "<link>http://test/</link>");
    gweb::expect_contains(t, res.body, "<atom:link href=\"http://test/feed\" rel=\"self\"");
    gweb::expect_contains(t, res.body, "<link>http://test/posts/first</link>");
    gweb::expect_contains(t, res.body, "<guid isPermaLink=\"false\">post-1</guid>");
    gweb::expect_contains(t, res.body, "<pubDate>Tue, 18 Nov 2025 15:04:05 GMT</pubDate>");
    gweb::expect_contains(t, res.body, "<lastBuildDate>Tue, 18 Nov 2025 15:04:05 GMT</lastBuildDate>");
    gweb::expect_contains(t, res.body, "<description>A &amp; B</description>");
    gweb::expect_contains(t, res.body, "<link>https://example.org/x?a=1&amp;b=2</link>");
    gweb::expect_contains(t, res.body, "<title>Second &quot;quoted&quot;</title>");
    gweb::expect_contains(t, res.body, "<guid isPermaLink=\"true\">https://example.org/id/3</guid>");
    gweb::expect_contains(t, res.body, "&lt;b&gt;bold&lt;/b&gt;");
    gweb::expect_not_contains(t, res.body, "javascript:");
    gweb::expect_not_contains(t, res.body, "Bad");
}

fn test_atom(t: gweb::Tester&) {
    let res = site::get(t, "/feed?atom=1");
    gweb::expect_status(t, res, 200);
    gweb::expect_header(t, res, "Content-Type", "application/atom+xml; charset=utf-8");
    gweb::expect_contains(t, res.body, "<feed xmlns=\"http://www.w3.org/2005/Atom\">");
    gweb::expect_contains(t, res.body, "<updated>2025-11-18T15:04:05Z</updated>");
    gweb::expect_contains(t, res.body, "<link rel=\"self\" type=\"application/atom+xml\" href=\"http://test/feed\"/>");
    gweb::expect_contains(t, res.body, "<id>post-1</id>");
    gweb::expect_contains(t, res.body, "<published>2001-09-09T01:46:40Z</published>");
    gweb::expect_contains(t, res.body, "<summary>A &amp; B</summary>");
}
