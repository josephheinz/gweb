import std;
let LABEL = "Shell";
struct Link { href: u8[..60] = "", text: u8[..30] = "" }
root struct Props {
    title: gweb::Text = "",
    nav: Link[>..<] = [],
}
