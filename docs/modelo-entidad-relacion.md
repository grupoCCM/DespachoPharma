# Modelo entidad-relación

## Cómo leer los diagramas

Los diagramas se dividen por dominio para conservar legibilidad. Las entidades
operativas heredadas se incluyen porque son consumidas por las RPC actuales,
aunque su creación original no aparece en `001_pharma_core_schema.sql`.
Algunas uniones heredadas, como `dispatch_items` con `medicines`, son relaciones
lógicas por código de barras y no claves foráneas declaradas.

## 1. Identidad y despacho farmacéutico

```mermaid
erDiagram
  APP_USERS ||--o{ APP_SESSIONS : inicia
  APP_USERS ||--o{ DISPATCH_HEADER : confirma
  DISPATCH_HEADER ||--|{ DISPATCH_ITEMS : contiene
  DISPATCH_ITEMS }o--|| MEDICINES : identifica
  DISPATCH_ITEMS ||--o{ INVENTORY_RESERVATIONS : reserva
  INVENTORY_LOTS ||--o{ INVENTORY_RESERVATIONS : asigna
  DISPATCH_ITEMS ||--o{ DISPATCH_ITEM_ADJUSTMENTS : corrige
  INVENTORY_RESERVATIONS }o--o| INVENTORY_LOT_MOVEMENTS : cumple
  DISPATCH_HEADER ||--o{ AUDIT_LOG : audita
  APP_USERS ||--o{ AUDIT_LOG : ejecuta

  APP_USERS {
    uuid id PK
    text display_name
    user_role role
    boolean active
  }
  APP_SESSIONS {
    uuid id PK
    uuid user_id FK
    text token_hash
    timestamptz expires_at
    timestamptz revoked_at
  }
  DISPATCH_HEADER {
    uuid id PK
    bigint delivery_no
    text expediente
    text status
    int stock_reservation_version
  }
  DISPATCH_ITEMS {
    uuid id PK
    uuid dispatch_id FK
    text barcode
    numeric original_qty
    numeric qty
    text line_status
  }
  INVENTORY_RESERVATIONS {
    uuid id PK
    uuid dispatch_item_id FK
    uuid lot_id FK
    numeric qty
    text status
  }
```

## 2. Catálogo, compras, ventas y pacientes

```mermaid
erDiagram
  MEDICINES ||--o{ PURCHASE_ITEMS : comprado
  SUPPLIERS ||--o{ PURCHASE_DOCUMENTS : emite
  PURCHASE_DOCUMENTS ||--|{ PURCHASE_ITEMS : contiene
  MEDICINES ||--o{ SALES_ITEMS : vendido
  PATIENTS ||--o{ SALES_DOCUMENTS : compra
  SALES_DOCUMENTS ||--|{ SALES_ITEMS : contiene
  PATIENTS ||--o{ CONSULTATION_VISITS : consulta
  MEDICINES ||--o{ MEDICINE_REFERENCE_PRICES : referencia
  MEDICINES ||--o| MEDICINE_REFERENCE_PRICE_OVERRIDES : ajuste

  MEDICINES {
    uuid id PK
    int external_code UK
    text barcode
    text name
    boolean active
    numeric last_cost
  }
  PURCHASE_DOCUMENTS {
    uuid id PK
    int external_purchase_no
    date purchase_date
    uuid supplier_id FK
  }
  PURCHASE_ITEMS {
    uuid id PK
    uuid purchase_document_id FK
    uuid medicine_id FK
    numeric qty
    numeric line_total
  }
  SALES_DOCUMENTS {
    uuid id PK
    int external_sale_no
    date sale_date
    uuid patient_id FK
  }
  SALES_ITEMS {
    uuid id PK
    uuid sales_document_id FK
    uuid medicine_id FK
    numeric qty
    numeric net_sale
    numeric profit
  }
```

## 3. Inventario, lotes y devoluciones

