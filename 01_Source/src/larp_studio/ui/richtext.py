"""A small, offline rich-text subset; no images, links or active resources."""
from html import escape
from html.parser import HTMLParser
import re

ALLOWED = {'p', 'h1', 'h2', 'h3', 'h4', 'b', 'strong', 'i', 'em', 'u', 'br', 'ul', 'ol', 'li', 'blockquote', 'span'}


class _TextFilter(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.result = []
        self.skip = 0

    def handle_starttag(self, tag, attrs):
        if tag in ('script', 'style', 'iframe', 'object'):
            self.skip += 1
            return
        if self.skip or tag not in ALLOWED:
            return
        safe = ''
        if tag == 'span':
            style = dict(attrs).get('style', '')
            styles = []
            for part in style.split(';'):
                if re.fullmatch(r'\s*(font-weight\s*:\s*(bold|[6-9]00)|font-style\s*:\s*italic|text-decoration\s*:\s*underline)\s*', part):
                    styles.append(part.strip())
            if styles:
                safe = ' style="' + ';'.join(styles) + '"'
        self.result.append(f'<{tag}{safe}>')

    def handle_endtag(self, tag):
        if tag in ('script', 'style', 'iframe', 'object'):
            self.skip = max(0, self.skip - 1)
        elif not self.skip and tag in ALLOWED and tag != 'br':
            self.result.append(f'</{tag}>')

    def handle_data(self, data):
        if not self.skip:
            self.result.append(escape(data))


def safe_html(value):
    parser = _TextFilter()
    parser.feed(value)
    parser.close()
    return ''.join(parser.result)
