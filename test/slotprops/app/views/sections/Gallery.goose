import std;
let LABEL = "Gallery";
struct Item { name: u8[..30] = "" }
root struct Props {
    heading: gweb::Text = "",
    items: Item[>..<] = [],
}
