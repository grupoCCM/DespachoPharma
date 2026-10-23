# Modelo de datos

## 1. Convenciones

- Las claves nuevas son mayoritariamente UUID.
- `external_code` identifica el artículo en el ERP.
- `barcode` identifica el producto farmacéutico; no sustituye el lote.
- `serial_code` o un identificador GS1 identifica una unidad de dispositivo.
- `created_at` registra el instante técnico; las fechas del documento se guardan
  por separado cuando tienen significado contable u operativo.
- Las cantidades de inventario se reconstruyen; no se corrigen editando un total.

## 2. Identidad y operación heredada

Estas entidades son anteriores al esquema analítico versionado, pero siguen
siendo centrales para las RPC activas.

| Entidad | Función | Relaciones principales |
| --- | --- | --- |
| `app_users` | Usuario, rol, PIN y estado | sesiones, despachos, validaciones, auditoría |
| `app_sessions` | Token hash, expiración y revocación | pertenece a `app_users` |
| `dispatch_header` | Cabecera de entrega farmacéutica | usuario, expediente, estado, ítems |
| `dispatch_items` | Producto y cantidad efectiva/original | cabecera, reservas, correcciones |
| `audit_log` | Eventos operativos inmutables | usuario y objeto afectado |

Estados de despacho usados por el flujo: `draft`, `confirmed`, `validated`,
`observed` y `voided`. Las migraciones posteriores añaden versión de reserva y
metadatos de corrección sin borrar la entrega original.

## 3. Catálogo, compras y ventas importadas

| Entidad | Contenido |
| --- | --- |
| `medicines` | Ficha maestra, códigos, nombre, clasificación, precios, costo, banderas y barcode |
| `medicine_reference_prices` | Historial de precio de referencia por archivo |
| `medicine_reference_price_overrides` | Precio de referencia manual vigente y trazable |
| `suppliers` | Proveedor normalizado y código externo |
| `purchase_documents` | Documento de compra del ERP |
| `purchase_items` | Producto, cantidad, total y costo unitario calculado |
| `patients` | Expediente externo y nombre disponible |
| `sales_documents` | Venta importada por número, comprobante, fecha y paciente |
| `sales_items` | Unidades, venta neta, costo, utilidad y márgenes |
| `consultation_visits` | Visita/consulta importada para análisis de penetración |

Las ventas importadas son evidencia comercial del ERP. Los despachos son eventos
operativos internos. Se pueden conciliar, pero no deben duplicarse ni asumir que
son el mismo documento.

## 4. Inventario y lotes

| Entidad | Contenido |
| --- | --- |
| `inventory_snapshots` | Corte importado con fecha y totales |
| `inventory_snapshot_items` | Existencia y costo por producto en el corte |
| `inventory_lots` | Lote, vencimiento y cantidad de origen |
| `inventory_movements` | Delta inmutable por producto después del corte |
| `inventory_lot_movements` | Delta inmutable asignado a lote |
| `inventory_reservations` | Cantidad comprometida por despacho y lote |
| `inventory_reclassifications` | Corrección trazable entre productos |

Vistas:

- `vw_inventory_live`: corte más movimientos posteriores.
- `vw_inventory_lot_live`: saldo reconstruido por lote.
- `vw_lot_stock_state`: físico, vencido, reservado, retenido y vendible por lote.
- `vw_product_stock_state`: consolidado semántico por producto.
- `vw_inventory_sellable`: compatibilidad de lecturas vendibles anteriores.

Estados de reserva: activa mientras la entrega está confirmada, cumplida al
validar y liberada al observar, anular o corregir antes de Caja.

## 5. Conteos y diferencias

| Entidad | Contenido |
| --- | --- |
| `inventory_count_sessions` | Sesión, alcance, usuario, inicio, cierre o cancelación |
| `inventory_count_session_items` | Esperado congelado, conteo y diferencia observada |
| `inventory_manual_counts` | Conteos/ajustes puntuales heredados |
| `inventory_variance_cases` | Expediente de diferencia confirmada |
| `inventory_variance_case_events` | Seguimiento cronológico de investigación |
| `inventory_variance_resolutions` | Unidades resueltas, tipo y posible movimiento |

