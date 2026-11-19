// Glue: a document of nodes rendered through the generated registry, as a CMS does.
namespace pg;

import std;
import net.http;
import gweb;
import views;

let BODY = -2;

struct Node { parent: i64, zone: u8[..16], section: bool, view: u8[..32], props: u8[..400] }
struct Doc { nodes: Node[..16] }

fn node(doc: Doc&, parent: i64, zone: const u8[:], section: bool, view: const u8[:], props: const u8[:]) -> i64 {
    var n = Node { parent: parent, zone: "", section: section, view: "", props: "" };
    n.zone.append(zone);
    n.view.append(view);
    n.props.append(props);
    doc.nodes.push(n);
    return doc.nodes.len - 1;
}

recursive fn fill(out: u8[>..]&, req: const http::Request&, ctx: const gweb::Ctx&, doc: const Doc&, at: i64, name: const u8[:]) {
    for i in doc.nodes.len {
        if doc.nodes[i].parent != at || doc.nodes[i].zone != name { continue; }
        let n = doc.nodes[i];
        var ok = false;
        if n.section { ok = views::sections_render(out, req, ctx, n.view, n.props, doc, i, fill); }
        else { ok = views::widgets_render(out, req, ctx, n.view, n.props, doc, i, fill); }
        if !ok { out.append("[no such view]"); }
    }
}

fn render(out: u8[>..]&, req: const http::Request&, ctx: const gweb::Ctx&, doc: const Doc&, shell: const u8[:]) {
    if !views::layouts_render(out, req, ctx, "Shell", shell, doc, BODY, fill) { out.append("[no layout]"); }
}
