// A foreign field type with gw_label, so a repeater's ITEM_LABEL may name it (1.3).
namespace tag;

import std;
import net.http;
import json;
import gweb;
import gweb.site.views;
import gweb.forms.valid;
import gweb.site.template;

struct Tag { name: u8[..40] = "" }

fn gw_read(r: json::Reader&, v: Tag&, warn: i64&) { gweb::_jr_text(r, v.name, warn); }
fn gw_write(out: u8[>..]&, v: const Tag&) { json::format_string(out, v.name); }
fn gw_field(out: u8[>..]&, name: const u8[:], v: const Tag&, label: const u8[:], help: const u8[:], editor: const u8[:], errs: const gweb::FieldErrors&) {
    out.append("<div class=\"tag-picker\" data-name=\"");
    gweb::escape(out, name);
    out.append("\">");
    gweb::escape(out, v.name);
    out.append("</div>\n");
}
fn gw_parse(req: const http::Request&, name: const u8[:], v: Tag&, errs: gweb::FieldErrors&) -> bool {
    return gweb::form_text(req, name, v.name, errs, false);
}
// The item legend's text.
fn gw_label(out: u8[>..]&, v: const Tag&) { out.append("tag "); out.append(v.name); }
