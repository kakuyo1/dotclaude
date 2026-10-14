"""The news tracks, as data. Every script reads the track vocabulary from here.

A track has a key (its job and handover folder are news-<key>), a label (the Track field in
CANDIDATES.md), a section (the page heading, which SELECTED.md names in its Section field), a
window_hours (how far back an item's publish date may be; crawl_track.py --since overrides it), an
optional max_per_source (the most items one source may keep), and sources. A source is (name, file key, feed URL, blocked). A blocked source is skipped unless
crawl_track.py gets --include-blocked.

To add a track: add it here, add its section marker and nav link to template/news-template.html,
and add its quota to SKILL.md. No other script names a track.
"""

REUTERS = "https://news.google.com/rss/search?q=when:24h+site:reuters.com&hl=en-US&gl=US&ceid=US:en"

TRACKS = {
    "international": {
        "label": "International",
        "section": "International",
        "window_hours": 48,
        "sources": [
            ("BBC News", "bbc", "https://feeds.bbci.co.uk/news/world/rss.xml", False),
            ("The Guardian", "guardian", "https://www.theguardian.com/world/rss", False),
            ("Al Jazeera English", "aljazeera", "https://www.aljazeera.com/xml/rss/all.xml", False),
            ("NPR", "npr", "https://feeds.npr.org/1001/rss.xml", False),
            ("Reuters", "reuters", REUTERS, True),
        ],
    },
    "china": {
        "label": "China",
        "section": "China",
        "window_hours": 168,
        "max_per_source": 15,
        "sources": [
            ("South China Morning Post", "scmp", "https://www.scmp.com/rss/4/feed", False),
            ("The Diplomat", "diplomat", "https://thediplomat.com/category/china-power/feed/", False),
            ("Financial Times", "ft", "https://www.ft.com/china?format=rss", True),
            ("China Digital Times", "cdt", "https://chinadigitaltimes.net/feed/", False),
        ],
    },
    "tech": {
        "label": "Tech",
        "section": "Technology",
        "window_hours": 48,
        "sources": [
            ("Hacker News", "hn", "https://news.ycombinator.com/rss", False),
            ("arXiv cs.AI", "arxiv_ai", "https://rss.arxiv.org/rss/cs.AI", False),
            ("arXiv cs.LG", "arxiv_lg", "https://rss.arxiv.org/rss/cs.LG", False),
            ("arXiv cs.CL", "arxiv_cl", "https://rss.arxiv.org/rss/cs.CL", False),
            ("Techmeme", "techmeme", "https://www.techmeme.com/feed.xml", False),
            ("Ars Technica", "ars", "https://feeds.arstechnica.com/arstechnica/index", True),
            ("Simon Willison", "willison", "https://simonwillison.net/atom/everything/", False),
        ],
    },
}
