#!/usr/bin/env python3
"""Renders the README illustrations: every panel style, in English and in
Chinese, from the same template and the same made-up clippings — never from a
real screen. Then the two hero banners, built from three of those shots.

    python3 design/readme/render.py            # everything
    python3 design/readme/render.py en-grid    # one image

Needs Google Chrome; fonts are the system's (SF, PingFang), so run on a Mac.
"""
import html
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.join(HERE, "build")
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
W, H = 1600, 1000          # the mock screen, in CSS px (1 px = 1 pt)
STYLES = ["basic", "minimal", "light-strip", "top-drop", "sidebar", "grid", "palette"]

# ---------------------------------------------------------------- content

APPS = {
    "notes":      ("#F5B400", "✎"),
    "terminal":   ("#2E2E33", ">_"),
    "safari":     ("#2C8AF5", "◎"),
    "screenshot": ("#6E6E76", "◉"),
    "xcode":      ("#3B6BF0", "⚒"),
    "figma":      ("#8E5CF6", "✦"),
    "finder":     ("#1E9BF0", "☺"),
    "messages":   ("#34C759", "✉"),
    "mail":       ("#3A7BFF", "✉"),
    "slack":      ("#B0338F", "#"),
    "photos":     ("#F26B3A", "❀"),
}

# kind, app, age-key, payload
ITEMS = [
    ("text",  "slack",      "now", {"en": "Product review notes — Q4 roadmap confirmed, sync with design and engineering on Monday",
                                    "zh": "产品评审纪要 — Q4 Roadmap 已确认，周一同步给设计和研发"}),
    ("cmd",   "terminal",   "5m",  "git push origin feat/light-list --force-with-lease"),
    ("link",  "safari",     "12m", ("developer.apple.com", "/design/human-interface-guidelines", "Human Interface Guidelines")),
    ("image", "screenshot", "32m", ("chart", "Screenshot 14.02", "1284 × 802")),
    ("code",  "xcode",      "48m", "let rows = clips.prefix(14).map(ClipRow.init)"),
    ("color", "figma",      "1h",  ("#F2552C", "Ember / 500")),
    ("file",  "finder",     "1h",  ("Q4-roadmap-final.pdf", "2.4 MB")),
    ("text",  "messages",   "2h",  {"en": "Meeting at 3 pm tomorrow — bring the signed contract",
                                    "zh": "明天下午三点开会，记得带上打印好的合同"}),
    ("text",  "slack",      "3h",  {"en": "Can you review PR #482 before lunch? Mostly layout.",
                                    "zh": "午饭前能看一下 PR #482 吗？主要是布局改动。"}),
    ("image", "screenshot", "4h",  ("wireframe", "Onboarding v3 — Frame 12", "2880 × 1800")),
    ("text",  "notes",      "1d",  {"en": "1 Infinite Loop, Cupertino, CA 95014",
                                    "zh": "上海市徐汇区漕溪北路 88 号 12 楼，200030"}),
    ("text",  "mail",       "1d",  {"en": "Thanks — I'll send the signed copy by Friday.",
                                    "zh": "谢谢，签好的版本我周五前发你。"}),
    ("cmd",   "terminal",   "1d",  "ssh deploy@10.0.3.21 -p 2222"),
    ("link",  "safari",     "1d",  ("github.com", "/pastel/pastel/pull/482", "Light list for the clip panel · #482")),
    ("image", "photos",     "1d",  ("mountain", "IMG_2291.HEIC", "4032 × 3024")),
    ("color", "figma",      "1d",  ("#2F6BFF", "Ocean / 600")),
    ("code",  "xcode",      "2d",  "SELECT id, kind FROM clips WHERE pinned = 1;"),
    ("text",  "notes",      "2d",  {"en": "Reminder: renew the Apple Developer membership before the 30th",
                                    "zh": "提醒：30 号前续费 Apple Developer 会员"}),
    ("file",  "finder",     "2d",  ("icon_512x512@2x.png", "186 KB")),
    ("link",  "safari",     "2d",  ("figma.com", "/design/Kx9f2/round-3-lists", "Round 3 · lists")),
    ("text",  "messages",   "2d",  {"en": "OK, I'll fix it from this screenshot and send it over this afternoon",
                                    "zh": "好的，我按这版截图改，下午给你看"}),
    ("cmd",   "terminal",   "2d",  "xcodebuild test -scheme paster -destination 'platform=macOS'"),
]

