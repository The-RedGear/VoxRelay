"""Render collection-prefixed Icônes/Iconify identifiers into cached PNG files."""
import re
from pathlib import Path
from urllib.request import Request, urlopen
from xml.etree import ElementTree as ET

import resvg_py


def render_icon(identifier: str, destination: Path, color: str = '#B6A3FF') -> Path:
    if not re.fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)*:[a-z0-9]+(?:-[a-z0-9]+)*', identifier):
        raise ValueError('Use a collection:name icon identifier from Icônes')
    if not re.fullmatch(r'#[0-9a-fA-F]{6}', color):
        raise ValueError('Invalid icon color')
    if destination.is_file():
        return destination
    prefix, name = identifier.split(':')
    request = Request(f'https://api.iconify.design/{prefix}/{name}.svg', headers={'User-Agent': 'YapLoq/0.5'})
    with urlopen(request, timeout=8) as response:
        svg = response.read(1_000_001)
    if len(svg) > 1_000_000:
        raise ValueError('Icon response is too large')
    if b'<!DOCTYPE' in svg.upper() or b'<!ENTITY' in svg.upper():
        raise ValueError('Unsupported SVG declarations')
    root = ET.fromstring(svg)
    for node in root.iter():
        if node.tag.rsplit('}', 1)[-1] in ('script', 'foreignObject'):
            raise ValueError('Unsupported external SVG content')
        for key, value in node.attrib.items():
            external_href = key.rsplit('}', 1)[-1] == 'href' and not value.startswith(('#', 'data:image/'))
            if key.lower().startswith('on') or external_href or re.search(r'url\(\s*["\']?(?!#)', value, re.I):
                raise ValueError('External SVG resources are not supported')
    root.set('color', color)
    png = resvg_py.svg_to_bytes(svg_string=ET.tostring(root, encoding='unicode'), width=96, height=96, skip_system_fonts=True)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(png)
    return destination
