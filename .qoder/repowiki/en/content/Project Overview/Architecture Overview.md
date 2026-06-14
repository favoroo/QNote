# Architecture Overview

<cite>
**Referenced Files in This Document**
- [app.dart](file://lib/app.dart)
- [main.dart](file://lib/main.dart)
- [app_router.dart](file://lib/core/router/app_router.dart)
- [database_init.dart](file://lib/database_init.dart)
- [database_init_io.dart](file://lib/database_init_io.dart)
- [diary_repository.dart](file://lib/core/storage/diary_repository.dart)
- [database_helper.dart](file://lib/core/storage/database_helper.dart)
- [ai_service.dart](file://lib/core/ai/ai_service.dart)
- [webdav_service.dart](file://lib/core/network/webdav_service.dart)
- [notification_service.dart](file://lib/core/notification/notification_service.dart)
- [AGENTS.md](file://AGENTS.md)
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
This document presents QNote Flutter's architectural overview, emphasizing clean architecture principles with a repository pattern implementation. The system separates concerns across four layers:
- Presentation layer (UI pages)
- Business logic layer (services)
- Data access layer (repositories)
- Data models

It also documents state management via Riverpod providers, the service layer pattern for encapsulating business logic, and observer-style reactive updates. The data flow is illustrated from user interactions through pages → providers → repositories → database and the reverse for updates. Design patterns include MVVM-like structure, factory patterns for platform-specific implementations, and observer patterns for real-time updates.

## Project Structure
QNote Flutter organizes code by functional domains and architectural layers:
- lib/config: configuration and constants
- lib/core: cross-cutting services (AI, network, storage, notification, router)
- lib/pages: UI pages implementing presentation logic
- lib/widgets: reusable UI components
- lib/providers: Riverpod provider definitions
- lib/models: data models and domain entities
- lib/database_init.dart and lib/database_init_io.dart: platform-specific database initialization
- lib/app.dart and lib/main.dart: application bootstrap and routing

```mermaid
graph TB
subgraph "Presentation Layer"
Pages["Pages<br/>DiaryPage, Editor Views"]
Widgets["Widgets<br/>Reusable UI Components"]
end
subgraph "State Management"
Providers["Riverpod Providers<br/>AsyncNotifier, StateProvider"]
end
subgraph "Business Logic Layer"
Services["Services<br/>AI, Network, Notification"]
end
subgraph "Data Access Layer"
Repositories["Repositories<br/>DiaryRepository, ConfigRepository"]
DBHelper["DatabaseHelper<br/>SQL/SQLite Abstraction"]
end
subgraph "Platform Layer"
PlatformIO["database_init_io.dart<br/>Platform Factory"]
end
Pages --> Providers
Widgets --> Providers
Providers --> Repositories
Repositories --> DBHelper
Services -. "Encapsulate business logic" .-> Repositories
Providers --> Services
PlatformIO --> DBHelper
```

**Diagram sources**
- [app_router.dart:27-57](file://lib/core/router/app_router.dart#L27-L57)
- [database_init.dart](file://lib/database_init.dart)
- [database_init_io.dart:1-1](file://lib/database_init_io.dart#L1-L1)
- [database_helper.dart](file://lib/core/storage/database_helper.dart)
- [diary_repository.dart](file://lib/core/storage/diary_repository.dart)

**Section sources**
- [app.dart](file://lib/app.dart)
- [main.dart](file://lib/main.dart)
- [app_router.dart:27-57](file://lib/core/router/app_router.dart#L27-L57)

## Core Components
This section outlines the primary architectural components and their responsibilities.

- Application bootstrap and routing:
  - The app initializes routing and navigation using a dedicated router provider, defining shell routes and nested routes for pages like the diary editor.
  - The main entry point sets up the application shell and navigation scaffold.

- State management with Riverpod:
  - Async data is managed using AsyncNotifierProvider and AsyncNotifier.
  - Simple state uses StateProvider.
  - One-off reads use FutureProvider.family.
  - Service instances are provided via Provider.
  - Providers are invalidated or refreshed after data changes to trigger reactive updates.

- Business logic services:
  - AI service encapsulates AI-related operations.
  - WebDAV service handles synchronization tasks.
  - Notification service manages push notifications and reminders.

- Data access layer:
  - Repositories implement CRUD operations with unified method signatures (getAll, getById, insert, update, softDelete, hardDelete, search).
  - Soft delete semantics filter out deleted records by default.
  - All write operations log changes for synchronization.

- Platform-specific initialization:
  - Platform-specific database factory initialization is handled separately to support different platforms.

**Section sources**
- [AGENTS.md:71-102](file://AGENTS.md#L71-L102)
- [app_router.dart:27-57](file://lib/core/router/app_router.dart#L27-L57)
- [database_init.dart](file://lib/database_init.dart)
- [database_init_io.dart:1-1](file://lib/database_init_io.dart#L1-L1)
- [diary_repository.dart](file://lib/core/storage/diary_repository.dart)
- [database_helper.dart](file://lib/core/storage/database_helper.dart)
- [ai_service.dart](file://lib/core/ai/ai_service.dart)
- [webdav_service.dart](file://lib/core/network/webdav_service.dart)
- [notification_service.dart](file://lib/core/notification/notification_service.dart)

## Architecture Overview
QNote Flutter follows a layered architecture with clear separation of concerns:
- Presentation layer: UI pages and widgets consume Riverpod providers to render state and handle user interactions.
- State management: Riverpod providers orchestrate state transitions and coordinate between UI and services.
- Business logic: Services encapsulate domain-specific logic and coordinate with repositories.
- Data access: Repositories abstract persistence and expose a consistent interface to the business logic.
- Data models: Entities define the shape of stored data and provide serialization helpers.

```mermaid
graph TB
UI["UI Pages & Widgets"] --> RP["Riverpod Providers"]
RP --> SVC["Business Logic Services"]
SVC --> REPO["Repositories"]
REPO --> DB["DatabaseHelper / Storage"]
subgraph "Presentation"
UI
end
subgraph "State Management"
RP
end
subgraph "Business Logic"
SVC
end
subgraph "Data Access"
REPO
DB
end
```

**Diagram sources**
- [app_router.dart:27-57](file://lib/core/router/app_router.dart#L27-L57)
- [AGENTS.md:71-102](file://AGENTS.md#L71-L102)
- [diary_repository.dart](file://lib/core/storage/diary_repository.dart)
- [database_helper.dart](file://lib/core/storage/database_helper.dart)

## Detailed Component Analysis

### State Management with Riverpod
- Async data loading uses AsyncNotifierProvider with AsyncNotifier to manage loading, data, and error states.
- Simple state updates use StateProvider.
- One-off reads use FutureProvider.family for parameterized queries.
- Service instances are provided via Provider to maintain singletons.
- After data mutations, providers are invalidated or refreshed to propagate changes reactively.

```mermaid
sequenceDiagram
participant UI as "UI Widget"
participant RP as "Riverpod Provider"
participant SVC as "Business Service"
participant REPO as "Repository"
participant DB as "DatabaseHelper"
UI->>RP : "Read state"
RP->>SVC : "Invoke business operation"
SVC->>REPO : "Perform CRUD"
REPO->>DB : "Execute SQL"
DB-->>REPO : "Result"
REPO-->>SVC : "Domain model"
SVC-->>RP : "Updated state"
RP-->>UI : "Rebuild with new state"
```

**Diagram sources**
- [AGENTS.md:71-102](file://AGENTS.md#L71-L102)
- [diary_repository.dart](file://lib/core/storage/diary_repository.dart)
- [database_helper.dart](file://lib/core/storage/database_helper.dart)

**Section sources**
- [AGENTS.md:71-102](file://AGENTS.md#L71-L102)

### Service Layer Pattern
- Services encapsulate business logic and coordinate between UI and repositories.
- Examples include AI service for AI-driven features, WebDAV service for synchronization, and notification service for reminders.

```mermaid
classDiagram
class AIService {
+processContent(input) Future
}
class WebDAVService {
+sync() Future
}
class NotificationService {
+scheduleReminder(task) Future
}
class DiaryRepository {
+getAll() Stream
+insert(record) Future
+update(id, changes) Future
+softDelete(id) Future
}
class DatabaseHelper {
+query(sql) Future
+execute(sql) Future
}
AIService --> DiaryRepository : "uses"
WebDAVService --> DiaryRepository : "uses"
NotificationService --> DiaryRepository : "reads"
DiaryRepository --> DatabaseHelper : "persists"
```

**Diagram sources**
- [ai_service.dart](file://lib/core/ai/ai_service.dart)
- [webdav_service.dart](file://lib/core/network/webdav_service.dart)
- [notification_service.dart](file://lib/core/notification/notification_service.dart)
- [diary_repository.dart](file://lib/core/storage/diary_repository.dart)
- [database_helper.dart](file://lib/core/storage/database_helper.dart)

**Section sources**
- [ai_service.dart](file://lib/core/ai/ai_service.dart)
- [webdav_service.dart](file://lib/core/network/webdav_service.dart)
- [notification_service.dart](file://lib/core/notification/notification_service.dart)

### Repository Pattern Implementation
- Repositories provide a unified interface for data operations with consistent method signatures.
- Soft delete semantics and change logging ensure data integrity and synchronization readiness.
- Model contracts require id, toMap/fromMap, and copyWith for immutability and serialization.

```mermaid
flowchart TD
Start(["Repository Operation"]) --> Method{"Method Type"}
Method --> |getAll| QueryAll["Query All Records"]
Method --> |getById| QueryOne["Query By Id"]
Method --> |insert| InsertOp["Insert Record"]
Method --> |update| UpdateOp["Update Record"]
Method --> |softDelete| SoftDeleteOp["Mark As Deleted"]
Method --> |hardDelete| HardDeleteOp["Remove From Storage"]
Method --> |search| SearchOp["Search With Filters"]
InsertOp --> Log["Log Change"]
UpdateOp --> Log
SoftDeleteOp --> Log
HardDeleteOp --> Log
QueryAll --> Filter["Filter Deleted (Default)"]
QueryOne --> Filter
SearchOp --> Filter
Filter --> Return["Return Domain Model(s)"]
Log --> Return
```

**Diagram sources**
- [AGENTS.md:84-91](file://AGENTS.md#L84-L91)
- [diary_repository.dart](file://lib/core/storage/diary_repository.dart)

**Section sources**
- [AGENTS.md:84-91](file://AGENTS.md#L84-L91)
- [diary_repository.dart](file://lib/core/storage/diary_repository.dart)

### Platform-Specific Initialization (Factory Pattern)
- Platform-specific database factory initialization is isolated to platform files, enabling factory-style selection of implementations per platform.
- This supports consistent behavior across iOS/Android/Web/Windows targets.

```mermaid
sequenceDiagram
participant App as "App Startup"
participant Init as "database_init.dart"
participant IO as "database_init_io.dart"
participant DB as "DatabaseHelper"
App->>Init : "Initialize database"
Init->>IO : "Delegate to platform impl"
IO-->>DB : "Configure platform factory"
DB-->>Init : "Ready"
Init-->>App : "Database initialized"
```

**Diagram sources**
- [database_init.dart](file://lib/database_init.dart)
- [database_init_io.dart:1-1](file://lib/database_init_io.dart#L1-L1)
- [database_helper.dart](file://lib/core/storage/database_helper.dart)

**Section sources**
- [database_init.dart](file://lib/database_init.dart)
- [database_init_io.dart:1-1](file://lib/database_init_io.dart#L1-L1)

### Data Flow: User Interactions to Persistence
- User interactions in pages trigger provider updates.
- Providers invoke services, which coordinate repositories.
- Repositories persist changes via DatabaseHelper and log modifications.
- Reverse flow occurs for updates and refreshes, propagating reactive changes to UI.

```mermaid
sequenceDiagram
participant User as "User"
participant Page as "DiaryPage"
participant Provider as "Riverpod Provider"
participant Service as "Business Service"
participant Repo as "DiaryRepository"
participant DB as "DatabaseHelper"
User->>Page : "Tap Save"
Page->>Provider : "Call save action"
Provider->>Service : "Invoke save"
Service->>Repo : "insert(record)"
Repo->>DB : "INSERT INTO diary"
DB-->>Repo : "Success"
Repo-->>Service : "Saved record"
Service-->>Provider : "Updated state"
Provider-->>Page : "Rebuild with saved data"
```

**Diagram sources**
- [app_router.dart:27-57](file://lib/core/router/app_router.dart#L27-L57)
- [AGENTS.md:71-102](file://AGENTS.md#L71-L102)
- [diary_repository.dart](file://lib/core/storage/diary_repository.dart)
- [database_helper.dart](file://lib/core/storage/database_helper.dart)

**Section sources**
- [app_router.dart:27-57](file://lib/core/router/app_router.dart#L27-L57)
- [AGENTS.md:71-102](file://AGENTS.md#L71-L102)

## Dependency Analysis
The system exhibits low coupling and high cohesion across layers:
- Presentation depends on Riverpod providers, not on services or repositories directly.
- Services depend on repositories, not on UI.
- Repositories depend on DatabaseHelper, not on UI or services.
- Platform initialization is decoupled and injected at startup.

```mermaid
graph LR
UI["UI Pages & Widgets"] --> RP["Riverpod Providers"]
RP --> SVC["Business Services"]
SVC --> REPO["Repositories"]
REPO --> DB["DatabaseHelper"]
INIT["Platform Init"] --> DB
```

**Diagram sources**
- [app_router.dart:27-57](file://lib/core/router/app_router.dart#L27-L57)
- [AGENTS.md:71-102](file://AGENTS.md#L71-L102)
- [diary_repository.dart](file://lib/core/storage/diary_repository.dart)
- [database_helper.dart](file://lib/core/storage/database_helper.dart)
- [database_init.dart](file://lib/database_init.dart)

**Section sources**
- [AGENTS.md:71-102](file://AGENTS.md#L71-L102)

## Performance Considerations
- Prefer asynchronous loading with Riverpod AsyncNotifier to avoid blocking the UI thread.
- Use provider invalidation judiciously to minimize unnecessary rebuilds.
- Batch repository operations where possible to reduce database round-trips.
- Leverage platform-specific initialization to optimize database factory configuration.

## Troubleshooting Guide
- State not updating after mutation:
  - Ensure providers are invalidated or refreshed after repository writes.
  - Verify that services rethrow exceptions for proper error propagation to UI.
- Repository errors:
  - Confirm unified method signatures and soft-delete filtering defaults.
  - Check that change logging is invoked for all write operations.
- Platform initialization issues:
  - Validate platform-specific database factory initialization is called during app startup.

**Section sources**
- [AGENTS.md:71-102](file://AGENTS.md#L71-L102)
- [AGENTS.md:94-102](file://AGENTS.md#L94-L102)

## Conclusion
QNote Flutter employs a clean architecture with Riverpod-driven state management, a robust repository pattern, and service-layer encapsulation. The design promotes separation of concerns, testability, and scalability while supporting platform-specific implementations. Reactive updates are achieved through observer-style provider invalidation, ensuring a responsive and consistent user experience.