STR = {
    "en": {
        "app": "Notes", "menus": ["File", "Edit", "View", "Window", "Help"], "clock": "Fri 26 Sep  14:08",
        "doc": "Q4 planning · Notes",
        "ages": {"now": "now", "5m": "5 minutes ago", "12m": "12 minutes ago", "32m": "32 minutes ago",
                 "48m": "48 minutes ago", "1h": "1 hour ago", "2h": "2 hours ago", "3h": "3 hours ago",
                 "4h": "4 hours ago", "1d": "Yesterday", "2d": "Wednesday"},
        "short": {"now": "now", "5m": "5m", "12m": "12m", "32m": "32m", "48m": "48m", "1h": "1h",
                  "2h": "2h", "3h": "3h", "4h": "4h", "1d": "1d", "2d": "2d"},
        "kinds": {"text": "Text", "cmd": "Text", "code": "Text", "link": "Link", "image": "Image",
                  "color": "Color", "file": "File"},
        "apps": {"notes": "Notes", "terminal": "Terminal", "safari": "Safari", "screenshot": "Screenshot",
                 "xcode": "Xcode", "figma": "Figma", "finder": "Finder", "messages": "Messages",
                 "mail": "Mail", "slack": "Slack", "photos": "Photos"},
        "clipboard": "Clipboard", "pinned": "Pinned", "search": "Search clipboard",
        "today": "Today", "yesterday": "Yesterday", "wednesday": "Wednesday",
        "chars": "{n} characters", "paste": "Paste", "plain": "Plain text", "pin": "Pin",
        "richtext": "Rich text · copied just now", "all": "All",
    },
    "zh": {
        "app": "备忘录", "menus": ["文件", "编辑", "显示", "窗口", "帮助"], "clock": "9月26日 周五 14:08",
        "doc": "Q4 规划 · 备忘录",
        "ages": {"now": "刚刚", "5m": "5 分钟前", "12m": "12 分钟前", "32m": "32 分钟前",
                 "48m": "48 分钟前", "1h": "1 小时前", "2h": "2 小时前", "3h": "3 小时前",
                 "4h": "4 小时前", "1d": "昨天", "2d": "周三"},
        "short": {"now": "刚刚", "5m": "5分", "12m": "12分", "32m": "32分", "48m": "48分", "1h": "1时",
                  "2h": "2时", "3h": "3时", "4h": "4时", "1d": "1天", "2d": "2天"},
        "kinds": {"text": "文本", "cmd": "文本", "code": "文本", "link": "链接", "image": "图片",
                  "color": "颜色", "file": "文件"},
        "apps": {"notes": "备忘录", "terminal": "终端", "safari": "Safari", "screenshot": "截图",
                 "xcode": "Xcode", "figma": "Figma", "finder": "访达", "messages": "信息",
                 "mail": "邮件", "slack": "Slack", "photos": "照片"},
        "clipboard": "剪贴板", "pinned": "已置顶", "search": "搜索剪贴板",
        "today": "今天", "yesterday": "昨天", "wednesday": "周三",
        "chars": "{n} 个字符", "paste": "粘贴", "plain": "纯文本", "pin": "置顶",
        "richtext": "富文本 · 刚刚复制", "all": "全部",
    },
}

# ---------------------------------------------------------------- pieces

SEARCH_SVG = '<svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><circle cx="10.5" cy="10.5" r="6.5"/><path d="M15.5 15.5 21 21"/></svg>'
CLOCK_SVG = '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 12a8.5 8.5 0 1 0 2.5-6"/><path d="M3 4v4h4"/><path d="M12 7.5V12l3 2"/></svg>'
LIST_SVG = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><path d="M4 7h16M7 12h10M10 17h4"/></svg>'


def esc(s):
    return html.escape(str(s))

def text_of(item, lang):
    kind, _, _, payload = item
    if kind == "text":
        return payload[lang]
    if kind in ("cmd", "code"):
        return payload
    if kind == "link":
        return payload[0] + payload[1]
    if kind == "image":
        return payload[1]
    if kind == "color":
        return payload[0]
    if kind == "file":
        return payload[0]

def app_icon(app, size):
    color, glyph = APPS[app]
    fs = round(size * 0.5)
    return (f'<span class="ai" style="width:{size}px;height:{size}px;background:{color};'
            f'font-size:{fs}px;border-radius:{round(size*0.22)}px">{glyph}</span>')

