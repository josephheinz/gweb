import std;
import net.http;
import gweb;
import gweb.testing;
import views;
import lib.page;

fn has(t: gweb::Tester&, text: const u8[:], needle: const u8[:], what: const u8[:]) {
    var msg: u8[>..] = [];
    format(msg, what, ": '", text, "' lacks '", needle, "'");
    gweb::expect(t, find(text, needle) >= 0, msg);
}

fn get_req(raw: u8[>..]&) -> http::Request {
    raw.clear();
    raw.append("GET / HTTP/1.1\r\nHost: a\r\n\r\n");
    let req, parsed = http::parse_request(raw);
    return req;
}

// A layout and a section whose Props hold gweb::Text and a repeater, with @slot: they render, the text and the items
// before and after each slot, and the section inside a zone of another.
fn test_slotted_views_with_text_and_repeaters(t: gweb::Tester&) {
    var raw: u8[>..] = [];
    let req = get_req(raw);
    var ctx = gweb::_new_ctx(0, -1);
    var doc = pg::Doc { nodes: [] };
    let g = pg::node(doc, pg::BODY, "body", true, "Gallery", "{\"heading\":\"Top <b>\",\"items\":[{\"name\":\"one\"},{\"name\":\"two\"}]}");
    pg::node(doc, g, "a", false, "Note", "{\"text\":\"first\"}");
    let inner = pg::node(doc, g, "a", true, "Gallery", "{\"heading\":\"Inner\",\"items\":[{\"name\":\"x\"}]}");
    pg::node(doc, inner, "b", false, "Note", "{\"text\":\"deep\"}");
    pg::node(doc, g, "b", false, "Note", "{\"text\":\"last\"}");
    var out: u8[>..] = [];
    pg::render(out, req, ctx, doc, "{\"title\":\"Site\",\"nav\":[{\"href\":\"/a\",\"text\":\"A\"},{\"href\":\"/b\",\"text\":\"B\"}]}");
    has(t, out, "<title>Site</title></head><body><nav><a href=\"/a\">A</a><a href=\"/b\">B</a></nav>", "the layout's text and repeater render before its slot");
    has(t, out, "<footer>Site (2)</footer></body></html>", "and after it");
    has(t, out, "<section><h2>Top &lt;b&gt;</h2><ul><li>one</li><li>two</li></ul><div class=\"a\"><i>first</i>\n<section><h2>Inner</h2><ul><li>x</li></ul><div class=\"a\"></div><p>after Inner</p><div class=\"b\"><i>deep</i>\n</div><footer>1</footer></section>\n</div>", "the section renders its text and items, then the views of its first zone");
    has(t, out, "<p>after Top &lt;b&gt;</p><div class=\"b\"><i>last</i>\n</div><footer>2</footer></section>", "the text and items are still there after the slots");
}
