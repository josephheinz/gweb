import std;
import gweb;

let ITEM_LABEL = "kind";
let ENUM_LABELS = [gweb::EnumLabel { ty: "Kind", variant: "Start", label: "First step" }];

enum Kind { Start, Middle, End }
struct Step { kind: Kind = Kind.Middle, note: u8[..40] = "" }
struct Props { steps: Step[..8] }