def picture(kind, w, h, radius=6):
    """A fake picture: a bar chart, an orange wireframe, or a mountain."""
    if kind == "chart":
        bars = "".join(f'<rect x="{6+i*14}" y="{60-v}" width="9" height="{v}" rx="2"/>'
                       for i, v in enumerate([22, 34, 28, 44, 38, 54, 60]))
        inner = (f'<rect width="120" height="70" fill="#fff"/><rect x="6" y="6" width="80" height="6" rx="3" fill="#dcdce2"/>'
                 f'<g fill="#4B7BFF">{bars}</g>')
        vb = "0 0 120 70"
    elif kind == "wireframe":
        inner = ('<rect width="120" height="75" fill="#FFF3EC"/><rect x="10" y="8" width="100" height="26" rx="4" fill="#F2552C"/>'
                 '<rect x="10" y="42" width="70" height="6" rx="3" fill="#2E2E33"/><rect x="10" y="54" width="52" height="6" rx="3" fill="#2E2E33"/>')
        vb = "0 0 120 75"
    else:
        inner = ('<defs><linearGradient id="sky" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#8FB8FF"/><stop offset="1" stop-color="#E9F1FF"/></linearGradient></defs>'
                 '<rect width="120" height="90" fill="url(#sky)"/><path d="M0 70 L30 38 L52 58 L75 30 L100 55 L120 44 L120 90 L0 90Z" fill="#3E6B4F"/>'
                 '<path d="M0 90 L0 76 L40 66 L80 74 L120 64 L120 90Z" fill="#2E4F3B"/>')
        vb = "0 0 120 90"
    return (f'<svg class="pic" viewBox="{vb}" width="{w}" height="{h}" preserveAspectRatio="xMidYMid slice" '
            f'style="border-radius:{radius}px;display:block">{inner}</svg>')

def pdf_icon(size):
    return (f'<svg width="{size}" height="{round(size*1.25)}" viewBox="0 0 40 50"><rect x="1" y="1" width="38" height="48" rx="5" fill="#fff" stroke="#d0d0d6"/>'
            f'<rect x="7" y="33" width="26" height="9" rx="2.5" fill="#E5484D"/><rect x="8" y="10" width="20" height="3" rx="1.5" fill="#d8d8de"/>'
            f'<rect x="8" y="17" width="24" height="3" rx="1.5" fill="#d8d8de"/></svg>')

def swatch(color, w, h, radius=8):
    return f'<span class="sw" style="width:{w}px;height:{h}px;background:{color};border-radius:{radius}px"></span>'

def thumb(item, size, radius=8):
    """The visual for a list row's leading slot."""
    kind, app, _, p = item
    if kind == "image":
        return picture(p[0], size, size, radius)
    if kind == "color":
        return swatch(p[0], size, size, radius)
    if kind == "file":
        return f'<span class="ctr" style="width:{size}px;height:{size}px">{pdf_icon(round(size*0.68))}</span>'
    return app_icon(app, size)

def primary(item, lang, mono_class="mono"):
    kind, _, _, p = item
    if kind in ("cmd", "code"):
        return f'<span class="{mono_class}">{esc(p)}</span>'
    if kind == "link":
        return f'<b>{esc(p[0])}</b><span class="dim">{esc(p[1])}</span>'
    if kind == "color":
        return f'<span class="{mono_class}">{esc(p[0])}</span>'
    if kind in ("image", "file"):
        return esc(p[1] if kind == "image" else p[0])
    return esc(p[lang])

def secondary(item, lang):
    """The quieter second line: app · age, plus one detail."""
    kind, app, age, p = item
    s = STR[lang]
    bits = [s["apps"][app], s["ages"][age]]
    if kind == "image":
        bits.append(p[2])
    elif kind == "color":
        bits.append(p[1])
    elif kind == "file":
        bits.append(p[1])
    return " · ".join(bits)

# ---------------------------------------------------------------- screen

CSS = """
*{box-sizing:border-box;margin:0;padding:0}
html,body{width:%dpx;height:%dpx;overflow:hidden}
body{font-family:system-ui,-apple-system,"Helvetica Neue","PingFang SC",sans-serif;color:#1d1d1f;position:relative;
  background:radial-gradient(900px 700px at 0%% 0%%,#C6D5FF,transparent 70%%),
    radial-gradient(900px 700px at 100%% 0%%,#F4D3EC,transparent 70%%),
    radial-gradient(900px 600px at 20%% 100%%,#FFE3C8,transparent 70%%),
    radial-gradient(800px 600px at 90%% 100%%,#CFEDE5,transparent 70%%),#E9E2FA}
.bar{height:28px;background:#ffffff8c;display:flex;align-items:center;padding:0 16px;gap:20px;font-size:13.5px;font-weight:500}
.bar .app{font-weight:700}.bar .r{margin-left:auto;font-weight:400}
.win{position:absolute;background:#fff;border-radius:12px;box-shadow:0 20px 50px #0002}
.win .t{position:absolute;left:0;right:0;top:0;height:40px;text-align:center;line-height:40px;font-size:13px;color:#6e6e73}
.dots{position:absolute;left:14px;top:14px;display:flex;gap:8px}.dots i{width:12px;height:12px;border-radius:50%%;display:block}
.line{position:absolute;height:9px;border-radius:5px;background:#E6E6EB}
.glass{background:#F8F7FBEB;box-shadow:inset 0 0 0 .5px #ffffffb0,0 0 0 .5px #00000014}
.panel{position:absolute;overflow:hidden}
.float{box-shadow:0 26px 60px #2A1F6030,0 1px 2px #0000000f,inset 0 0 0 .5px #ffffffb0,0 0 0 .5px #0000001a}
.ai{display:inline-flex;align-items:center;justify-content:center;color:#fff;font-weight:700;flex:none;line-height:1}
.sw,.ctr{display:inline-flex;align-items:center;justify-content:center;flex:none}
.mono{font-family:ui-monospace,"SF Mono",Menlo,monospace;font-size:.93em}
.dim{color:#8a8a8e}
b{font-weight:600}
.pill{display:inline-flex;align-items:center;gap:6px;padding:0 13px;height:30px;border-radius:99px;font-size:13px;font-weight:500}
.pill.on{background:#E5E4E9}.pill.off{color:#6e6e73}
.dot{width:11px;height:11px;border-radius:50%%;background:#FF3B30;display:inline-block}
.icn{display:inline-flex;padding:0 8px}
.pill svg,.searchbar svg{flex:none}
.searchbar{display:flex;align-items:center;gap:10px;font-size:17px;color:#8a8a8e;padding:0 20px}
.row{display:flex;align-items:center;gap:14px;padding:0 12px;border-radius:13px}
.row .l{min-width:0;flex:1}
.row .p{font-size:15px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.row .s{font-size:13px;color:#8a8a8e;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:2px}
.row.sel{background:#0A7AFF24}
.row .ret{color:#0A7AFF;font-size:14px;margin-left:auto;flex:none}
.sec{font-size:13px;font-weight:600;color:#8a8a8e;padding:0 14px;display:flex;align-items:center}
"""

