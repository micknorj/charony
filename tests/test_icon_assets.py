"""Reject a compiled icon that silently falls back to flattened artwork."""
import copy
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('verify_icon', ROOT / 'scripts/verify_icon.py')
icon = importlib.util.module_from_spec(spec)
spec.loader.exec_module(icon)


def native_catalog():
    entries = [{'AssetType': 'Vector', 'Name': name} for name in icon.VECTORS]
    for appearance in icon.APPEARANCES:
        groups = [{'AssetType': 'IconGroup', 'Name': name, 'Appearance': appearance,
                   'Layers': [{'LayerHasLightingEffects': name.endswith('/01 Moon')}]} for name in icon.GROUPS]
        entries.extend(groups)
        entries.append({'AssetType': 'IconImageStack', 'Name': 'AppIcon', 'Appearance': appearance,
                        'LayerCount': 4, 'CanvasWidth': 1024, 'CanvasHeight': 1024,
                        'CompositeImagePresent': False, 'Layers': copy.deepcopy(groups)})
    return entries


class IconAssetsTests(unittest.TestCase):
    def test_real_layer_structure_is_accepted(self):
        icon.verify(native_catalog())

    def test_flattened_and_missing_vector_catalogs_fail(self):
        for entries in [[], [{'AssetType': 'Icon Image', 'Name': 'AppIcon'}],
                        [entry for entry in native_catalog() if entry.get('Name') != 'AppIcon_Assets/03-craters']]:
            with self.subTest(entries=len(entries)), self.assertRaises(ValueError):
                icon.verify(entries)

    def test_every_appearance_requires_native_groups_and_stack(self):
        for appearance in icon.APPEARANCES:
            for kind in ['IconGroup', 'IconImageStack']:
                entries = [e for e in native_catalog() if not (e.get('Appearance') == appearance and e['AssetType'] == kind)]
                with self.subTest(appearance=appearance, kind=kind), self.assertRaises(ValueError):
                    icon.verify(entries)

    def test_composites_and_missing_native_lighting_fail(self):
        for defect in ['flattened', 'lighting', 'count', 'canvas', 'group']:
            entries = native_catalog()
            for entry in entries:
                if entry['AssetType'] == 'IconImageStack':
                    if defect == 'flattened': entry['CompositeImagePresent'] = True
                    if defect == 'count': entry['LayerCount'] = 1
                    if defect == 'canvas': entry['CanvasWidth'] = 512
                    if defect == 'group': entry['Layers'].pop()
                if defect == 'lighting' and entry['AssetType'] == 'IconGroup': entry['Layers'] = []
            with self.subTest(defect=defect), self.assertRaises(ValueError):
                icon.verify(entries)
