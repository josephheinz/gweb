# Templates

`page.html` and `layout.html` are templates. Tags are Goose expressions.
The compiler type-checks them, so a wrong field name is a build error.

```html
<h1>{props.title}</h1>
{#if props.items.len == 0}
<p>Nothing here.</p>
{#else}
<ul>
{#for item, i in props.items}
  <li>{i + 1}. {item.name} @price(item.cents)</li>
{/for}
</ul>
{/if}
```

| Syntax | Does |
|---|---|
| `{expr}` | writes the value, HTML-escaped (an enum of a view prints its `ENUM_LABELS` label or variant name, 1.4) |
| `{#raw expr}` | writes it raw |
| `{#if e}` `{#else if e}` `{#else}` `{/if}` | conditions |
| `{#for x in e}`, `{#for x, i in e}`, `{/for}` | loops |
| `{#let n = e}` | a local |
| `{#var n = e}` | a mutable local (1.4), for a helper that fills it by reference: `{#var p = v_types_Post::Props { .. }}{#if site::props_Post(c, p)}{p.title}{/if}`; not in components |
| `@f(a)`, `@ns::f(a)` | calls `f(out, a)` |
| `@Name(expr)` | a component |
| `@slot()` | the page, in a layout |
| `{-- note --}` | a comment |

## Rules

- In scope: `req`, `ctx`, `props` (when `load` exists), and what `page.goose`
  imports.
- A tag may go on over several lines (1.8.6): `{#if a &&\n b}`, `@f(a,\n b)` and `{-- a\n note --}` are joined and
  compile to one Goose line, the lines after it empty, so compiler errors still point at your HTML line (the first
  line of the tag). Inside a tag the line breaks count as spaces. Components (`.gshtml`) keep a tag on one line.
- A literal brace is `&#123;` or `&#125;`. A literal `@` before `name(` is
  `&#64;`.
- Inside `<script>` and `<style>` nothing is a tag. The text passes
  through.
- Use `{#raw}` only for text you trust.

Full reference: [README](../../README.md#templates).
