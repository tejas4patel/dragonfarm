"""Documents -> text -> chunks, with provenance.

    python -m dragonfarm.documents build --out DIR --name NAME [options] PATH_OR_URL...
    python -m dragonfarm.documents read PATH_OR_URL        # print the extracted text (debugging)

Readers turn PDF, HTML, Markdown, plain text, Word (.docx), spreadsheets
(.xlsx, .csv, .tsv) and web pages into a light Markdown: headings as ``#``
lines, quoted material as ``> `` lines, code as fenced blocks. One chunker
then splits that into chunks of about ``max_words`` words that never cross a
heading, each keeping the file (or URL) and the section heading it came
from, so an answer can cite where it came from.

A document set lives in one directory:

    manifest.json   the sources, their hashes, chunk counts, flags, errors
    chunks.jsonl    one chunk per line: id, source, section, text, n_words,
                    quoted, code, weight

Building again over the same directory re-reads only sources whose bytes
changed and keeps the other chunks as they were.

Nothing in this module needs torch or a model. pypdf, python-docx and
openpyxl are imported only when a file of that kind is read, so a missing
one fails with a clear message for that source and nothing else.
"""

import argparse
import csv
import hashlib
import io
import json
import os
import re
import sys
import time
import urllib.request
from html.parser import HTMLParser
from pathlib import Path

from .errors import DragonError, classify

SUPPORTED = {".pdf", ".html", ".htm", ".md", ".markdown", ".txt", ".docx", ".xlsx", ".xlsm", ".csv", ".tsv"}
# Formats people often have, and the one-step way to a supported one.
SAVE_AS = {
    ".doc": "save it as .docx (Word: File > Save As) and add that",
    ".rtf": "save it as .docx (Word: File > Save As) and add that",
    ".odt": "save it as .docx and add that",
    ".xls": "save it as .xlsx (Excel: File > Save As) and add that",
    ".ods": "save it as .xlsx and add that",
    ".ppt": "export it to PDF (PowerPoint: File > Export) and add that",
    ".pptx": "export it to PDF (PowerPoint: File > Export) and add that",
    ".odp": "export it to PDF and add that",
}
CHANGELOG_NAMES = re.compile(r"^(news|changelog|changes|history|releases?|whatsnew)\b", re.I)
# "v1.2", "Version 1.2", "pkg 0.3.4", "0.3.4": an optional v/version marker or a
# single leading word, then the dotted number.
VERSION_START = re.compile(r"^(?:(v(?:ersion)?)\s*|[A-Za-z][\w.-]*\s+)?(\d+(?:\.\d+)+)\b", re.I)


def version_heading(section):
    """Does a section heading name a release? "0.3.4", "v1.2", "Version 1.2 highlights",
    "pkg 0.3.4 (2026-01-01)" and "(development version)" do; the numbered section
    titles of a manual or FAQ ("2.1 What is R?", "2.5.1 How can R be installed") do not."""
    s = (section or "").strip()
    if not s:
        return False
    if re.search(r"\(development version\)", s, re.I) or re.match(r"^\d{4}-\d{2}-\d{2}", s):
        return True
    m = VERSION_START.match(s)
    if not m:
        return False
    prefixed = bool(m.group(1))
    parts = m.group(2).count(".") + 1
    rest = re.sub(r"\([^)]*\)", "", s[m.end():]).strip(" :-\u2013\u2014\u00b6")
    words = len(rest.split())
    return prefixed or words == 0 or (parts >= 3 and words <= 2)
# Private-use glyphs (icon fonts in HTML, bullets in PDFs) and zero-width marks.
# Bumped whenever a reader or the chunker changes what a file turns into, so a
# set built by an older version is re-read rather than reused by checksum.
READER_VERSION = 19   # 19: text files in Windows-1252 or UTF-16; 18: a short PDF without pictures is read
# "(dollars in millions, except per share data)": the unit note a filing puts
# once above a section or statement. Carried into later chunks that show money
# without a unit word, so "$11,339" is not read as eleven thousand dollars.
UNIT_NOTE = re.compile(r"\((?:[^()]{0,40}\s)?in (?:millions|thousands|billions)\b[^()]{0,80}\)", re.I)
MONEY = re.compile(r"\$\s?\d|\(\d{1,3}(?:,\d{3})+\)")
# Runs of four or more spaced dots: the leaders that pad a contents line or a
# table label ("Net sales . . . . . . 249,625"). Three dots, an ellipsis, stay.
DOT_LEADER = re.compile(r"(?:\s?\.){4,}")
UNIT_WORD = re.compile(r"\b(?:millions?|billions?|thousands?)\b", re.I)
# Between parts that must not share a chunk (the sheets of a workbook): a short
# part after it stands alone instead of being folded into the previous chunk.
HARD_BREAK = "\x02break"
# One per PDF page in the text handed to chunk_text(); never shown to anyone.
PAGE_MARK = re.compile(r"^\x01page (\d+)$")
ANCHOR_GLYPH = re.compile(r"\s*(?:[\u00b6\u00a7#\u2693\U0001f517]|Permalink(?: to this heading)?)+\s*$", re.I)
JUNK = re.compile(r"[-​‌‍﻿]")
USER_AGENT = "dragonfarm/0.4 (+https://dragonfarm.dev)"


def words(s):
    return len(s.split())


