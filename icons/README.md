# App icon

`AppIcon.icon` is an editable native Icon Composer document with three original 1024 × 1024 SVG layers: moon body, terrain and craters. Open it with Apple's Icon Composer on macOS. The front-to-back group order keeps subtle surface detail above the circular moon; the system applies the icon's outer mask.

Liquid Glass lighting, translucency and shadows come from Icon Composer properties and Apple's renderer. The artwork does not bake gradients, shadows or a canvas mask into PNGs. Geometry stays consistent across Default, Dark and monochrome/tinted appearances.

`build.sh` compiles the document directly with Xcode's `actool`. `verify_icon.py` requires native vector/group/image-stack records for Light, Dark and tintable appearances. Apple's generated raster compatibility images are packaged alongside the layered catalog; they are not source substitutes.

`tests/run_icon_tests.sh` uses Apple's bundled `ictool` to render native previews and checks that lunar detail is visible. Simulator fixtures compile/install the same project and verify icon registration in Light/Dark. Actual iOS 27 Home Screen appearance remains a physical-device check. Exact native appearance evidence is recorded in [TESTING.md](../TESTING.md).

References: [Apple Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer), [App icon guidelines](https://developer.apple.com/design/human-interface-guidelines/app-icons).
