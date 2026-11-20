#!/usr/bin/env python3
"""Require actual layered Icon Composer renditions in assetutil's catalog report."""
import json
from pathlib import Path
import sys

APPEARANCES = {'UIAppearanceLight', 'UIAppearanceDark', 'ISAppearanceTintable'}
VECTORS = {'AppIcon_Assets/01-moon', 'AppIcon_Assets/02-terrain', 'AppIcon_Assets/03-craters'}
GROUPS = {'AppIcon/01 Moon', 'AppIcon/02 Terrain', 'AppIcon/03 Craters'}


def verify(entries):
    if not isinstance(entries, list):
        raise ValueError('Invalid native catalog report')
    vectors = {e.get('Name') for e in entries if e.get('AssetType') == 'Vector'}
    if not VECTORS.issubset(vectors):
        raise ValueError('Compiled icon lost separate vector artwork')
    for appearance in APPEARANCES:
        stacks = [e for e in entries if e.get('AssetType') == 'IconImageStack' and e.get('Appearance') == appearance]
        if len(stacks) != 1:
            raise ValueError(f'Missing or ambiguous layered appearance: {appearance}')
        stack = stacks[0]
        if (stack.get('Name') != 'AppIcon' or stack.get('LayerCount') != 4 or
                stack.get('CanvasWidth') != 1024 or stack.get('CanvasHeight') != 1024 or
                stack.get('CompositeImagePresent') is not False):
            raise ValueError('Icon must retain its background and three native layer groups')
        names = {layer.get('Name') for layer in stack.get('Layers', []) if layer.get('AssetType') == 'IconGroup'}
        if names != GROUPS:
            raise ValueError('Native stack lost moon, terrain or crater group')
        groups = [e for e in entries if e.get('AssetType') == 'IconGroup' and e.get('Appearance') == appearance]
        if {e.get('Name') for e in groups} != GROUPS:
            raise ValueError('Missing native appearance groups')
        moon = next(e for e in groups if e['Name'] == 'AppIcon/01 Moon')
        if not any(layer.get('LayerHasLightingEffects') is True for layer in moon.get('Layers', [])):
            raise ValueError('Native moon material has no lighting effects')


if __name__ == '__main__':
    verify(json.loads(Path(sys.argv[1]).read_text()))
    print('Native layered icon, vector groups and Light/Dark/monochrome renditions verified')
