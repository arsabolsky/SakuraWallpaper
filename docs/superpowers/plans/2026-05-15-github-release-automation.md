# GitHub Release Automation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `main` pushes publish a latest downloadable DMG and make version tags publish formal GitHub Releases automatically.

**Architecture:** Keep the existing local `build.sh` flow as the single packaging entry point. Add one GitHub Actions workflow for `main` that updates a rolling `latest` prerelease and one workflow for `v*` tags that creates a versioned release.

**Tech Stack:** GitHub Actions, Homebrew, Python, Pillow, existing shell build script

---

### Task 1: Make build version overridable

**Files:**
- Modify: `/Users/sakura/Code/SakuraWallpaper/build.sh`

- [x] Allow CI to inject `APP_VERSION` without breaking local builds.

### Task 2: Publish latest build from main

**Files:**
- Create: `/Users/sakura/Code/SakuraWallpaper/.github/workflows/latest-release.yml`

- [x] Add a workflow that builds `SakuraWallpaper.dmg` on `main`, uploads it as an artifact, moves the `latest` tag, and updates a rolling prerelease.

### Task 3: Publish formal releases from tags

**Files:**
- Create: `/Users/sakura/Code/SakuraWallpaper/.github/workflows/tag-release.yml`

- [x] Add a workflow that builds `SakuraWallpaper.dmg` on `v*` tags and uploads it to the matching GitHub Release.

### Task 4: Verify local compatibility

**Files:**
- Verify: `/Users/sakura/Code/SakuraWallpaper/build.sh`
- Verify: `/Users/sakura/Code/SakuraWallpaper/.github/workflows/latest-release.yml`
- Verify: `/Users/sakura/Code/SakuraWallpaper/.github/workflows/tag-release.yml`

- [x] Confirm local `./build.sh dmg` still works and inspect workflow files for expected triggers and release targets.