```mermaid
erDiagram
  INVENTORY_SNAPSHOTS ||--|{ INVENTORY_SNAPSHOT_ITEMS : congela
  MEDICINES ||--o{ INVENTORY_SNAPSHOT_ITEMS : cuantifica
  INVENTORY_SNAPSHOT_ITEMS ||--o{ INVENTORY_LOTS : detalla
  MEDICINES ||--o{ INVENTORY_MOVEMENTS : mueve
  INVENTORY_LOTS ||--o{ INVENTORY_LOT_MOVEMENTS : mueve
  INVENTORY_MOVEMENTS ||--o{ INVENTORY_LOT_MOVEMENTS : desglosa
  SUPPLIER_RETURN_DOCUMENTS ||--|{ SUPPLIER_RETURN_ITEMS : contiene
  SUPPLIERS ||--o{ SUPPLIER_RETURN_DOCUMENTS : recibe
  MEDICINES ||--o{ SUPPLIER_RETURN_ITEMS : devuelve
  INVENTORY_LOTS ||--o{ SUPPLIER_RETURN_ITEMS : identifica
  INVENTORY_MOVEMENTS ||--o| SUPPLIER_RETURN_ITEMS : respalda
  INVENTORY_LOT_MOVEMENTS ||--o| SUPPLIER_RETURN_ITEMS : respalda

  INVENTORY_SNAPSHOTS {
    uuid id PK
    date snapshot_date
    numeric total_units
    numeric total_value
  }
  INVENTORY_SNAPSHOT_ITEMS {
    uuid id PK
    uuid snapshot_id FK
    uuid medicine_id FK
    numeric stock_qty
    numeric unit_cost
  }
  INVENTORY_LOTS {
    uuid id PK
    uuid inventory_snapshot_item_id FK
    uuid medicine_id FK
    text lot_no
    date expires_at
    numeric qty
  }
  INVENTORY_MOVEMENTS {
    uuid id PK
    uuid medicine_id FK
    text movement_type
    numeric qty_delta
    text source_event_key UK
  }
  INVENTORY_LOT_MOVEMENTS {
    uuid id PK
    uuid lot_id FK
    uuid inventory_movement_id FK
    numeric qty_delta
  }
```

## 4. Conteos y resolución de diferencias

```mermaid
erDiagram
  APP_USERS ||--o{ INVENTORY_COUNT_SESSIONS : inicia
  INVENTORY_COUNT_SESSIONS ||--|{ INVENTORY_COUNT_SESSION_ITEMS : contiene
  MEDICINES ||--o{ INVENTORY_COUNT_SESSION_ITEMS : cuenta
  INVENTORY_COUNT_SESSION_ITEMS ||--o| INVENTORY_VARIANCE_CASES : origina
  INVENTORY_VARIANCE_CASES ||--o{ INVENTORY_VARIANCE_CASE_EVENTS : documenta
  INVENTORY_VARIANCE_CASES ||--o{ INVENTORY_VARIANCE_RESOLUTIONS : resuelve
  INVENTORY_MOVEMENTS ||--o| INVENTORY_VARIANCE_RESOLUTIONS : ajusta
  APP_USERS ||--o{ INVENTORY_VARIANCE_CASE_EVENTS : registra
  APP_USERS ||--o{ INVENTORY_VARIANCE_RESOLUTIONS : autoriza

  INVENTORY_COUNT_SESSIONS {
    uuid id PK
    text name
    text status
    timestamptz started_at
    timestamptz closed_at
  }
  INVENTORY_COUNT_SESSION_ITEMS {
    uuid id PK
    uuid session_id FK
    uuid medicine_id FK
    numeric expected_qty
    numeric counted_qty
    numeric variance_qty
  }
  INVENTORY_VARIANCE_CASES {
    uuid id PK
    uuid count_item_id FK
    numeric verified_qty
    numeric confirmed_variance_qty
    text stock_adjustment_status
    text investigation_status
  }
```

