// The hk tool, laid out as goose-cms's cms is: cli/hk links to ../lib, and an import points outside the package.
// `hk check` fails on a file in content/ that holds BAD, else writes public/hooked.txt and adds a line to hook.log.
import kv from "../../nowhere/kv";
import std;
import os;
import hk.text;

let NOTE = embed_file("../note.txt");

fn main() {
    let a = args();
    if a.len < 2 || a[1] != "check" { write_stderr("usage: hk check\n"); exit(2); }
    var names: u8[>..] = [];
    list_dir("content", names);
    var n = 0;
    for f in split(names, '\n') {
        if f.len == 0 { continue; }
        var p: u8[>..] = [];
        format(p, "content/", f);
        var src: u8[>..] = [];
        read_file(p, src);
        if find(src, "BAD") >= 0 {
            var m: u8[>..] = [];
            format(m, p, ":1: error: BAD is not allowed\n");
            write_stderr(m);
            exit(1);
        }
        n += 1;
    }
    var out: u8[>..] = [];
    format(out, hk::LABEL, " ", n, " files, answer ", kv::answer(), ", ", trim(NOTE), "\n");
    write_file("public/hooked.txt", out);
    append_file("hook.log", "hk\n");
    write_stdout("hk: checked\n");
}