Invariantes:

- finalizar un conteo no modifica disponibilidad;
- el segundo conteo no lo realiza el primer contador;
- aplicar stock requiere rol admin y crea movimiento idempotente;
- resolver administrativamente no implica siempre mover inventario;
- el conteo y su resultado global permanecen reimprimibles.

## 6. Devoluciones a proveedor

| Entidad | Contenido |
| --- | --- |
| `supplier_return_documents` | Hoja, proveedor, estado y posterior nota de crédito |
| `supplier_return_items` | Producto, lote, cantidad, motivo y movimientos vinculados |

Estados: `draft`, `applied_pending_credit_note`,
`credit_note_reconciled`, `voided`.

Una línea aplicada referencia tanto el movimiento de producto como el de lote.
Los lotes referenciados no pueden eliminarse durante una importación posterior.

## 7. Rotación, compra sugerida y dashboard

| Entidad | Contenido |
| --- | --- |
| `rotation_runs` | Periodo y corte de una corrida de rotación |
| `rotation_metrics` | Rotación, cobertura, tendencia y puntos objetivo |
| `purchase_recommendations` | Sugerido, costo, riesgo y acción |
| `sales_goals` | Meta mensual |
| `holidays` | Días excluibles de proyecciones |

`rpc_purchasing_support` combina inventario vendible actual, rotación importada,
compras/proveedor, costos y precio de referencia. El inventario vencido no debe
evitar una recomendación de compra.

## 8. Dispositivos

| Entidad | Contenido |
| --- | --- |
| `device_products` | Catálogo separado, marca, modelo, precio, costo y reglas |
| `device_units` | Unidad serializada, lote, vencimiento, costo y estado |
| `device_unit_identifiers` | Identificadores alternos/GS1 de una unidad |
| `device_sales` | Cabecera por expediente, tipo, estado y usuarios |
| `device_sale_items` | Unidad exacta entregada, precio, costo y tipo |
| `device_inventory_movements` | Entrada, venta, reposición, reverso o ajuste |
| `device_inventory_adjustments` | Orden administrativa de retiro/reintegro/corrección |
| `device_admin_audit` | Cambios controlados a unidades |
| `device_product_admin_audit` | Cambios al catálogo |

Estados de unidad: `available`, `sold`, `inactive`, `damaged`, `lost`, `retired`.
Estados de salida: `confirmed`, `validated`, `observed`, `voided`. El estado de
Caja y el estado físico de la unidad son conceptos relacionados pero distintos.

## 9. Seguimiento de venta

| Entidad | Contenido |
| --- | --- |
| `sales_follow_up_reasons` | Catálogo administrable de motivos |
| `sales_follow_up_events` | Expediente, resultado, motivo, comentario y despacho opcional |
| `sales_follow_up_audit` | Ediciones y anulaciones administrativas |

Resultados: `no_purchase` y `partial_purchase`. Estado del registro: activo o
anulado. El texto del motivo se conserva como snapshot para no alterar historia
cuando el catálogo se renombra.

## 10. Procedencia de importaciones

| Entidad | Contenido |
| --- | --- |
| `source_files` | Tipo, nombre, hash, tamaño y última detección |
| `import_batches` | Ejecución, modo, estado, resumen y notas |
| `import_batch_files` | Archivo dentro del lote, filas y rango de fechas |
| `import_validation_issues` | Advertencias y errores estructurados |

Los tipos operativos actuales son ventas/utilidad, consultas, inventario y
compras. Las filas inválidas pueden omitirse y registrarse como advertencia según
el importador; por eso el resultado del lote debe revisarse, no solo el mensaje de
éxito HTTP.

## 11. Reglas de borrado y conservación

- Catálogos con historia se desactivan; no se eliminan.
- Movimientos de inventario y auditoría son registros históricos.
- Despachos y salidas se anulan o corrigen mediante eventos compensatorios.
- Un lote referenciado por devolución, reserva o movimiento debe conservarse.
- Las cargas nuevas no deben borrar evidencia requerida por operaciones previas.
- La edición directa de cantidades calculadas está fuera del modelo permitido.
