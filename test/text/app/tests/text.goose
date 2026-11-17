import std;
import net.http;
import gweb;
import gweb.testing;
import gweb.forms.valid;
import views;
import v_types_Article;

fn eq(t: gweb::Tester&, got: const u8[:], want: const u8[:], what: const u8[:]) {
    var msg: u8[>..] = [];
    format(msg, what, ": got '", got, "', want '", want, "'");
    gweb::expect(t, got == want, msg);
}

fn has(t: gweb::Tester&, text: const u8[:], needle: const u8[:], what: const u8[:]) {
    var msg: u8[>..] = [];
    format(msg, what, ": '", text, "' lacks '", needle, "'");
    gweb::expect(t, find(text, needle) >= 0, msg);
}

fn lacks(t: gweb::Tester&, text: const u8[:], needle: const u8[:], what: const u8[:]) {
    var msg: u8[>..] = [];
    format(msg, what, ": '", text, "' has '", needle, "'");
    gweb::expect(t, find(text, needle) < 0, msg);
}

fn get_req(raw: u8[>..]&) -> http::Request {
    raw.clear();
    raw.append("GET / HTTP/1.1\r\nHost: a\r\n\r\n");
    let req, parsed = http::parse_request(raw);
    return req;
}

fn post_req(raw: u8[>..]&, body: const u8[:]) -> http::Request {
    raw.clear();
    format(raw, "POST /f HTTP/1.1\r\nHost: a\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: ", body.len, "\r\n\r\n", body);
    let req, parsed = http::parse_request(raw);
    return req;
}

fn fill(out: u8[>..]&, req: const http::Request&, ctx: const gweb::Ctx&, doc: const i64&, at: i64, name: const u8[:]) {}

fn rep(out: u8[>..]&, s: const u8[:], n: i64) { for i in n { out.append(s); } }

// A Text is read whole, however long; over its limit it counts one warning, and read_errs names it.
fn test_read_whole(t: gweb::Tester&) {
    var title: u8[>..] = [];
    rep(title, "a", 200);
    var json: u8[>..] = [];
    format(json, "{\"title\":\"", title, "\",\"links\":[{\"label\":\"");
    rep(json, "b", 90);
    json.append("\"}]}");
    var p = v_types_Article::Props { .. };
    let w = v_types_Article::read(json, p);
    gweb::expect(t, p.title.len == 200, "the title is kept whole");
    gweb::expect(t, p.links.len == 1 && p.links[0].label.len == 80, "a u8[..80] item field is still cut");
    gweb::expect(t, w == 2, "one warning each");
    var q = v_types_Article::Props { .. };
    var errs = gweb::no_errors();
    v_types_Article::read_errs(json, q, errs);
    eq(t, gweb::error_for(errs, "title"), "Stored text is 200 characters; the limit is 128.", "named over the limit");
    eq(t, gweb::error_for(errs, "links.0.label"), "Stored text was cut to 80 bytes.", "named when cut");
    // 128 two-byte characters are 256 bytes and within the limit.
    var wide: u8[>..] = [];
    wide.append("{\"title\":\"");
    rep(wide, "é", 128);
    wide.append("\"}");
    var e2 = gweb::no_errors();
    var r = v_types_Article::Props { .. };
    gweb::expect(t, v_types_Article::read_errs(wide, r, e2) == 0 && e2.n == 0 && r.title.len == 256, "the limit counts characters");
    // The body's limit is FieldUi.max (200,000), above the LongText default.
    var big: u8[>..] = [];
    big.append("{\"title\":\"Hi\",\"body\":\"");
    rep(big, "x", 70000);
    big.append("\"}");
    var e3 = gweb::no_errors();
    var b = v_types_Article::Props { .. };
    gweb::expect(t, v_types_Article::read_errs(big, b, e3) == 0 && b.body.len == 70000, "a 70,000-character body is within max");
}

