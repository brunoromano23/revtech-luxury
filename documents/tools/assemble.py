#!/usr/bin/env python3
"""
Turns marked's flat HTML into the structured document WeasyPrint renders.

    assemble.py <body.html> <source-dir> <out.html> <head.html>

This used to run as JavaScript inside a headless browser, because Paged.js needed a DOM. WeasyPrint
executes no JavaScript, so every transform happens here instead — which is the better place for it:
the output is a static HTML file that can be opened and inspected when a layout goes wrong.

The transforms, in order:
  1. inline `<!-- include: assets/x.svg -->` directives
  2. lift everything before the first <hr> onto a cover page
  3. split "4 Data model" headings into a brass number and a title
  4. build the contents page (WeasyPrint resolves the page numbers itself, via target-counter)
  5. tag design-decision blockquotes, figure captions and table captions
  6. keep each figure with the heading that introduces it
"""
import os
import re
import sys

from bs4 import BeautifulSoup, NavigableString

body_path, src_dir, out_path, head_path = sys.argv[1:5]


def inline_includes(html: str) -> str:
    def repl(match):
        rel = match.group(1).strip()
        target = os.path.join(src_dir, rel)
        if not os.path.isfile(target):
            sys.exit(f"include not found: {target}")
        svg = open(target, encoding="utf-8").read()
        svg = re.sub(r"^<\?xml[^>]*\?>\s*", "", svg)  # invalid inside HTML
        print(f"  inlined {rel}")
        return svg

    html, n = re.subn(r"<!--\s*include:\s*([^>]+?)\s*-->", repl, html)
    if not n:
        print("  (no includes)")
    return html


soup = BeautifulSoup(inline_includes(open(body_path, encoding="utf-8").read()), "html.parser")


def build_cover():
    h1 = soup.find("h1")
    if not h1:
        return None
    cover = soup.new_tag("section", attrs={"class": "cover"})
    h1.insert_before(cover)

    node = cover.next_sibling
    while node is not None and getattr(node, "name", None) != "hr":
        nxt = node.next_sibling
        cover.append(node.extract())
        node = nxt
    if node is not None:
        node.extract()

    rule = soup.new_tag("div", attrs={"class": "cover-rule"})
    brass = soup.new_tag("div", attrs={"class": "cover-rule-brass"})
    eyebrow = soup.new_tag("p", attrs={"class": "eyebrow"})
    eyebrow.string = "Luxury Presence · RevTech"
    cover.insert(0, eyebrow)
    cover.insert(0, brass)
    cover.insert(0, rule)

    sub = cover.find("h1")
    sub = sub.find_next_sibling("p") if sub else None
    if sub:
        sub["class"] = "subtitle"

    foot = soup.new_tag("p", attrs={"class": "cover-foot"})
    foot.string = (
        "Prepared for the RevTech Senior Salesforce Developer case study · "
        "Not a Luxury Presence corporate document"
    )
    cover.append(foot)
    return cover


HEADING_NUM = re.compile(r"^((?:Appendix\s+[A-Z]|\d+(?:\.\d+)?))\s+(.*)$")


def number_headings():
    for h in soup.find_all(["h2", "h3"]):
        if h.find_parent(class_="cover"):
            continue
        m = HEADING_NUM.match(h.get_text().strip())
        if not m:
            continue
        h.clear()
        num = soup.new_tag("span", attrs={"class": "num"})
        num.string = m.group(1)
        h.append(num)
        # string-set copies text content, so without a real separator the running header reads
        # "4Data model". A zero-size span keeps the visual spacing under the CSS margin's control.
        sep = soup.new_tag("span", attrs={"class": "numsep"})
        sep.string = " — "
        h.append(sep)
        # "Appendix A — What building it changed" already carries its own dash; adding the
        # separator on top of it renders "Appendix A — — What building it changed".
        title = re.sub(r"^[—–-]\s*", "", m.group(2)).strip()
        h.append(NavigableString(title))


