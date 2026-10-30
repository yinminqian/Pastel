#!/usr/bin/env python3
"""Writes the Sparkle appcast for one release.

    appcast.py OUT VERSION BUILD MIN_SYSTEM DOWNLOAD_URL SIGNATURE LENGTH [NOTES.md]

The feed holds only the latest release: Sparkle needs nothing older to offer an
update, and a single item cannot drift out of order. Release notes are the same
Markdown as the GitHub release, turned into the little HTML Sparkle shows.
"""
import html
import re
import sys
from email.utils import formatdate


def notes_html(markdown: str) -> str:
    out, in_list = [], False
    for line in markdown.splitlines():
        line = line.strip()
        # Code blocks and the install footer are for the GitHub page, not for
        # someone already running the app.
        if line.startswith("```") or line.startswith("**Install:**"):
            break
        text = html.escape(line.lstrip("- ").strip())
        text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text)
        text = re.sub(r"`(.+?)`", r"<code>\1</code>", text)
        if line.startswith("- "):
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append(f"<li>{text}</li>")
        elif line:
            if in_list:
                out.append("</ul>")
                in_list = False
            out.append(f"<p>{text}</p>")
    if in_list:
        out.append("</ul>")
    return "\n".join(out)


def main() -> None:
    out, version, build, min_system, url, signature, length = sys.argv[1:8]
    notes = ""
    if len(sys.argv) > 8:
        with open(sys.argv[8], encoding="utf-8") as f:
            notes = notes_html(f.read())
    description = f"\n      <description><![CDATA[\n{notes}\n      ]]></description>" if notes else ""
    feed = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>paster</title>
    <item>
      <title>{html.escape(version)}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{html.escape(build)}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{html.escape(min_system)}</sparkle:minimumSystemVersion>{description}
      <enclosure url="{html.escape(url)}" type="application/octet-stream"
                 sparkle:edSignature="{html.escape(signature)}" length="{html.escape(length)}"/>
    </item>
  </channel>
</rss>
"""
    with open(out, "w", encoding="utf-8") as f:
        f.write(feed)


if __name__ == "__main__":
    main()