fn test_write_round_trip(t: gweb::Tester&) {
    var p = v_types_Article::Props { .. };
    v_types_Article::read("{\"title\":\"T\",\"body\":\"line\\nmore\",\"tone\":\"Cool\",\"notes\":[{\"text\":\"n\"}]}", p);
    var out: u8[>..] = [];
    v_types_Article::write(out, p);
    eq(t, out, "{\"title\":\"T\",\"links\":[],\"summary\":\"\",\"body\":\"line\\nmore\",\"tone\":\"Cool\",\"notes\":[{\"text\":\"n\"}],\"count\":0}", "canonical JSON, enums by name");
    var d: u8[>..] = [];
    gweb::expect(t, views::types_defaults("Article", d), "defaults");
    has(t, d, "\"title\":\"\"", "a required Text defaults to empty");
}

fn test_form_markup(t: gweb::Tester&) {
    var raw: u8[>..] = [];
    let req = get_req(raw);
    var errs = gweb::no_errors();
    var out: u8[>..] = [];
    let json = "{\"title\":\"Hi\",\"links\":[{\"label\":\"Home\",\"url\":\"/\"}],\"body\":\"a < b\",\"notes\":[{\"text\":\"n1\"}]}";
    gweb::expect(t, views::types_form_req(out, req, "Article", json, errs, "t."), "the rich form draws");
    has(t, out, "<input type=\"text\" id=\"t.title\" name=\"t.title\" value=\"Hi\" required>", "a Text is an input with no maxlength");
    has(t, out, "<input type=\"text\" id=\"t.summary\" name=\"t.summary\" value=\"\">", "a Text over 200 stays an input");
    has(t, out, "<textarea id=\"t.body\" name=\"t.body\" data-editor=\"markdown\">a &lt; b</textarea>", "a LongText is a textarea");
    lacks(t, out, "maxlength", "no maxlength in the rich form");
    has(t, out, "<legend>#1: Home</legend>", "ITEM_LABEL labels the repeater whose item has the field");
    has(t, out, "<fieldset class=\"gw-item\"><legend>#1</legend>\n<p class=\"gw-field\"><label for=\"t.notes.0.text\">", "and not the other one");
    var plain: u8[>..] = [];
    views::types_form(plain, "Article", json, errs, "t.");
    has(t, plain, "name=\"t.title\" value=\"Hi\" required>", "the plain form has no maxlength on a Text");
    has(t, plain, "name=\"t.links.0.label\" value=\"Home\" maxlength=\"80\">", "but keeps it on a u8[..N]");
    // A GET names stored text over its limit, under its control.
    var long: u8[>..] = [];
    long.append("{\"title\":\"");
    rep(long, "z", 130);
    long.append("\"}");
    var o2: u8[>..] = [];
    views::types_form_req(o2, req, "Article", long, errs, "t.");
    has(t, o2, "<span class=\"gw-error\" id=\"t.title-error\">Stored text is 130 characters; the limit is 128.</span>", "the editor sees it before saving");
    has(t, o2, "aria-invalid=\"true\"", "the control is invalid");
}

fn test_parse_limits(t: gweb::Tester&) {
    var raw: u8[>..] = [];
    var body: u8[>..] = [];
    body.append("title=");
    rep(body, "q", 131);
    body.append("&links.n=1&links.0.label=");
    rep(body, "w", 93);
    let req = post_req(raw, body);
    var errs = gweb::no_errors();
    var json: u8[>..] = [];
    gweb::expect(t, !views::types_parse(req, "Article", "", json, errs), "over the limits");
    eq(t, gweb::error_for(errs, "title"), "Use at most 128 characters (this is 131).", "a Text counts characters");
    eq(t, gweb::error_for(errs, "links.0.label"), "Use at most 80 bytes (this is 93).", "a u8[..N] counts bytes and says so");
    // 128 characters of two bytes each fit; the JSON holds them.
    body.clear();
    body.append("title=");
    rep(body, "%C3%A9", 128);
    body.append("&summary=");
    rep(body, "s", 250);
    var e2 = gweb::no_errors();
    var j2: u8[>..] = [];
    let req2 = post_req(raw, body);
    gweb::expect(t, views::types_parse(req2, "Article", "", j2, e2), "128 characters parse");
    has(t, j2, "\"summary\":\"ssss", "a summary of 250 under its max of 300");
    // validate runs after: check_length counts characters too.
    var e3 = gweb::no_errors();
    var j3: u8[>..] = [];
    let req3 = post_req(raw, "title=%C3%A9");
    gweb::expect(t, !views::types_parse(req3, "Article", "", j3, e3), "one character");
    eq(t, gweb::error_for(e3, "title"), "Use at least 2 characters.", "validate");
}

