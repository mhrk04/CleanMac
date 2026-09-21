# Requirements Document

## Introduction

CleanMac is a macOS 14+ SwiftUI application built with XcodeGen from `project.yml` (the `.xcodeproj` is generated and gitignored) via `bash scripts/build.sh`. The app's asset catalog currently declares the ten standard macOS app-icon slots at `CleanMac/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`, but none of those slots reference an actual PNG file. As a result, the app ships today with no real application icon and displays a blank or placeholder icon in Finder and the Dock.

This feature replaces the missing icon with a user-provided broom logo. The source image is a JPEG located at `~/Downloads/134903f2-e132-41cd-a54d-5fb03236241c.jpeg`: a broom with a sparkle trail rendered on a light-blue rounded-square background. The source is portrait-oriented (approximately 723x1024) with substantial white padding surrounding the icon graphic, and the artwork already has rounded-square corners baked into the blue background. Because macOS applies its own rounded "squircle" mask to application icons, the source must be prepared carefully to avoid double-rounded corners or white gaps at the corners of the final rendered icon.

The scope of this feature is limited to preparing the source image, generating the required PNG assets, wiring them into the asset catalog, and confirming the built app displays the icon correctly. No Swift source code changes are expected. Re-packaging and re-releasing a distribution DMG is treated as an optional, separate requirement.

## Glossary

- **CleanMac**: The macOS 14+ SwiftUI application being built in this repository.
- **Icon_Preparer**: The process or tooling responsible for cropping and preparing the source JPEG into a square master image.
- **Icon_Generator**: The process or tooling responsible for producing the sized PNG assets and updating the asset catalog.
- **Build_System**: The XcodeGen + Xcode build pipeline invoked via `bash scripts/build.sh`.
- **AppIcon.appiconset**: The asset catalog directory at `CleanMac/Resources/Assets.xcassets/AppIcon.appiconset/` containing `Contents.json` and the icon PNG files.
- **Contents.json**: The asset catalog manifest at `CleanMac/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json` that maps each macOS icon slot (size + scale) to a PNG filename.
- **App_Bundle**: The built `.app` product produced by the Build_System.
- **Squircle_Mask**: The rounded-corner mask macOS applies automatically to application icons at render time in Finder and the Dock.
- **@1x / @2x**: Asset catalog scale factors. A slot declared at size NxN and scale @2x requires a PNG of (2N)x(2N) pixels.
- **sips**: The macOS command-line image-processing utility (`sips`) used to crop and resize images.
- **iconutil**: The macOS command-line utility for converting `.iconset` directories to `.icns` files.
- **Master_Image**: The prepared square, tightly-cropped image derived from the source JPEG, used as the input for generating all sized PNGs.

## Requirements

### Requirement 1: Source Image Preparation

**User Story:** As a developer, I want the source broom JPEG cropped to a square containing only the blue rounded-square artwork, so that the generated icon fills the frame without white padding and does not appear double-rounded.

#### Acceptance Criteria

1. WHEN the source JPEG at `~/Downloads/134903f2-e132-41cd-a54d-5fb03236241c.jpeg` is processed, THE Icon_Preparer SHALL produce a Master_Image with an aspect ratio of 1:1 (equal width and height in pixels).
2. WHEN the Master_Image is produced, THE Icon_Preparer SHALL crop the source so that the white padding surrounding the blue rounded-square artwork is removed and the blue rounded-square artwork occupies the full extent of the Master_Image.
3. WHERE macOS applies the Squircle_Mask to the App_Bundle icon, THE Icon_Preparer SHALL prepare the Master_Image so that the final rendered icon shows no white corner gaps and no visible double-rounded corners.
4. THE Icon_Preparer SHALL produce a Master_Image with a pixel width of at least 1024 pixels, so that the largest required icon size can be generated without upscaling.
5. IF the source JPEG cannot be read or located at the specified path, THEN THE Icon_Preparer SHALL report a descriptive error identifying the missing source file.

### Requirement 2: Icon Set Generation

**User Story:** As a developer, I want all ten required macOS icon PNG sizes generated and referenced in the asset catalog, so that the asset catalog resolves a real image for every declared slot.