def screen_head(lang):
    s = STR[lang]
    menus = "".join(f"<span>{m}</span>" for m in s["menus"])
    return (f'<div class="bar"><span>&#63743;</span><span class="app">{s["app"]}</span>{menus}'
            f'<span class="r">{s["clock"]}</span></div>')

def document_window(x, y, w, h, lang, lines=12):
    s = STR[lang]
    rows = ""
    widths = [0.42, 0.9, 0.84, 0.88, 0.56, 0, 0.3, 0.9, 0.76, 0.86, 0.62, 0, 0.36, 0.9, 0.8, 0.9, 0.5]
    top = 74
    for i in range(lines):
        wf = widths[i % len(widths)]
        if wf:
            rows += f'<div class="line" style="left:70px;top:{top}px;width:{round((w-140)*wf)}px;height:{16 if wf in (0.42,0.3,0.36) else 9}px"></div>'
        top += 30 if wf else 18
    return (f'<div class="win" style="left:{x}px;top:{y}px;width:{w}px;height:{h}px"><div class="dots">'
            f'<i style="background:#FF5F57"></i><i style="background:#FEBC2E"></i><i style="background:#28C840"></i></div>'
            f'<div class="t">{s["doc"]}</div>{rows}</div>')

def header_controls(lang, center=True):
    s = STR[lang]
    return (f'<div style="display:flex;align-items:center;justify-content:{"center" if center else "flex-start"};gap:8px;height:100%">'
            f'<span class="icn">{SEARCH_SVG}</span>'
            f'<span class="pill on">{CLOCK_SVG} {s["clipboard"]}</span><span class="pill off"><span class="dot"></span> {s["pinned"]}</span></div>')

# ---------------------------------------------------------------- styles

def style_basic(lang):
    s = STR[lang]
    cards = ""
    for i, item in enumerate(ITEMS[:7]):
        kind, app, age, p = item
        color = APPS[app][0]
        band = (f'<div class="band" style="background:{color}"><b>{s["kinds"][kind]}</b><span>{s["ages"][age]}</span>'
                f'{app_icon(app, 48)}</div>')
        if kind == "image":
            body = f'<div class="pic">{picture(p[0], 232, 184, 0)}<span class="cap">{p[2]}</span></div>'
        elif kind == "color":
            body = f'<div class="pic" style="background:{p[0]}"><span class="cap">{p[0]}</span></div>'
        elif kind == "file":
            body = f'<div class="body ctr" style="justify-content:center">{pdf_icon(64)}</div><div class="foot">{esc(p[0])}<span class="k">⌘{i+1}</span></div>'
        else:
            n = len(text_of(item, lang))
            body = (f'<div class="body">{primary(item, lang)}</div>'
                    f'<div class="foot">{s["chars"].format(n=n)}<span class="k">⌘{i+1}</span></div>')
        cards += f'<div class="card{" sel" if i == 0 else ""}">{band}{body}</div>'
    css = """
.panel.basic{left:8px;right:8px;bottom:8px;height:324px;border-radius:22px}
.hdr{height:62px;position:relative}
.hdr .more{position:absolute;right:20px;top:0;height:100%;display:flex;align-items:center;font-size:18px;font-weight:700;letter-spacing:1px}
.cards{display:flex;gap:24px;padding:6px 24px 0}
.card{flex:none;width:232px;height:232px;border-radius:14px;overflow:hidden;background:#fff;box-shadow:0 1px 2px #0000001a;display:flex;flex-direction:column;position:relative}
.card.sel{outline:3px solid #0A7AFF;outline-offset:1px}
.band{height:48px;padding:7px 12px;color:#fff;position:relative;display:flex;flex-direction:column;justify-content:center;gap:0}
.band b{font-size:15px;font-weight:500}.band span{font-size:12px;opacity:.8}
.band .ai{position:absolute;right:0;top:0;border-radius:0 0 0 10px !important}
.card .body{flex:1;padding:10px 12px;font-size:14px;line-height:1.4;overflow:hidden}
.card .foot{height:32px;display:flex;align-items:center;justify-content:center;font-size:12px;color:#8a8a8e;position:relative}
.card .foot .k{position:absolute;right:12px;font-weight:600}
.card .pic{flex:1;position:relative;display:flex;align-items:center;justify-content:center;background:#EEEEF1}
.card .pic svg{width:100%;height:100%}
.card .cap{position:absolute;bottom:7px;left:50%;transform:translateX(-50%);background:#0006;color:#fff;font-size:12px;padding:3px 8px;border-radius:99px;white-space:nowrap}
"""
    body = (screen_head(lang) + document_window(230, 70, 1140, 560, lang) +
            f'<div class="panel glass basic"><div class="hdr">{header_controls(lang)}<span class="more">•••</span></div>'
            f'<div class="cards">{cards}</div></div>')
    return css, body

