# Matriz de pantallas, roles y RPC

## Criterio

La restricción de una pantalla mejora la UX; la autorización efectiva debe estar
en cada RPC. `Público` significa que la función puede usarse sin sesión, no que
permita escritura irrestricta sobre tablas.

## 1. Acceso y consulta

| Pantalla | Acceso | RPC principales | Datos / efecto |
| --- | --- | --- | --- |
| `index.html` | Público; login para roles | `rpc_pin_login`, `rpc_session_touch`, `rpc_sales_follow_up_public_reasons`, `rpc_sales_follow_up_create`, `rpc_sales_follow_up_recent` | Inicia sesión o registra seguimiento comercial sin mover inventario |
| `availability.html` | Público | `rpc_public_availability_suggest`, `rpc_public_availability_search`; toque opcional de sesión | Consulta `sellable_qty`; no expone vencidos como disponibles |
| `dispatch-menu.html` | `dispatch` | `rpc_session_touch` | Selector entre Farmacia y Dispositivos |

## 2. Farmacia

| Pantalla | Acceso | RPC principales | Datos / efecto |
| --- | --- | --- | --- |
| `dispatch.html` | `dispatch` | `rpc_pharma_lookup`, `dispatch_stock_check`, `rpc_dispatch_submit_cart` | Busca por código, valida acumulado, crea entrega y reservas FEFO |
| `cashier.html` | `cashier`, `admin` | `rpc_dispatch_search`, `rpc_dispatch_get`, `rpc_dispatch_get_by_delivery_no`, `rpc_cashier_validate`, `rpc_cashier_observe` | Valida y descuenta reservas, u observa y libera |
| `catalog.html` | `admin` | `rpc_pharma_catalog_search`, `rpc_pharma_catalog_upsert`, `rpc_pharma_catalog_set_active`, RPC de usuarios | Administra catálogo y usuarios sin borrar historia |
| `purchasing.html` | `admin` | `rpc_purchasing_support`, `rpc_reference_price_set` | Combina stock vendible, rotación, proveedor, costo y referencia |
| `expiration-dashboard.html` | `admin` | `rpc_inventory_expiration_dashboard` | Riesgo por lote usando inventario vivo y fechas de vencimiento |
| `history.html` | `admin` | `rpc_dispatch_search/get/get_by_delivery_no`, `rpc_dispatch_void`, `rpc_dispatch_adjust_item` | Consulta, anulación y corrección parcial trazable |

## 3. Inventario y auditoría

| Área de `inventory-audit.html` | Acceso | Familias RPC | Efecto |
| --- | --- | --- | --- |
| Conteo físico | `admin`, `dispatch`, `cashier` según acción | `rpc_inventory_count_*` | Crea sesión, guarda observaciones, finaliza y muestra historial; contar no mueve stock |
| Diferencias | principalmente `admin` | `rpc_inventory_variance_*` | Segundo conteo, aplicación de stock, seguimiento y resolución |
| Ajuste puntual | `admin` para aplicar | RPC de conteo manual/ajuste | Crea movimiento administrativo trazable |
| Correcciones | `admin` | RPC de reclassificación | Resta un producto y suma otro dentro de una operación controlada |
| Devoluciones | `admin` | `rpc_supplier_return_*` | Borrador, líneas, salida física, anulación previa y conciliación NC |
| Kardex | usuarios autorizados | RPC de auditoría/Kardex | Lectura de movimientos y procedencia |

## 4. Importaciones y dashboard

| Pantalla | Acceso | RPC principales | Datos / efecto |
| --- | --- | --- | --- |
| `imports.html` | `admin` | `rpc_import_overview`, `rpc_import_sales_profit`, `rpc_import_consultations`, `rpc_import_inventory_snapshot`, `rpc_import_purchases` | Registra archivos, lotes, filas normalizadas e incidencias |
| `dashboard.html` | `admin` | `rpc_dashboard_overview`, `rpc_dashboard_price_margin_watch`, `rpc_sales_follow_up_admin_overview/save/set_status/save_reason` | Analítica histórica, valor vendible actual, control de margen y seguimiento |

## 5. Dispositivos

| Pantalla | Acceso | RPC principales | Datos / efecto |
| --- | --- | --- | --- |
| `device-dispatch.html` | `dispatch` | `rpc_device_unit_lookup`, `rpc_device_dispatch_submit` | Entrega unidad exacta como venta o reposición |
| `cashier.html` | `cashier`, `admin` | `rpc_device_cashier_search`, `rpc_device_cashier_get_by_sale_no`, `rpc_device_cashier_validate`, `rpc_device_cashier_observe` | Cambia control de Caja; no descuenta por segunda vez |
| `device-inventory.html` | `admin` | `rpc_device_inventory_overview`, `rpc_device_kardex`, `rpc_device_unit_register`, `rpc_device_units_bulk_register`, RPC `device_product_admin_*`, `rpc_device_inventory_adjustment_*`, `rpc_device_identifier_*` | Catálogo, unidades, carga masiva, ajustes, identidad GS1 y Kardex |
| `history.html` | `admin` | `rpc_device_sales_history`, `rpc_device_sale_detail`, `rpc_device_sale_void` | Histórico, detalle, exportación y anulación con reintegro |

## 6. Efectos de las acciones críticas

| Acción | Cabecera/registro | Reserva | Movimiento producto | Movimiento lote |
| --- | --- | --- | --- | --- |
| Confirmar despacho farmacia | `confirmed` | crea `active` | no | no |
| Validar en Caja | `validated` | `fulfilled` | salida | salida FEFO reservada |
| Observar en Caja | `observed` | `released` | no | no |
| Anular antes de validar | `voided` | `released` | no | no |
| Anular validado | `voided` | conserva evidencia | entrada compensatoria | entrada al lote usado |
| Corregir línea confirmada | conserva entrega | libera diferencia | no | no |
| Corregir línea validada | conserva original y motivo | conserva evidencia | entrada por diferencia | entrada al lote usado |
| Guardar conteo | sesión/ítem | no | no | no |
| Aplicar diferencia admin | caso `applied` | valida restricciones | ajuste | según asignación disponible |
| Aplicar devolución proveedor | documento pendiente NC | no | salida | salida del lote indicado |
| Conciliar nota de crédito | documento conciliado | no | no | no |
| Despachar dispositivo | salida `confirmed` | no aplica | movimiento de unidad | no aplica |
| Validar dispositivo | salida `validated` | no aplica | no adicional | no aplica |
| Anular dispositivo | salida `voided` | no aplica | reintegro de unidad | no aplica |

## 7. Controles transversales esperados en cada RPC de escritura

1. validar token no expirado y usuario activo;
2. validar rol permitido;
3. normalizar y validar parámetros;
4. bloquear la entidad que puede competir con otra sesión;
5. verificar estado vigente dentro de la misma transacción;
6. escribir evento y auditoría con idempotencia;
7. devolver un contrato JSON estable para la interfaz;
8. fallar de forma cerrada si no puede preservar trazabilidad.

La matriz se debe actualizar cuando una página adopte una RPC nueva o cuando una
migración cambie el efecto de una acción existente.