def build_toc(cover):
    if cover is None:
        return
    toc = soup.new_tag("section", attrs={"class": "toc"})
    head = soup.new_tag("p", attrs={"class": "toc-head"})
    head.string = "Contents"
    toc.append(head)

    # A table, not a flex list: WeasyPrint's flexbox leaves stray leader fragments floating in the
    # empty half of the page, and tables it lays out exactly.
    lst = soup.new_tag("table", attrs={"class": "toc-table"})
    n = 0
    for h in soup.find_all(["h2", "h3"]):
        if h.find_parent(class_="cover") or h.find_parent(class_="toc"):
            continue
        n += 1
        if not h.get("id"):
            h["id"] = f"sec-{n}"
        tr = soup.new_tag("tr", attrs={"class": "lvl1" if h.name == "h2" else "lvl2"})

        td_t = soup.new_tag("td", attrs={"class": "t"})
        label = soup.new_tag("span")
        # Rebuild from the parts rather than stripping the separator out of the rendered text:
        # "1 — Scope" should read "1 Scope", but "Appendix A — What building it changed" keeps
        # its dash, because there the dash is the title's own punctuation.
        num_el = h.find("span", class_="num")
        number = num_el.get_text().strip() if num_el else ""
        rest = "".join(
            str(x) for x in h.contents
            if isinstance(x, NavigableString)
        ).strip()
        joiner = " — " if number.lower().startswith("appendix") else " "
        label.string = f"{number}{joiner}{rest}" if number else re.sub(r"\s+", " ", h.get_text()).strip()
        td_t.append(label)

        td_p = soup.new_tag("td", attrs={"class": "pg"})
        # Empty on purpose: the page number is generated content resolved at layout time.
        a = soup.new_tag("a", href=f"#{h['id']}")
        td_p.append(a)

        tr.append(td_t)
        tr.append(td_p)
        lst.append(tr)
    toc.append(lst)
    cover.insert_after(toc)


def tag_callouts():
    for bq in soup.find_all("blockquote"):
        first = bq.find("p")
        if not first:
            continue
        # D-n · DESIGN DECISION in the solution design, REC-n · RECOMMENDATION in the business
        # briefing. Any "<ID> · <LABEL IN CAPS>" opener is an argued choice and renders as one.
        if re.match(r"^[A-Z]{1,3}-\d+\s*·\s*[A-Z][A-Z ]+", first.get_text().strip()):
            first["class"] = "callout-head"
        else:
            bq["class"] = bq.get("class", []) + ["plain"]


def tag_captions():
    for p in soup.find_all("p"):
        text = p.get_text().strip()
        if re.match(r"^FIGURE\s+\d+", text, re.I):
            p["class"] = "figure-caption"
            for child in p.contents:
                if isinstance(child, NavigableString):
                    m = re.match(r"^(FIGURE\s+\d+)(.*)$", str(child), re.S | re.I)
                    if m:
                        label = soup.new_tag("span", attrs={"class": "figure-label"})
                        label.string = m.group(1)
                        child.replace_with(label)
                        label.insert_after(NavigableString(m.group(2)))
                        break
        elif re.match(r"^(TABLE|CASE\s+\d+)\s*—", text, re.I):
            p["class"] = "table-caption"


def bind_headings_to_figures():
    """A figure that starts its own page must take its heading with it.

    Otherwise the break lands between the heading and the diagram and leaves a page carrying two
    lines of heading and nothing else — which is exactly what happened to page 6 of v2.1.
    """
    for fig in soup.find_all(class_=["landscape-figure", "figure"]):
        classes = fig.get("class", [])
        wrapper = soup.new_tag("section", attrs={"class": "figure-block " + " ".join(classes)})
        # Absorb the heading chain immediately above the figure (h3 then h2, where present).
        leading = []
        prev = fig.previous_sibling
        while prev is not None and (
            getattr(prev, "name", None) in (None, "h2", "h3")
        ):
            if getattr(prev, "name", None) is None and not str(prev).strip():
                prev = prev.previous_sibling
                continue
            if getattr(prev, "name", None) not in ("h2", "h3"):
                break
            leading.insert(0, prev)
            prev = prev.previous_sibling

        fig.insert_before(wrapper)
        for node in leading:
            wrapper.append(node.extract())
        wrapper.append(fig.extract())
        # The break now sits before the whole block rather than inside it.
        fig["class"] = [c for c in classes if c not in ("landscape-figure", "figure")] or None
        if not fig.get("class"):
            del fig["class"]
        fig["class"] = ["figure-body"]


cover = build_cover()
number_headings()
build_toc(cover)
tag_callouts()
tag_captions()
bind_headings_to_figures()

with open(out_path, "w", encoding="utf-8") as out:
    out.write(open(head_path, encoding="utf-8").read())
    out.write(str(soup))
    out.write("\n</body></html>\n")

print(f"  assembled {out_path}")
