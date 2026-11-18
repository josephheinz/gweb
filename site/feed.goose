// Part of gweb. Import with `import gweb.site.feed;`.
// RSS 2.0 and Atom feeds from one list of items: RFC 822 and RFC 3339 dates, XML escaping, absolute links.

namespace gweb;

import std;
import net;
import net.http;
import gweb;
import site.template;
import site.meta;

let FEED_MAX_ITEMS = 500;
let FEED_MAX_BYTES = 8388608;
let FEED_DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
let FEED_MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

// The items are kept as RSS and as Atom markup, so either reply is one copy. updated: the newest date given (Unix seconds).
// Fill one the caller owns (a root struct cannot be returned):
//   var f = gweb::Feed { base: [], self_url: [], title: [], link: [], about: [], rss: [], atom: [], count: 0, updated: 0 };
//   gweb::feed_init(req, f, "Blog", "/blog", "News from us");
root struct Feed { base: u8[>..], self_url: u8[>..], title: u8[>..], link: u8[>..], about: u8[>..], rss: u8[>..], atom: u8[>..], count: i64, updated: i64 }

fn _feed_pad(out: u8[>..]&, n: i64, width: i64) {
    var div = 1;
    for i in width - 1 { div *= 10; }
    while div > 0 { out.push('0' + ((n / div) % 10) as u8); div /= 10; }
}

// Splits Unix seconds into year, month, day, and the weekday (0 = Sunday).
fn _feed_civil(secs: i64) -> i64, i64, i64, i64 {
    let days = max(secs, 0) / 86400;
    let z = days + 719468;
    let era = z / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + (if month <= 2 { 1 } else { 0 });
    return year, month, day, (days + 4) % 7;
}

// Appends Unix seconds as an RFC 822 date in GMT, as RSS wants: Tue, 18 Nov 2026 15:04:05 GMT.
fn rfc822(out: u8[>..]&, secs: i64) {
    let y, m, d, wd = _feed_civil(secs);
    let rem = max(secs, 0) % 86400;
    out.append(FEED_DAYS[wd]);
    out.append(", ");
    _feed_pad(out, d, 2);
    out.push(' ');
    out.append(FEED_MONTHS[m - 1]);
    out.push(' ');
    _feed_pad(out, y, 4);
    out.push(' ');
    _feed_pad(out, rem / 3600, 2); out.push(':');
    _feed_pad(out, (rem % 3600) / 60, 2); out.push(':');
    _feed_pad(out, rem % 60, 2);
    out.append(" GMT");
}

// Appends Unix seconds as an RFC 3339 date in UTC, as Atom wants: 2026-11-18T15:04:05Z.
fn rfc3339(out: u8[>..]&, secs: i64) {
    let y, m, d, wd = _feed_civil(secs);
    let rem = max(secs, 0) % 86400;
    _feed_pad(out, y, 4); out.push('-');
    _feed_pad(out, m, 2); out.push('-');
    _feed_pad(out, d, 2); out.push('T');
    _feed_pad(out, rem / 3600, 2); out.push(':');
    _feed_pad(out, (rem % 3600) / 60, 2); out.push(':');
    _feed_pad(out, rem % 60, 2); out.push('Z');
}

// Appends s escaped for XML text or an attribute. Bytes XML cannot hold (control bytes except tab, newline and
// carriage return) are dropped, so one stray byte never makes the whole feed unparseable.
fn xml_escape(out: u8[>..]&, s: const u8[:]) {
    for c in s {
        if c == '&' { out.append("&amp;"); }
        else if c == '<' { out.append("&lt;"); }
        else if c == '>' { out.append("&gt;"); }
        else if c == '"' { out.append("&quot;"); }
        else if c == '\'' { out.append("&#39;"); }
        else if c < 32 && c != '\t' && c != '\n' && c != '\r' { continue; }
        else { out.push(c); }
    }
}

// Makes link absolute: a path (/blog/x) gets the base; http:// and https:// stay; anything else is refused.
fn _feed_abs(f: const Feed&, link: const u8[:], out: u8[>..]&) -> bool {
    if link.len > 0 && link[0] == '/' { out.append(f.base); out.append(link); return true; }
    if starts_with(link, "http://") || starts_with(link, "https://") { out.append(link); return true; }
    return false;
}

// Starts a feed: title, the page it is about (link, a path or URL) and a description. Links given as paths are
// made absolute with SITE_URL, else the request's scheme and host (as @meta does). The feed's own address is the request's.
fn feed_init(req: const http::Request&, f: Feed&, title: const u8[:], link: const u8[:], about: const u8[:]) {
    f.base.clear(); f.self_url.clear(); f.title.clear(); f.link.clear(); f.about.clear(); f.rss.clear(); f.atom.clear();
    f.count = 0;
    f.updated = 0;
    site_url(req, f.base);
    f.self_url.append(f.base);
    f.self_url.append(req.path);
    f.title.append(title);
    f.about.append(about);
    if !_feed_abs(f, link, f.link) { f.link.append(f.base); f.link.push('/'); }
}

