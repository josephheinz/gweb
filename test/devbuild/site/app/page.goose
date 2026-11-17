import std;
import net.http;
import gweb;
import Card;
struct Props { n: i64, card: Card::State }
fn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props {
    return Props { n: 1, card: Card::State { n: 2 } };
}