def rows_html(items, lang, height, two_line, thumb_size, selected=0, ret=True):
    out = ""
    for i, item in enumerate(items):
        sel = " sel" if i == selected else ""
        second = f'<div class="s">{esc(secondary(item, lang))}</div>' if two_line else ""
        r = f'<span class="ret">↩</span>' if (i == selected and ret) else ""
        out += (f'<div class="row{sel}" style="height:{height}px">{thumb(item, thumb_size, 9)}'
                f'<div class="l"><div class="p">{primary(item, lang)}</div>{second}</div>{r}</div>')
    return out

def list_panel(lang, x, y, w, h, radius, items, row_h, two_line, thumb_size, header=True, gap=3):
    hdr = f'<div style="height:52px;padding:0 10px">{header_controls(lang)}</div>' if header else ""
    rows = rows_html(items, lang, row_h, two_line, thumb_size)
    return (f'<div class="panel glass float" style="left:{x}px;top:{y}px;width:{w}px;height:{h}px;border-radius:{radius}px">'
            f'{hdr}<div style="display:flex;flex-direction:column;gap:{gap}px;padding:4px 8px 8px">{rows}</div></div>')

def style_minimal(lang):
    w, h = 500, 620
    x, y = (W - w) // 2, (H - h) // 2 - 40
    n = (h - 52 - 12) // 65
    body = screen_head(lang) + document_window(200, 90, 1200, 640, lang, 14) + \
        list_panel(lang, x, y, w, h, 22, ITEMS[:n], 62, True, 40)
    return "", body

def style_top_drop(lang):
    w, h = 680, 640
    x, y = (W - w) // 2, 80
    n = (h - 52 - 12) // 67
    body = screen_head(lang) + document_window(200, 110, 1200, 640, lang, 14) + \
        list_panel(lang, x, y, w, h, 26, ITEMS[:n], 64, True, 42)
    return "", body