#### Acceptance Criteria

1. WHEN the Master_Image is prepared, THE Icon_Generator SHALL produce PNG files at the following ten pixel dimensions: 16x16, 32x32, 64x64, 128x128, 256x256, 512x512, and 1024x1024, covering the slots 16x16@1x (16px), 16x16@2x (32px), 32x32@1x (32px), 32x32@2x (64px), 128x128@1x (128px), 128x128@2x (256px), 256x256@1x (256px), 256x256@2x (512px), 512x512@1x (512px), and 512x512@2x (1024px).
2. THE Icon_Generator SHALL place every generated PNG file inside the `AppIcon.appiconset` directory.
3. WHEN the PNG files are placed in `AppIcon.appiconset`, THE Icon_Generator SHALL update `Contents.json` so that each of the ten declared slots includes a `filename` key referencing the correct PNG for that size and scale combination.
4. THE Icon_Generator SHALL preserve the existing `idiom`, `size`, and `scale` values for all ten slots in `Contents.json`.
5. WHEN `Contents.json` is updated, THE Icon_Generator SHALL produce valid JSON that the Build_System parses without error.

### Requirement 3: Build Correctness

**User Story:** As a developer, I want the app to build cleanly with the new icon and display the broom icon in Finder and the Dock, so that the shipped app no longer appears with a blank or placeholder icon.

#### Acceptance Criteria

1. WHEN the app is built via `bash scripts/build.sh`, THE Build_System SHALL complete successfully without errors related to the `AppIcon` asset catalog.
2. WHEN the app is built, THE App_Bundle SHALL contain an `AppIcon` resource that resolves to the broom artwork.
3. WHEN the App_Bundle is viewed in Finder or the Dock, THE App_Bundle SHALL display the broom icon rather than a blank or placeholder icon.
4. THE `project.yml` setting `ASSETCATALOG_COMPILER_APPICON_NAME` SHALL remain set to `AppIcon`.

### Requirement 4: Visual Fidelity

**User Story:** As a user, I want the app icon to look sharp and correctly proportioned at every size, so that the icon appears professional in all macOS contexts.

#### Acceptance Criteria

1. WHEN each PNG size is generated from the Master_Image, THE Icon_Generator SHALL produce an image with a 1:1 aspect ratio matching its target slot dimensions, so that the artwork is not stretched or distorted.
2. WHEN a smaller PNG size is generated, THE Icon_Generator SHALL downscale from a source of equal or larger resolution, so that no icon size is produced by upscaling.
3. THE Icon_Generator SHALL produce each PNG at exactly its declared pixel dimensions as listed in Requirement 2.
4. WHEN the icon is rendered at the 16x16@1x and 32x32@1x sizes, THE broom artwork SHALL remain recognizable and free of upscaling artifacts.

### Requirement 5: Non-Regression

**User Story:** As a developer, I want the icon change confined to asset files, so that no application behavior changes and the risk of regression is minimized.

#### Acceptance Criteria

1. WHEN the icon feature is implemented, THE implementation SHALL modify only files within `AppIcon.appiconset` (the generated PNGs and `Contents.json`).
2. THE implementation SHALL NOT modify any Swift source file in the repository.
3. WHERE the `AppIcon` name is already configured in `project.yml` via `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`, THE implementation SHALL leave `project.yml` unchanged.
4. IF wiring the icon asset requires a change to `project.yml`, THEN THE implementation SHALL document the specific required change before applying it.

### Requirement 6 (Optional): Release Re-Packaging

**User Story:** As a maintainer, I want an updated release DMG with the new icon, so that downloaded builds also show the broom icon. This requirement is OPTIONAL and out of scope unless explicitly requested.

#### Acceptance Criteria

1. WHERE re-packaging is explicitly requested, THE maintainer SHALL build a new release DMG at version v1.0.1 containing the App_Bundle with the updated icon.
2. WHERE re-packaging is explicitly requested, THE maintainer SHALL publish the v1.0.1 DMG as a GitHub release.
3. WHILE re-packaging is not explicitly requested, THE implementation SHALL treat DMG re-packaging and GitHub release publication as out of scope.
