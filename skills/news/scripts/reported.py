"""Find stories that earlier digests already carry, from the news-*.html pages in the project folder.

The pages are the record: a page counts from the moment it exists, so deleting one un-reports its
stories. repeat() is the hard filter crawl_track.py applies to links. similar() only flags a title for
the orchestrator, because a title match can be a follow-up with new facts.
"""
import glob
import html
import os
import re
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

HEADLINE = re.compile(r'<h3 class="headline"><a href="([^"]+)">(.+?)</a></h3>')
ALSO = re.compile(r'<p class="also">Also covered by: <a href="([^"]+)">')
TRACKING = re.compile(r"^(utm_.*|traffic_source|at_medium|at_campaign)$")
STOP = {"with", "from", "that", "this", "into", "over", "after", "says", "will", "their", "about",
        "have", "been", "your", "just", "what", "when", "than", "more", "show"}
SIMILAR = 0.3


def words(title):
    return {w for w in re.findall(r"[a-z0-9]{4,}", title.lower()) if w not in STOP}


def key(url):
    """The link without its fragment, trailing slash, or tracking parameters. Other query parameters
    stay, because HN's item?id= links differ only there."""
    parts = urlsplit(url)
    query = [(k, v) for k, v in parse_qsl(parts.query, keep_blank_values=True) if not TRACKING.match(k)]
    return urlunsplit((parts.scheme, parts.netloc.lower(), parts.path.rstrip("/"), urlencode(query), ""))


class Reported:
    def __init__(self):
        self.links = {}
        self.titles = []

    def add(self, link, page, title=None):
        self.links.setdefault(key(link), page)
        if title:
            self.titles.append((words(title), title, page))

    def repeat(self, link):
        """The page that carries this link, or None."""
        return self.links.get(key(link))

    def similar(self, title):
        """The (page, title, score) of the closest earlier title at or above SIMILAR, or None."""
        mine = words(title)
        best = None
        for theirs, other, page in self.titles:
            if not mine or not theirs:
                continue
            score = len(mine & theirs) / len(mine | theirs)
            if score >= SIMILAR and (best is None or score > best[2]):
                best = (page, other, round(score, 2))
        return best


def load(project):
    """Read every news-*.html in the project folder. A page whose stories do not all parse is an error,
    because a short history would let repeats back in without a sign."""
    reported = Reported()
    for path in sorted(glob.glob(os.path.join(project, "news-*.html"))):
        with open(path, encoding="utf-8") as f:
            text = f.read()
        page = os.path.basename(path)
        stories = HEADLINE.findall(text)
        articles = text.count("<article")
        if len(stories) != articles:
            raise ValueError(f"{page}: {articles} articles but {len(stories)} headlines parsed")
        for link, title in stories:
            reported.add(html.unescape(link), page, html.unescape(title))
        for link in ALSO.findall(text):
            reported.add(html.unescape(link), page)
    return reported