def style_light_strip(lang):
    s = STR[lang]
    tiles = ""
    for i, item in enumerate(ITEMS[:7]):
        kind, app, age, p = item
        sel = " sel" if i == 0 else ""
        if kind == "image":
            inner = f'{picture(p[0], 210, 160, 0)}<span class="cap">{p[2]}</span>'
        elif kind == "color":
            inner = f'<div class="tsw" style="background:{p[0]}"></div><div class="tp"><span class="mono">{p[0]}</span></div><div class="ts">{p[1]}</div>'
        elif kind == "file":
            inner = f'<div style="padding:12px 0 6px">{pdf_icon(36)}</div><div class="tp">{esc(p[0])}</div><div class="ts">{p[1]}</div>'
        elif kind == "link":
            inner = (f'<div class="tp" style="display:flex;align-items:center;gap:6px">{app_icon(app,16)}<b>{esc(p[0])}</b></div>'
                     f'<div class="tp" style="font-size:14.5px;margin-top:4px">{esc(p[2])}</div><div class="ts dim">{esc(p[1])}</div>')
        else:
            inner = f'<div class="tp">{primary(item, lang)}</div>'
        meta = "" if kind == "image" else f'<span class="tag">{app_icon(app, 14)}</span>'
        age_tag = f'<span class="age">{s["short"][age]} ↩</span>' if i == 0 else ""
        tiles += f'<div class="tile{sel}">{inner}{meta}{age_tag}</div>'
    css = """
.panel.strip{left:8px;right:8px;bottom:8px;height:230px;border-radius:26px}
.tiles{display:flex;gap:14px;padding:35px 18px 0}
.tile{flex:none;width:210px;height:160px;border-radius:16px;background:#fff;box-shadow:0 1px 2px #0000001a;padding:14px;position:relative;overflow:hidden;font-size:15px;line-height:1.35}
.tile.sel{background:#0A7AFF14;box-shadow:0 0 0 1.5px #0A7AFF}
.tile svg.pic{position:absolute;inset:0;width:100%;height:100%}
.tile .cap{position:absolute;bottom:8px;left:50%;transform:translateX(-50%);background:#0006;color:#fff;font-size:12px;padding:3px 8px;border-radius:99px;white-space:nowrap}
.tile .tp{display:-webkit-box;-webkit-line-clamp:4;-webkit-box-orient:vertical;overflow:hidden}
.tile .ts{font-size:13px;color:#8a8a8e;margin-top:3px}
.tile .tsw{height:52px;border-radius:10px;margin:-2px 0 10px}
.tile .tag{position:absolute;right:10px;bottom:10px}
.tile .age{position:absolute;left:14px;bottom:10px;font-size:13px;color:#0A7AFF;font-weight:500}
.srch{position:absolute;left:50%;transform:translateX(-50%);top:-27px;height:36px;padding:0 16px;border-radius:99px;display:flex;align-items:center;gap:8px;font-size:14px}
"""
    body = (screen_head(lang) + document_window(230, 70, 1140, 640, lang, 14) +
            f'<div class="panel glass strip"><div class="srch glass float" style="top:-0px;display:none"></div><div class="tiles">{tiles}</div></div>')
    return css, body

def style_sidebar(lang):
    s = STR[lang]
    w = 440
    x, y = W - w - 8, 28 + 8
    h = H - y - 8
    groups = [(s["today"], ITEMS[:10]), (s["yesterday"], ITEMS[10:16]), (s["wednesday"], ITEMS[16:22])]
    inner = ""
    first = True
    for title, items in groups:
        inner += f'<div class="sec" style="height:34px">{title}</div>'
        inner += rows_html(items, lang, 44, False, 30, selected=0 if first else -1)
        first = False
    body = (screen_head(lang) + document_window(120, 90, 960, 720, lang, 16) +
            f'<div class="panel glass float" style="left:{x}px;top:{y}px;width:{w}px;height:{h}px;border-radius:24px">'
            f'<div style="height:52px;padding:0 10px">{header_controls(lang)}</div>'
            f'<div style="display:flex;flex-direction:column;gap:2px;padding:0 8px 8px">{inner}</div></div>')
    return "", body

def style_grid(lang):
    s = STR[lang]
    w, h = 830, 680
    x, y = (W - w) // 2, (H - h) // 2 - 40
    tiles = ""
    for i, item in enumerate(ITEMS[:20]):
        kind, app, age, p = item
        sel = " sel" if i == 0 else ""
        if kind == "image":
            inner = f'{picture(p[0], 150, 150, 0)}'
        elif kind == "color":
            inner = f'<div class="gsw" style="background:{p[0]}"></div><div class="gp mono">{p[0]}</div>'
        elif kind == "file":
            inner = f'<div style="padding:6px 0 4px">{pdf_icon(30)}</div><div class="gp">{esc(p[0])}</div>'
        elif kind == "link":
            inner = f'<div class="gp"><b>{esc(p[0])}</b></div><div class="gp" style="margin-top:2px">{esc(p[2])}</div>'
        else:
            inner = f'<div class="gp">{primary(item, lang)}</div>'
        age_tag = f'<span class="gage">{s["short"][age]} ↩</span>' if i == 0 else ""
        tiles += f'<div class="gt{sel}">{inner}<span class="gtag">{app_icon(app, 14)}</span>{age_tag}</div>'
    css = """
.gtiles{display:grid;grid-template-columns:repeat(5,150px);gap:12px;padding:0 16px 16px}
.gt{width:150px;height:150px;border-radius:16px;background:#fff;box-shadow:0 1px 2px #0000001a;padding:12px;position:relative;overflow:hidden;font-size:13.5px;line-height:1.35}
.gt.sel{background:#0A7AFF14;box-shadow:0 0 0 1.5px #0A7AFF}
.gt svg.pic{position:absolute;inset:0;width:100%;height:100%}
.gt .gp{display:-webkit-box;-webkit-line-clamp:4;-webkit-box-orient:vertical;overflow:hidden}
.gt .gsw{height:56px;border-radius:10px;margin:-2px 0 8px}
.gt .gtag{position:absolute;right:9px;bottom:9px}
.gt .gage{position:absolute;left:12px;bottom:9px;font-size:12px;color:#0A7AFF;font-weight:500}
"""
    body = (screen_head(lang) + document_window(180, 60, 1240, 700, lang, 16) +
            f'<div class="panel glass float" style="left:{x}px;top:{y}px;width:{w}px;height:{h}px;border-radius:26px">'
            f'<div class="searchbar" style="height:60px">{SEARCH_SVG} <span>{s["search"]}</span>'
            f'<span style="margin-left:auto;display:flex;gap:8px"><span class="pill on">{CLOCK_SVG} {s["clipboard"]}</span>'
            f'<span class="pill off"><span class="dot"></span> {s["pinned"]}</span></span></div>'
            f'<div class="gtiles">{tiles}</div></div>')
    return css, body