# ---------------------------------------------------------------- readers
class _Html(HTMLParser):
    SKIP = {"script", "style", "nav", "header", "footer", "svg", "button", "noscript", "head", "form", "aside"}
    VOID = {"meta", "link", "br", "img", "hr", "input", "source", "wbr"}
    BLOCK = {"p", "li", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "tr", "div", "section", "article",
             "blockquote", "dt", "dd", "figcaption", "summary"}

    def __init__(self, main_only):
        super().__init__(convert_charrefs=True)
        self.out, self.cur = [], []
        self.head, self.pre, self.quote = None, 0, 0
        self.main_only, self.in_main = main_only, 0
        self.skip_tag, self.skip_depth = None, 0
        self.title = None
        self._in_title = False
        self.in_link, self.link_chars, self.n_links = 0, 0, 0

    def _active(self):
        return self.skip_tag is None and (not self.main_only or self.in_main > 0)

    def _flush(self):
        t = "".join(self.cur)
        t = t.strip("\n") if self.pre else t.strip()
        if t:
            if self.head:
                # Drop the anchor glyph many generators append to headings (pilcrow,
                # section sign, hash, link emoji) so section names read cleanly.
                t = ANCHOR_GLYPH.sub("", re.sub(r"\s+", " ", t)).strip()
                self.out.append("#" * self.head + " " + t)
            elif self.pre:
                self.out.append("```\n" + t + "\n```")
            elif self.quote:
                self.out.append("\n".join("> " + line for line in t.splitlines() if line.strip()))
            elif self.n_links >= 4 and self.link_chars >= 0.6 * len(re.sub(r"\s", "", t)):
                pass   # a menu or link list without a <nav> tag: mostly links, no content
            else:
                self.out.append(t)
        self.cur, self.head = [], None
        self.link_chars, self.n_links = 0, 0

    def handle_starttag(self, tag, attrs):
        if tag == "title":
            self._in_title = True
        if tag in self.VOID:
            if tag == "br" and self._active():
                self.cur.append("\n" if self.pre else " ")
            return
        a = dict(attrs)
        if self.skip_tag is not None:
            if tag == self.skip_tag:
                self.skip_depth += 1
            return
        cls = a.get("class") or ""
        role = (a.get("role") or "").lower()
        if (tag in self.SKIP or "visually-hidden" in cls or "sr-only" in cls
                or role in ("navigation", "banner", "contentinfo", "search")):
            self._flush()
            self.skip_tag, self.skip_depth = tag, 1
            return
        if tag == "main":
            self.in_main += 1
        if not self._active():
            return
        if tag in self.BLOCK:
            self._flush()
            if tag[0] == "h" and tag[1:].isdigit():
                self.head = min(int(tag[1:]), 4)
            if tag == "pre":
                self.pre += 1
            if tag == "blockquote":
                self.quote += 1
        if tag in ("td", "th") and self.cur:
            self.cur.append(" | ")
        if tag == "a":
            self.in_link += 1
            self.n_links += 1

    def handle_endtag(self, tag):
        if tag == "title":
            self._in_title = False
        if tag in self.VOID:
            return
        if self.skip_tag is not None:
            if tag == self.skip_tag:
                self.skip_depth -= 1
                if self.skip_depth == 0:
                    self.skip_tag = None
            return
        if tag == "main":
            self._flush()
            self.in_main -= 1
            return
        if tag == "a":
            self.in_link = max(0, self.in_link - 1)
        if not self._active():
            return
        if tag in self.BLOCK:
            self._flush()
            if tag == "pre":
                self.pre = max(0, self.pre - 1)
            if tag == "blockquote":
                self.quote = max(0, self.quote - 1)

    def handle_data(self, d):
        if self._in_title and self.title is None and d.strip():
            self.title = d.strip()
        if self._active():
            self.cur.append(d if self.pre else re.sub(r"\s+", " ", d))
            if self.in_link:
                self.link_chars += len(re.sub(r"\s", "", d))


def html_to_text(raw):
    p = _Html("<main" in raw)
    p.feed(raw)
    p._flush()
    return "\n\n".join(p.out)