// Two repeaters in one Props: each has its buttons.
fn test_two_repeaters(t: gweb::Tester&) {
    var raw: u8[>..] = [];
    var errs = gweb::no_errors();
    var json: u8[>..] = [];
    let req = post_req(raw, "title=Hi&links.n=1&links.0.label=A&notes.n=1&notes.0.text=x&notes.act=add");
    gweb::expect(t, !views::types_parse(req, "Article", "", json, errs) && errs.n == 0, "notes.add is an action");
    has(t, json, "\"notes\":[{\"text\":\"x\"},{\"text\":\"\"}]", "a note is added");
    has(t, json, "\"links\":[{\"label\":\"A\",\"url\":\"\"}]", "the links are kept");
    json.clear();
    let req2 = post_req(raw, "title=Hi&links.n=2&links.0.label=A&links.1.label=B&links.act=del%3A0");
    gweb::expect(t, !views::types_parse(req2, "Article", "", json, errs) && errs.n == 0, "links.del");
    has(t, json, "\"links\":[{\"label\":\"B\",\"url\":\"\"}]", "the first link is removed");
}

fn test_item_labels(t: gweb::Tester&) {
    var raw: u8[>..] = [];
    let req = get_req(raw);
    var errs = gweb::no_errors();
    var out: u8[>..] = [];
    views::widgets_form_req(out, req, "Tags", "{\"rows\":[{\"tag\":\"red\"},{\"tag\":\"blue\"}]}", errs, "");
    has(t, out, "<legend>#1: tag red</legend>", "a foreign ITEM_LABEL through gw_label");
    has(t, out, "<legend>#2: tag blue</legend>", "each item");
    out.clear();
    views::widgets_form_req(out, req, "Steps", "{\"steps\":[{\"kind\":\"Start\"},{\"kind\":\"End\"}]}", errs, "");
    has(t, out, "<legend>#1: First step</legend>", "an enum ITEM_LABEL by its label");
    has(t, out, "<legend>#2: End</legend>", "or its name");
}

// {props.tone} prints the ENUM_LABELS label (or the name); gweb::enum_name gives the stored name.
fn test_enum_in_templates(t: gweb::Tester&) {
    var raw: u8[>..] = [];
    let req = get_req(raw);
    var ctx = gweb::_new_ctx(0, -1);
    let doc = 0;
    var out: u8[>..] = [];
    gweb::expect(t, views::types_render(out, req, ctx, "Article", "{\"title\":\"Hi <b>\"}", doc, 0, fill), "renders");
    has(t, out, "<article class=\"tone-Warm\"><h1>Hi &lt;b&gt;</h1><p class=\"tone\">Warm tone</p><p class=\"raw\">Warm</p>", "label, and the name");
    has(t, out, "</article><p class=\"var\">Warm tone</p>", "{#var} is a mutable local a function fills by reference");
    out.clear();
    views::types_render(out, req, ctx, "Article", "{\"title\":\"Hi\",\"tone\":\"Cool\"}", doc, 0, fill);
    has(t, out, "<p class=\"tone\">Cool</p>", "a variant with no label prints its name");
    out.clear();
    views::widgets_render(out, req, ctx, "Steps", "{\"steps\":[{\"kind\":\"Start\"},{}]}", doc, 0, fill);
    eq(t, out, "<ol><li class=\"Start\">First step</li><li class=\"Middle\">Middle</li></ol>\n", "in a repeater");
    eq(t, gweb::enum_label(v_types_Article::Tone.Warm), "Warm tone", "gweb::enum_label");
    var s: u8[>..] = [];
    format(s, v_types_Article::Tone.Cool);
    eq(t, s, "Cool", "format prints the name, not Tone.Cool");
}

