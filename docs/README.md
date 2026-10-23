# Documentación de Botiquín CCM

## Propósito

Este índice describe el estado técnico representado por el repositorio y sus
migraciones SQL. Está dirigido a desarrollo, soporte, auditoría y continuidad
operativa.

## Documentos principales

1. [Arquitectura técnica](arquitectura-tecnica.md): componentes, seguridad,
   despliegue, flujos críticos, reglas de negocio y límites del sistema.
2. [Modelo de datos](modelo-datos.md): diccionario por dominio, fuentes de verdad,
   estados e invariantes.
3. [Modelo entidad-relación](modelo-entidad-relacion.md): diagramas Mermaid del
   catálogo, inventario, despacho, dispositivos, importaciones y auditoría.
4. [Matriz de pantallas, roles y RPC](matriz-pantallas-rpc.md): trazabilidad desde
   cada pantalla hasta las funciones y entidades que consulta o modifica.

## Documentos operativos especializados

- [Control de sesión](control-sesion.md)
- [Diferencias de inventario](diferencias-inventario.md)
- [Devoluciones a proveedor](supplier-returns-flow.md)
- [Correcciones parciales de despachos](dispatch-item-corrections.md)
- [Productos y dispositivos](productos-dispositivos.md)
- [Seguimiento de venta](seguimiento-venta.md)
- [Inventario y carga diferida](inventario-carga-diferida.md)

## Alcance y criterio de evidencia

- Las tablas y funciones de `supabase/sql/` representan el esquema versionado.
- `app_users`, `app_sessions`, `dispatch_header`, `dispatch_items` y `audit_log`
  son estructuras operativas anteriores al esquema analítico. Sus relaciones se
  documentan a partir de las funciones activas que las consumen.
- Una instalación de Supabase puede contener objetos previos no recreados por
  estas migraciones. Antes de una restauración desde cero debe compararse este
  inventario con `information_schema`, `pg_proc` y los respaldos de producción.
- La documentación explica el comportamiento; no sustituye un respaldo ni una
  validación de migraciones en staging.
