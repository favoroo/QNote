# Core Features

<cite>
**Referenced Files in This Document**
- [main.dart](file://lib/main.dart)
- [app.dart](file://lib/app.dart)
- [database_init.dart](file://lib/database_init.dart)
- [database_init_io.dart](file://lib/database_init_io.dart)
- [ai_service.dart](file://lib/core/ai/ai_service.dart)
- [ai_role_service.dart](file://lib/core/ai/ai_role_service.dart)
- [model_fetch_service.dart](file://lib/core/ai/model_fetch_service.dart)
- [sync_scheduler.dart](file://lib/core/network/sync_scheduler.dart)
- [webdav_service.dart](file://lib/core/network/webdav_service.dart)
- [diary_repository.dart](file://lib/core/storage/diary_repository.dart)
- [config_repository.dart](file://lib/core/storage/config_repository.dart)
- [folder_repository.dart](file://lib/core/storage/folder_repository.dart)
- [fixed_event_repository.dart](file://lib/core/storage/fixed_event_repository.dart)
- [daily_score_repository.dart](file://lib/core/storage/daily_score_repository.dart)
- [color_mark_repository.dart](file://lib/core/storage/color_mark_repository.dart)
- [image_repository.dart](file://lib/core/storage/image_repository.dart)
- [database_helper.dart](file://lib/core/storage/database_helper.dart)
- [ai_config.dart](file://lib/models/ai_config.dart)
- [webdav_config.dart](file://lib/models/webdav_config.dart)
- [ai_provider.dart](file://lib/providers/ai_provider.dart)
- [ai_config_page.dart](file://lib/pages/settings/ai_config_page.dart)
- [MainActivity.kt](file://android/app/src/main/java/com/appone/qnote_flutter/MainActivity.kt)
- [QuickRecordActivity.kt](file://android/app/src/main/java/com/appone/qnote_flutter/QuickRecordActivity.kt)
- [TodoWidgetProvider.kt](file://android/app/src/main/java/com/appone/qnote_flutter/TodoWidgetProvider.kt)
- [QuickRecordWidgetProvider.kt](file://android/app/src/main/java/com/appone/qnote_flutter/QuickRecordWidgetProvider.kt)
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
10. [Appendices](#appendices)

## Introduction
This document explains QNote Flutter's core features and how they integrate to deliver a cohesive productivity experience. The primary functional areas are:
- Diary Management: capture daily entries, organize by date and tags, and maintain structured logs
- Note Taking: flexible text-based notes with metadata and image support
- Todo Management: fixed events and daily tasks with completion tracking
- AI Integration: configurable AI providers, role-based prompts, and model fetching
- Cloud Synchronization: automated WebDAV backup and restore with conflict-aware change logs
- Widget Support: Android home screen widgets for quick recording and todo lists

These features share a modular design with clear separation of concerns: storage repositories, network services, AI services, and UI providers. They interoperate via shared repositories and services, enabling independent development while maintaining system cohesion.

## Project Structure
The application follows a layered, feature-oriented structure:
- Entry points: main.dart initializes the app, app.dart defines routing and providers, database initialization files set up local persistence
- Core services: ai, network, storage, notification, router, logger
- Models: domain entities for AI configurations, WebDAV settings, and others
- Providers: Riverpod provider definitions for reactive state
- Pages: UI screens including settings and feature-specific views
- Android integration: native activities and widget providers for home screen experiences

```mermaid
graph TB
subgraph "Entry Points"
M["lib/main.dart"]
A["lib/app.dart"]
DIO["lib/database_init_io.dart"]
DI["lib/database_init.dart"]
end
subgraph "Core Services"
AI["core/ai/*"]
NET["core/network/*"]
ST["core/storage/*"]
LOG["core/logger/*"]
end
subgraph "Models"
MC["models/ai_config.dart"]
WC["models/webdav_config.dart"]
end
subgraph "Providers"
AP["providers/ai_provider.dart"]
end
subgraph "Android"
MA["android/.../MainActivity.kt"]
QRA["android/.../QuickRecordActivity.kt"]
TWP["android/.../TodoWidgetProvider.kt"]
QRWP["android/.../QuickRecordWidgetProvider.kt"]
end
M --> A
A --> ST
A --> NET
A --> AI
A --> AP
ST --> MC
ST --> WC
NET --> WC
AI --> MC
DIO --> ST
DI --> ST
MA --> A
QRA --> A
TWP --> A
QRWP --> A
```

**Diagram sources**
- [main.dart](file://lib/main.dart)
- [app.dart](file://lib/app.dart)
- [database_init.dart](file://lib/database_init.dart)
- [database_init_io.dart](file://lib/database_init_io.dart)
- [ai_service.dart](file://lib/core/ai/ai_service.dart)
- [sync_scheduler.dart](file://lib/core/network/sync_scheduler.dart)
- [diary_repository.dart](file://lib/core/storage/diary_repository.dart)
- [config_repository.dart](file://lib/core/storage/config_repository.dart)
- [ai_config.dart](file://lib/models/ai_config.dart)
- [webdav_config.dart](file://lib/models/webdav_config.dart)
- [ai_provider.dart](file://lib/providers/ai_provider.dart)
- [MainActivity.kt](file://android/app/src/main/java/com/appone/qnote_flutter/MainActivity.kt)
- [QuickRecordActivity.kt](file://android/app/src/main/java/com/appone/qnote_flutter/QuickRecordActivity.kt)
- [TodoWidgetProvider.kt](file://android/app/src/main/java/com/appone/qnote_flutter/TodoWidgetProvider.kt)
- [QuickRecordWidgetProvider.kt](file://android/app/src/main/java/com/appone/qnote_flutter/QuickRecordWidgetProvider.kt)

**Section sources**
- [main.dart](file://lib/main.dart)
- [app.dart](file://lib/app.dart)
- [database_init.dart](file://lib/database_init.dart)
- [database_init_io.dart](file://lib/database_init_io.dart)

## Core Components
This section outlines the principal components and their responsibilities:

- Storage Layer
  - Repositories encapsulate CRUD operations for diaries, configs, folders, fixed events, daily scores, color marks, and images
  - DatabaseHelper centralizes database initialization and migrations
  - Example repositories: [diary_repository.dart](file://lib/core/storage/diary_repository.dart), [config_repository.dart](file://lib/core/storage/config_repository.dart), [folder_repository.dart](file://lib/core/storage/folder_repository.dart), [fixed_event_repository.dart](file://lib/core/storage/fixed_event_repository.dart), [daily_score_repository.dart](file://lib/core/storage/daily_score_repository.dart), [color_mark_repository.dart](file://lib/core/storage/color_mark_repository.dart), [image_repository.dart](file://lib/core/storage/image_repository.dart), [database_helper.dart](file://lib/core/storage/database_helper.dart)

- Network Layer
  - SyncScheduler orchestrates periodic and on-demand synchronization using WebDAV
  - WebDAV service handles upload/download and backup cleanup
  - Example: [sync_scheduler.dart](file://lib/core/network/sync_scheduler.dart), [webdav_service.dart](file://lib/core/network/webdav_service.dart)

- AI Layer
  - AiService manages chat interactions and integrates with configurable providers
  - AiRoleService supports role-based prompting and context filtering
  - ModelFetchService retrieves available models from providers
  - Example: [ai_service.dart](file://lib/core/ai/ai_service.dart), [ai_role_service.dart](file://lib/core/ai/ai_role_service.dart), [model_fetch_service.dart](file://lib/core/ai/model_fetch_service.dart)

- Models
  - AiConfig and WebdavConfig define persistent configuration structures
  - Example: [ai_config.dart](file://lib/models/ai_config.dart), [webdav_config.dart](file://lib/models/webdav_config.dart)

- Providers
  - Riverpod providers expose reactive state for AI configuration, roles, temperatures, and context filters
  - Example: [ai_provider.dart](file://lib/providers/ai_provider.dart)

- Android Integration
  - Native activities and widget providers enable quick recording and todo list widgets on the home screen
  - Example: [MainActivity.kt](file://android/app/src/main/java/com/appone/qnote_flutter/MainActivity.kt), [QuickRecordActivity.kt](file://android/app/src/main/java/com/appone/qnote_flutter/QuickRecordActivity.kt), [TodoWidgetProvider.kt](file://android/app/src/main/java/com/appone/qnote_flutter/TodoWidgetProvider.kt), [QuickRecordWidgetProvider.kt](file://android/app/src/main/java/com/appone/qnote_flutter/QuickRecordWidgetProvider.kt)

**Section sources**
- [diary_repository.dart](file://lib/core/storage/diary_repository.dart)
- [config_repository.dart](file://lib/core/storage/config_repository.dart)
- [folder_repository.dart](file://lib/core/storage/folder_repository.dart)
- [fixed_event_repository.dart](file://lib/core/storage/fixed_event_repository.dart)
- [daily_score_repository.dart](file://lib/core/storage/daily_score_repository.dart)
- [color_mark_repository.dart](file://lib/core/storage/color_mark_repository.dart)
- [image_repository.dart](file://lib/core/storage/image_repository.dart)
- [database_helper.dart](file://lib/core/storage/database_helper.dart)
- [sync_scheduler.dart](file://lib/core/network/sync_scheduler.dart)
- [webdav_service.dart](file://lib/core/network/webdav_service.dart)
- [ai_service.dart](file://lib/core/ai/ai_service.dart)
- [ai_role_service.dart](file://lib/core/ai/ai_role_service.dart)
- [model_fetch_service.dart](file://lib/core/ai/model_fetch_service.dart)
- [ai_config.dart](file://lib/models/ai_config.dart)
- [webdav_config.dart](file://lib/models/webdav_config.dart)
- [ai_provider.dart](file://lib/providers/ai_provider.dart)
- [MainActivity.kt](file://android/app/src/main/java/com/appone/qnote_flutter/MainActivity.kt)
- [QuickRecordActivity.kt](file://android/app/src/main/java/com/appone/qnote_flutter/QuickRecordActivity.kt)
- [TodoWidgetProvider.kt](file://android/app/src/main/java/com/appone/qnote_flutter/TodoWidgetProvider.kt)
- [QuickRecordWidgetProvider.kt](file://android/app/src/main/java/com/appone/qnote_flutter/QuickRecordWidgetProvider.kt)

## Architecture Overview
The system architecture emphasizes modularity and separation of concerns:
- UI layer depends on Riverpod providers for reactive state
- Feature services depend on storage repositories for persistence
- Network and AI services are pluggable and configurable
- Android widgets integrate via native providers and activities

```mermaid
graph TB
UI["UI Screens<br/>and Widgets"] --> RP["Riverpod Providers"]
RP --> SRV["Feature Services"]
SRV --> REPO["Storage Repositories"]
SRV --> NET["Network Services"]
SRV --> AI["AI Services"]
NET --> WD["WebDAV"]
AI --> CFG["AI Configurations"]
REPO --> DB["Local Database"]
```

**Diagram sources**
- [app.dart](file://lib/app.dart)
- [ai_provider.dart](file://lib/providers/ai_provider.dart)
- [sync_scheduler.dart](file://lib/core/network/sync_scheduler.dart)
- [ai_service.dart](file://lib/core/ai/ai_service.dart)
- [diary_repository.dart](file://lib/core/storage/diary_repository.dart)
- [config_repository.dart](file://lib/core/storage/config_repository.dart)

## Detailed Component Analysis

### Diary Management
Diary management centers around capturing, organizing, and retrieving daily entries. The flow:
- UI captures diary content and metadata
- DiaryRepository persists entries and supports queries by date and tags
- SyncScheduler uploads changes to WebDAV for cloud backup
- On restore, entries are rehydrated locally

```mermaid
sequenceDiagram
participant UI as "Diary UI"
participant Repo as "DiaryRepository"
participant DB as "Local Database"
participant Sync as "SyncScheduler"
participant Net as "WebDAV Service"
UI->>Repo : "Save/Update/Delete entry"
Repo->>DB : "Persist changes"
Sync->>Net : "Upload database snapshot"
Net-->>Sync : "Upload result"
Sync-->>UI : "Sync status update"
```

**Diagram sources**
- [diary_repository.dart](file://lib/core/storage/diary_repository.dart)
- [sync_scheduler.dart](file://lib/core/network/sync_scheduler.dart)
- [webdav_service.dart](file://lib/core/network/webdav_service.dart)

**Section sources**
- [diary_repository.dart](file://lib/core/storage/diary_repository.dart)
- [sync_scheduler.dart](file://lib/core/network/sync_scheduler.dart)
- [webdav_config.dart](file://lib/models/webdav_config.dart)

### Note Taking
Notes are flexible text-based records with optional metadata and images. The flow:
- UI composes notes and attaches images
- ImageRepository stores media assets
- ConfigRepository manages note-related preferences
- Changes are persisted via repositories and synchronized via WebDAV

```mermaid
flowchart TD
Start(["Compose Note"]) --> AddText["Add Text Content"]
AddText --> AddImage["Attach Images"]
AddImage --> Save["Persist via Config/Folder Repositories"]
Save --> Sync["Trigger SyncScheduler"]
Sync --> End(["Note Saved"])
```

**Diagram sources**
- [image_repository.dart](file://lib/core/storage/image_repository.dart)
- [config_repository.dart](file://lib/core/storage/config_repository.dart)
- [sync_scheduler.dart](file://lib/core/network/sync_scheduler.dart)

**Section sources**
- [image_repository.dart](file://lib/core/storage/image_repository.dart)
- [config_repository.dart](file://lib/core/storage/config_repository.dart)

### Todo Management
Fixed events and daily tasks are managed through dedicated repositories:
- FixedEventRepository tracks recurring or scheduled events
- DailyScoreRepository maintains completion metrics
- UI updates statuses and persists via repositories
- SyncScheduler ensures todos synchronize across devices

```mermaid
sequenceDiagram
participant UI as "Todo UI"
participant FER as "FixedEventRepository"
participant DSR as "DailyScoreRepository"
participant DB as "Local Database"
participant Sync as "SyncScheduler"
UI->>FER : "Create/Update Event"
UI->>DSR : "Update Completion Score"
FER->>DB : "Persist event"
DSR->>DB : "Persist score"
Sync->>DB : "Periodic sync"
```

**Diagram sources**
- [fixed_event_repository.dart](file://lib/core/storage/fixed_event_repository.dart)
- [daily_score_repository.dart](file://lib/core/storage/daily_score_repository.dart)
- [sync_scheduler.dart](file://lib/core/network/sync_scheduler.dart)

**Section sources**
- [fixed_event_repository.dart](file://lib/core/storage/fixed_event_repository.dart)
- [daily_score_repository.dart](file://lib/core/storage/daily_score_repository.dart)

### AI Integration
AI integration supports configurable providers, role-based prompts, and model discovery:
- AiConfig defines provider, model, base URL, and API key
- AiService coordinates chat requests and responses
- AiRoleService applies role templates and context filters
- ModelFetchService retrieves available models from providers
- Settings page validates configurations and measures latency

```mermaid
sequenceDiagram
participant UI as "AI Settings Page"
participant Prov as "AiProvider"
participant AIS as "AiService"
participant Role as "AiRoleService"
participant MF as "ModelFetchService"
participant CFG as "AiConfig"
UI->>Prov : "Select provider/model"
Prov->>CFG : "Load current config"
UI->>AIS : "Test connection"
AIS->>MF : "Fetch models"
MF-->>AIS : "Model list"
AIS-->>UI : "Latency and status"
UI->>Role : "Apply role/context"
Role-->>UI : "Prompt ready"
```

**Diagram sources**
- [ai_provider.dart](file://lib/providers/ai_provider.dart)
- [ai_service.dart](file://lib/core/ai/ai_service.dart)
- [ai_role_service.dart](file://lib/core/ai/ai_role_service.dart)
- [model_fetch_service.dart](file://lib/core/ai/model_fetch_service.dart)
- [ai_config_page.dart](file://lib/pages/settings/ai_config_page.dart)
- [ai_config.dart](file://lib/models/ai_config.dart)

**Section sources**
- [ai_provider.dart](file://lib/providers/ai_provider.dart)
- [ai_service.dart](file://lib/core/ai/ai_service.dart)
- [ai_role_service.dart](file://lib/core/ai/ai_role_service.dart)
- [model_fetch_service.dart](file://lib/core/ai/model_fetch_service.dart)
- [ai_config_page.dart](file://lib/pages/settings/ai_config_page.dart)
- [ai_config.dart](file://lib/models/ai_config.dart)

### Cloud Synchronization
Cloud synchronization automates backup and restore:
- SyncScheduler reads WebDAV configuration and sets up periodic sync
- WebDAV service uploads database snapshots and downloads backups
- Change counts and pending logs drive conflict awareness
- UI surfaces sync status and errors

```mermaid
flowchart TD
Init["Init SyncScheduler"] --> LoadCfg["Load WebDAV Config"]
LoadCfg --> Setup["Setup Periodic Timer"]
Setup --> Trigger{"Sync Triggered"}
Trigger --> |Upload| Upload["Upload Database Snapshot"]
Trigger --> |Restore| Download["Download Backup"]
Upload --> UpdateLogs["Refresh Pending Changes"]
Download --> UpdateLogs
UpdateLogs --> Done["Sync Complete"]
```

**Diagram sources**
- [sync_scheduler.dart](file://lib/core/network/sync_scheduler.dart)
- [webdav_service.dart](file://lib/core/network/webdav_service.dart)
- [webdav_config.dart](file://lib/models/webdav_config.dart)

**Section sources**
- [sync_scheduler.dart](file://lib/core/network/sync_scheduler.dart)
- [webdav_service.dart](file://lib/core/network/webdav_service.dart)
- [webdav_config.dart](file://lib/models/webdav_config.dart)

### Widget Support
Android home screen widgets provide quick actions:
- QuickRecordWidgetProvider enables instant diary entries
- TodoWidgetProvider displays and toggles todo items
- QuickRecordActivity supports voice or text input
- MainActivity integrates core navigation and settings

```mermaid
sequenceDiagram
participant Home as "Home Screen"
participant QRWP as "QuickRecordWidgetProvider"
participant QRA as "QuickRecordActivity"
participant TWP as "TodoWidgetProvider"
participant App as "MainActivity"
Home->>QRWP : "Tap Quick Record"
QRWP->>QRA : "Launch input activity"
QRA->>App : "Persist entry via repositories"
Home->>TWP : "Open Todo Widget"
TWP->>App : "Toggle todo status"
```

**Diagram sources**
- [QuickRecordWidgetProvider.kt](file://android/app/src/main/java/com/appone/qnote_flutter/QuickRecordWidgetProvider.kt)
- [QuickRecordActivity.kt](file://android/app/src/main/java/com/appone/qnote_flutter/QuickRecordActivity.kt)
- [TodoWidgetProvider.kt](file://android/app/src/main/java/com/appone/qnote_flutter/TodoWidgetProvider.kt)
- [MainActivity.kt](file://android/app/src/main/java/com/appone/qnote_flutter/MainActivity.kt)

**Section sources**
- [QuickRecordWidgetProvider.kt](file://android/app/src/main/java/com/appone/qnote_flutter/QuickRecordWidgetProvider.kt)
- [QuickRecordActivity.kt](file://android/app/src/main/java/com/appone/qnote_flutter/QuickRecordActivity.kt)
- [TodoWidgetProvider.kt](file://android/app/src/main/java/com/appone/qnote_flutter/TodoWidgetProvider.kt)
- [MainActivity.kt](file://android/app/src/main/java/com/appone/qnote_flutter/MainActivity.kt)

## Dependency Analysis
The following diagram shows key dependencies among modules:

```mermaid
graph LR
UI["UI Screens"] --> RP["Providers"]
RP --> SRV["Feature Services"]
SRV --> REPO["Repositories"]
SRV --> NET["Network"]
SRV --> AI["AI"]
NET --> CFG["WebdavConfig"]
AI --> CFG
REPO --> DB["Database"]
```

**Diagram sources**
- [app.dart](file://lib/app.dart)
- [ai_provider.dart](file://lib/providers/ai_provider.dart)
- [sync_scheduler.dart](file://lib/core/network/sync_scheduler.dart)
- [ai_service.dart](file://lib/core/ai/ai_service.dart)
- [diary_repository.dart](file://lib/core/storage/diary_repository.dart)
- [config_repository.dart](file://lib/core/storage/config_repository.dart)
- [webdav_config.dart](file://lib/models/webdav_config.dart)
- [ai_config.dart](file://lib/models/ai_config.dart)

**Section sources**
- [app.dart](file://lib/app.dart)
- [ai_provider.dart](file://lib/providers/ai_provider.dart)
- [sync_scheduler.dart](file://lib/core/network/sync_scheduler.dart)
- [ai_service.dart](file://lib/core/ai/ai_service.dart)
- [diary_repository.dart](file://lib/core/storage/diary_repository.dart)
- [config_repository.dart](file://lib/core/storage/config_repository.dart)
- [webdav_config.dart](file://lib/models/webdav_config.dart)
- [ai_config.dart](file://lib/models/ai_config.dart)

## Performance Considerations
- Minimize UI rebuilds by using Riverpod selectors and efficient state updates
- Batch repository writes to reduce database contention during bulk operations
- Use incremental WebDAV sync strategies to avoid large transfers
- Cache frequently accessed AI models and configurations to reduce latency
- Offload heavy computations to background threads and avoid blocking the UI thread

## Troubleshooting Guide
Common issues and resolutions:
- Sync fails silently
  - Verify WebDAV configuration and credentials
  - Check periodic timer setup and error logging
  - Review last sync time and pending change counts
  - Reference: [sync_scheduler.dart](file://lib/core/network/sync_scheduler.dart), [webdav_config.dart](file://lib/models/webdav_config.dart)

- AI configuration test fails
  - Confirm provider URL, API key, and model availability
  - Measure latency and log errors in the settings page
  - Reference: [ai_config_page.dart](file://lib/pages/settings/ai_config_page.dart), [ai_service.dart](file://lib/core/ai/ai_service.dart)

- Widget does not update
  - Ensure widget providers are registered and updated
  - Verify repository state after UI actions
  - Reference: [QuickRecordWidgetProvider.kt](file://android/app/src/main/java/com/appone/qnote_flutter/QuickRecordWidgetProvider.kt), [TodoWidgetProvider.kt](file://android/app/src/main/java/com/appone/qnote_flutter/TodoWidgetProvider.kt)

**Section sources**
- [sync_scheduler.dart](file://lib/core/network/sync_scheduler.dart)
- [webdav_config.dart](file://lib/models/webdav_config.dart)
- [ai_config_page.dart](file://lib/pages/settings/ai_config_page.dart)
- [ai_service.dart](file://lib/core/ai/ai_service.dart)
- [QuickRecordWidgetProvider.kt](file://android/app/src/main/java/com/appone/qnote_flutter/QuickRecordWidgetProvider.kt)
- [TodoWidgetProvider.kt](file://android/app/src/main/java/com/appone/qnote_flutter/TodoWidgetProvider.kt)

## Conclusion
QNote Flutter’s modular architecture enables independent development of features while ensuring seamless integration. The storage, network, and AI layers provide robust foundations, while Riverpod and Android widgets enhance usability. By following the established patterns—repository-first persistence, provider-driven state, and pluggable services—new features can be introduced consistently and efficiently.

## Appendices
- Integration guidelines for new features
  - Define a repository under core/storage for persistence
  - Create a service under core/network or core/ai as appropriate
  - Expose reactive state via Riverpod providers
  - Wire UI screens to providers and repositories
  - Add tests for critical flows and edge cases