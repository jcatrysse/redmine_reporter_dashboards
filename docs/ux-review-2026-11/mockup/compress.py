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

total = 0
for f in sorted(os.listdir(IMG)):
    if not f.endswith('.png'):
        continue
    path = os.path.join(IMG, f)
    im = Image.open(path)
    if im.mode != 'P':
        im = im.convert('RGB').quantize(colors=256, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.NONE)
        im.save(path, optimize=True)
    total += os.path.getsize(path)
print(f'{len([f for f in os.listdir(IMG) if f.endswith(".png")])} images, {total / 1e6:.1f} MB')