## 5. Dispositivos serializados

```mermaid
erDiagram
  DEVICE_PRODUCTS ||--o{ DEVICE_UNITS : clasifica
  DEVICE_UNITS ||--o{ DEVICE_UNIT_IDENTIFIERS : identifica
  DEVICE_SALES ||--|{ DEVICE_SALE_ITEMS : contiene
  DEVICE_UNITS ||--o{ DEVICE_SALE_ITEMS : entrega
  DEVICE_UNITS ||--o{ DEVICE_INVENTORY_MOVEMENTS : mueve
  DEVICE_SALES ||--o{ DEVICE_INVENTORY_MOVEMENTS : origina
  DEVICE_UNITS ||--o{ DEVICE_INVENTORY_ADJUSTMENTS : ajusta
  APP_USERS ||--o{ DEVICE_SALES : confirma
  APP_USERS ||--o{ DEVICE_ADMIN_AUDIT : ejecuta
  DEVICE_PRODUCTS ||--o{ DEVICE_PRODUCT_ADMIN_AUDIT : audita

  DEVICE_PRODUCTS {
    uuid id PK
    int external_code UK
    text name
    text category
    numeric default_cost
    boolean active
  }
  DEVICE_UNITS {
    uuid id PK
    uuid device_product_id FK
    text serial_code
    text normalized_serial UK
    text status
    numeric cost
  }
  DEVICE_SALES {
    uuid id PK
    bigint sale_no UK
    text expediente
    text sale_type
    text status
  }
  DEVICE_SALE_ITEMS {
    uuid id PK
    uuid sale_id FK
    uuid device_unit_id FK
    numeric price
    numeric cost
  }
```

## 6. Importaciones y seguimiento comercial

```mermaid
erDiagram
  SOURCE_FILES ||--o{ IMPORT_BATCH_FILES : participa
  IMPORT_BATCHES ||--o{ IMPORT_BATCH_FILES : agrupa
  IMPORT_BATCHES ||--o{ IMPORT_VALIDATION_ISSUES : reporta
  SALES_FOLLOW_UP_REASONS ||--o{ SALES_FOLLOW_UP_EVENTS : explica
  DISPATCH_HEADER ||--o{ SALES_FOLLOW_UP_EVENTS : vincula
  SALES_FOLLOW_UP_EVENTS ||--o{ SALES_FOLLOW_UP_AUDIT : audita
  APP_USERS ||--o{ SALES_FOLLOW_UP_AUDIT : administra

  SOURCE_FILES {
    uuid id PK
    text source_type
    text original_filename
    text sha256
  }
  IMPORT_BATCHES {
    uuid id PK
    text batch_key UK
    text mode
    text status
    jsonb source_summary
  }
  SALES_FOLLOW_UP_EVENTS {
    uuid id PK
    text expediente
    text outcome
    uuid reason_id FK
    uuid dispatch_id FK
    text status
  }
```

## 7. Vistas derivadas

Las vistas no son nuevas fuentes de eventos; proyectan las entidades anteriores:

```mermaid
flowchart LR
  SNAP[inventory_snapshot_items] --> LIVE[vw_inventory_live]
  MOV[inventory_movements] --> LIVE
  LOT[inventory_lots] --> LOTLIVE[vw_inventory_lot_live]
  LOTMOV[inventory_lot_movements] --> LOTLIVE
  LOTLIVE --> LOTSTATE[vw_lot_stock_state]
  LIVE --> PRODSTATE[vw_product_stock_state]
  LOTSTATE --> PRODSTATE
  RES[inventory_reservations activas] --> PRODSTATE
  PRODSTATE --> AV[Disponibilidad]
  PRODSTATE --> PUR[Compras sugeridas]
  LOTSTATE --> FEFO[Despacho FEFO]
  LOTSTATE --> EXP[Vencimientos]
```