fn test_meta(t: gweb::Tester&) {
    let m = views::types_meta(views::types_index("Article"));
    gweb::expect(t, m.fields.len == 7, "seven fields");
    let f = m.fields[0];
    gweb::expect(t, f.kind == gweb::FieldKind.Text && f.cap == 128 && f.chars && f.required, "a Text: 128 characters, required");
    eq(t, f.ty, "gweb::Text", "its ty");
    gweb::expect(t, m.fields[2].cap == 300 && m.fields[2].chars, "FieldUi.max");
    gweb::expect(t, m.fields[3].cap == 200000 && m.fields[3].chars, "a LongText's max");
    eq(t, m.fields[3].ty, "gweb::LongText", "its ty");
    gweb::expect(t, m.fields[1].kind == gweb::FieldKind.List && !m.fields[1].chars, "a repeater");
    let w = views::widgets_meta(views::widgets_index("Tags"));
    gweb::expect(t, w.fields[0].cap == 40 && !w.fields[0].chars, "a u8[..N] counts bytes");
}

// g_read_errs checks stored JSON as a form would: text cut or over its limit, then validate.
fn test_read_errs_registry(t: gweb::Tester&) {
    var errs = gweb::no_errors();
    var out: u8[>..] = [];
    var long: u8[>..] = [];
    long.append("{\"title\":\"");
    rep(long, "z", 129);
    long.append("\"}");
    gweb::expect(t, !views::types_read_errs("Article", long, out, errs, "t."), "over the limit");
    eq(t, gweb::error_for(errs, "t.title"), "Stored text is 129 characters; the limit is 128.", "with the prefix");
    has(t, out, "zzzz\"", "the JSON keeps the whole text");
    var e2 = gweb::no_errors();
    out.clear();
    gweb::expect(t, !views::types_read_errs("Article", "{\"title\":\"A\"}", out, e2, ""), "validate runs");
    eq(t, gweb::error_for(e2, "title"), "Use at least 2 characters.", "its message");
    var e3 = gweb::no_errors();
    out.clear();
    gweb::expect(t, views::types_read_errs("Article", "{\"title\":\"Fine\"}", out, e3, "") && e3.n == 0, "good JSON");
    var e4 = gweb::no_errors();
    gweb::expect(t, !views::types_read_errs("Nope", "{}", out, e4, "") && gweb::error_for(e4, "") == "Unknown view.", "an unknown view");
}

fn test_helpers(t: gweb::Tester&) {
    var c = gweb::no_errors();
    gweb::expect(t, gweb::check_length(c, "a", "ééé", 2, 3), "check_length counts characters");
    gweb::expect(t, !gweb::check_length(c, "b", "éééé", 2, 3), "four is over three");
    var raw: u8[>..] = [];
    let req = post_req(raw, "x=%C3%A9%C3%A9%C3%A9&y=abcd");
    var errs = gweb::no_errors();
    var x: u8[>..] = [];
    var y: u8[>..] = [];
    gweb::expect(t, gweb::form_text_max(req, "x", x, errs, true, 3) && x == "ééé", "form_text_max takes three characters");
    gweb::expect(t, !gweb::form_text_max(req, "y", y, errs, true, 3), "four bytes of ASCII are four characters");
    eq(t, gweb::error_for(errs, "y"), "Use at most 3 characters (this is 4).", "its message");
    gweb::expect(t, !gweb::form_text_max(req, "z", y, errs, true, 3) && gweb::error_for(errs, "z") == "Required.", "required");
}
