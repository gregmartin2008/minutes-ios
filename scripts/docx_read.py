"""Reads the paragraphs of a Word (.docx) file with the standard library only."""
import io, zipfile
import xml.etree.ElementTree as ET

W = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"


def paragraphs(data):
    """Returns [(style id or None, text)] for every paragraph of the document, in order."""
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        bad = z.testzip()
        if bad:
            raise ValueError(f"damaged entry in the Word file: {bad}")
        for name in z.namelist():           # every part must be well-formed XML
            ET.fromstring(z.read(name))
        root = ET.fromstring(z.read("word/document.xml"))
    out = []
    for p in root.iter(W + "p"):
        style = p.find(f"{W}pPr/{W}pStyle")
        text = "".join(t.text or "" for t in p.iter(W + "t"))
        out.append((style.get(W + "val") if style is not None else None, text))
    return out


def transcript(parts):
    """The (speaker heading, speech) pairs after the Transcript heading."""
    start = next((i for i, (s, t) in enumerate(parts) if s == "Heading1" and t == "Transcript"), None)
    if start is None:
        return None
    out, speaker = [], None
    for style, text in parts[start + 1:]:
        if style == "Speaker":
            speaker = text
        elif style is None and speaker is not None:
            out.append((speaker, text))
    return out
