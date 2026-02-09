# Changelog

All notable changes to TablePro will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Fix appcast.xml to support both ARM64 and x86_64 architectures by creating a universal binary for Sparkle auto-updates

## [0.1.1] - 2026-02-09

### Added

- Auto-update support via Sparkle 2 framework (EdDSA signed)
- "Check for Updates..." menu item in TablePro menu
- Software Update section in Settings > General with auto-check toggle
- CI appcast generation and auto-deploy on tagged releases

- Migrate SQL editor to CodeEditSourceEditor (tree-sitter powered)
- Multi-statement SQL execution support
- "Show Structure" context menu for sidebar tables
- Improved filter panel UI/UX
- SwiftUI EditorTabBar (replacing AppKit NativeTabBarView)
- GPL v3 license

### Fixed

- Fix MySQL 8+ connections failing with `caching_sha2_password` plugin error by rebuilding libmariadb.a with the auth plugin compiled statically
- Fix Delete key on data grid row from marking table as deleted
- Downgrade all APIs to support macOS 13.5 (Ventura)
- Code review fixes for multi-statement execution

### Changed

- CI release notes now read from CHANGELOG.md instead of auto-generating from commits
- Removed `prepare-libs` CI job to speed up build pipeline (~5 min savings)
- Add SPM Package.resolved for CodeEditSourceEditor dependencies
- Add Claude Code project settings
- Update build/test commands with `-skipPackagePluginValidation`

## [0.1.0] - 2026-02-05

### Initial Public Release

TablePro is a native macOS database client built with SwiftUI and AppKit, designed as a fast, lightweight alternative to TablePlus.

### Features

- **Database Support**
  - MySQL/MariaDB connections
  - PostgreSQL support
  - SQLite database files
  - SSH tunneling for secure remote connections

- **SQL Editor**
  - Syntax highlighting with TreeSitter
  - Intelligent autocomplete for tables, columns, and SQL keywords
  - Multi-tab editing support
  - Query execution with result grid

- **Data Management**
  - Interactive data grid with sorting and filtering
  - Inline editing capabilities
  - Add, edit, and delete rows
  - Pagination for large result sets
  - Export data (CSV, JSON, SQL)

- **Database Explorer**
  - Browse tables, views, and schema
  - View table structure and indexes
  - Quick table information and statistics
  - Search across database objects

- **User Experience**
  - Native macOS design with SwiftUI
  - Dark mode support
  - Customizable keyboard shortcuts
  - Query history tracking
  - Multiple database connections

- **Developer Features**
  - Import/export connection configurations
  - Custom SQL query templates
  - Performance optimized for large datasets

[Unreleased]: https://github.com/datlechin/tablepro/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/datlechin/tablepro/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/datlechin/tablepro/releases/tag/v0.1.0