// Adds an item: title, link (a path or URL), summary (text, escaped here), published (Unix seconds; 0 = none) and an
// id (a stable unique name; "" is the link). False, with f unchanged, for a link that is neither a path nor an
// http(s) URL, or when the feed is full (500 items, 8 MiB).
fn feed_add(f: Feed&, title: const u8[:], link: const u8[:], summary: const u8[:], published: i64 = 0, id: const u8[:] = "") -> bool {
    var url: u8[>..] = [];
    if !_feed_abs(f, link, url) { return false; }
    if f.count >= FEED_MAX_ITEMS || f.rss.len + f.atom.len + (title.len + url.len + summary.len + id.len) * 12 + 1024 > FEED_MAX_BYTES { return false; }
    let key = if id.len > 0 { id } else { url[..] };
    // is the id a URL? RSS then says isPermaLink
    let perma = id.len == 0 || starts_with(id, "http://") || starts_with(id, "https://");
    f.rss.append("<item><title>"); xml_escape(f.rss, title);
    f.rss.append("</title><link>"); xml_escape(f.rss, url);
    f.rss.append("</link><guid isPermaLink=\""); f.rss.append(if perma { "true" } else { "false" });
    f.rss.append("\">"); xml_escape(f.rss, key); f.rss.append("</guid>");
    if published > 0 { f.rss.append("<pubDate>"); rfc822(f.rss, published); f.rss.append("</pubDate>"); }
    if summary.len > 0 { f.rss.append("<description>"); xml_escape(f.rss, summary); f.rss.append("</description>"); }
    f.rss.append("</item>\n");
    f.atom.append("<entry><title>"); xml_escape(f.atom, title);
    f.atom.append("</title><link rel=\"alternate\" href=\""); xml_escape(f.atom, url);
    f.atom.append("\"/><id>"); xml_escape(f.atom, key);
    f.atom.append("</id><updated>"); rfc3339(f.atom, published); f.atom.append("</updated>");
    if published > 0 { f.atom.append("<published>"); rfc3339(f.atom, published); f.atom.append("</published>"); }
    if summary.len > 0 { f.atom.append("<summary>"); xml_escape(f.atom, summary); f.atom.append("</summary>"); }
    f.atom.append("</entry>\n");
    f.count += 1;
    if published > f.updated { f.updated = published; }
    return true;
}

// Replies with the feed as RSS 2.0 (application/rss+xml), 200, public for ten minutes.
fn feed_rss(res: http::Response&, f: const Feed&) {
    reply(res, http::Status.Ok, "application/rss+xml; charset=utf-8", "");
    http::set_header(res, "Cache-Control", "public, max-age=600");
    res.body.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<rss version=\"2.0\" xmlns:atom=\"http://www.w3.org/2005/Atom\">\n<channel>\n<title>");
    xml_escape(res.body, f.title);
    res.body.append("</title>\n<link>"); xml_escape(res.body, f.link);
    res.body.append("</link>\n<description>"); xml_escape(res.body, f.about);
    res.body.append("</description>\n");
    if f.updated > 0 { res.body.append("<lastBuildDate>"); rfc822(res.body, f.updated); res.body.append("</lastBuildDate>\n"); }
    res.body.append("<atom:link href=\""); xml_escape(res.body, f.self_url);
    res.body.append("\" rel=\"self\" type=\"application/rss+xml\"/>\n");
    res.body.append(f.rss);
    res.body.append("</channel>\n</rss>\n");
}

// Replies with the feed as Atom (application/atom+xml). The feed's id is its page link; its date the newest item's.
fn feed_atom(res: http::Response&, f: const Feed&) {
    reply(res, http::Status.Ok, "application/atom+xml; charset=utf-8", "");
    http::set_header(res, "Cache-Control", "public, max-age=600");
    res.body.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<feed xmlns=\"http://www.w3.org/2005/Atom\">\n<title>");
    xml_escape(res.body, f.title);
    res.body.append("</title>\n<subtitle>"); xml_escape(res.body, f.about);
    res.body.append("</subtitle>\n<link rel=\"alternate\" href=\""); xml_escape(res.body, f.link);
    res.body.append("\"/>\n<link rel=\"self\" type=\"application/atom+xml\" href=\""); xml_escape(res.body, f.self_url);
    res.body.append("\"/>\n<id>"); xml_escape(res.body, f.link);
    res.body.append("</id>\n<updated>"); rfc3339(res.body, f.updated);
    res.body.append("</updated>\n");
    res.body.append(f.atom);
    res.body.append("</feed>\n");
}