def decode_text(data, charset=None):
    """Bytes of a text file to str. UTF-8 (with or without a byte-order mark)
    when the bytes are valid UTF-8; UTF-16 when a byte-order mark says so; then
    the charset a web server declared; then Windows-1252, which is what Excel
    and Notepad on Windows long saved (read as UTF-8, its accented letters
    came out as replacement marks). Latin-1 last, since it never fails.
    A UTF-8 file with a stray bad byte stays UTF-8: more good accented
    characters than bad bytes means the file is UTF-8, damaged in places."""
    if data[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return data.decode("utf-16", errors="replace")
    try:
        return data.decode("utf-8-sig")
    except UnicodeDecodeError:
        loose = data.decode("utf-8-sig", errors="replace")
        bad = loose.count("�")
        if sum(ord(c) > 127 for c in loose) - bad > bad:
            return loose
    for enc in (charset, "cp1252"):
        if enc:
            try:
                return data.decode(enc)
            except (UnicodeDecodeError, LookupError):
                pass
    return data.decode("latin-1")


def read_html(path):
    return html_to_text(decode_text(Path(path).read_bytes()))


def read_text(path):
    return decode_text(Path(path).read_bytes())


def _need(module, pip_name, kind):
    try:
        return __import__(module)
    except ImportError:
        raise RuntimeError(f"reading {kind} files needs the Python package {pip_name}; "
                           f"it is in dragonfarm's requirements, so run dragon_check() to refresh the environment")


def pdf_to_text(fh):
    pypdf = _need("pypdf", "pypdf", "PDF")
    reader = pypdf.PdfReader(fh)
    if getattr(reader, "is_encrypted", False):
        # Most encrypted PDFs only restrict printing or editing and open with
        # an empty password, which pypdf tries; AES ones need `cryptography`.
        try:
            opened = reader.decrypt("")
        except pypdf.errors.DependencyError:
            raise DragonError("ENCRYPTED_NEEDS_CRYPTOGRAPHY", "this PDF is encrypted (AES) and reading it needs the Python package "
                             "cryptography; install it in the Python dragonfarm uses") from None
        if not opened:
            raise DragonError("PASSWORD_PROTECTED", "this PDF is password-protected; open it, save an unlocked copy "
                             "(or print it to PDF), and add that")
    pages = []
    for page in reader.pages:
        text = page.extract_text() or ""
        if fragmented(text):
            # Some PDFs (typesetting tools that place every few glyphs as a
            # separate text object: annual reports, brochures) come out of the
            # plain extractor as two-letter lines, "De", "ce", "mb", "er".
            # pypdf's layout mode reads those by position and gives words back.
            try:
                text = tidy_layout(page.extract_text(extraction_mode="layout") or text)
            except Exception:   # older pypdf has no layout mode, and layout can fail on an odd page
                pass
        # No-break spaces as plain spaces: with "CALIFORNIA\u00a0\u2013\u00a0140" a 7B read
        # past the number and said the report did not give it.
        pages.append(LOST_APOSTROPHE.sub("\u2019", text).replace("\u00a0", " "))
    return pages_to_text(pages)


def fragmented(text, max_median=4, min_lines=20):
    """True when extracted text is mostly tiny lines: glyph runs, not words."""
    lines = [l.strip() for l in text.splitlines() if l.strip()]
    if len(lines) < min_lines:
        return False
    lengths = sorted(len(l) for l in lines)
    return lengths[len(lengths) // 2] <= max_median


def tidy_layout(text):
    """Layout-mode text keeps column positions as runs of spaces; collapse them
    to single spaces and drop trailing blanks, keeping the blank lines that
    separate paragraphs."""
    return "\n".join(re.sub(r" {2,}", " ", l).strip() for l in text.splitlines())


PAGE_NUMBER = re.compile(r"^[\divxlc]+$", re.I)
# A contents entry set with a dot leader: "Item 1A. Risk Factors . . .. . 10".
# One small page number after the dots, no currency: a financial table row has
# "$" or several amounts, so it is left alone.
LEADER_ENTRY = re.compile(r"(?:\.\s*){4,}\s*\d{1,3}$")
# An apostrophe the font did not map comes out as U+FFFD: "Registrant\ufffds".
LOST_APOSTROPHE = re.compile(r"(?<=[A-Za-z])\ufffd(?=(?:s|t|re|ll|ve|d|m)\b)")
CONTENTS_LINE = re.compile(r"^(\d+(\.\d+)*|[A-Z](\.\d+)*|Chapter \d+:?|Appendix [A-Z]:?)\s.*\d+$")
CODE_LINE = re.compile(r"^[>+$#%]|<-|\(\)|==|=>")


def running_lines(pages):
    """Lines that recur at the top or bottom of several pages, with digits removed:
    chapter titles, document names, page numbers."""
    counts = {}
    for text in pages:
        lines = [l.strip() for l in text.splitlines() if l.strip()]
        edge = lines[:2] + lines[-2:]
        for key in {re.sub(r"\d+", "", l) for l in edge}:
            counts[key] = counts.get(key, 0) + 1
    floor = max(3, len(pages) // 10)
    return {k for k, n in counts.items() if n >= floor}


def all_caps_title(line):
    """Two or more words in capitals ("CONSOLIDATED STATEMENTS OF INCOME"): a
    title, never the continuation of a sentence from the previous page."""
    letters = [c for c in line if c.isalpha()]
    return len(line.split()) >= 2 and len(letters) >= 6 and sum(c.isupper() for c in letters) >= 0.9 * len(letters)


def repetitive(line):
    """A column header such as "52 Weeks Ended 53 Weeks Ended 52 Weeks Ended":
    most of its words are repeats."""
    words = line.lower().split()
    return len(words) >= 4 and len(set(words)) <= len(words) / 2


def mostly_letters(line):
    """At least half of the non-space characters are letters: true of "2.3
    Generating regular sequences", false of a row of numbers."""
    chars = [c for c in line if not c.isspace()]
    return bool(chars) and sum(c.isalpha() for c in chars) >= 0.5 * len(chars)


YEAR_HEADER = re.compile(r"^(?:(?:19|20)\d\d\s+){1,5}(?:19|20)\d\d$")
YEAR_VALUE = re.compile(r"^\$?\(?-?[\d,]*\d(?:\.\d+)?\)?%?$|^[\u2014\u2013-]$")


def label_year_columns(lines):
    """Financial tables put the years once, above the figures:

        2024 2023 2022
        Net cash used in investing activities ... (4,409) (4,972) (3,915)

    Flattened into text, nothing says which figure belongs to which year, and
    answers came back from the wrong column. Rows under a year header that end
    in exactly one figure per year are rewritten with the years attached:
    "Net cash used in investing activities (2024: (4,409); 2023: (4,972);
    2022: (3,915))". Other lines are left alone."""
    out, years, misses = [], None, 0
    for line in lines:
        bare = line.strip()
        if YEAR_HEADER.match(bare):
            years, misses = bare.split(), 0
            out.append(line)
            continue
        if years and bare:
            norm = re.sub(r"\$\s+", "$", re.sub(r"\s+%", "%", bare))
            toks = norm.split()
            vals = []
            while toks and len(vals) < len(years) and YEAR_VALUE.match(toks[-1]):
                vals.insert(0, toks.pop())
            label = DOT_LEADER.sub(" ", " ".join(toks)).strip(" .")
            if len(vals) == len(years) and re.search(r"[A-Za-z]{3,}", label):
                pairs = "; ".join(f"{y}: {v}" for y, v in zip(years, vals))
                out.append(f"{label} ({pairs})")
                misses = 0
                continue
            misses += 1
            if misses >= 3:
                years = None
        out.append(line)
    return out


# One entry of a list printed a line each, "CALIFORNIA – 140" or
# "Ontario - 41": a name, a dash, a count. Joined with spaces, a run of them
# read "CALIFORNIA – 140 COLORADO – 16 CONNECTICUT – 8", and a 7B
# answered 8 for California.
LIST_ENTRY = re.compile(r"^[^\W\d_][^\d\n]{0,40}\s[–—-]\s\d[\d,]*$")


def join_lines(lines):
    """Lines of one paragraph, with "; " between consecutive list entries."""
    out = lines[0]
    for prev, line in zip(lines, lines[1:]):
        out += ("; " if LIST_ENTRY.match(prev) and LIST_ENTRY.match(line) else " ") + line
    return out


NUMBERED_HEADING = re.compile(r"^\d+(\.\d+){1,3}\s+[A-Z]")
# Outline headings in guidance and policy documents: "I. INTRODUCTION",
# "III. RECOMMENDATIONS FOR ...", "A. General Considerations". Their ". " used
# to mark them as sentences, so in FDA guidances no section after the cover
# page was ever started. "1. Title" is left out: in R's data import manual
# those are list items ("4. Missing values"), and as headings they mislabelled
# the paragraphs after the list.
OUTLINE_HEADING = re.compile(r"^(?:[IVXL]{1,6}|[A-Z])\.\s+[A-Z][A-Za-z]")
# A street address or letterhead line ("10001 New Hampshire Ave., Hillandale
# Bldg., 4th Floor") is never a heading; it labelled 48 of 153 chunks of four
# FDA guidances.
ADDRESS_LINE = re.compile(r"^\d{1,6}\s+(?:[A-Z][\w'.-]*\s+){1,4}(?:Ave(?:nue)?|St(?:reet)?|Road|Rd|Blvd|Boulevard|"
                          r"Drive|Dr|Lane|Ln|Way|Pkwy|Parkway|Court|Ct|Place|Pl|Square|Sq|Highway|Hwy)\b"
                          r"|,\s*(?:Suite|Ste\.?|Floor|Fl\.|Bldg\.?|Building|Room|P\.?\s?O\.?\s?Box)\b")


def outline_heading(line):
    """An outline-numbered title: one "N. " at the start and no other sentence break."""
    m = OUTLINE_HEADING.match(line)
    return bool(m) and ". " not in line[line.index(". ") + 2:]


def pages_to_text(pages):
    """Paragraphs and '## ' headings from the extracted text of each page.

    Headings are guessed: a short line without end punctuation that starts a
    paragraph, begins with a capital or a section number, and is not code.
    Repeated page furniture, contents entries, and bare page numbers are
    dropped, and a sentence that breaks across a page boundary is rejoined."""
    recurring = running_lines(pages) if len(pages) >= 3 else set()
    paras, buf = [], []

    def flush():
        if buf:
            paras.append(join_lines(buf))
            buf.clear()

    def last_text():
        for k in range(len(paras) - 1, -1, -1):
            if not PAGE_MARK.match(paras[k]):
                return k
        return None

    def open_sentence():
        k = last_text()
        return k is not None and not paras[k].startswith("## ") and not re.search(r"[.:?!)]$", paras[k])

    for page_no, text in enumerate(pages, 1):
        flush()
        if len(pages) > 1:
            paras.append("\x01page %d" % page_no)
        lines = label_year_columns([l.strip() for l in text.splitlines()])
        nonblank = [i for i, l in enumerate(lines) if l]
        edges = set(nonblank[:2] + nonblank[-2:])
        page_start = True
        for i, line in enumerate(lines):
            if not line:
                flush()
                continue
            if i in edges and (re.sub(r"\d+", "", line) in recurring or PAGE_NUMBER.match(line)):
                continue
            if (CONTENTS_LINE.match(line) or re.match(r"^(Table of )?Contents$", line, re.I)
                    or (LEADER_ENTRY.search(line) and "$" not in line)):
                continue
            line = re.sub(r" {2,}", " ", DOT_LEADER.sub(" ", line)).strip()
            if not line:
                continue
            if page_start:
                page_start = False
                if (open_sentence() and not re.match(r"^\d+(\.\d+)*\s", line) and not all_caps_title(line)
                        and not outline_heading(line)):
                    # The sentence ran off the previous page: carry on with it
                    # (it is then credited to the page where it ends).
                    buf.append(paras.pop(last_text()))
                    buf.append(line)
                    if re.search(r"[.:]$", line) and len(line) < 60:
                        flush()
                    continue
            following = next((l for l in lines[i + 1:] if l), "")
            outline = outline_heading(line)
            heading_like = (
                4 <= len(line) < (90 if outline else 55)
                and (len(line.split()) >= 2 or re.match(r"^\d", line))   # "In", "Mr": a wrapped word, not a title
                and (not re.search(r"[.,;:)\d]$", line)
                     or (outline and re.search(r"\((?:[A-Z]\.)?\d+(\.\d+)*\)$", line)))   # "III. ESTIMANDS (A.3)"
                and not re.match(r"^[\d\W]+$", line)
                and re.match(r"^[A-Z\d]", line)
                and not CODE_LINE.search(line)
                and (". " not in line or outline)          # a sentence, not a title
                and not ADDRESS_LINE.search(line)          # letterhead: "10001 New Hampshire Ave., ..."
                and (NUMBERED_HEADING.match(line)          # "6.4 Updating packages" before "update.packages() ..."
                     or not CODE_LINE.search(following))   # "A call such as" before an example
                and mostly_letters(line)                   # "59.75 93.0 900 5 1.9 yes" is a data row
                and not repetitive(line)                   # "52 Weeks Ended 53 Weeks Ended 52 Weeks Ended"
                and not re.match(r"^[a-z]", following)     # the sentence continues on the next line
            )
            # A numbered heading ("6.4 Updating packages") after a long line
            # that ended a sentence: that line did not close its paragraph
            # (only short ones do), so the heading used to be glued on to the
            # end of it and its section was never started. 26 of them in R's
            # installation and data manuals, 29 in An Introduction to R.
            numbered_after_sentence = (bool(buf) and (NUMBERED_HEADING.match(line) or outline)
                                       and re.search(r"[.!?)]$", buf[-1]))
            if heading_like and (not buf or numbered_after_sentence):
                flush()
                paras.append("## " + line)
                continue
            buf.append(line)
            if re.search(r"[.:]$", line) and len(line) < 60:
                flush()
        flush()
    return "\n\n".join(paras)


def read_pdf(path):
    with open(path, "rb") as fh:
        text = pdf_to_text(fh)
    words = len([w for w in re.sub(r"\x01page \d+", " ", text).split() if any(ch.isalnum() for ch in w)])
    if words < 10 and (words == 0 or pdf_has_images(path)):
        # No text layer: pages that are pictures of text (a scan, a photo, a
        # fax). Say so, rather than adding a source that contributes nothing.
        # A short PDF with no pictures at all (a one-line notice) is just short.
        raise DragonError("NO_TEXT_LAYER", "no text layer; this looks like a scanned PDF. Run OCR on it first "
                         "(for example `ocrmypdf in.pdf out.pdf`) and add the result")
    return text


def pdf_has_images(path):
    pypdf = _need("pypdf", "pypdf", "PDF")
    try:
        return any(len(page.images) for page in pypdf.PdfReader(path).pages)
    except Exception:   # an image pypdf cannot list still means a picture is there
        return True


def emphasis_title(para, text):
    """A short paragraph set entirely in bold or entirely in italic that could be
    a title: at most 120 characters, no tab (column headers use tabs), no final
    punctuation, and at least two words of three or more letters. Whether it
    really is a heading is decided by what follows it (see read_docx)."""
    runs = [r for r in para.runs if r.text.strip()]
    if not runs or len(text) > 120 or "\t" in text or text.endswith((".", ":", ";", ",")):
        return False
    style_font = para.style.font if para.style is not None else None

    def on(r, attr):
        v = getattr(r, attr)
        return v if v is not None else bool(style_font is not None and getattr(style_font, attr))

    if not (all(on(r, "bold") for r in runs) or all(on(r, "italic") for r in runs)):
        return False
    return len(re.findall(r"[A-Za-z]{3,}", text)) >= 2


def prose(text):
    """Running text: a dozen words or more ending like a sentence."""
    return len(text.split()) >= 12 and text.rstrip().endswith((".", ".)", ".\u201d", ":"))


def docx_table_rows(table):
    """Text rows of a Word table. A merged cell is returned by python-docx once
    per grid column it spans, so "249,625" came out twice and a section label
    seven times; cells are collapsed by identity, which keeps two genuinely
    equal neighbours. Under a row whose cells carry years ("September 1,
    2024 | September 3, 2023 | ..."), rows with one figure per year get the
    years attached, as label_year_columns() does for PDFs."""
    rows, years = [], None
    for row in table.rows:
        seen, cells = set(), []
        for c in row.cells:
            if id(c._tc) in seen:
                continue
            seen.add(id(c._tc))
            text = re.sub(r"\s+", " ", DOT_LEADER.sub(" ", c.text)).strip()
            cells.append(re.sub(r"\$ (?=[\d(])", "$", text))
        while len(cells) > 1 and not cells[-1]:
            cells.pop()
        if not any(cells):
            continue
        filled = [c for c in cells if c]
        found = [re.search(r"\b(?:19|20)\d\d\b", c) for c in filled]
        if len(filled) >= 2 and all(found) and not any(YEAR_VALUE.match(c.replace(" ", "")) and len(c) > 4 for c in filled):
            years = [m.group(0) for m in found]
            rows.append(" | ".join(filled))
            continue
        label, values = (cells[0], [c for c in cells[1:] if c]) if cells else ("", [])
        if (years and label and re.search(r"[A-Za-z]{3,}", label) and len(values) == len(years)
                and all(YEAR_VALUE.match(v.replace(" ", "")) for v in values)):
            rows.append(f"{label} (" + "; ".join(f"{y}: {v}" for y, v in zip(years, values)) + ")")
            continue
        rows.append(" | ".join(c for k, c in enumerate(cells) if c or k == 0))
    return rows


def read_docx(path):
    docx = _need("docx", "python-docx", "Word")
    doc = docx.Document(path)
    out = []
    for block in doc.element.body.iterchildren():
        tag = block.tag.rsplit("}", 1)[-1]
        if tag == "p":
            para = docx.text.paragraph.Paragraph(block, doc)
            text = para.text.strip()
            if not text:
                continue
            style = (para.style.name if para.style is not None else "") or ""
            m = re.match(r"heading\s*(\d)", style, re.I)
            if m:
                out.append("#" * min(int(m.group(1)), 4) + " " + text)
            elif style.lower().startswith(("quote", "intense quote")):
                out.append("> " + text)
            elif "list" in style.lower():
                out.append("- " + text)
            elif emphasis_title(para, text):
                # Many documents mark headings with bold or italic type instead of
                # a heading style. Table labels look the same, so the decision
                # waits for the next paragraph: a heading is followed by prose.
                out.append(("CANDIDATE", text))
            else:
                out.append(text)
        elif tag == "tbl":
            out.extend(docx_table_rows(docx.table.Table(block, doc)))
    resolved = []
    for i, item in enumerate(out):
        if isinstance(item, tuple):
            nxt = next((o for o in out[i + 1:] if not isinstance(o, tuple)), "")
            resolved.append(("### " + item[1]) if prose(nxt) else item[1])
        else:
            resolved.append(item)
    return "\n\n".join(resolved)


def looks_like_header(row, body):
    """Is the first row column names? Names are short labels, mostly filled in,
    and not numbers; a key-value sheet ("Source" | "a sentence of text") is not
    a header."""
    cells = ["" if v is None else str(v).strip() for v in row]
    filled = [c for c in cells if c]
    if len(filled) < max(1, len(cells) // 2):
        return False
    if any(len(c) > 60 for c in filled):
        return False
    if any(re.fullmatch(r"[-+$(]?[\d.,%)]+", c) for c in filled):
        return False
    return bool(body)


def key_value_sheet(rows):
    """Two columns, short labels on the left, longer text or values on the right."""
    rows = [r for r in rows if any(v not in (None, "") for v in r)]
    if not rows or any(len([v for v in r if v not in (None, "")]) > 2 for r in rows):
        return False
    left = [str(r[0]).strip() for r in rows if r and r[0] not in (None, "")]
    return len(left) == len(rows) and all(len(k) <= 40 for k in left)


def rows_to_text(sheet_name, header, rows):
    """One paragraph per row, 'column: value' pairs, under a heading per sheet."""
    out = ["## " + sheet_name] if sheet_name else []
    for row in rows:
        cells = ["" if v is None else str(v).strip() for v in row]
        if not any(cells):
            continue
        if header:
            pairs = [f"{h}: {v}" for h, v in zip(header, cells) if v]
            out.append("; ".join(pairs))
        elif len([c for c in cells if c]) == 2 and cells[0]:
            out.append(cells[0] + ": " + " ".join(c for c in cells[1:] if c))
        else:
            out.append(" | ".join(c for c in cells if c))
    return "\n\n".join(out)


def read_xlsx(path):
    openpyxl = _need("openpyxl", "openpyxl", "Excel")
    wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
    parts = []
    for ws in wb.worksheets:
        rows = list(ws.iter_rows(values_only=True))
        if not rows:
            continue
        header = [("" if h is None else str(h).strip()) for h in rows[0]]
        has_header = looks_like_header(rows[0], rows[1:]) and not key_value_sheet(rows)
        parts.append(rows_to_text(ws.title, header if has_header else None, rows[1:] if has_header else rows))
    return ("\n\n" + HARD_BREAK + "\n\n").join(parts)


def read_csv(path, delimiter=","):
    rows = list(csv.reader(io.StringIO(decode_text(Path(path).read_bytes()), newline=""), delimiter=delimiter))
    if not rows:
        return ""
    header = [h.strip() for h in rows[0]]
    return rows_to_text(Path(path).stem, header, rows[1:])


def read_tsv(path):
    return read_csv(path, delimiter="\t")


READERS = {
    ".pdf": read_pdf, ".html": read_html, ".htm": read_html,
    ".md": read_text, ".markdown": read_text, ".txt": read_text,
    ".docx": read_docx, ".xlsx": read_xlsx, ".xlsm": read_xlsx,
    ".csv": read_csv, ".tsv": read_tsv,
}


def is_url(s):
    return bool(re.match(r"^https?://", str(s), re.I))


def fetch_url(url, timeout=30):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        ctype = (resp.headers.get("Content-Type") or "").lower()
        data = resp.read()
    return data, ctype


def read_url(url):
    data, ctype = fetch_url(url)
    m = re.search(r"charset=[\"']?([\w.:-]+)", ctype)
    charset = m.group(1) if m else None
    if "pdf" in ctype or url.lower().endswith(".pdf"):
        text = pdf_to_text(io.BytesIO(data))
    elif "html" in ctype or b"<html" in data[:2048].lower():
        text = html_to_text(decode_text(data, charset))
    else:
        text = decode_text(data, charset)
    return text, data


# ---------------------------------------------------------------- chunker
def _unit_kind(u):
    lines = [line for line in u.splitlines() if line.strip()]
    if u.startswith("```"):
        return "code"
    if lines and all(line.lstrip().startswith(">") for line in lines):
        return "quote"
    return "text"


def chunk_text(text, source, max_words=170, min_words=35):
    """Split light Markdown into chunks that never cross a heading."""
    text = JUNK.sub("", text)
    # Keep fenced code blocks whole: protect their inner blank lines.
    fenced = re.split(r"(```.*?```)", text, flags=re.S)
    units = []
    for i, part in enumerate(fenced):
        if i % 2 == 1:
            units.append(part.strip())
            continue
        for block in re.split(r"\n\s*\n", part):
            block = block.strip()
            if block:
                units.append(block)

    chunks, section, cur, cur_w = [], "", [], 0
    page, cur_page = None, None
    unit_note = None
    no_fold = False

    def emit():
        nonlocal cur, cur_w, no_fold
        if not cur:
            return
        body = "\n\n".join(u for u, _ in cur).strip()
        if unit_note and MONEY.search(body) and not UNIT_WORD.search(body):
            body = "[" + unit_note.strip("()") + "]\n\n" + body
        n = words(body)
        kinds = {}
        for u, k in cur:
            kinds[k] = kinds.get(k, 0) + words(u)
        major = max(kinds, key=kinds.get) if kinds else "text"
        rec = {"source": source, "section": section, "text": body, "n_words": n,
               "quoted": major == "quote", "code": major == "code"}
        if cur_page is not None:
            rec["page"] = cur_page
        if rec["code"] or n >= min_words:
            # Code blocks stand on their own however short: they are self-contained and
            # folding them into prose would hide the marker that lets generation skip them.
            chunks.append(rec)
        elif chunks and not chunks[-1]["code"] and not no_fold and chunks[-1]["n_words"] + n <= max_words * 1.5:
            # A short section: fold it into the previous chunk when that stays a sane size.
            prev = chunks[-1]
            prev["text"] += "\n\n" + ((section + ". ") if section and section != prev["section"] else "") + body
            prev["n_words"] = words(prev["text"])
        elif n >= 12 or not chunks or no_fold:
            # Keep it: either long enough to stand alone, or the only content this source has
            # (a two-line FAQ spreadsheet must still produce a chunk).
            chunks.append(rec)
        cur, cur_w = [], 0
        no_fold = False

    for u in units:
        if u == HARD_BREAK:
            emit()
            no_fold = True
            continue
        pm = PAGE_MARK.match(u)
        if pm:
            page = int(pm.group(1))
            continue
        m = re.match(r"^(#{1,6})\s+(.*)", u)
        if m and "\n" not in u and len(u) <= 200:
            title = m.group(2).strip()
            note = UNIT_NOTE.search(title)
            if note:
                # "(amounts in millions)" styled as a heading, alone or in front of
                # the real title: it sets the unit; whatever is left is the section.
                unit_note = note.group(0)
                title = (title[:note.start()] + " " + title[note.end():]).strip(" -—:")
                if not title:
                    continue
            emit()
            section = title
            continue
        note = UNIT_NOTE.search(u)
        w = words(u)
        if cur and cur_w + w > max_words:
            emit()
        if note:
            unit_note = note.group(0)
        if not cur:
            cur_page = page
        cur.append((u, _unit_kind(u)))
        cur_w += w
    emit()
    return chunks


def changelog_like(display_name, chunks):
    if CHANGELOG_NAMES.match(Path(display_name).stem):
        return True
    if not chunks:
        return False
    versioned = sum(1 for c in chunks if version_heading(c["section"]))
    return versioned / len(chunks) >= 0.6


# ---------------------------------------------------------------- building a set
def expand_paths(paths, skipped=None):
    """Files and URLs to read, in order; directories are walked for supported
    files. Files in a directory that no reader handles are added to `skipped`
    (hidden files and Office lock files "~$..." aside), so the user can be told
    rather than left wondering where their .doc went."""
    out = []
    for p in paths:
        if is_url(p):
            out.append(("url", p))
            continue
        path = Path(p)
        if path.is_dir():
            for f in sorted(path.rglob("*")):
                if not f.is_file() or f.name.startswith((".", "~$")):
                    continue
                if f.suffix.lower() in SUPPORTED:
                    out.append(("file", str(f)))
                elif skipped is not None:
                    skipped.append({"name": f.relative_to(path).as_posix(), "ext": f.suffix.lower() or "(none)",
                                    "hint": SAVE_AS.get(f.suffix.lower())})
        else:
            out.append(("file", str(path)))
    return out


def sha256_bytes(b):
    return hashlib.sha256(b).hexdigest()


def display_name(kind, locator):
    return locator if kind == "url" else Path(locator).name


def read_source(kind, locator):
    """Returns (text, raw_bytes). Raises with a readable message on failure."""
    if kind == "url":
        return read_url(locator)
    path = Path(locator)
    if not path.exists():
        raise FileNotFoundError(f"{locator} does not exist")
    reader = READERS.get(path.suffix.lower())
    if reader is None:
        hint = SAVE_AS.get(path.suffix.lower())
        raise DragonError("UNSUPPORTED_FILE_TYPE", f"unsupported file type {path.suffix or '(none)'}; "
                         + (hint or "supported: " + ", ".join(sorted(SUPPORTED))))
    return reader(str(path)), path.read_bytes()


def load_manifest(out_dir):
    p = Path(out_dir) / "manifest.json"
    if p.exists():
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    return None


def load_chunks(out_dir):
    p = Path(out_dir) / "chunks.jsonl"
    if not p.exists():
        return []
    with open(p, encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]


def build(paths, out_dir, name, max_words=170, min_words=35, log=None):
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    log = log or (lambda *_: None)
    old = load_manifest(out_dir)
    old_sources = {s["locator"]: s for s in (old or {}).get("sources", [])}
    chunking = {"max_words": max_words, "min_words": min_words, "reader": READER_VERSION}
    same_chunking = bool(old) and old.get("chunking") == chunking
    old_chunks = load_chunks(out_dir) if same_chunking else []

    sources, all_chunks = [], []
    n_reused = 0
    skipped = []
    for kind, locator in expand_paths(paths, skipped):
        shown = display_name(kind, locator)
        entry = {"locator": locator, "kind": kind, "name": shown, "reader": Path(shown).suffix.lower() or "url",
                 "sha256": None, "bytes": None, "n_chunks": 0, "n_words": 0,
                 "changelog_like": False, "error": None, "read_at": None}
        try:
            if kind == "file":
                if not Path(locator).is_file():
                    raise FileNotFoundError(f"{locator} does not exist")
                raw = Path(locator).read_bytes()
                sha = sha256_bytes(raw)
                prev = old_sources.get(locator)
                if prev and prev.get("sha256") == sha and same_chunking and not prev.get("error"):
                    chunks = [c for c in old_chunks if c["source_id"] == sha[:12]]
                    entry.update(prev)
                    n_reused += 1
                    log(f"unchanged {shown}: {len(chunks)} chunks kept")
                else:
                    text, _ = read_source(kind, locator)
                    chunks = chunk_text(text, shown, max_words, min_words)
                    entry["read_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
                    log(f"read {shown}: {words(text)} words -> {len(chunks)} chunks")
                entry["sha256"], entry["bytes"] = sha, len(raw)
            else:
                text, raw = read_source(kind, locator)
                sha = sha256_bytes(raw)
                chunks = chunk_text(text, shown, max_words, min_words)
                entry.update(sha256=sha, bytes=len(raw), read_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
                log(f"fetched {shown}: {words(text)} words -> {len(chunks)} chunks")
        except Exception as e:  # noqa: BLE001 - one bad source must not sink the set
            entry["error"] = f"{type(e).__name__}: {e}"
            entry["code"] = classify(e)
            log(f"failed {shown}: {entry['error']}")
            sources.append(entry)
            continue
        flagged = changelog_like(shown, chunks)
        for i, c in enumerate(chunks):
            c["id"] = f"{sha[:12]}-{i:03d}"
            c["source_id"] = sha[:12]
            c["weight"] = 0.7 if flagged else 1.0
        entry.update(n_chunks=len(chunks), n_words=sum(c["n_words"] for c in chunks), changelog_like=flagged)
        sources.append(entry)
        all_chunks.extend(chunks)

    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    manifest = {
        "schema_version": 1,
        "name": name,
        "created_at": (old or {}).get("created_at") or now,
        "updated_at": now,
        "chunking": chunking,
        "sources": sources,
        "n_chunks": len(all_chunks),
        "index": (old or {}).get("index") if same_chunking and n_reused == len(sources) and all(not s["error"] for s in sources) else None,
    }
    tmp = out_dir / "chunks.jsonl.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        for c in all_chunks:
            f.write(json.dumps(c, ensure_ascii=False) + "\n")
    os.replace(tmp, out_dir / "chunks.jsonl")
    with open(out_dir / "manifest.json", "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)
    return {"dir": str(out_dir), "name": name, "n_sources": len(sources), "n_chunks": len(all_chunks),
            "n_reused": n_reused, "n_failed": sum(1 for s in sources if s["error"]),
            "failed": [{"name": s["name"], "error": s["error"], "code": s.get("code") or "UNKNOWN"} for s in sources if s["error"]],
            "skipped": skipped}


def main(argv=None):
    ap = argparse.ArgumentParser(prog="python -m dragonfarm.documents")
    sub = ap.add_subparsers(dest="command", required=True)
    b = sub.add_parser("build", help="Read, chunk, and write a document set.")
    b.add_argument("paths", nargs="+")
    b.add_argument("--out", required=True)
    b.add_argument("--name", required=True)
    b.add_argument("--max-words", type=int, default=170)
    b.add_argument("--min-words", type=int, default=35)
    r = sub.add_parser("read", help="Print the extracted text of one file or URL.")
    r.add_argument("path")
    a = ap.parse_args(argv)
    if a.command == "read":
        kind = "url" if is_url(a.path) else "file"
        text, _ = read_source(kind, a.path)
        sys.stdout.write(text)
        return
    summary = build(a.paths, a.out, a.name, a.max_words, a.min_words,
                    log=lambda m: print(f"[dragonfarm] {m}", file=sys.stderr, flush=True))
    print(json.dumps(summary))


if __name__ == "__main__":
    main()