def style_palette(lang):
    s = STR[lang]
    w, h = 1080, 760
    x, y = (W - w) // 2, (H - h) // 2 - 30
    groups = [(s["pinned"], [ITEMS[12], ITEMS[10]]), (s["today"], ITEMS[:8])]
    inner = ""
    for gi, (title, items) in enumerate(groups):
        inner += f'<div class="sec" style="height:36px">{title.upper() if lang == "en" else title}</div>'
        inner += rows_html(items, lang, 62, True, 40, selected=0 if gi == 1 else -1, ret=False)
    first = ITEMS[0]
    preview = (f'<div class="ph">{app_icon("slack", 44)}<div><div style="font-size:15px;font-weight:600">{s["apps"]["slack"]}</div>'
               f'<div style="font-size:13px;color:#8a8a8e">{s["richtext"]}</div></div></div>'
               f'<div class="pv"><div style="font-size:22px;font-weight:700;margin-bottom:12px">{esc(first[3][lang].split(" — ")[0])}</div>'
               f'<div style="font-size:15px;line-height:1.6">{esc(first[3][lang])}</div></div>'
               f'<div class="pa"><span class="btn pri">{s["paste"]} ↩</span><span class="btn">{s["plain"]} ⇧↩</span><span class="btn">{s["pin"]} ⌘P</span></div>')
    css = """
.pal{display:grid;grid-template-columns:420px 1fr;height:calc(100% - 64px)}
.pal .lst{display:flex;flex-direction:column;gap:3px;padding:4px 10px 8px;border-right:.5px solid #0000001a}
.ph{display:flex;align-items:center;gap:12px;padding:20px 24px 12px}
.pv{margin:0 24px;background:#ffffffb0;border:.5px solid #0000000f;border-radius:16px;padding:22px 24px;min-height:300px}
.pa{display:flex;gap:10px;padding:20px 24px}
.btn{height:36px;padding:0 16px;border-radius:99px;display:inline-flex;align-items:center;background:#E5E4E9;font-size:14px;font-weight:500}
.btn.pri{background:#0A7AFF;color:#fff}
"""
    body = (screen_head(lang) + document_window(150, 60, 1300, 760, lang, 16) +
            f'<div class="panel glass float" style="left:{x}px;top:{y}px;width:{w}px;height:{h}px;border-radius:30px">'
            f'<div class="searchbar" style="height:64px;border-bottom:.5px solid #0000001a">{SEARCH_SVG} <span>{s["search"]}</span>'
            f'<span class="pill on" style="margin-left:auto">{LIST_SVG} {s["all"]}</span></div>'
            f'<div class="pal"><div class="lst">{inner}</div><div>{preview}</div></div></div>')
    return css, body

RENDER = {
    "basic": style_basic, "minimal": style_minimal, "light-strip": style_light_strip,
    "top-drop": style_top_drop, "sidebar": style_sidebar, "grid": style_grid, "palette": style_palette,
}

# ---------------------------------------------------------------- hero

HERO = {
    "en": {"tag": "Everything you copied,<br>one keystroke away.",
           "sub": "A small, honest clipboard history for macOS 26. Keeps every format you copy, refuses to store secrets, and lives in a strip of Liquid Glass.",
           "keys": "to open, click to paste",
           "chips": ["Rich text stays rich", "Secrets never stored", "Seven panel styles", "Local MCP for AI tools"]},
    "zh": {"tag": "复制过的一切，<br>一个快捷键就回来。",
           "sub": "一个小巧、诚实的 macOS 26 剪贴板历史。保留你复制的每一种格式，拒绝保存密码，住在一条 Liquid Glass 里。",
           "keys": "打开面板，点一下即粘贴",
           "chips": ["富文本保持富文本", "从不保存密码", "七种面板样式", "本地 MCP 给 AI 工具用"]},
}

