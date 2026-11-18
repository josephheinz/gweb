// A tool built against the app's generated views (1.6): `import views from "...";` gets .gweb.tools/gen.
import gweb from "../../gweb";
import net from "../../goose-net";
import views from "../.gweb";
import std;

fn main() {
    var out: u8[>..] = [];
    let a = args();
    let name = if a.len > 1 { a[1] } else { "Hero" };
    let ok = views::widgets_defaults(name, out);
    print("vt ", ok, " ", views::widgets_count(), " ", out);
}
