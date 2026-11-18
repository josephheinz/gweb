import std;
import net.http;
import gweb;
import gweb.site.feed;

// /feed gives RSS, /feed?atom=1 Atom: the same three items.
fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    var f = gweb::Feed { base: [], self_url: [], title: [], link: [], about: [], rss: [], atom: [], count: 0, updated: 0 };
    gweb::feed_init(req, f, "Tom & Jerry's <blog>", "/", "Notes");
    gweb::feed_add(f, "First", "/posts/first", "A & B", 1763478245, "post-1");
    gweb::feed_add(f, "Second \x01\"quoted\"", "https://example.org/x?a=1&b=2", "", 0);
    gweb::feed_add(f, "Third", "/posts/third", "<b>bold</b>", 1000000000, "https://example.org/id/3");
    if !gweb::feed_add(f, "Bad", "javascript:alert(1)", "", 0) { f.count += 0; }
    if req.query == "atom=1" { gweb::feed_atom(res, f); } else { gweb::feed_rss(res, f); }
}
