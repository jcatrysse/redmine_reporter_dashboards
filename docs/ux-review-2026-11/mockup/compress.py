#!/usr/bin/env python3
"""UX review 2026-11: builds the before/after composites and quantises every PNG in ../img
to a 256-colour palette (screenshots of flat UI lose nothing visible). Run after capture.mjs:

    python3 docs/ux-review-2026-11/mockup/compress.py
"""
import os
from PIL import Image, ImageDraw, ImageFont

IMG = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'img')

# (output, before, after, layout)
COMPOSITES = [
    ('03-compare-report', '03-widget-before-report', '03-widget-after-report', 'stack'),
    ('03-compare-chart', '03-widget-before-chart', '03-widget-after-chart', 'side'),
    ('03-compare-degraded', '03-widget-before-degraded', '03-widget-after-degraded', 'side'),
    ('03-compare-unconfigured', '03-widget-before-unconfigured', '03-widget-after-unconfigured', 'side'),
    ('01-compare-menu-label', '01-menu-label-before', '01-menu-label-after', 'stack'),
    ('06-compare-permissions', '06-permissions-before', '06-permissions-after', 'stack'),
    ('02-compare-sent', '02-yellow-before-sent', '02-yellow-after-sent', 'side'),
    ('07-compare-time-widget', '07-viewer-before-time-widget', '07-viewer-after-time-widget', 'side'),
]


def font(size):
    for path in ('/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf',
                 '/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf'):
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def labelled(img, text):
    bar = 56
    out = Image.new('RGB', (img.width, img.height + bar), 'white')
    out.paste(img.convert('RGB'), (0, bar))
    d = ImageDraw.Draw(out)
    d.rectangle([0, 0, img.width, bar - 1], fill=(233, 236, 239))
    d.text((16, 12), text, fill=(33, 37, 41), font=font(30))
    return out


def composite(name, before, after, layout):
    b = Image.open(os.path.join(IMG, before + '.png'))
    a = Image.open(os.path.join(IMG, after + '.png'))
    b, a = labelled(b, 'Before'), labelled(a, 'After')
    gap = 24
    if layout == 'side':
        h = max(b.height, a.height)
        out = Image.new('RGB', (b.width + a.width + gap, h), 'white')
        out.paste(b, (0, 0))
        out.paste(a, (b.width + gap, 0))
    else:
        w = max(b.width, a.width)
        out = Image.new('RGB', (w, b.height + a.height + gap), 'white')
        out.paste(b, (0, 0))
        out.paste(a, (0, b.height + gap))
    out.save(os.path.join(IMG, name + '.png'))


for spec in COMPOSITES:
    if all(os.path.exists(os.path.join(IMG, f + '.png')) for f in spec[1:3]):
        composite(*spec)

FINAL = os.path.join(IMG, 'final')


def triptych(key, labels=('Before', 'After A: one tab bar', 'After B: two levels'), scale=0.5):
    """before | after A | after B, each panel at 1x (half the 2x capture)."""
    panels = []
    for suffix, label in zip(('before', 'a', 'b'), labels):
        im = Image.open(os.path.join(FINAL, f'{key}-{suffix}.png')).convert('RGB')
        if im.width > 2000:  # a fresh 2x capture; a re-run finds them already at 1x
            im = im.resize((int(im.width * scale), int(im.height * scale)), Image.LANCZOS)
        panels.append(labelled(im, label))
    gap = 24
    out = Image.new('RGB', (sum(p.width for p in panels) + gap * 2, max(p.height for p in panels)), 'white')
    x = 0
    for p in panels:
        out.paste(p, (x, 0))
        x += p.width + gap
    out.save(os.path.join(FINAL, f'{key}.png'))


if os.path.isdir(FINAL):
    keys = sorted({f[:-len('-before.png')] for f in os.listdir(FINAL) if f.endswith('-before.png')})
    for key in keys:
        if all(os.path.exists(os.path.join(FINAL, f'{key}-{s}.png')) for s in ('a', 'b')):
            triptych(key)

total = 0
files = [os.path.join(IMG, f) for f in os.listdir(IMG)]
if os.path.isdir(FINAL):
    files += [os.path.join('final', f) for f in os.listdir(FINAL)]
for f in sorted(files):
    if not f.endswith('.png'):
        continue
    path = os.path.join(IMG, f)
    im = Image.open(path)
    # final/<page>-{before,a,b}: kept at 1x; the composites are what people look at.
    if os.path.dirname(f) == 'final' and f.endswith(('-before.png', '-a.png', '-b.png')) and im.width > 2000:
        im = im.convert('RGB').resize((im.width // 2, im.height // 2), Image.LANCZOS)
    if im.mode != 'P':
        im = im.convert('RGB').quantize(colors=256, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.NONE)
        im.save(path, optimize=True)
    total += os.path.getsize(path)
print(f'{len([f for f in files if f.endswith(".png")])} images, {total / 1e6:.1f} MB')