def hero_html(lang):
    t = HERO[lang]
    chips = "".join(f'<span class="chip"><b style="background:{c}"></b>{txt}</span>'
                    for c, txt in zip(["#8B5CF6", "#22A06B", "#2F6BFF", "#F2552C"], t["chips"]))
    # The bottom of the basic shot: the panel and a sliver of desktop above it.
    crop_top, crop_h = round(860 * 640 / W), round(860 * 360 / W)
    return f"""<!doctype html><html><head><meta charset="utf-8"><style>
*{{box-sizing:border-box;margin:0}}
html,body{{width:1600px;height:860px;overflow:hidden}}
body{{font-family:system-ui,-apple-system,"Helvetica Neue","PingFang SC",sans-serif;color:#1B1640;position:relative;
  background:radial-gradient(900px 600px at 0% 0%,#D3DEFF 0%,transparent 70%),
    radial-gradient(800px 600px at 100% 100%,#FFE0D6 0%,transparent 70%),
    radial-gradient(700px 500px at 70% 10%,#F1DDFF 0%,transparent 70%),#F6F1FF}}
.copy{{position:absolute;left:88px;top:96px;width:560px}}
.brand{{display:flex;align-items:center;gap:18px}}.brand img{{width:92px;height:92px}}
.brand h1{{font-size:84px;font-weight:800;letter-spacing:-3px}}
h2{{margin-top:30px;font-size:40px;line-height:1.16;font-weight:700;letter-spacing:-1px;color:#231C4D}}
p{{margin-top:20px;font-size:19px;line-height:1.55;color:#5B5579}}
.keys{{margin-top:32px;display:flex;align-items:center;gap:8px;font-size:17px;color:#5B5579}}
kbd{{font-family:inherit;width:44px;height:44px;display:grid;place-items:center;border-radius:10px;background:#fffc;border:1px solid #1B164022;box-shadow:0 2px 4px #1B164014;font-size:19px;font-weight:600;color:#1B1640}}
.chips{{margin-top:40px;display:flex;flex-wrap:wrap;gap:10px}}
.chip{{padding:8px 14px;border-radius:99px;background:#ffffffa8;border:1px solid #1B164014;font-size:14.5px;font-weight:500;color:#3B3563}}
.chip b{{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:8px;vertical-align:1px}}
.shot{{position:absolute;border-radius:16px;overflow:hidden;box-shadow:0 30px 60px -12px #2A1F6045,0 0 0 1px #1B164012}}
.shot img{{display:block;width:100%}}
.s1{{width:560px;left:900px;top:60px;transform:rotate(3deg)}}
.s2{{width:560px;left:1010px;top:470px;transform:rotate(-2.5deg)}}
.s0{{width:860px;left:690px;top:360px}}
.crop{{height:{crop_h}px}}.crop img{{margin-top:-{crop_top}px}}
</style></head><body>
<div class="copy"><div class="brand"><img src="../../hero/icon.png"><h1>Pastel</h1></div>
<h2>{t["tag"]}</h2><p>{t["sub"]}</p>
<div class="keys"><kbd>⌘</kbd><kbd>⇧</kbd><kbd>V</kbd><span>&nbsp;{t["keys"]}</span></div>
<div class="chips">{chips}</div></div>
<div class="shot s1"><img src="../{lang}-grid.png"></div>
<div class="shot s2"><img src="../{lang}-minimal.png"></div>
<div class="shot s0 crop"><img src="../{lang}-basic.png"></div>
</body></html>"""

# ---------------------------------------------------------------- run

def shoot(html_path, png_path, w, h):
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                    "--force-device-scale-factor=2", f"--window-size={w},{h}",
                    "--virtual-time-budget=4000", f"--screenshot={png_path}", f"file://{html_path}"],
                   check=True, capture_output=True)

def render_style(lang, style):
    css, body = RENDER[style](lang)
    doc = f'<!doctype html><html lang="{lang}"><head><meta charset="utf-8"><style>{CSS % (W, H)}{css}</style></head><body>{body}</body></html>'
    path = os.path.join(BUILD, f"{lang}-{style}.html")
    with open(path, "w") as f:
        f.write(doc)
    out = os.path.join(HERE, f"{lang}-{style}.png")
    shoot(path, out, W, H)
    # Shot at 2x for crisp type, kept at 1x: the README shows these two to a
    # row, and the hero is what gets looked at closely.
    from PIL import Image
    Image.open(out).convert("RGB").resize((W, H), Image.LANCZOS).save(out, optimize=True)

def render_hero(lang):
    path = os.path.join(BUILD, f"hero-{lang}.html")
    with open(path, "w") as f:
        f.write(hero_html(lang))
    shoot(path, os.path.join(HERE, f"hero-{lang}.png"), 1600, 860)

if __name__ == "__main__":
    os.makedirs(BUILD, exist_ok=True)
    only = sys.argv[1:]
    for lang in ("en", "zh"):
        for style in STYLES:
            if not only or f"{lang}-{style}" in only:
                render_style(lang, style)
                print(f"{lang}-{style}.png")
        if not only or f"hero-{lang}" in only:
            render_hero(lang)
            print(f"hero-{lang}.png")
