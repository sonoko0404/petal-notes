#!/usr/bin/env python3
"""Offline audit of exported pages; no network or build execution."""
from pathlib import Path
from html.parser import HTMLParser
import re, sys, json

class Page(HTMLParser):
    def __init__(self):
        super().__init__(); self.tags=[]; self.text=[]; self.links=[]; self.lang=None; self.viewport=False
    def handle_starttag(self, tag, attrs):
        a=dict(attrs); self.tags.append(tag)
        if tag=='html': self.lang=a.get('lang')
        if tag=='meta' and a.get('name')=='viewport': self.viewport=True
        self.links += [value for key,value in attrs if key in ('href','src')]
    def handle_data(self, data): self.text.append(data)

def audit(root):
    errors=[]
    catalog=json.loads((root/'apple/PetalChecklist/Resources/Localizable.xcstrings').read_text())['strings']
    for path in sorted((root/'site').rglob('*.html')):
        parser=Page(); source=path.read_text(); parser.feed(source)
        if not parser.lang or not parser.viewport or 'main' not in parser.tags or 'h1' not in parser.tags: errors.append(f'{path}: inaccessible structure')
        if set(parser.tags)&{'script','iframe','form','object'}: errors.append(f'{path}: active content')
        for link in parser.links:
            if re.match(r'\w+:|//|/',link): errors.append(f'{path}: external/absolute resource {link}')
            elif not (path.parent/link).resolve().is_file(): errors.append(f'{path}: broken link {link}')
        if path.parent.name in ('privacy','support'):
            lang=path.stem
            md=root/('docs/legal/privacy-policy-'+lang+'.md' if path.parent.name=='privacy' else 'docs/support/faq-'+lang+'.md')
            text=''.join(parser.text)
            for paragraph in md.read_text().split('\n\n')[1:]:
                if paragraph.strip() not in text: errors.append(f'{path}: Markdown content differs')
            body=md.read_text().split('\n',1)[1].strip()
            key='privacy.body' if path.parent.name=='privacy' else 'help.body'
            if catalog[key]['localizations'][lang]['stringUnit']['value'] != body: errors.append(f'{path}: in-app copy differs')
    css=(root/'site/style.css').read_text()
    if re.search(r'@import|url\(|@font-face',css): errors.append('External CSS resource')
    if len(list((root/'site').rglob('*.html')))!=5: errors.append('Missing bilingual page')
    return errors

if __name__=='__main__':
    errors=audit(Path(__file__).resolve().parents[2])
    print('\n'.join(errors) if errors else 'Site verified: 5 accessible static pages; Markdown parity; relative links; zero external resources')
    sys.exit(bool(errors))
