import std;
import gweb;
import lib.tag;

let ITEM_LABEL: const u8[:] = "tag";

struct Row { tag: tag::Tag = tag::Tag { .. }, n: i64 = 0 }
struct Props { heading: u8[..40] = "", rows: Row[>..<] }
