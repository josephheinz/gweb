import std;
import net.http;
import gweb;
import gweb.testing;
import views;
import v_widgets_Rule;

// A view whose Props has no fields (goose-cms ask 1): its codec, form and parser are generated.
fn test_empty_props(t: gweb::Tester&) {
    var out: u8[>..] = [];
    gweb::expect(t, views::widgets_defaults("Rule", out) && out == "{}", "defaults of an empty Props are {}");
    out.clear();
    gweb::expect(t, views::layouts_defaults("Bare", out) && out == "{}", "a layout with an empty Props");
    var p = v_widgets_Rule::Props { .. };
    gweb::expect(t, v_widgets_Rule::read("{\"old\":1}", p) == 0, "an unknown key is skipped");
    var errs = gweb::FieldErrors { .. };
    out.clear();
    gweb::expect(t, views::widgets_form(out, "Rule", "{}", errs, "p.") && out.len == 0, "the form has no fields");
    var raw: u8[>..] = [];
    raw.append("POST /f HTTP/1.1\r\nHost: a\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 0\r\n\r\n");
    let req, parsed = http::parse_request(raw);
    out.clear();
    gweb::expect(t, views::widgets_parse(req, "Rule", "p.", out, errs) && out == "{}", "parse writes {}");
}
