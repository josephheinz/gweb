import std;
import gweb;
import gweb.forms.valid;

let ITEM_LABEL = "label";
let UI = [gweb::FieldUi { field: "summary", max: 300 },
          gweb::FieldUi { field: "body", editor: "markdown", max: 200000 }];
let ENUM_LABELS = [gweb::EnumLabel { ty: "Tone", variant: "Warm", label: "Warm tone" }];

enum Tone { Warm, Cool }
struct Link { label: u8[..80] = "", url: u8[..200] = "" }
struct Note { text: u8[..40] = "" }

// Several repeaters, not last, and growable text: a root struct.
root struct Props {
    title: gweb::Text,
    links: Link[>..<] = [],
    summary: gweb::Text = "",
    body: gweb::LongText = "",
    tone: Tone = Tone.Warm,
    notes: Note[..4] = [],
    count: i64 = 0,
}

fn validate(p: const Props&, errs: gweb::FieldErrors&) {
    gweb::check_length(errs, "title", p.title, 2, 128);
}
