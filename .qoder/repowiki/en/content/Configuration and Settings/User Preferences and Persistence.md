# User Preferences and Persistence

<cite>
**Referenced Files in This Document**
- [config_repository.dart](file://lib/core/storage/config_repository.dart)
- [defaults.dart](file://lib/config/defaults.dart)
- [models.dart](file://lib/config/models.dart)
- [ai_config.dart](file://lib/models/ai_config.dart)
- [shortcut_config.dart](file://lib/models/shortcut_config.dart)
- [webdav_config.dart](file://lib/models/webdav_config.dart)
- [ai_config_page.dart](file://lib/pages/settings/ai_config_page.dart)
- [database_helper.dart](file://lib/core/storage/database_helper.dart)
- [database_init.dart](file://lib/database_init.dart)
- [database_init_io.dart](file://lib/database_init_io.dart)
- [app.dart](file://lib/app.dart)
- [main.dart](file://lib/main.dart)
- [models_test.dart](file://test/config/models_test.dart)
</cite>

## Table of Contents
1. [Introduction](#introduction)
2. [Project Structure](#project-structure)
3. [Core Components](#core-components)
4. [Architecture Overview](#architecture-overview)
5. [Detailed Component Analysis](#detailed-component-analysis)
6. [Dependency Analysis](#dependency-analysis)
7. [Performance Considerations](#performance-considerations)
8. [Troubleshooting Guide](#troubleshooting-guide)
9. [Conclusion](#conclusion)

## Introduction
This document explains QNote Flutter’s user preferences and configuration persistence system. It covers how user settings are stored, retrieved, and synchronized across application restarts, the configuration repository pattern implementation, and data persistence strategies. It also documents preference categories (UI settings, functional preferences, and behavioral options), configuration migration and versioning mechanisms, and practical guidance for adding new configuration options, handling defaults, and managing updates. Finally, it addresses performance considerations and the relationship between runtime configuration state and persistent storage.

## Project Structure
QNote organizes configuration under a dedicated configuration module and a storage repository that persists settings to the device’s local database. Supporting model classes define typed configuration structures, while initialization helpers set up the underlying database. The application bootstraps configuration during startup.

```mermaid
graph TB
subgraph "Config Layer"
CFG_MODELS["config/models.dart"]
CFG_DEFAULTS["config/defaults.dart"]
end
subgraph "Storage Layer"
REPO["core/storage/config_repository.dart"]
DB_HELP["core/storage/database_helper.dart"]
DB_INIT["database_init.dart"]
DB_INIT_IO["database_init_io.dart"]
end
subgraph "App Layer"
APP["app.dart"]
MAIN["main.dart"]
end
CFG_MODELS --> REPO
CFG_DEFAULTS --> REPO
REPO --> DB_HELP
DB_HELP --> DB_INIT
DB_HELP --> DB_INIT_IO
APP --> REPO
MAIN --> APP
```

**Diagram sources**
- [config_repository.dart](file://lib/core/storage/config_repository.dart)
- [defaults.dart](file://lib/config/defaults.dart)
- [models.dart](file://lib/config/models.dart)
- [database_helper.dart](file://lib/core/storage/database_helper.dart)
- [database_init.dart](file://lib/database_init.dart)
- [database_init_io.dart](file://lib/database_init_io.dart)
- [app.dart](file://lib/app.dart)
- [main.dart](file://lib/main.dart)

**Section sources**
- [config_repository.dart](file://lib/core/storage/config_repository.dart)
- [defaults.dart](file://lib/config/defaults.dart)
- [models.dart](file://lib/config/models.dart)
- [database_helper.dart](file://lib/core/storage/database_helper.dart)
- [database_init.dart](file://lib/database_init.dart)
- [database_init_io.dart](file://lib/database_init_io.dart)
- [app.dart](file://lib/app.dart)
- [main.dart](file://lib/main.dart)

## Core Components
- Configuration models: Strongly typed structures representing persisted configuration categories (e.g., AI, WebDAV, shortcuts).
- Defaults provider: Centralized default values for configuration keys.
- Configuration repository: Implements the repository pattern to load/save configurations from persistent storage.
- Storage backend: Local database abstraction via a helper and initialization modules.
- Application bootstrap: Initializes configuration early in the app lifecycle.

Key responsibilities:
- Define configuration schemas and defaults.
- Persist and retrieve configuration items reliably.
- Provide a unified interface for reading/writing preferences.
- Support migration/versioning of configuration records.

**Section sources**
- [models.dart](file://lib/config/models.dart)
- [defaults.dart](file://lib/config/defaults.dart)
- [config_repository.dart](file://lib/core/storage/config_repository.dart)
- [database_helper.dart](file://lib/core/storage/database_helper.dart)
- [database_init.dart](file://lib/database_init.dart)
- [database_init_io.dart](file://lib/database_init_io.dart)
- [app.dart](file://lib/app.dart)
- [main.dart](file://lib/main.dart)

## Architecture Overview
The configuration system follows a layered architecture:
- Presentation/UI: Settings screens update configuration values.
- Domain/Repository: Centralized logic for persistence and retrieval.
- Data/Storage: Local database abstraction with initialization.

```mermaid
sequenceDiagram
participant UI as "Settings UI"
participant Repo as "ConfigRepository"
participant DB as "DatabaseHelper"
participant App as "App"
UI->>Repo : "save(key, value)"
Repo->>DB : "insertOrUpdate(key, value)"
DB-->>Repo : "success"
Repo-->>UI : "done"
App->>Repo : "load(key)"
Repo->>DB : "select(key)"
DB-->>Repo : "value"
Repo-->>App : "value"
```

**Diagram sources**
- [config_repository.dart](file://lib/core/storage/config_repository.dart)
- [database_helper.dart](file://lib/core/storage/database_helper.dart)
- [ai_config_page.dart](file://lib/pages/settings/ai_config_page.dart)
- [app.dart](file://lib/app.dart)

## Detailed Component Analysis

### Configuration Repository Pattern
The repository encapsulates persistence concerns and exposes a simple API for reading/writing configuration values. It coordinates with the database helper to perform inserts/updates and queries.

```mermaid
classDiagram
class ConfigRepository {
+load(key) Future~dynamic~
+save(key, value) Future~void~
+loadAll() Future~Map~
+delete(key) Future~void~
}
class DatabaseHelper {
+insertOrUpdate(key, value) Future~void~
+select(key) Future~dynamic~
+selectAll() Future~Map~
+delete(key) Future~void~
}
ConfigRepository --> DatabaseHelper : "delegates"
```

**Diagram sources**
- [config_repository.dart](file://lib/core/storage/config_repository.dart)
- [database_helper.dart](file://lib/core/storage/database_helper.dart)

**Section sources**
- [config_repository.dart](file://lib/core/storage/config_repository.dart)
- [database_helper.dart](file://lib/core/storage/database_helper.dart)

### Configuration Models and Defaults
Configuration models define structured settings for different domains (e.g., AI, WebDAV, shortcuts). Defaults provide fallback values when a setting is missing.

```mermaid
classDiagram
class ConfigModels {
<<models>>
}
class AiConfig {
+provider
+apiKey
+model
+temperature
+maxTokens
}
class WebDavConfig {
+url
+username
+password
+remotePath
}
class ShortcutConfig {
+toggleQuickRecord
+openSettings
}
ConfigModels --> AiConfig : "defines"
ConfigModels --> WebDavConfig : "defines"
ConfigModels --> ShortcutConfig : "defines"
```

**Diagram sources**
- [models.dart](file://lib/config/models.dart)
- [ai_config.dart](file://lib/models/ai_config.dart)
- [webdav_config.dart](file://lib/models/webdav_config.dart)
- [shortcut_config.dart](file://lib/models/shortcut_config.dart)

**Section sources**
- [models.dart](file://lib/config/models.dart)
- [ai_config.dart](file://lib/models/ai_config.dart)
- [webdav_config.dart](file://lib/models/webdav_config.dart)
- [shortcut_config.dart](file://lib/models/shortcut_config.dart)

### Defaults Provider
Defaults centralize default values for configuration keys, ensuring consistent behavior when no persisted value exists.

```mermaid
flowchart TD
Start(["Load Defaults"]) --> Keys["Enumerate Config Keys"]
Keys --> HasDefault{"Has Default?"}
HasDefault --> |Yes| UseDefault["Use Default Value"]
HasDefault --> |No| NoDefault["No Default"]
UseDefault --> Store["Persist Default on First Load"]
NoDefault --> Prompt["Prompt User or Skip"]
Store --> End(["Ready"])
Prompt --> End
```

**Diagram sources**
- [defaults.dart](file://lib/config/defaults.dart)

**Section sources**
- [defaults.dart](file://lib/config/defaults.dart)

### Database Initialization and Helper
Initialization modules set up the local database environment, and the helper abstracts CRUD operations for configuration entries.

```mermaid
graph TB
INIT["database_init.dart"] --> DBH["database_helper.dart"]
INIT_IO["database_init_io.dart"] --> DBH
DBH --> Repo["config_repository.dart"]
```

**Diagram sources**
- [database_init.dart](file://lib/database_init.dart)
- [database_init_io.dart](file://lib/database_init_io.dart)
- [database_helper.dart](file://lib/core/storage/database_helper.dart)
- [config_repository.dart](file://lib/core/storage/config_repository.dart)

**Section sources**
- [database_init.dart](file://lib/database_init.dart)
- [database_init_io.dart](file://lib/database_init_io.dart)
- [database_helper.dart](file://lib/core/storage/database_helper.dart)

### Runtime State vs Persistent Storage
Runtime configuration state is typically held in memory and synchronized with persistent storage through the repository. This ensures fast reads and writes during UI interactions, while durability is guaranteed by the underlying database.

```mermaid
stateDiagram-v2
[*] --> Initializing
Initializing --> Loaded : "load defaults and persisted values"
Loaded --> Synced : "no pending writes"
Loaded --> PendingWrite : "save invoked"
PendingWrite --> Synced : "write committed"
Synced --> PendingWrite : "change detected"
PendingWrite --> Error : "write failed"
Error --> PendingWrite : "retry"
```

**Diagram sources**
- [config_repository.dart](file://lib/core/storage/config_repository.dart)
- [database_helper.dart](file://lib/core/storage/database_helper.dart)

**Section sources**
- [config_repository.dart](file://lib/core/storage/config_repository.dart)
- [database_helper.dart](file://lib/core/storage/database_helper.dart)

### Preference Categories
- UI settings: Theme, font size, color scheme, and layout preferences.
- Functional preferences: AI provider configuration, WebDAV synchronization settings, and shortcut bindings.
- Behavioral options: Quick record toggles, notification preferences, and sync scheduling.

These categories are represented by typed models and persisted via the repository.

**Section sources**
- [models.dart](file://lib/config/models.dart)
- [ai_config.dart](file://lib/models/ai_config.dart)
- [webdav_config.dart](file://lib/models/webdav_config.dart)
- [shortcut_config.dart](file://lib/models/shortcut_config.dart)

### Adding New Configuration Options
Steps to add a new configuration option:
1. Define a new model field or category in the configuration models.
2. Add a default value in the defaults provider.
3. Integrate UI to read/write the new setting.
4. Ensure the repository supports persistence for the new key.
5. Test migration and backward compatibility.

```mermaid
flowchart TD
A["Define Model Field"] --> B["Add Default Value"]
B --> C["Wire UI Controls"]
C --> D["Persist via Repository"]
D --> E["Test Migration"]
E --> F["Release"]
```

**Diagram sources**
- [models.dart](file://lib/config/models.dart)
- [defaults.dart](file://lib/config/defaults.dart)
- [config_repository.dart](file://lib/core/storage/config_repository.dart)

**Section sources**
- [models.dart](file://lib/config/models.dart)
- [defaults.dart](file://lib/config/defaults.dart)
- [config_repository.dart](file://lib/core/storage/config_repository.dart)

### Handling Default Values
- On first load, defaults are applied for missing keys.
- UI reads fall back to defaults when no persisted value exists.
- Defaults are written to storage on first encounter to avoid repeated computation.

**Section sources**
- [defaults.dart](file://lib/config/defaults.dart)
- [config_repository.dart](file://lib/core/storage/config_repository.dart)

### Managing Configuration Updates
- Incremental updates: Apply delta changes to existing records.
- Versioned migrations: Track schema/version and apply transformations.
- Validation: Ensure type safety and constraints before persisting.

**Section sources**
- [config_repository.dart](file://lib/core/storage/config_repository.dart)
- [models_test.dart](file://test/config/models_test.dart)

### Configuration Migration and Versioning
- Maintain a version number for the configuration schema.
- On startup, compare current version with stored version.
- Apply migration steps to transform older records to the new schema.
- Ensure idempotent migrations to prevent reapplication issues.

```mermaid
flowchart TD
S["Startup"] --> CheckVer["Check Stored Version"]
CheckVer --> UpToDate{"Is Current?"}
UpToDate --> |Yes| Done["Proceed"]
UpToDate --> |No| Migrate["Run Migrations"]
Migrate --> SaveVer["Save New Version"]
SaveVer --> Done
```

**Diagram sources**
- [config_repository.dart](file://lib/core/storage/config_repository.dart)

**Section sources**
- [config_repository.dart](file://lib/core/storage/config_repository.dart)

## Dependency Analysis
The configuration system exhibits low coupling and high cohesion:
- Models depend only on primitives and enums.
- Repository depends on the database helper.
- Initialization modules abstract platform-specific setup.
- UI pages depend on repository for persistence.

```mermaid
graph LR
Models["config/models.dart"] --> Repo["core/storage/config_repository.dart"]
Defaults["config/defaults.dart"] --> Repo
Repo --> DBH["core/storage/database_helper.dart"]
DBH --> Init["database_init.dart"]
DBH --> InitIO["database_init_io.dart"]
App["app.dart"] --> Repo
Main["main.dart"] --> App
```

**Diagram sources**
- [models.dart](file://lib/config/models.dart)
- [defaults.dart](file://lib/config/defaults.dart)
- [config_repository.dart](file://lib/core/storage/config_repository.dart)
- [database_helper.dart](file://lib/core/storage/database_helper.dart)
- [database_init.dart](file://lib/database_init.dart)
- [database_init_io.dart](file://lib/database_init_io.dart)
- [app.dart](file://lib/app.dart)
- [main.dart](file://lib/main.dart)

**Section sources**
- [models.dart](file://lib/config/models.dart)
- [defaults.dart](file://lib/config/defaults.dart)
- [config_repository.dart](file://lib/core/storage/config_repository.dart)
- [database_helper.dart](file://lib/core/storage/database_helper.dart)
- [database_init.dart](file://lib/database_init.dart)
- [database_init_io.dart](file://lib/database_init_io.dart)
- [app.dart](file://lib/app.dart)
- [main.dart](file://lib/main.dart)

## Performance Considerations
- Minimize IO operations: Batch writes and coalesce frequent updates.
- Use in-memory caching: Keep a lightweight cache of recent values to reduce disk access.
- Lazy initialization: Load defaults lazily only when needed.
- Efficient serialization: Prefer compact binary or JSON encodings for complex models.
- Background writes: Perform persistence off the UI thread to avoid jank.
- Indexing: Ensure the configuration table is indexed by key for fast lookups.

[No sources needed since this section provides general guidance]

## Troubleshooting Guide
Common issues and resolutions:
- Missing defaults: Verify defaults provider includes all keys; initialize missing values on first load.
- Type mismatches: Validate deserialization against model schemas; handle unknown fields gracefully.
- Migration failures: Log version mismatch and rollback strategy; ensure migrations are idempotent.
- Concurrency: Serialize writes to prevent race conditions; use transactions for batch updates.
- Corruption: Implement checksums or version stamps; provide recovery paths.

**Section sources**
- [config_repository.dart](file://lib/core/storage/config_repository.dart)
- [models_test.dart](file://test/config/models_test.dart)

## Conclusion
QNote’s configuration system combines typed models, centralized defaults, and a repository pattern backed by a local database. This design ensures reliable persistence, clear separation of concerns, and extensibility for future preferences. By following the outlined patterns for adding options, handling defaults, and managing migrations, developers can maintain a robust and performant configuration layer.